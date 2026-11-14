import ImageIO
import Foundation
import CoreGraphics
import CoreText

/// FrameSeeder (§6.4, §1.4, §3.1.3): 3 khung built-in + 8 preset theo seedVersion idempotent.
/// Khung vẽ bằng CoreGraphics/CoreText lúc seed — không dùng ảnh bản quyền, không UI mock.
public enum FrameSeeder {
    public static let seedVersion = "1"

    public static func seedIfNeeded(db: SQLiteDatabase, frameRepo: FrameRepository,
                                    presetRepo: PresetRepository, assets: AssetStore) throws {
        let rows = try db.query("SELECT value FROM app_state WHERE key='seedVersion'")
        if let v = rows.first?["value"].stringValue, v == seedVersion { return }
        try seedPresets(presetRepo: presetRepo)
        try seedFrames(frameRepo: frameRepo, assets: assets)
        try db.run("""
            INSERT INTO app_state(key, value, updated_at_ms) VALUES('seedVersion', ?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at_ms=excluded.updated_at_ms
            """, [.text(seedVersion), .int(Time.nowMs())])
        EventBus.shared.post(.frameLibraryChanged(frameID: nil))
        EventBus.shared.post(.presetChanged)
    }

    static func seedPresets(presetRepo: PresetRepository) throws {
        let existing = try presetRepo.listPresets()
        let existingNames = Set(existing.map { $0.name.lowercased() })
        for builtin in BuiltinPreset.all where !existingNames.contains(builtin.nameVN.lowercased()) {
            _ = try? presetRepo.createPreset(name: builtin.nameVN, parameters: builtin.parameters, isSystem: true)
        }
    }

    static func seedFrames(frameRepo: FrameRepository, assets: AssetStore) throws {
        let existing = try frameRepo.listFrames(includeTrashed: true)
        let existingNames = Set(existing.map(\.name))
        let specs: [(String, CanvasSpec)] = [
            ("Dải 3 ảnh", .photostrip),
            ("Lưới 4 ảnh", .grid4),
            ("Một ảnh lớn", .single)
        ]
        for (name, spec) in specs where !existingNames.contains(name) {
            try createBuiltinFrame(name: name, spec: spec, frameRepo: frameRepo, assets: assets)
        }
    }

    enum CanvasSpec {
        case photostrip, grid4, single

        var canvas: (Int, Int) {
            switch self {
            case .photostrip: return (1200, 1800)
            case .grid4: return (1600, 1600)
            case .single: return (1200, 1800)
            }
        }
    }

    static func createBuiltinFrame(name: String, spec: CanvasSpec,
                                   frameRepo: FrameRepository, assets: AssetStore) throws {
        let (w, h) = spec.canvas
        let bgKey = "seed-\(name)-bg"
        let fgKey = "seed-\(name)-fg"
        let bgData = renderBackground(width: w, height: h)
        let fgData = renderForeground(spec: spec, width: w, height: h)
        let bg = try assets.store(data: bgData, mediaType: "image/png", purpose: AssetKind.frameBackground.rawValue,
                                  ownerType: "frame_revision", ownerID: bgKey)
        let fg = try assets.store(data: fgData, mediaType: "image/png", purpose: AssetKind.frameForeground.rawValue,
                                  ownerType: "frame_revision", ownerID: fgKey)
        let frame = try frameRepo.createEmptyFrame(name: name, categoryID: nil, canvasWidth: w, canvasHeight: h)
        var rev = FrameRevision(frameID: frame.id, revisionNo: 1, canvasWidth: w, canvasHeight: h,
                                backgroundAssetID: bg.id, foregroundAssetID: fg.id,
                                backgroundColorHex: "#FFFFFFFF",
                                backgroundPlacement: .aspectFill,
                                foregroundPlacement: .stretchToCanvas)
        _ = rev.revisionNo
        let slots = slotsFor(spec: spec)
        _ = try frameRepo.commitRevision(frameID: frame.id, draft: rev, slots: slots)
        try frameRepo.setValidationStatus(frameID: frame.id, status: .ready)
        try frameRepo.markBuiltIn(frameID: frame.id)
        // Chuyển owner references từ key tạm sang revision thật
        if let revID = try frameRepo.getFrame(id: frame.id)?.currentRevisionID {
            try assets.moveReferences(ownerType: "frame_revision", fromOwnerID: bgKey, toOwnerID: revID)
            try assets.moveReferences(ownerType: "frame_revision", fromOwnerID: fgKey, toOwnerID: revID)
        }
    }

    static func slotsFor(spec: CanvasSpec) -> [FrameSlot] {
        switch spec {
        case .photostrip:
            return (0..<3).map { i in
                FrameSlot(captureIndex: i + 1,
                          x: 0.10, y: 0.06 + Double(i) * 0.32,
                          width: 0.80, height: 0.24,
                          zOrder: i, maskType: .roundedRectangle, cornerRadius: 0.02,
                          defaultCropMode: .fill)
            }
        case .grid4:
            return (0..<2).flatMap { row in
                (0..<2).map { col in
                    let idx = row * 2 + col
                    return FrameSlot(captureIndex: idx + 1,
                                     x: 0.06 + Double(col) * 0.46, y: 0.06 + Double(row) * 0.46,
                                     width: 0.42, height: 0.42,
                                     zOrder: idx, maskType: .roundedRectangle, cornerRadius: 0.02,
                                     defaultCropMode: .fill)
                }
            }
        case .single:
            return [FrameSlot(captureIndex: 1, x: 0.08, y: 0.08, width: 0.84, height: 0.64,
                              zOrder: 0, maskType: .roundedRectangle, cornerRadius: 0.015,
                              defaultCropMode: .fill)]
        }
    }

    // MARK: - Vẽ PNG (CoreGraphics, y-up)

    static func renderBackground(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(red: 1.0, green: 0.97, blue: 0.90, alpha: 1),
                      CGColor(red: 0.93, green: 0.95, blue: 1.0, alpha: 1)] as CFArray
        if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(height)),
                                   end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }
        return pngData(ctx.makeImage()!)
    }

    static func renderForeground(spec: CanvasSpec, width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height)) // nền trong suốt
        let accent = CGColor(red: 0.36, green: 0.42, blue: 0.92, alpha: 1)
        // Viền canvas
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(CGFloat(width) * 0.012)
        ctx.stroke(CGRect(x: 6, y: 6, width: width - 12, height: height - 12))
        // Viền quanh slot (tọa độ top-left → đổi y-up)
        for slot in slotsFor(spec: spec) {
            let r = CGRect(x: slot.x * Double(width) - 8, y: slot.y * Double(height) - 8,
                           width: slot.width * Double(width) + 16, height: slot.height * Double(height) + 16)
            let yUp = CGFloat(height) - r.maxY
            let path = CGPath(roundedRect: CGRect(x: r.minX, y: yUp, width: r.width, height: r.height),
                              cornerWidth: 14, cornerHeight: 14, transform: nil)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(CGFloat(width) * 0.008)
            ctx.addPath(path)
            ctx.strokePath()
        }
        // Tiêu đề bằng CoreText
        let title: String
        switch spec {
        case .photostrip: title = "PHOTOBOOTH"
        case .grid4: title = "4 KHOẢNH KHẮC"
        case .single: title = "PORTRAIT"
        }
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, CGFloat(width) * 0.05, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: accent]
        if let attrStr = CFAttributedStringCreate(nil, title as CFString, attrs as CFDictionary) {
            let line = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: CGFloat(height) * 0.035)
            CTLineDraw(line, ctx)
        }
        return pngData(ctx.makeImage()!)
    }

    static func pngData(_ img: CGImage) -> Data {
        let out = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        return out as Data
    }
}
