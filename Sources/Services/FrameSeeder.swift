import ImageIO
import Foundation
import CoreGraphics
import CoreText

/// FrameSeeder (§6.4, §1.4, §3.1.3): Khung built-in và 8 preset theo seedVersion idempotent.
/// Khung vẽ bằng CoreGraphics/CoreText lúc seed — không dùng ảnh bản quyền, không UI mock.
public enum FrameSeeder {
    public static let seedVersion = "3"

    public static func seedIfNeeded(db: SQLiteDatabase, frameRepo: FrameRepository,
                                    presetRepo: PresetRepository, assets: AssetStore) throws {
        let rows = try db.query("SELECT value FROM app_state WHERE key='seedVersion'")
        let installedVersion = rows.first?["value"].stringValue
        if installedVersion == seedVersion { return }
        if installedVersion == nil {
            try seedPresets(presetRepo: presetRepo)
        }
        if installedVersion == nil || installedVersion == "1" {
            try seedFrames(frameRepo: frameRepo, assets: assets, includeOriginals: installedVersion == nil)
        }
        if installedVersion == "1" || installedVersion == "2" {
            try updateBuiltinTitles(frameRepo: frameRepo, assets: assets)
        }
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

    static func seedFrames(frameRepo: FrameRepository, assets: AssetStore, includeOriginals: Bool) throws {
        let existingNames = Set(try frameRepo.listFrames(includeTrashed: true).map(\.name))
        let originals: [(String, CanvasSpec)] = [
            ("Dải 3 ảnh", .photostrip),
            ("Lưới 4 ảnh", .grid4),
            ("Một ảnh lớn", .single)
        ]
        let additional: [(String, CanvasSpec)] = [
            ("Cặp ảnh dọc", .grid(columns: 1, rows: 2)),
            ("Cặp ảnh ngang", .grid(columns: 2, rows: 1)),
            ("Collage 5 ảnh", .collage5),
            ("Lưới 6 ảnh", .grid(columns: 2, rows: 3)),
            ("Lưới 8 ảnh", .grid(columns: 2, rows: 4)),
            ("Lưới 9 ảnh", .grid(columns: 3, rows: 3))
        ]
        for (name, spec) in (includeOriginals ? originals + additional : additional)
            where !existingNames.contains(name) {
            try createBuiltinFrame(name: name, spec: spec, frameRepo: frameRepo, assets: assets)
        }
    }

    private static func updateBuiltinTitles(frameRepo: FrameRepository, assets: AssetStore) throws {
        let specs: [String: CanvasSpec] = ["Dải 3 ảnh": .photostrip, "Lưới 4 ảnh": .grid4]
        for frame in try frameRepo.listFrames() where frame.isBuiltIn {
            guard let spec = specs[frame.name], let id = frame.currentRevisionID,
                  var revision = try frameRepo.getRevision(id: id), revision.revisionNo == 2,
                  (revision.canvasWidth, revision.canvasHeight) == spec.canvas,
                  let foregroundID = revision.foregroundAssetID,
                  revision.backgroundAssetID != nil else { continue }
            let slots = try frameRepo.getSlots(revisionID: id)
            let expected = slotsFor(spec: spec)
            guard slots.count == expected.count, zip(slots, expected).allSatisfy({ saved, original in
                var comparable = saved
                comparable.id = original.id
                comparable.frameRevisionID = original.frameRevisionID
                return comparable == original
            }) else { continue }

            let png = renderForeground(spec: spec, width: revision.canvasWidth, height: revision.canvasHeight)
            // Thư viện đã có đúng mẫu (ví dụ ở lần tạo mới trước khi seedVersion được ghi).
            if try assets.loadData(assetID: foregroundID) == png { continue }
            let stagedOwner = "seed-title-\(frame.id)-\(id)"
            let asset = try assets.store(data: png, mediaType: "image/png", purpose: "foreground",
                                         ownerType: "frame_revision", ownerID: stagedOwner)
            revision.foregroundAssetID = asset.id
            _ = try frameRepo.commitRevision(frameID: frame.id, draft: revision, slots: slots,
                                              replacing: id, stagedOwnerID: stagedOwner)
        }
    }

    enum CanvasSpec {
        case photostrip, grid4, single, collage5
        case grid(columns: Int, rows: Int)

        var canvas: (Int, Int) {
            switch self {
            case .photostrip, .single, .collage5: return (1200, 1800)
            case .grid4: return (1600, 1600)
            case let .grid(columns, rows):
                if columns > rows { return (1800, 1200) }
                if columns == rows { return (1600, 1600) }
                return (1200, 1800)
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
        let rev = FrameRevision(frameID: frame.id, revisionNo: 1, canvasWidth: w, canvasHeight: h,
                                backgroundAssetID: bg.id, foregroundAssetID: fg.id,
                                backgroundColorHex: "#FFFFFFFF",
                                backgroundPlacement: .aspectFill,
                                foregroundPlacement: .stretchToCanvas)
        let slots = slotsFor(spec: spec)
        guard FrameValidator.validate(revision: rev, slots: slots).isEmpty else {
            throw AppError.frameUnconfigured
        }
        let revision = try frameRepo.commitRevision(frameID: frame.id, draft: rev, slots: slots)
        try assets.moveReferences(ownerType: "frame_revision", fromOwnerID: bgKey, toOwnerID: revision.id)
        try assets.moveReferences(ownerType: "frame_revision", fromOwnerID: fgKey, toOwnerID: revision.id)
        try frameRepo.markBuiltIn(frameID: frame.id)
        try frameRepo.setValidationStatus(frameID: frame.id, status: .ready)
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
        case let .grid(columns, rows):
            let gap = 0.035
            let width = (0.88 - Double(columns - 1) * gap) / Double(columns)
            let height = (0.84 - Double(rows - 1) * gap) / Double(rows)
            return (0..<rows).flatMap { row in
                (0..<columns).map { column in
                    let index = row * columns + column
                    return FrameSlot(captureIndex: index + 1,
                                     x: 0.06 + Double(column) * (width + gap),
                                     y: 0.05 + Double(row) * (height + gap), width: width, height: height,
                                     zOrder: index, maskType: .roundedRectangle, cornerRadius: 0.02,
                                     defaultCropMode: .fill)
                }
            }
        case .collage5:
            let hero = FrameSlot(captureIndex: 1, x: 0.06, y: 0.05, width: 0.88, height: 0.32,
                                 zOrder: 0, maskType: .roundedRectangle, cornerRadius: 0.02,
                                 defaultCropMode: .fill)
            let smaller = (0..<4).map { index in
                FrameSlot(captureIndex: index + 2, x: 0.06 + Double(index % 2) * 0.46,
                          y: 0.41 + Double(index / 2) * 0.25, width: 0.42, height: 0.22,
                          zOrder: index + 1, maskType: .roundedRectangle, cornerRadius: 0.02,
                          defaultCropMode: .fill)
            }
            return [hero] + smaller
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
        case .collage5: title = "5 KHOẢNH KHẮC"
        case let .grid(columns, rows): title = "\(columns * rows) KHOẢNH KHẮC"
        }
        let width = CGFloat(width)
        let height = CGFloat(height)
        let preferredSize = width * 0.05
        let fitBelowSlots: Bool
        switch spec {
        case .photostrip, .grid4: fitBelowSlots = true
        default: fitBelowSlots = false
        }
        let margin = max(6, min(width, height) * 0.005)
        let lowerBound = 6 + width * 0.006 + margin
        let lowestSlotBottom = slotsFor(spec: spec).map { (1 - $0.y - $0.height) * height }.min() ?? height
        let upperBound = lowestSlotBottom - 8 - width * 0.004 - margin
        let availableWidth = width - 2 * lowerBound

        var fontSize = preferredSize
        while fontSize >= 1 {
            let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: accent]
            guard let attr = CFAttributedStringCreate(nil, title as CFString, attrs as CFDictionary) else { break }
            let line = CTLineCreateWithAttributedString(attr)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            if fitBelowSlots {
                let scale = min(availableWidth / bounds.width, (upperBound - lowerBound) / bounds.height)
                if scale < 1 {
                    fontSize = floor(fontSize * scale)
                    continue
                }
                ctx.textPosition = CGPoint(x: width / 2 - bounds.midX,
                                           y: (lowerBound + upperBound) / 2 - bounds.midY)
            } else {
                ctx.textPosition = CGPoint(x: (width - bounds.width) / 2, y: height * 0.035)
            }
            CTLineDraw(line, ctx)
            break
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
