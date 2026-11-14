import Foundation
import CoreGraphics

/// Thumbnail/cache store — cache có thể tạo lại, KHÔNG thuộc vòng đời Trash 30 ngày (§1.3, §10.5).
public final class ThumbnailStore: @unchecked Sendable {
    private let layout: FileLayout
    private let memory = NSCache<NSString, NSData>()

    public init(layout: FileLayout) {
        self.layout = layout
        memory.countLimit = 400
    }

    public func cachedData(key: String) -> Data? {
        if let mem = memory.object(forKey: key as NSString) { return mem as Data }
        let url = layout.thumbnailsDir.appendingPathComponent(Self.safeFileName(key) + ".png")
        guard let data = try? Data(contentsOf: url) else { return nil }
        memory.setObject(data as NSData, forKey: key as NSString)
        return data
    }

    public func store(data: Data, key: String) {
        memory.setObject(data as NSData, forKey: key as NSString)
        let url = layout.thumbnailsDir.appendingPathComponent(Self.safeFileName(key) + ".png")
        try? data.write(to: url, options: .atomic)
    }

    public func cacheImage(key: String, size: CGSize, maker: () -> CGImage?) -> CGImage? {
        let data = cachedData(key: key)
        if let data, let img = CGImage.createFrom(data: data) { return img }
        guard let img = maker() else { return nil }
        let ctx = CIContextHolder.shared.context
        if let encoded = ctx.pngRepresentation(of: CIImage(cgImage: img), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
            store(data: encoded, key: key)
        }
        return img
    }

    /// Dọn cache thumbnail/temp (§10.5) — không đụng ảnh gốc, Recovery, Trash.
    public func clearAll() throws {
        memory.removeAllObjects()
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: layout.thumbnailsDir, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
    }

    /// Dọn file thumbnail cũ (> `days` ngày) — cache có thể tạo lại (§10.5).
    /// Chặn tăng trưởng đĩa vô hạn vì key có revisionNo bump liên tục.
    public func pruneOlderThan(days: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: layout.thumbnailsDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    static func safeFileName(_ key: String) -> String {
        Hashing.sha256Hex(Data(key.utf8))
    }
}

/// CIContext dùng chung cho mọi render/thumbnail (một pipeline §7.6).
public enum CIContextHolder {
    public static let shared = CIContextHolderBox()
}

public final class CIContextHolderBox: @unchecked Sendable {
    public let context: CIContext
    init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .cacheIntermediates: false
        ])
    }
}
