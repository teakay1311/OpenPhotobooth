import Foundation
import CoreImage
import CoreGraphics

/// CompositeRenderer — DUY NHẤT tạo hình học cho live preview / review / export (I-05, §7.6).
/// Thứ tự lớp §7.2:
///   Canvas (color/alpha) → Background → Photo slots theo zOrder → Foreground overlay.
/// Mỗi slot: source (đã normalize) → skin smoothing → preset → intensity blend → adjustments
///   → crop/placement → mask (rect/rounded/ellipse) → rotate slot → composite.
public enum CompositeRenderer {
    public static var geometryVersion: Int { 1 }

    // MARK: - Entry

    public static func render(model: CompositionModel) throws -> CGImage {
        let W = model.options.targetWidth
        let H = model.options.targetHeight
        guard W >= 1, H >= 1 else { throw AppError.invalidState("Kích thước render không hợp lệ") }
        let snap = model.snapshot
        let scale = Double(W) / Double(snap.canvasWidth)
        let canvasRect = CGRect(x: 0, y: 0, width: W, height: H)

        // Base: màu canvas hoặc trong suốt (PNG alpha §11.2)
        var canvas: CIImage
        if model.options.transparentBackground {
            canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvasRect)
        } else {
            let c = CIColor(cgColor: model.options.matteColor)
            canvas = CIImage(color: c).cropped(to: canvasRect)
        }

        // Background layer
        if let bg = snap.background, let image = model.assetImages[bg.assetID] {
            if let layer = placeLayer(CIImage(cgImage: image), canvasWidth: W, canvasHeight: H, placement: bg.placement) {
                canvas = layer.composited(over: canvas)
            }
        }

        // Photo slots theo zOrder
        let slots = snap.slots.sorted { $0.zOrder < $1.zOrder }
        for slot in slots {
            guard let source = model.sources[slot.captureIndex] else { continue }
            if let slotLayer = renderSlot(slot: slot, source: source.image, model: model,
                                          scale: scale, canvasWidth: W, canvasHeight: H) {
                canvas = slotLayer.composited(over: canvas)
            }
        }

        // Foreground overlay (luôn trên ảnh — §18.5)
        if let fg = snap.foreground, let image = model.assetImages[fg.assetID] {
            if let layer = placeLayer(CIImage(cgImage: image), canvasWidth: W, canvasHeight: H, placement: fg.placement) {
                canvas = layer.composited(over: canvas)
            }
        }

        guard let output = CIContextHolder.shared.context.createCGImage(canvas, from: canvasRect) else {
            throw AppError.exportFailed("Không tạo được ảnh render")
        }
        return output
    }

    // MARK: - Slot

    static func renderSlot(slot: SnapshotSlot, source: CGImage, model: CompositionModel,
                           scale: Double, canvasWidth: Int, canvasHeight: Int) -> CIImage? {
        // Slot pixel trong target space (top-left coords)
        let slotTopLeft = slot.rect.pixelRect(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        guard slotTopLeft.width >= 1, slotTopLeft.height >= 1 else { return nil }
        // Chuyển sang hệ CI (y-up)
        let slotRectCI = CGRect(x: slotTopLeft.minX,
                                y: Double(canvasHeight) - slotTopLeft.maxY,
                                width: slotTopLeft.width, height: slotTopLeft.height)

        var photo = CIImage(cgImage: source)
        let resolved = ResolvedPhotoParams.resolve(defaults: model.defaults,
                                                   override: model.overrides[slot.captureIndex])

        // 1. Skin smoothing (trước preset — §8.4)
        if resolved.skinSmooth > 0.001,
           let faces = model.faces[slot.captureIndex], !faces.isEmpty,
           let smoothed = SkinSmoothingFilter.apply(ciImage: photo, faces: faces, strength: resolved.skinSmooth) {
            photo = smoothed
        }
        // 2. Preset + intensity + adjustments
        photo = ImageColorPipeline.applyColor(photo, resolved: resolved)

        // 3. Crop/placement (§7.3)
        let cropMode = model.cropModes[slot.id] ?? slot.defaultCropMode
        let placement = (model.placements[slot.id] ?? PhotoPlacement())
        let (s, t) = SlotGeometry.photoTransform(
            sourceWidth: CGFloat(source.width), sourceHeight: CGFloat(source.height),
            slotPixel: slotTopLeft, cropMode: cropMode, placement: placement)
        let drawnW = CGFloat(source.width) * s
        let drawnH = CGFloat(source.height) * s
        // (t.x, t.y) là góc trên trái của ảnh vẽ trong hệ top-left → đổi sang CI
        let ciX = t.x
        let ciY = CGFloat(canvasHeight) - (t.y + drawnH)
        // Cắt content trong slot rect (chưa xoay) — I-05: preview/export cùng công thức
        var content = photo.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: ciX, ty: ciY))
            .cropped(to: slotRectCI)

        // 4. Xoay slot quanh tâm trước, rồi mask cùng lúc để cạnh slot xoay khớp (§7.3)
        if slot.rotationDegrees.truncatingRemainder(dividingBy: 360) != 0 {
            let radians = CGFloat(-slot.rotationDegrees * Double.pi / 180) // clockwise màn hình
            let center = CGPoint(x: slotRectCI.midX, y: slotRectCI.midY)
            let rt = CGAffineTransform(translationX: center.x, y: center.y)
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
            let bbox = FrameGeometry.rotatedPixelBounds(slot.rect, rotationDegrees: slot.rotationDegrees,
                                                        canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            let bboxCI = CGRect(x: bbox.minX, y: CGFloat(canvasHeight) - bbox.maxY,
                                width: bbox.width, height: bbox.height).insetBy(dx: -2, dy: -2)
            content = content.transformed(by: rt).clampedToExtent().cropped(to: bboxCI)
        }

        // 5. Mask slot (§7.3) — mask vẽ trong hệ canvas CI
        let radius = SlotGeometry.cornerRadiusPixels(slot.cornerRadius, slotPixel: slotTopLeft,
                                                     canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        guard var maskImage = MaskBuilder.slotMask(canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                                                   slotRect: slotRectCI, maskType: slot.maskType,
                                                   cornerRadius: radius) else { return nil }
        // Offset cần áp cho mask sau khi round-trip qua CGImage (extent reset về (0,0))
        var maskOffset: CGPoint? = nil
        if slot.rotationDegrees.truncatingRemainder(dividingBy: 360) != 0 {
            let radians = CGFloat(-slot.rotationDegrees * Double.pi / 180)
            let center = CGPoint(x: slotRectCI.midX, y: slotRectCI.midY)
            let rt = CGAffineTransform(translationX: center.x, y: center.y)
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
            let bbox = FrameGeometry.rotatedPixelBounds(slot.rect, rotationDegrees: slot.rotationDegrees,
                                                        canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            let bboxCI = CGRect(x: bbox.minX, y: CGFloat(canvasHeight) - bbox.maxY,
                                width: bbox.width, height: bbox.height).insetBy(dx: -2, dy: -2)
            let maskCI = CIImage(cgImage: maskImage)
            if let rotated = CIContextHolder.shared.context.createCGImage(
                maskCI.transformed(by: rt).clampedToExtent().cropped(to: bboxCI), from: bboxCI) {
                // CIImage(cgImage:) đặt extent tại (0,0) — phải dịch mask về đúng vị trí bbox trên canvas,
                // nếu không mask lệch (-bbox.minX, -bbox.minY) so với content và slot bị che mất.
                maskImage = rotated
                maskOffset = CGPoint(x: bboxCI.minX, y: bboxCI.minY)
            }
        }
        let canvasRect = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvasRect)
        let blend = CIFilter(name: "CIBlendWithMask")
        blend?.setValue(content, forKey: kCIInputImageKey)
        blend?.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        var maskImageCI = CIImage(cgImage: maskImage)
        if let offset = maskOffset {
            maskImageCI = maskImageCI.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
        }
        blend?.setValue(maskImageCI, forKey: kCIInputMaskImageKey)
        // 6. Composite trong vùng canvas
        let masked = blend?.outputImage?.cropped(to: canvasRect)
        return masked
    }

    // MARK: - Lớp background/foreground

    static func placeLayer(_ image: CIImage, canvasWidth: Int, canvasHeight: Int, placement: PlacementKind) -> CIImage? {
        let W = CGFloat(canvasWidth), H = CGFloat(canvasHeight)
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let canvasRect = CGRect(x: 0, y: 0, width: W, height: H)
        var s: CGFloat, tx: CGFloat, ty: CGFloat
        switch placement {
        case .aspectFill, .fillCrop:
            s = max(W / extent.width, H / extent.height)
            tx = (W - extent.width * s) / 2
            ty = (H - extent.height * s) / 2
        case .aspectFit:
            s = min(W / extent.width, H / extent.height)
            tx = (W - extent.width * s) / 2
            ty = (H - extent.height * s) / 2
        case .stretchToCanvas:
            s = 1
            tx = 0; ty = 0
            let stretched = image.transformed(by: CGAffineTransform(scaleX: W / extent.width, y: H / extent.height))
            return stretched.cropped(to: canvasRect)
        }
        return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .cropped(to: canvasRect)
    }
}

/// Vẽ mask slot trên bitmap context (hệ y-up khớp CI).
public enum MaskBuilder {
    public static func slotMask(canvasWidth: Int, canvasHeight: Int,
                                slotRect: CGRect, maskType: MaskType, cornerRadius: CGFloat) -> CGImage? {
        guard canvasWidth >= 1, canvasHeight >= 1 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: canvasWidth, height: canvasHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        switch maskType {
        case .rectangle:
            ctx.fill(slotRect)
        case .roundedRectangle:
            let path = CGPath(roundedRect: slotRect, cornerWidth: max(cornerRadius, 0.5), cornerHeight: max(cornerRadius, 0.5), transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        case .ellipse:
            ctx.fillEllipse(in: slotRect)
        }
        return ctx.makeImage()
    }
}

extension Int {
    func toDouble() -> CGFloat { CGFloat(self) }
}
