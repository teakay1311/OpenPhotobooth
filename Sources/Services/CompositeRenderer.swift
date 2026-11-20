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
    static let renderCacheVersion = 2

    // MARK: - Entry

    public static func render(model: CompositionModel) throws -> CGImage {
        let W = model.options.targetWidth
        let H = model.options.targetHeight
        guard W >= 1, H >= 1 else { throw AppError.invalidState("Kích thước render không hợp lệ") }
        let snap = model.snapshot
        let scale = Double(W) / Double(snap.canvasWidth)
        let canvasRect = CGRect(x: 0, y: 0, width: W, height: H)

        // D2-A09: Màu canvas nằm dưới lớp nền, ảnh và overlay (§7.2, §11.2).
        // Quy tắc thống nhất:
        // - Trắng mặc định (#FFFFFFFF / #FFFFFF) thiếu dấu hiệu explicitWhite -> canvas trong suốt (alpha 0).
        // - Trắng chọn tường minh (explicitWhite == true) -> trắng đục (1,1,1,1).
        // - Các màu khác -> dùng đúng màu RGBA và alpha đã lưu.
        let hex = snap.backgroundColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        let isWhiteHex = (hex == "FFFFFFFF" || hex == "FFFFFF")
        let canvasColor: CIColor
        if isWhiteHex {
            if snap.explicitWhite == true {
                canvasColor = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            } else {
                canvasColor = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            }
        } else {
            let cg = ColorHex.toCGColor(snap.backgroundColorHex)
            canvasColor = CIColor(cgColor: cg)
        }
        var canvas = CIImage(color: canvasColor).cropped(to: canvasRect)

        // Background layer
        if let bg = snap.background, let image = model.assetImages[bg.assetID] {
            let pixels = try ImageNormalizer.orientedFrameLayer(image, orientation: bg.imageOrientation)
            if let layer = placeLayer(pixels, canvasWidth: W, canvasHeight: H, placement: bg.placement) {
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
            let pixels = try ImageNormalizer.orientedFrameLayer(image, orientation: fg.imageOrientation)
            if let layer = placeLayer(pixels, canvasWidth: W, canvasHeight: H, placement: fg.placement) {
                canvas = layer.composited(over: canvas)
            }
        }

        // D2-A09: JPG (hoặc transparentBackground == false) ghép kết quả còn trong suốt lên nền trắng
        if !model.options.transparentBackground {
            let whiteMatte = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: canvasRect)
            canvas = canvas.composited(over: whiteMatte)
        }

        guard let output = CIContextHolder.shared.context.createCGImage(canvas, from: canvasRect) else {
            throw AppError.exportFailed("Không tạo được ảnh render")
        }
        return output
    }

    // MARK: - Slot

    static func renderSlot(slot: SnapshotSlot, source: CGImage, model: CompositionModel,
                           scale: Double, canvasWidth: Int, canvasHeight: Int) -> CIImage? {
        let mask = MaskBuilder.CanvasSlot(slot: slot, width: canvasWidth, height: canvasHeight)
        let slotTopLeft = mask.topLeft
        guard mask.canRender else { return nil }
        let slotRectCI = mask.rect

        var photo = CIImage(cgImage: source)
        let resolved = ResolvedPhotoParams.resolve(defaults: model.defaults,
                                                   override: model.overrides[slot.captureIndex])

        // 1. Preset + intensity + adjustments (§8.4)
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

        if mask.rotates {
            content = content.transformed(by: mask.rotation).clampedToExtent().cropped(to: mask.bounds)
        }

        guard let maskImage = mask.image(in: mask.canvas) else { return nil }
        var maskImageCI = CIImage(cgImage: maskImage)
        if mask.rotates, let rotated = CIContextHolder.shared.context.createCGImage(
            maskImageCI.transformed(by: mask.rotation).clampedToExtent().cropped(to: mask.bounds), from: mask.bounds) {
            maskImageCI = CIImage(cgImage: rotated).transformed(by: CGAffineTransform(
                translationX: mask.bounds.minX, y: mask.bounds.minY))
        }
        let transparent = CIImage(color: .clear).cropped(to: mask.canvas)
        let blend = CIFilter(name: "CIBlendWithMask")
        blend?.setValue(content, forKey: kCIInputImageKey)
        blend?.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        blend?.setValue(maskImageCI, forKey: kCIInputMaskImageKey)
        // 6. Composite trong vùng canvas
        let masked = blend?.outputImage?.cropped(to: mask.canvas)
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
    struct CanvasSlot {
        let topLeft: CGRect
        let rect: CGRect
        let canvas: CGRect
        let radius: CGFloat
        let maskType: MaskType
        let rotation: CGAffineTransform
        let bounds: CGRect

        var canRender: Bool { rect.width >= 1 && rect.height >= 1 }
        var rotates: Bool { !rotation.isIdentity }

        init(slot: SnapshotSlot, width: Int, height: Int) {
            canvas = CGRect(x: 0, y: 0, width: width, height: height)
            topLeft = slot.rect.pixelRect(canvasWidth: width, canvasHeight: height)
            rect = CGRect(x: topLeft.minX, y: Double(height) - topLeft.maxY,
                          width: topLeft.width, height: topLeft.height)
            radius = SlotGeometry.cornerRadiusPixels(slot.cornerRadius, slotPixel: topLeft,
                                                      canvasWidth: width, canvasHeight: height)
            maskType = slot.maskType
            if slot.rotationDegrees.truncatingRemainder(dividingBy: 360) == 0 {
                rotation = .identity
                bounds = rect
            } else {
                rotation = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                    .concatenating(CGAffineTransform(rotationAngle: -slot.rotationDegrees * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
                let topBounds = FrameGeometry.rotatedPixelBounds(slot.rect, rotationDegrees: slot.rotationDegrees,
                                                                 canvasWidth: width, canvasHeight: height)
                bounds = CGRect(x: topBounds.minX, y: Double(height) - topBounds.maxY,
                                width: topBounds.width, height: topBounds.height).insetBy(dx: -2, dy: -2)
            }
        }

        func image(in area: CGRect) -> CGImage? {
            MaskBuilder.slotMask(canvasWidth: Int(area.width), canvasHeight: Int(area.height),
                                 slotRect: rect.offsetBy(dx: -area.minX, dy: -area.minY),
                                 maskType: maskType, cornerRadius: radius)
        }

        func coverage(in tile: CGRect) throws -> CIImage {
            let clear = CIImage(color: .clear).cropped(to: tile)
            let source = rotates ? tile.applying(rotation.inverted()).insetBy(dx: -2, dy: -2)
                .integral.intersection(canvas) : tile
            guard !source.isEmpty else { return clear }
            guard let bitmap = image(in: source) else { throw AppError.frameFileCorrupt }
            var coverage = CIImage(cgImage: bitmap).transformed(by: CGAffineTransform(
                translationX: source.minX, y: source.minY))
            if rotates {
                coverage = coverage.transformed(by: rotation).clampedToExtent().cropped(to: bounds)
            }
            return coverage.composited(over: clear).cropped(to: tile)
        }
    }

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
