import Foundation
import SwiftUI
import CoreGraphics
import ImageIO

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
        case completed = "Đủ ảnh"
        case incomplete = "Chưa đủ ảnh"
    }

    public let env: AppEnvironment

    public init(env: AppEnvironment) { self.env = env }

    public func reload() {
        let raw = (try? env.sessions.listSessions()) ?? []
        var filtered: [SessionRepository.SessionCard]
        switch filter {
        case .all:
            filtered = raw
        case .completed:
            filtered = raw.filter { $0.committedCount >= $0.session.captureCount }
        case .incomplete:
            filtered = raw.filter { $0.committedCount < $0.session.captureCount }
        }
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

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    private var frameNameCache: [String: String] = [:]

    func frameName(for card: SessionRepository.SessionCard) -> String {
        if let atCapture = card.session.frameNameAtCapture, !atCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return atCapture
        }
        if let hit = frameNameCache[card.session.activeFrameSnapshotID] {
            return hit
        }
        let name: String
        if let snapshot = try? (env.db.query("SELECT source_frame_id FROM frame_snapshots WHERE id=?", [.text(card.session.activeFrameSnapshotID)]).first?["source_frame_id"].stringValue),
           !snapshot.isEmpty,
           let frame = try? env.frames.getFrame(id: snapshot) {
            name = frame.name
        } else {
            name = "Không rõ tên khung lúc chụp"
        }
        frameNameCache[card.session.activeFrameSnapshotID] = name
        return name
    }

    func formatDate(_ ms: Int64) -> String {
        Self.dateFormatter.string(from: Time.date(ms: ms))
    }

    // Monitoring & event sync (LIB-06)
    private var eventTask: Task<Void, Never>?
    private var scheduledReloadTask: Task<Void, Never>?

    public func startEventMonitoring() {
        stopEventMonitoring()
        reload()
        eventTask = Task { [weak self] in
            for await event in EventBus.shared.stream {
                guard let self else { return }
                switch event {
                case .sessionChanged, .shotCommitted, .photoAdjusted, .frameSnapshotChanged:
                    self.scheduleDebouncedReload()
                default:
                    break
                }
            }
        }
    }

    public func stopEventMonitoring() {
        eventTask?.cancel()
        eventTask = nil
        scheduledReloadTask?.cancel()
        scheduledReloadTask = nil
    }

    public func scheduleDebouncedReload() {
        scheduledReloadTask?.cancel()
        scheduledReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            guard !Task.isCancelled, let self else { return }
            guard self.env.route == .library else { return }
            self.reload()
        }
    }

    public func continueSession(_ sessionID: String, requiresMissingPhotos: Bool = false) async {
        guard !env.showLeaveCaptureConfirmation else { return }
        guard !env.engine.hasPhotoToSave else {
            env.requestNavigation(to: .capture)
            env.showToast("Thử lưu lại ảnh của phiên đang mở trước", kind: .warning)
            return
        }
        guard env.engine.canAdoptSession else {
            env.showToast("Không thể tiếp tục phiên lúc này — máy đang bận", kind: .warning)
            return
        }
        guard let detail = try? env.sessions.getDetail(sessionID: sessionID),
              detail.session.status != .trashed && detail.session.status != .purging else {
            env.showToast("Phiên chụp không còn khả dụng", kind: .warning)
            reload()
            return
        }
        if requiresMissingPhotos {
            if detail.missingIndices.isEmpty {
                reload()
                env.showToast("Phiên đã đủ ảnh — hãy chọn ảnh hoặc xuất", kind: .info)
                return
            }
        } else {
            if detail.session.pendingSelectionCount != nil && detail.missingIndices.isEmpty {
                env.openReview(sessionID: sessionID, source: .library)
                return
            }
        }
        let adopted = env.engine.adoptSession(record: detail.session,
                                              snapshot: detail.snapshot,
                                              committed: detail.currentRevisions())
        if adopted {
            env.route = .capture
        } else {
            env.showToast("Không thể nhận phiên chụp", kind: .warning)
        }
    }

    public func selectPhotosForSession(_ sessionID: String) {
        guard let detail = try? env.sessions.getDetail(sessionID: sessionID),
              detail.session.status != .trashed && detail.session.status != .purging else {
            env.showToast("Phiên chụp không còn khả dụng", kind: .warning)
            reload()
            return
        }
        guard detail.needsPhotoSelection else {
            reload()
            env.showToast("Trạng thái phiên đã thay đổi", kind: .info)
            return
        }
        env.openReview(sessionID: sessionID, source: .library)
    }

    public func openExportForSession(_ sessionID: String) {
        guard env.route == .library else { return }
        guard let detail = try? env.sessions.getDetail(sessionID: sessionID),
              detail.session.status != .trashed && detail.session.status != .purging else {
            env.showToast("Phiên chụp không còn khả dụng", kind: .warning)
            reload()
            return
        }
        guard !detail.needsPhotoSelection else {
            env.showToast("Cần chọn ảnh vào khung trước", kind: .warning)
            reload()
            return
        }
        guard detail.hasEnoughPhotos else {
            env.showToast("Phiên chưa đủ ảnh để xuất", kind: .warning)
            reload()
            return
        }
        env.openReview(sessionID: sessionID, source: .library, openExport: true)
    }

    private var activeRenderTokens: [String: Int] = [:] // sessionID -> target revisionNo

    /// Preview card: render nếu đủ ảnh (render trước, fallback thumbnail đầu tiên hợp lệ §2.4, B-02).
    public func generatePreview(for card: SessionCardModel) async -> Data? {
        let sessionID = card.id
        let targetRevision = card.card.session.revisionNo
        let cacheKey = "session-\(sessionID)-\(targetRevision)"

        if let cached = env.thumbnails.cachedData(key: cacheKey) {
            return cached
        }

        activeRenderTokens[sessionID] = targetRevision

        guard let detail = try? env.sessions.getDetail(sessionID: sessionID) else { return nil }
        guard detail.session.revisionNo == targetRevision else { return nil }

        if detail.hasEnoughPhotos {
            guard let img = await env.renderBuilder.renderPreview(detail: detail, maxDimension: 420) else { return nil }
            guard !Task.isCancelled else { return nil }
            guard activeRenderTokens[sessionID] == targetRevision else { return nil }
            guard let current = try? env.sessions.getSession(id: sessionID), current.revisionNo == targetRevision else { return nil }
            guard let data = CIContextHolder.shared.context.pngRepresentation(
                of: CIImage(cgImage: img), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
            env.thumbnails.store(data: data, key: cacheKey)
            return data
        } else {
            for entry in detail.currentRevisions().sorted(by: { $0.key < $1.key }) {
                let rev = entry.value
                if let cached = env.thumbnails.cachedData(key: "shot-\(rev.id)") {
                    return cached
                }
                if let url = try? env.sessions.fileURL(for: rev),
                   FileManager.default.fileExists(atPath: url.path) {
                    if let downscaled = Self.downscaleThumbnail(url: url, maxDimension: 420) {
                        env.thumbnails.store(data: downscaled, key: "shot-\(rev.id)")
                        return downscaled
                    }
                }
            }
            return nil
        }
    }

    nonisolated public static func downscaleThumbnail(url: URL, maxDimension: CGFloat = 420) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
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

    public var fileMetadataProbe: ((URL) throws -> (isRegularFile: Bool, isDirectory: Bool))? = nil

    public enum FileResolutionErrorClassification {
        case missingOrInvalid
        case inaccessible
    }

    public static func classifyFileError(_ error: Error) -> FileResolutionErrorClassification {
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

    public func revealRecentExport(sessionID: String) {
        let records: [ExportRecordModel]
        do {
            records = try env.sessions.listExportRecords(sessionID: sessionID)
        } catch {
            env.showToast("Lỗi đọc lịch sử xuất: \(error.localizedDescription)", kind: .warning)
            return
        }

        let successRecords = records.filter { $0.status == .success }
        guard !successRecords.isEmpty else {
            env.showToast("Chưa có bản xuất thành công", kind: .info)
            return
        }

        let sorted = successRecords.sorted { a, b in
            if a.createdAtMs != b.createdAtMs {
                return a.createdAtMs > b.createdAtMs
            }
            let aComp = a.completedAtMs ?? Int64.min
            let bComp = b.completedAtMs ?? Int64.min
            if aComp != bComp {
                return aComp > bComp
            }
            return a.id < b.id
        }

        var hasInaccessible = false
        var hasMissingOrInvalid = false

        for record in sorted {
            guard let path = record.destinationDisplayPath,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  path.hasPrefix("/") else {
                hasMissingOrInvalid = true
                continue
            }
            let fileURL = URL(fileURLWithPath: path)

            do {
                let meta: (isRegularFile: Bool, isDirectory: Bool)
                if let probe = fileMetadataProbe {
                    meta = try probe(fileURL)
                } else {
                    let vals = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    meta = (vals.isRegularFile == true, vals.isDirectory == true)
                }

                if meta.isRegularFile && !meta.isDirectory {
                    env.shareService.revealInFinder(fileURL)
                    return
                } else {
                    hasMissingOrInvalid = true
                    continue
                }
            } catch {
                let classification = Self.classifyFileError(error)
                switch classification {
                case .inaccessible:
                    hasInaccessible = true
                case .missingOrInvalid:
                    hasMissingOrInvalid = true
                }
                continue
            }
        }

        if hasInaccessible {
            env.showToast("Có bản xuất nhưng không thể truy cập tệp", kind: .warning)
        } else if hasMissingOrInvalid {
            env.showToast("Không còn tìm thấy tệp xuất tại vị trí đã lưu", kind: .warning)
        } else {
            env.showToast("Chưa có bản xuất thành công", kind: .info)
        }
    }

    public func revealExport(record: ExportRecordModel) {
        revealRecentExport(sessionID: record.sessionID)
    }

    public func exportRecords(sessionID: String) -> [ExportRecordModel] {
        (try? env.sessions.listExportRecords(sessionID: sessionID)) ?? []
    }
}

/// TrashViewModel (§2.5, §3, §4): lọc, sắp hết hạn, khôi phục, xóa vĩnh viễn, dọn sạch.
@MainActor
public final class TrashViewModel: ObservableObject {
    @Published public private(set) var items: [TrashItem] = []
    @Published public var filter: TrashRootType? = nil
    @Published public var searchText = ""
    @Published public var sortByExpiry = true
    @Published public var selection: Set<String> = []
    @Published public private(set) var totalBytesText = ""
    @Published public private(set) var totalRepoCount: Int = 0
    @Published public private(set) var isPurging: Bool = false

    public var restorableSelectedCount: Int { restorableSelectedItems.count }

    private var restorableSelectedItems: [TrashItem] {
        let now = Time.nowMs()
        return items.filter {
            selection.contains($0.id) && $0.expiresAtMs > now
                && ($0.status == .trashed || $0.status == .purgeFailed)
        }
    }

    // MARK: - Chốt phạm vi xác nhận xóa (TRS-04, §3.2, T01, T02)
    public struct PurgeConfirmationScope: Equatable {
        public enum Kind: Equatable {
            case single(item: TrashItem)
            case selection(items: [TrashItem])
            case all(items: [TrashItem])
        }
        public let kind: Kind
        public let targetIDs: [String]
        public let itemCount: Int
        public let estimatedBytes: Int64
        public let displayName: String?

        public init(kind: Kind, targetIDs: [String], itemCount: Int, estimatedBytes: Int64, displayName: String?) {
            self.kind = kind
            self.targetIDs = targetIDs
            self.itemCount = itemCount
            self.estimatedBytes = estimatedBytes
            self.displayName = displayName
        }
    }

    @Published public var activePurgeScope: PurgeConfirmationScope? = nil
    @Published public var showScopeChangedAlert = false
    @Published public var scopeChangedMessage = ""

    public let env: AppEnvironment

    public init(env: AppEnvironment) { self.env = env }

    public func reload() {
        let allRepoItems = (try? env.trashRepo.list()) ?? []
        totalRepoCount = allRepoItems.count

        var list = allRepoItems
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

    public func prepareSinglePurgeScope(item: TrashItem) -> PurgeConfirmationScope? {
        guard item.status == .trashed || item.status == .purgeFailed else { return nil }
        return PurgeConfirmationScope(
            kind: .single(item: item),
            targetIDs: [item.id],
            itemCount: 1,
            estimatedBytes: item.estimatedBytes,
            displayName: item.displayName
        )
    }

    public func prepareSelectionPurgeScope() -> PurgeConfirmationScope? {
        let eligible = items.filter { selection.contains($0.id) && ($0.status == .trashed || $0.status == .purgeFailed) }
        guard !eligible.isEmpty else { return nil }
        let totalBytes = eligible.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        return PurgeConfirmationScope(
            kind: .selection(items: eligible),
            targetIDs: eligible.map(\.id),
            itemCount: eligible.count,
            estimatedBytes: totalBytes,
            displayName: nil
        )
    }

    public func prepareAllPurgeScope() -> PurgeConfirmationScope? {
        let all = (try? env.trashRepo.list()) ?? []
        let eligible = all.filter { $0.status == .trashed || $0.status == .purgeFailed }
        guard !eligible.isEmpty else { return nil }
        let totalBytes = eligible.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        return PurgeConfirmationScope(
            kind: .all(items: eligible),
            targetIDs: eligible.map(\.id),
            itemCount: eligible.count,
            estimatedBytes: totalBytes,
            displayName: nil
        )
    }

    public func executePurge(scope: PurgeConfirmationScope) {
        guard !env.isManualPurging && !isPurging else {
            env.showToast("Đang có tác vụ dọn khác đang chạy", kind: .warning)
            return
        }
        guard let taskID = env.beginManualPurge() else {
            env.showToast("Đang có tác vụ dọn khác đang chạy", kind: .warning)
            return
        }

        // Đọc lại danh sách và kiểm tra scope shift trước khi thực thi (§3.2, T02)
        let freshItems = (try? env.trashRepo.list()) ?? []
        let validatedItems: [TrashItem]

        switch scope.kind {
        case .single(let orig):
            guard let fresh = freshItems.first(where: { $0.id == orig.id }) else {
                env.endManualPurge(taskID: taskID)
                activePurgeScope = nil
                env.showToast("Mục đã thay đổi hoặc không còn trong Thùng rác", kind: .warning)
                reload()
                return
            }
            guard fresh.status == .trashed || fresh.status == .purgeFailed else {
                env.endManualPurge(taskID: taskID)
                activePurgeScope = nil
                env.showToast("Mục đang trong thao tác khác", kind: .warning)
                reload()
                return
            }
            if fresh.estimatedBytes != orig.estimatedBytes {
                env.endManualPurge(taskID: taskID)
                activePurgeScope = PurgeConfirmationScope(
                    kind: .single(item: fresh),
                    targetIDs: [fresh.id],
                    itemCount: 1,
                    estimatedBytes: fresh.estimatedBytes,
                    displayName: fresh.displayName
                )
                scopeChangedMessage = "Dung lượng mục đã thay đổi (\(FileLayout.formattedBytes(fresh.estimatedBytes)))."
                showScopeChangedAlert = true
                return
            }
            validatedItems = [fresh]

        case .selection(let originalItems):
            let freshSelected = freshItems.filter { item in
                scope.targetIDs.contains(item.id) && (item.status == .trashed || item.status == .purgeFailed)
            }
            let freshBytes = freshSelected.reduce(Int64(0)) { $0 + $1.estimatedBytes }
            let originalBytes = originalItems.reduce(Int64(0)) { $0 + $1.estimatedBytes }
            if Set(freshSelected.map(\.id)) != Set(scope.targetIDs) || freshBytes != originalBytes {
                env.endManualPurge(taskID: taskID)
                if freshSelected.isEmpty {
                    activePurgeScope = nil
                    env.showToast("Các mục đã chọn không còn đủ điều kiện xóa", kind: .warning)
                    reload()
                    return
                }
                activePurgeScope = PurgeConfirmationScope(
                    kind: .selection(items: freshSelected),
                    targetIDs: freshSelected.map(\.id),
                    itemCount: freshSelected.count,
                    estimatedBytes: freshBytes,
                    displayName: nil
                )
                scopeChangedMessage = "Danh sách mục hoặc dung lượng đã thay đổi (\(freshSelected.count) mục, \(FileLayout.formattedBytes(freshBytes)))."
                showScopeChangedAlert = true
                return
            }
            validatedItems = freshSelected

        case .all(let originalItems):
            let freshAll = freshItems.filter { $0.status == .trashed || $0.status == .purgeFailed }
            let freshBytes = freshAll.reduce(Int64(0)) { $0 + $1.estimatedBytes }
            let originalBytes = originalItems.reduce(Int64(0)) { $0 + $1.estimatedBytes }
            if Set(freshAll.map(\.id)) != Set(scope.targetIDs) || freshBytes != originalBytes {
                env.endManualPurge(taskID: taskID)
                if freshAll.isEmpty {
                    activePurgeScope = nil
                    env.showToast("Thùng rác không còn mục nào đủ điều kiện xóa", kind: .info)
                    reload()
                    return
                }
                activePurgeScope = PurgeConfirmationScope(
                    kind: .all(items: freshAll),
                    targetIDs: freshAll.map(\.id),
                    itemCount: freshAll.count,
                    estimatedBytes: freshBytes,
                    displayName: nil
                )
                scopeChangedMessage = "Toàn bộ kho đã thay đổi (\(freshAll.count) mục, \(FileLayout.formattedBytes(freshBytes)))."
                showScopeChangedAlert = true
                return
            }
            validatedItems = freshAll
        }

        activePurgeScope = nil
        isPurging = true
        let trashService = env.trashService

        Task.detached(priority: .utility) { [weak self, validatedItems] in
            let report = trashService.purgeAll(items: validatedItems)
            await MainActor.run {
                guard let self else { return }
                self.env.endManualPurge(taskID: taskID)
                self.isPurging = false
                self.selection.subtract(validatedItems.map(\.id))
                self.reload()
                if report.failed > 0 {
                    self.env.showToast("Xóa: \(report.success) thành công / \(report.failed) lỗi / \(report.skipped) bỏ qua", kind: .warning)
                } else if report.skipped > 0 {
                    self.env.showToast("Đã xóa \(report.success) mục (\(report.skipped) mục bỏ qua do đã thay đổi)")
                } else {
                    self.env.showToast("Đã xóa vĩnh viễn \(report.success) mục")
                }
            }
        }
    }

    public func restoreSelected() {
        guard !env.isManualPurging && !isPurging else {
            env.showToast("Đang có tác vụ dọn khác đang chạy", kind: .warning)
            return
        }
        let selectedItems = items.filter { selection.contains($0.id) }
        let validItems = restorableSelectedItems
        let expiredOrInvalidCount = selectedItems.count - validItems.count

        guard !validItems.isEmpty else {
            if expiredOrInvalidCount > 0 {
                env.showToast("Các mục đã chọn đã hết hạn hoặc không thể khôi phục", kind: .warning)
            }
            return
        }

        var ok = 0
        var skipped = 0
        var fail = 0
        for item in validItems {
            switch env.trashService.restoreResult(item) {
            case .processed: ok += 1
            case .skipped: skipped += 1
            case .failed: fail += 1
            }
        }
        selection.removeAll()
        reload()

        let totalSkipped = skipped + expiredOrInvalidCount
        if fail > 0 {
            env.showToast("Khôi phục: \(ok) thành công / \(fail) lỗi / \(totalSkipped) bỏ qua", kind: .warning)
        } else if totalSkipped > 0 {
            env.showToast("Đã khôi phục \(ok) mục (bỏ qua \(totalSkipped) mục hết hạn hoặc không khả dụng)")
        } else {
            env.showToast("Đã khôi phục \(ok) mục")
        }
    }

    public func restore(item: TrashItem) {
        guard !env.isManualPurging && !isPurging else {
            env.showToast("Đang có tác vụ dọn khác đang chạy", kind: .warning)
            return
        }
        let now = Time.nowMs()
        guard item.expiresAtMs > now else {
            env.showToast("Mục đã quá hạn 30 ngày trong Thùng rác", kind: .warning)
            return
        }
        switch env.trashService.restoreResult(item) {
        case .processed:
            env.showToast("Đã khôi phục: \(item.displayName)")
        case .skipped(let reason):
            env.showToast("Không thể khôi phục: \(reason)", kind: .warning)
        case .failed(let error):
            env.showToast("Khôi phục thất bại: \(error)", kind: .warning)
        }
        reload()
    }

    public func purgeSelected() {
        if let scope = prepareSelectionPurgeScope() {
            activePurgeScope = scope
        }
    }

    public func emptyTrash() {
        if let scope = prepareAllPurgeScope() {
            activePurgeScope = scope
        }
    }
}
