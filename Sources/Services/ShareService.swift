import Foundation
import AppKit
import CoreGraphics
import Darwin

/// ShareService (§11.4): share cache + NSSharingServicePicker (AirDrop do macOS quản lý).
/// Không tự viết AirDrop transport; đóng picker không nghĩa recipient đã nhận.
public final class ShareService: @unchecked Sendable {
    private let layout: FileLayout
    private let sessions: SessionRepository
    private let builder: SessionRenderBuilder

    public init(layout: FileLayout, sessions: SessionRepository, builder: SessionRenderBuilder) {
        self.layout = layout
        self.sessions = sessions
        self.builder = builder
    }

    /// Chuẩn bị file trong Shares/Temp/<share-id>/ (§11.4) — dùng lại export file nếu khớp revision.
    public func prepareShareFile(detail: SessionDetail, filenameBase: String,
                                 format: ExportImageFormat = .jpeg, quality: Int = 95,
                                 parentToken: OperationCoordinator.OperationToken? = nil) async throws -> URL {
        let opToken = try OperationCoordinator.shared.acquire(key: "session:\(detail.session.id)", reason: "ShareService: prepare share", parentToken: parentToken)
        defer { opToken.release() }

        guard let latestSession = try sessions.activeSession(id: detail.session.id) else {
            throw AppError.notFound("Phiên chụp không tồn tại hoặc đã bị xóa")
        }
        guard latestSession.revisionNo == detail.session.revisionNo,
              latestSession.activeFrameSnapshotID == detail.snapshot.id else {
            throw AppError.invalidState("Dữ liệu phiên đã thay đổi, vui lòng làm mới và thử lại")
        }

        let cg = try await renderForShare(detail: detail, format: format)
        let data = try ExportService.encode(cg: cg, format: format, quality: quality)
        let dir = layout.sharesTempDir.appendingPathComponent(IDFactory.new(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sanitize tên file — tên frame do người dùng đặt có thể chứa "/" (P2-24)
        let safeBase = ExportService.sanitizedFilenameBase(filenameBase)
        let url = dir.appendingPathComponent("\(safeBase).\(format.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func renderForShare(detail: SessionDetail, format: ExportImageFormat) async throws -> CGImage {
        guard detail.hasEnoughPhotos else {
            throw AppError.notEnoughPhotos(missing: detail.missingCount)
        }
        let model = try await builder.buildModelStrict(detail: detail,
                                                       targetWidth: detail.snapshot.canvasWidth,
                                                       targetHeight: detail.snapshot.canvasHeight,
                                                       transparentBackground: format == .png)
        return try CompositeRenderer.render(model: model)
    }

    /// Hiển thị NSSharingServicePicker từ view (macOS quyết định dịch vụ, gồm AirDrop).
    @MainActor
    public func presentPicker(items: [Any], from view: NSView) {
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// Dọn share cache TTL an toàn (§11.4): file > 24h và không còn tác vụ chia sẻ.
    public func cleanupStaleShareCache() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: layout.sharesTempDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for dir in dirs {
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff {
                try? fm.removeItem(at: dir)
            }
        }
    }

    public var revealInFinderHook: ((URL) -> Void)? = nil

    public func revealInFinder(_ url: URL) {
        if let hook = revealInFinderHook {
            hook(url)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Kiểm tra file export còn tồn tại (§11.3) — không tự tìm bản khác.
    public func exportFileExists(_ record: ExportRecordModel) -> Bool {
        guard let path = record.destinationDisplayPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}

/// The file checks shared by the export sheet and the library before revealing an export.
enum ExportFileVerifier {
    enum Check: Sendable {
        case verified(stat)
        case missingOrInvalid, modified
    }

    enum Unavailable {
        case missingOrInvalid, inaccessible
    }

    static func matchesCurrentVersion(_ url: URL, _ version: stat) throws -> Bool {
        var current = stat()
        guard lstat(url.path, &current) == 0 else { throw posixError(errno) }
        return sameVersion(current, version)
    }

    static func check(
        _ url: URL, expectedHash: String?, beforeHash: (@Sendable (URL) throws -> Void)?
    ) throws -> Check {
        try Task.checkCancellation()
        guard !url.path.utf8.contains(0) else { return .missingOrInvalid }
        var entry = stat()
        guard lstat(url.path, &entry) == 0 else { throw posixError(errno) }
        guard entry.st_mode & S_IFMT == S_IFREG else { return .missingOrInvalid }
        guard let expectedHash, !expectedHash.isEmpty else { return .verified(entry) }

        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP { return .missingOrInvalid }
            throw posixError(code)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw posixError(errno) }
        guard sameVersion(entry, opened) else { return .modified }
        try beforeHash?(url)
        let hash = try Hashing.sha256Hex(reading: handle)

        var current = stat()
        guard lstat(url.path, &current) == 0 else { throw posixError(errno) }
        guard sameVersion(current, opened), hash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            return .modified
        }
        return .verified(current)
    }

    private static func sameVersion(_ a: stat, _ b: stat) -> Bool {
        a.st_mode & S_IFMT == S_IFREG && b.st_mode & S_IFMT == S_IFREG &&
        (a.st_dev, a.st_ino, a.st_gen, a.st_size) == (b.st_dev, b.st_ino, b.st_gen, b.st_size) &&
        (a.st_mtimespec.tv_sec, a.st_mtimespec.tv_nsec) == (b.st_mtimespec.tv_sec, b.st_mtimespec.tv_nsec) &&
        (a.st_ctimespec.tv_sec, a.st_ctimespec.tv_nsec) == (b.st_ctimespec.tv_sec, b.st_ctimespec.tv_nsec)
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func classifyFileError(_ error: Error) -> Unavailable {
        if (error as? AppError) == .externalFolderPermissionLost { return .inaccessible }
        let ns = error as NSError
        var chain: [NSError] = []
        var current: NSError? = ns
        while let err = current {
            chain.append(err)
            current = err.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        // Ưu tiên không thể truy cập khi có nguyên nhân quyền rõ ràng (§4.3)
        for err in chain {
            if err.domain == NSCocoaErrorDomain {
                if err.code == NSFileReadNoPermissionError {
                    return .inaccessible
                }
            } else if err.domain == NSPOSIXErrorDomain {
                if err.code == Int(EACCES) || err.code == Int(EPERM) {
                    return .inaccessible
                }
            }
        }

        // Tệp mất hoặc đường dẫn không còn hợp lệ
        for err in chain {
            if err.domain == NSCocoaErrorDomain {
                if err.code == NSFileNoSuchFileError || err.code == NSFileReadNoSuchFileError {
                    return .missingOrInvalid
                }
            } else if err.domain == NSPOSIXErrorDomain {
                if err.code == Int(ENOENT) || err.code == Int(ENOTDIR) {
                    return .missingOrInvalid
                }
            }
        }

        return .inaccessible
    }
}
