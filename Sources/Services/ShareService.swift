import Foundation
import AppKit
import CoreGraphics

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
