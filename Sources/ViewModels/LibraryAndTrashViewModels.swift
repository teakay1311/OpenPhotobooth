import Foundation
import SwiftUI

/// LibraryViewModel (§2.4): danh sách phiên, bộ lọc, context menu.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public private(set) var cards: [SessionCardModel] = []
    @Published public var searchText = ""
    @Published public var filter: LibraryFilter = .all
    @Published public var sortNewest = true
    @Published public private(set) var loadingPreviews = false

    public enum LibraryFilter: String, CaseIterable {
        case all = "Tất cả"
        case completed = "Hoàn thành"
        case incomplete = "Chưa hoàn thành"
    }

    public let env: AppEnvironment

    public init(env: AppEnvironment) { self.env = env }

    public func reload() {
        var statuses: [SessionStatus]? = nil
        switch filter {
        case .all: statuses = nil
        case .completed: statuses = [.completed]
        case .incomplete: statuses = [.draft, .inProgress, .paused, .reviewable]
        }
        let raw = (try? env.sessions.listSessions(statuses: statuses)) ?? []
        var filtered = raw
        if !searchText.isEmpty {
            filtered = filtered.filter { card in
                let frameName = frameName(for: card)
                return frameName.localizedCaseInsensitiveContains(searchText) ||
                       formatDate(card.session.createdAtMs).localizedCaseInsensitiveContains(searchText)
            }
        }
        filtered.sort { sortNewest ? $0.session.updatedAtMs > $1.session.updatedAtMs : $0.session.updatedAtMs < $1.session.updatedAtMs }
        cards = filtered.map { card in
            SessionCardModel(card: card, frameName: frameName(for: card),
                             preview: env.thumbnails.cachedData(key: "session-\(card.id)-\(card.session.revisionNo)"),
                             formattedDate: formatDate(card.session.createdAtMs))
        }
    }

    func frameName(for card: SessionRepository.SessionCard) -> String {
        guard let snapshot = try? (env.db.query("SELECT source_frame_id FROM frame_snapshots WHERE id=?", [.text(card.session.activeFrameSnapshotID)]).first?["source_frame_id"].stringValue),
              !snapshot.isEmpty,
              let frame = try? env.frames.getFrame(id: snapshot) else {
            return "Khung đã xóa"
        }
        return frame.name
    }

    func formatDate(_ ms: Int64) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: Time.date(ms: ms))
    }

    /// Preview card: render nếu đủ ảnh (render trước, fallback thumbnail đầu tiên §2.4).
    public func generatePreview(for card: SessionCardModel) async -> Data? {
        if let p = card.preview { return p }
        guard let detail = try? env.sessions.getDetail(sessionID: card.id),
              detail.hasEnoughPhotos else { return nil }
        guard let img = await env.renderBuilder.renderPreview(detail: detail, maxDimension: 420),
              let data = CIContextHolder.shared.context.pngRepresentation(
                of: CIImage(cgImage: img), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        env.thumbnails.store(data: data, key: "session-\(card.id)-\(card.card.session.revisionNo)")
        return data
    }

    public func openSession(_ id: String) {
        env.openReview(sessionID: id)
    }

    public func trashSession(_ id: String) {
        do {
            try env.trashService.trashSession(sessionID: id)
            reload()
            env.showToast("Đã chuyển phiên vào Thùng rác (file xuất bên ngoài không bị xóa)")
        } catch {
            env.showToast("\((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    public func revealExport(record: ExportRecordModel) {
        if let path = record.destinationDisplayPath,
           FileManager.default.fileExists(atPath: path) {
            env.shareService.revealInFinder(URL(fileURLWithPath: path))
        } else {
            env.showToast("Không tìm thấy file tại vị trí cũ — có thể xuất lại", kind: .warning)
        }
    }

    public func exportRecords(sessionID: String) -> [ExportRecordModel] {
        (try? env.sessions.listExportRecords(sessionID: sessionID)) ?? []
    }
}

/// TrashViewModel (§2.5): lọc, sắp hết hạn, khôi phục, xóa vĩnh viễn, dọn sạch.
@MainActor
public final class TrashViewModel: ObservableObject {
    @Published public private(set) var items: [TrashItem] = []
    @Published public var filter: TrashRootType? = nil
    @Published public var searchText = ""
    @Published public var sortByExpiry = true
    @Published public var selection: Set<String> = []
    @Published public private(set) var totalBytesText = ""

    public let env: AppEnvironment

    public init(env: AppEnvironment) { self.env = env }

    public func reload() {
        var list = (try? env.trashRepo.list()) ?? []
        list.sort { sortByExpiry ? $0.expiresAtMs < $1.expiresAtMs : $0.deletedAtMs > $1.deletedAtMs }
        if let f = filter { list = list.filter { $0.rootType == f } }
        if !searchText.isEmpty {
            list = list.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        items = list
        let bytes = (try? env.trashRepo.totalBytes()) ?? 0
        totalBytesText = FileLayout.formattedBytes(bytes)
        selection = selection.filter { id in list.contains { $0.id == id } }
    }

    public func remainingText(for item: TrashItem) -> String {
        TrashPolicy.remainingText(expiresAtMs: item.expiresAtMs, nowMs: Time.nowMs())
    }

    public func typeLabel(for item: TrashItem) -> String { item.rootType.label }

    public func restoreSelected() {
        var ok = 0, fail = 0
        for item in items where selection.contains(item.id) {
            do {
                try env.trashService.restore(item)
                ok += 1
            } catch {
                fail += 1
                env.showToast("Khôi phục lỗi: \(item.displayName)", kind: .warning)
            }
        }
        selection.removeAll()
        reload()
        if ok > 0 { env.showToast("Đã khôi phục \(ok) mục") }
        _ = fail
    }

    public func purgeSelected() {
        let selected = items.filter { selection.contains($0.id) }
        let report = env.trashService.purgeAll(items: selected)
        selection.removeAll()
        reload()
        if report.failed > 0 {
            env.showToast("Xóa vĩnh viễn: \(report.success) thành công / \(report.failed) lỗi", kind: .warning)
        } else {
            env.showToast("Đã xóa vĩnh viễn \(report.success) mục")
        }
    }

    public func emptyTrash() {
        let all = (try? env.trashRepo.list()) ?? []
        let report = env.trashService.purgeAll(items: all)
        reload()
        if report.failed > 0 {
            env.showToast("Dọn sạch: \(report.success) thành công / \(report.failed) lỗi (TRS-13)", kind: .warning)
        } else {
            env.showToast("Đã dọn sạch \(report.success) mục")
        }
    }
}
