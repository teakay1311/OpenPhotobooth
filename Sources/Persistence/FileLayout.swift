import Foundation

/// Cấu trúc file nội bộ §16.6 — mọi đường dẫn nội bộ là relative từ Application Support root,
/// được validate không chứa "..", không absolute (§16.1).
public final class FileLayout: @unchecked Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) throws {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let bundle = Bundle.main.bundleIdentifier ?? "vn.openphotobooth.app"
            self.rootURL = support.appendingPathComponent(bundle, isDirectory: true)
        }
        try Self.makeDirectories(root: rootURL ?? self.rootURL)
    }

    private static func makeDirectories(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for sub in allRelativeDirs {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    static let allRelativeDirs: [String] = [
        "Database", "Assets", "Sessions", "Trash", "Trash/Sessions", "Trash/Staging",
        "Imports/Staging", "Exports/Temp", "Shares/Temp", "Thumbnails", "Recovery/Quarantine", "Logs"
    ]

    public var databaseURL: URL { rootURL.appendingPathComponent("Database/photobooth.sqlite") }
    public var sessionsDir: URL { rootURL.appendingPathComponent("Sessions", isDirectory: true) }
    public var trashSessionsDir: URL { rootURL.appendingPathComponent("Trash/Sessions", isDirectory: true) }
    public var trashStagingDir: URL { rootURL.appendingPathComponent("Trash/Staging", isDirectory: true) }
    public var importsStagingDir: URL { rootURL.appendingPathComponent("Imports/Staging", isDirectory: true) }
    public var exportsTempDir: URL { rootURL.appendingPathComponent("Exports/Temp", isDirectory: true) }
    public var sharesTempDir: URL { rootURL.appendingPathComponent("Shares/Temp", isDirectory: true) }
    public var thumbnailsDir: URL { rootURL.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var quarantineDir: URL { rootURL.appendingPathComponent("Recovery/Quarantine", isDirectory: true) }
    public var logsDir: URL { rootURL.appendingPathComponent("Logs", isDirectory: true) }

    /// Path tuyệt đối từ relative path đã validate.
    public func absoluteURL(forRelativePath rel: String) throws -> URL {
        guard Self.isValidRelativePath(rel) else {
            throw AppError.ioFailure("Đường dẫn nội bộ không hợp lệ: \(Log.safePath(rel))")
        }
        return rootURL.appendingPathComponent(rel)
    }

    public static func isValidRelativePath(_ rel: String) -> Bool {
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("\\") else { return false }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return false }
        for p in parts {
            if p == "." || p == ".." { return false }
            if p.contains("\0") { return false }
        }
        return true
    }

    public func sessionDir(_ sessionID: String) -> URL { sessionsDir.appendingPathComponent(sessionID, isDirectory: true) }
    public func sessionOriginalsDir(_ sessionID: String) -> URL { sessionDir(sessionID).appendingPathComponent("Originals", isDirectory: true) }
    public func sessionRendersDir(_ sessionID: String) -> URL { sessionDir(sessionID).appendingPathComponent("Renders", isDirectory: true) }
    public func sessionMetadataDir(_ sessionID: String) -> URL { sessionDir(sessionID).appendingPathComponent("Metadata", isDirectory: true) }

    public func ensureSessionDirs(_ sessionID: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionOriginalsDir(sessionID), withIntermediateDirectories: true)
        try fm.createDirectory(at: sessionRendersDir(sessionID), withIntermediateDirectories: true)
        try fm.createDirectory(at: sessionMetadataDir(sessionID), withIntermediateDirectories: true)
    }

    /// Dung lượng thư mục (ước tính) — dùng cho Trash estimatedBytes.
    public static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    public func formattedSize() -> String {
        Self.formattedBytes(Self.directorySize(rootURL))
    }

    public static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
