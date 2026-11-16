import Foundation

// MARK: - Frame Pack manifest (§13.1) — schemaVersion 1, packFormatVersion 1

public struct PackManifest: Codable, Equatable {
    public var schemaVersion: Int
    public var packFormatVersion: Int
    public var packId: String
    public var name: String
    public var createdAt: String
    public var frames: [PackFrame]
    public var files: [PackFileEntry]
}

public struct PackFrame: Codable, Equatable {
    public var frameId: String
    public var name: String
    public var category: String?
    public var canvas: PackCanvas
    public var slots: [PackSlot]
    public var assets: PackFrameAssets
    public var backgroundColor: String?
    public var backgroundPlacement: String?
    public var foregroundPlacement: String?
    public var explicitWhite: Bool?
}

public struct PackCanvas: Codable, Equatable {
    public var width: Int
    public var height: Int
}

public struct PackSlot: Codable, Equatable {
    public var id: String
    public var captureIndex: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rotationDegrees: Double?
    public var zOrder: Int
    public var mask: String?
    public var cornerRadius: Double?
    public var cropMode: String?
}

public struct PackFrameAssets: Codable, Equatable {
    public var background: String?   // "sha256:<hex>" hoặc null
    public var foreground: String?
}

public struct PackFileEntry: Codable, Equatable {
    public var path: String          // "assets/<sha256>.<ext>"
    public var sha256: String
    public var size: Int
}

/// Kết quả xác minh pack trước khi preview (§13.2) — không giải nén vào thư viện đang hoạt động.
public struct PackValidationResult {
    public var manifest: PackManifest
    public var entries: [PackEntry]
    public var warnings: [String]
}

public struct PackEntry: Identifiable, Equatable {
    public var id: String { frame.frameId }
    public var frame: PackFrame
    public var thumbnailData: Data?
    public var assetCount: Int
    public var isDuplicate: Bool
    public var existingFrameID: String?
}

public enum PackDuplicatePolicy: String, CaseIterable {
    case skip = "Bỏ qua"
    case copy = "Bản sao"
    case replace = "Thay thế"

    public var label: String { rawValue }
}
