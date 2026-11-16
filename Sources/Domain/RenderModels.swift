import Foundation
import CoreGraphics
import ImageIO

// MARK: - Composition model bất biến dùng chung preview/review/export (§7.6, I-05)

public struct RenderSource: @unchecked Sendable {
    public var image: CGImage
    public var width: Int { image.width }
    public var height: Int { image.height }

    public init(image: CGImage) { self.image = image }
}

/// Model bất biến: FrameSnapshot + ảnh nguồn + chỉnh màu + placement + render options.
/// Preview và Export dùng CÙNG model + CÙNG renderer, chỉ khác target size (§7.6).
/// Ảnh nguồn đã được chuẩn hóa orientation + OutputMirror + photo rotation trước khi đưa vào.
public struct CompositionModel: @unchecked Sendable {
    public var snapshot: FrameSnapshot
    public var sources: [Int: RenderSource]              // captureIndex -> ảnh current revision
    public var faces: [Int: [FaceBox]]                   // captureIndex -> face boxes (normalized)
    public var defaults: SessionDefaultsSnapshot
    public var overrides: [Int: PhotoOverride]           // captureIndex -> override
    public var placements: [String: PhotoPlacement]      // snapshotSlotID -> placement
    public var cropModes: [String: CropMode]             // snapshotSlotID -> crop mode hiệu lực
    public var assetImages: [String: CGImage]            // assetID -> ảnh lớp frame
    public var options: RenderOptions

    public init(snapshot: FrameSnapshot, sources: [Int: RenderSource],
                faces: [Int: [FaceBox]] = [:], defaults: SessionDefaultsSnapshot,
                overrides: [Int: PhotoOverride], placements: [String: PhotoPlacement],
                cropModes: [String: CropMode], assetImages: [String: CGImage], options: RenderOptions) {
        self.snapshot = snapshot; self.sources = sources; self.faces = faces
        self.defaults = defaults; self.overrides = overrides; self.placements = placements
        self.cropModes = cropModes; self.assetImages = assetImages; self.options = options
    }
}

public struct RenderOptions: Equatable, Sendable {
    public var targetWidth: Int
    public var targetHeight: Int
    public var transparentBackground: Bool
    public var matteColor: CGColor

    public init(targetWidth: Int, targetHeight: Int,
                transparentBackground: Bool = false,
                matteColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.transparentBackground = transparentBackground
        self.matteColor = matteColor
    }
}

public enum ColorHex {
    public static func toCGColor(_ hex: String) -> CGColor {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if raw.count == 6 {
            var rgb: UInt64 = 0
            Scanner(string: raw).scanHexInt64(&rgb)
            let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
            let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
            let b = CGFloat(rgb & 0xFF) / 255.0
            return CGColor(red: r, green: g, blue: b, alpha: 1.0)
        }
        var value: UInt64 = 0xFFFFFFFF
        Scanner(string: raw).scanHexInt64(&value)
        let r = CGFloat((value >> 24) & 0xFF) / 255.0
        let g = CGFloat((value >> 16) & 0xFF) / 255.0
        let b = CGFloat((value >> 8) & 0xFF) / 255.0
        let a = CGFloat(value & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    public static func toColor(_ hex: String) -> CGColor { toCGColor(hex) }
}
