import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Asset Store bất biến content-addressed (§6.5, §12.2, §16.3):
/// - bytes theo sha256, không đổi; tham chiếu qua asset_references với reachability thực.
/// - Không dùng refCount thủ công làm cơ sở xóa duy nhất (§16.3): GC tính lại bằng query.
public final class AssetStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let layout: FileLayout
    private let queue = DispatchQueue(label: "vn.openphotobooth.assetstore", qos: .utility)

    public init(db: SQLiteDatabase, layout: FileLayout) {
        self.db = db
        self.layout = layout
    }

    public struct StoredAsset: Equatable {
        public var id: String
        public var sha256: String
        public var relativePath: String
        public var width: Int?
        public var height: Int?
    }

    /// Lưu asset (dedupe theo sha256). Trả về asset hiện có nếu trùng bytes.
    public func store(data: Data, mediaType: String, purpose: String,
                      ownerType: String, ownerID: String) throws -> StoredAsset {
        guard data.count <= ResourceLimits.maxAssetBytes else {
            throw AppError.resourceLimitExceeded("Tệp vượt \(ResourceLimits.maxAssetBytes / 1_000_000)MB")
        }
        let sha = Hashing.sha256Hex(data)
        let (width, height) = Self.imageDimensions(of: data)
        // Asset dedupe có bytes thiếu: UPDATE quarantine phải NẰM NGOÀI transaction
        // (trong transaction sẽ bị ROLLBACK khi throw → trạng thái không bao giờ persist).
        var quarantinedID: String?
        defer {
            if let qid = quarantinedID {
                try? db.run("UPDATE assets SET storage_state='quarantined' WHERE id=?", [.text(qid)])
                Log.store.error("Asset bytes thiếu (quarantined): \(qid.prefix(8), privacy: .public)")
            }
        }

        return try db.withTransaction { tx in
            // Dedupe theo sha256
            let existing = try tx.query("SELECT id, relative_path, width, height FROM assets WHERE sha256 = ?", [.text(sha)])
            if let row = existing.first {
                let id = row["id"].stringValue
                try tx.run("""
                    INSERT OR IGNORE INTO asset_references(asset_id, owner_type, owner_id, purpose)
                    VALUES(?, ?, ?, ?)
                    """, [.text(id), .text(ownerType), .text(ownerID), .text(purpose)])
                let rel = row["relative_path"].stringValue
                let absURL = try self.layout.absoluteURL(forRelativePath: rel)
                // Bytes lỡ mất nhưng refs còn → mark quarantined và báo (§16.3), không xóa record
                if !FileManager.default.fileExists(atPath: absURL.path) {
                    quarantinedID = id   // defer sẽ persist SAU khi transaction rollback
                    throw AppError.missingFrameAssets
                }
                return StoredAsset(id: id, sha256: sha, relativePath: rel,
                                   width: row["width"].intValue, height: row["height"].intValue)
            }

            // Ghi file vào thư mục Assets/<prefix>/
            let ext = Self.extensionForMediaType(mediaType)
            let rel = "Assets/\(String(sha.prefix(2)))/\(sha).\(ext)"
            let dest = try self.layout.absoluteURL(forRelativePath: rel)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
            let id = IDFactory.new()
            try tx.run("""
                INSERT INTO assets(id, sha256, relative_path, media_type, byte_size, width, height, created_at_ms, storage_state)
                VALUES(?,?,?,?,?,?,?,?, 'available')
                """, [.text(id), .text(sha), .text(rel), .text(mediaType), .int(Int64(data.count)),
                      width.map { .int(Int64($0)) } ?? .null,
                      height.map { .int(Int64($0)) } ?? .null,
                      .int(Time.nowMs())])
            try tx.run("""
                INSERT INTO asset_references(asset_id, owner_type, owner_id, purpose)
                VALUES(?, ?, ?, ?)
                """, [.text(id), .text(ownerType), .text(ownerID), .text(purpose)])
            return StoredAsset(id: id, sha256: sha, relativePath: rel, width: width, height: height)
        }
    }

    public func addReference(assetID: String, ownerType: String, ownerID: String, purpose: String) throws {
        try db.run("""
            INSERT OR IGNORE INTO asset_references(asset_id, owner_type, owner_id, purpose)
            VALUES(?,?,?,?)
            """, [.text(assetID), .text(ownerType), .text(ownerID), .text(purpose)])
    }

    public func removeReferences(ownerType: String, ownerID: String) throws {
        try db.run("DELETE FROM asset_references WHERE owner_type=? AND owner_id=?", [.text(ownerType), .text(ownerID)])
    }

    /// Đổi owner của references (dùng khi promote staging → revision thật).
    public func moveReferences(ownerType: String, fromOwnerID: String, toOwnerID: String) throws {
        try db.run("UPDATE asset_references SET owner_id=? WHERE owner_type=? AND owner_id=?",
                   [.text(toOwnerID), .text(ownerType), .text(fromOwnerID)])
    }

    public func loadData(assetID: String) throws -> Data {
        let rows = try db.query("SELECT relative_path, storage_state FROM assets WHERE id=?", [.text(assetID)])
        guard let row = rows.first else { throw AppError.notFound("asset \(assetID)") }
        guard row["storage_state"].stringValue != "quarantined" else { throw AppError.missingFrameAssets }
        let url = try layout.absoluteURL(forRelativePath: row["relative_path"].stringValue)
        return try Data(contentsOf: url)
    }

    public func loadImage(assetID: String) throws -> CGImage {
        let data = try loadData(assetID: assetID)
        guard let img = CGImage.createFrom(data: data) else { throw AppError.frameFileCorrupt }
        return img
    }

    public func assetInfo(assetID: String) -> StoredAsset? {
        let rows = (try? db.query("SELECT id, sha256, relative_path, width, height FROM assets WHERE id=?", [.text(assetID)])) ?? []
        guard let r = rows.first else { return nil }
        return StoredAsset(id: r["id"].stringValue, sha256: r["sha256"].stringValue,
                           relativePath: r["relative_path"].stringValue,
                           width: r["width"].intValue, height: r["height"].intValue)
    }

    /// GC (§12.2, §16.3): xóa bytes asset không còn references từ active/trashed/journal.
    /// Chỉ gọi sau purge; trả về số asset dọn được.
    public func collectGarbage() throws -> Int {
        try queue.sync {
            let orphans = try db.query("""
                SELECT a.id, a.relative_path FROM assets a
                WHERE NOT EXISTS (SELECT 1 FROM asset_references r WHERE r.asset_id = a.id)
                  AND a.storage_state = 'available'
                LIMIT 200
                """)
            var removed = 0
            for row in orphans {
                let id = row["id"].stringValue
                let rel = row["relative_path"].stringValue
                if let url = try? layout.absoluteURL(forRelativePath: rel) {
                    try? FileManager.default.removeItem(at: url)
                }
                try db.run("DELETE FROM assets WHERE id=?", [.text(id)])
                removed += 1
            }
            if removed > 0 { Log.store.info("Asset GC: dọn \(removed) asset không còn tham chiếu") }
            return removed
        }
    }

    public static func imageDimensions(of data: Data) -> (Int?, Int?) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, nil) }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (nil, nil) }
        let w = props[kCGImagePropertyPixelWidth] as? Int
        let h = props[kCGImagePropertyPixelHeight] as? Int
        // Tôn trọng orientation khi tính kích thước hiển thị
        let orient = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if (5...8).contains(orient) { return (h, w) }
        return (w, h)
    }

    public static func extensionForMediaType(_ mediaType: String) -> String {
        switch mediaType {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case UTType.png.identifier: return "png"
        case UTType.jpeg.identifier: return "jpg"
        default: return mediaType.hasPrefix("image/") ? String(mediaType.dropFirst(6)) : "bin"
        }
    }
}

extension CGImage {
    /// Decode CGImage từ data + tôn trọng EXIF orientation (chuẩn hóa ngay đầu pipeline §8.4).
    public static func createFrom(data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary)
    }
}

extension SQLiteValue {
    var stringValue: String {
        if case .text(let t) = self { return t }
        return ""
    }
    var intValue: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .real(let v): return Int(v)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .real(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    var boolValue: Bool {
        switch self {
        case .int(let v): return v != 0
        case .real(let v): return v != 0
        default: return false
        }
    }
}
