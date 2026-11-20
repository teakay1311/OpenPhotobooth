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

    public enum LibraryFilter: String, CaseIterable, Sendable {
        case all = "Tất cả"
        case completed = "Đủ ảnh"
        case incomplete = "Chưa đủ ảnh"
    }

    public let env: AppEnvironment

    public init(env: AppEnvironment) { self.env = env }

    /// Both Library share entry points use the same fresh-data checks and error reporting.
    func prepareShareFile(for card: SessionCardModel) async -> URL? {
        do {
            try Task.checkCancellation()
            guard let detail = try env.sessions.getDetail(sessionID: card.id),
                  detail.session.status != .trashed && detail.session.status != .purging else {
                env.showToast("Phiên chụp không còn khả dụng", kind: .warning)
                reload()
                return nil
            }
            guard !detail.session.awaitsFrame else {
                env.showToast("Cần chọn khung ảnh", kind: .warning)
                reload()
                return nil
            }
            guard !detail.needsPhotoSelection else {
                env.showToast("Cần chọn ảnh vào khung", kind: .warning)
                reload()
                return nil
            }
            guard detail.hasEnoughPhotos else {
                env.showToast("Chưa đủ ảnh", kind: .warning)
                reload()
                return nil
            }
            let url = try await env.shareService.prepareShareFile(detail: detail, filenameBase: card.frameName)
            try Task.checkCancellation()
            return url
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            env.showToast("Không chuẩn bị được file chia sẻ: \((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
            return nil
        }
    }

    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    @discardableResult
    public func reload() -> Task<Void, Never> {
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration
        let repository = env.sessions
        let search = searchText
        let filter = filter
        let newest = sortNewest
        let locale = Locale.current
        let timeZone = TimeZone.current
        let worker = Task.detached(priority: .userInitiated) { () throws -> [SessionCardModel] in
            try Task.checkCancellation()
            let raw = try repository.listSessions()
            let dateFormatter = DateFormatter()
            dateFormatter.locale = locale
            dateFormatter.timeZone = timeZone
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            var cards: [SessionCardModel] = []
            for card in newest ? raw : Array(raw.reversed()) {
                try Task.checkCancellation()
                let complete = card.committedCount >= card.session.captureCount
                if (filter == .completed && !complete) || (filter == .incomplete && complete) { continue }
                let name = Self.frameName(for: card)
                let date = dateFormatter.string(from: Time.date(ms: card.session.createdAtMs))
                if !search.isEmpty &&
                    name.range(of: search, options: .caseInsensitive, locale: locale) == nil &&
                    date.range(of: search, options: .caseInsensitive, locale: locale) == nil { continue }
                // The existing visible-card task loads cached previews by revision.
                cards.append(SessionCardModel(card: card, frameName: name, preview: nil, formattedDate: date))
            }
            return cards
        }
        let task = Task { [weak self] in
            do {
                let cards = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.reloadGeneration == generation else { return }
                self.cards = cards
            } catch {
                guard let self, !Task.isCancelled, self.reloadGeneration == generation else { return }
                self.env.showToast("Không thể tải thư viện: \((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
            }
        }
        reloadTask = task
        return task
    }

    private nonisolated static func frameName(for card: SessionRepository.SessionCard) -> String {
        if card.session.awaitsFrame { return "Chưa chọn khung" }
        if let applied = card.session.defaults.appliedFrameName { return applied }
        if let atCapture = card.session.frameNameAtCapture, !atCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return atCapture
        }
        return card.sourceFrameName ?? "Không rõ tên khung lúc chụp"
    }

    // Monitoring & event sync (LIB-06)
    private var eventTask: Task<Void, Never>?
    private var scheduledReloadTask: Task<Void, Never>?

    @discardableResult
    public func startEventMonitoring() -> Task<Void, Never> {
        stopEventMonitoring()
        let stream = EventBus.shared.stream
        let initialLoad = reload()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .sessionChanged, .shotCommitted, .photoAdjusted, .frameSnapshotChanged:
                    self.scheduleDebouncedReload()
                default:
                    break
                }
            }
        }
        return initialLoad
    }

    public func stopEventMonitoring() {
        reloadGeneration += 1
        reloadTask?.cancel()
        reloadTask = nil
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
        if detail.session.awaitsFrame {
            env.openReview(sessionID: sessionID, source: .library)
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
        if detail.session.awaitsFrame {
            env.openReview(sessionID: sessionID, source: .library)
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
        let cacheKey = "session-r\(CompositeRenderer.renderCacheVersion)-\(sessionID)-\(targetRevision)"

        if let cached = env.thumbnails.cachedData(key: cacheKey) {
            return cached
        }

        activeRenderTokens[sessionID] = targetRevision

        guard let detail = try? env.sessions.getDetail(sessionID: sessionID) else { return nil }
        guard detail.session.revisionNo == targetRevision else { return nil }

        if detail.hasEnoughPhotos,
           let img = await env.renderBuilder.renderPreview(detail: detail, maxDimension: 420,
                                                           verifiedSources: detail.session.defaults.plannedCaptureCount != nil) {
            guard !Task.isCancelled else { return nil }
            guard activeRenderTokens[sessionID] == targetRevision else { return nil }
            guard let current = try? env.sessions.getSession(id: sessionID), current.revisionNo == targetRevision else { return nil }
            guard let data = CIContextHolder.shared.context.pngRepresentation(
                of: CIImage(cgImage: img), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
            env.thumbnails.store(data: data, key: cacheKey)
            return data
        } else {
            for entry in detail.currentRevisions(includeUnassigned: detail.session.defaults.plannedCaptureCount != nil).sorted(by: { $0.key < $1.key }) {
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

        revealAvailableExport(in: records)
    }

    private func revealAvailableExport(in records: [ExportRecordModel]) {
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
            let storedURL = URL(fileURLWithPath: path)
            do {
                let bookmark = try record.destinationBookmarkID.map { try env.trashRepo.useBookmark(id: $0) }
                defer { withExtendedLifetime(bookmark) {} }
                let folder = try bookmark.map { try env.exportService.resolveExportFolder(bookmarkID: $0.id) }
                let accessing = folder?.startAccessingSecurityScopedResource() == true
                defer { if accessing { folder?.stopAccessingSecurityScopedResource() } }
                let fileURL = folder?.appendingPathComponent(storedURL.lastPathComponent) ?? storedURL
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
                let classification = (error as? AppError) == .externalFolderPermissionLost
                    ? .inaccessible : Self.classifyFileError(error)
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
        revealAvailableExport(in: [record])
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
        public let plan: TrashService.PurgePlan?

        public init(kind: Kind, targetIDs: [String], itemCount: Int, estimatedBytes: Int64, displayName: String?, plan: TrashService.PurgePlan? = nil) {
            self.kind = kind
            self.targetIDs = targetIDs
            self.itemCount = itemCount
            self.estimatedBytes = estimatedBytes
            self.displayName = displayName
            self.plan = plan
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

    public var selectableIDs: Set<String> {
        Set(items.filter { $0.status == .trashed || $0.status == .purgeFailed }.map(\.id))
    }

    public func selectAllVisible() { selection = selectableIDs }
    public func clearSelection() { selection.removeAll() }
    @Published public private(set) var batchDetails = ""

    private func makeScope(kind: PurgeConfirmationScope.Kind, items: [TrashItem], name: String? = nil) -> PurgeConfirmationScope? {
        let eligible = items.filter { $0.status == .trashed || $0.status == .purgeFailed }
        guard !eligible.isEmpty, let plan = try? env.trashService.purgePlan(items: eligible) else { return nil }
        return PurgeConfirmationScope(kind: kind, targetIDs: eligible.map(\.id), itemCount: plan.affectedIDs.count,
            estimatedBytes: plan.estimatedBytes, displayName: name, plan: plan)
    }

    public func prepareSinglePurgeScope(item: TrashItem) -> PurgeConfirmationScope? {
        makeScope(kind: .single(item: item), items: [item], name: item.displayName)
    }

    public func prepareSelectionPurgeScope() -> PurgeConfirmationScope? {
        let chosen = items.filter { selection.contains($0.id) }
        return makeScope(kind: .selection(items: chosen), items: chosen)
    }

    public func prepareAllPurgeScope() -> PurgeConfirmationScope? {
        guard let all = try? env.trashRepo.list() else { return nil }
        return makeScope(kind: .all(items: all), items: all)
    }

    public func executePurge(scope: PurgeConfirmationScope) {
        guard !env.isManualPurging, !isPurging, let taskID = env.beginManualPurge() else {
            env.showToast("Đang có tác vụ dọn khác đang chạy", kind: .warning)
            return
        }
        let all = (try? env.trashRepo.list()) ?? []
        let current: PurgeConfirmationScope?
        switch scope.kind {
        case .single(let item):
            current = all.first(where: { $0.id == item.id }).flatMap { prepareSinglePurgeScope(item: $0) }
        case .selection:
            let selected = all.filter { scope.targetIDs.contains($0.id) }
            current = makeScope(kind: .selection(items: selected), items: selected)
        case .all: current = prepareAllPurgeScope()
        }
        guard let current, let plan = current.plan else {
            env.endManualPurge(taskID: taskID)
            activePurgeScope = nil
            reload()
            env.showToast("Mục không còn đủ điều kiện xóa", kind: .warning)
            return
        }
        guard scope.plan == plan else {
            env.endManualPurge(taskID: taskID)
            activePurgeScope = current
            scopeChangedMessage = "Phạm vi đã thay đổi: \(current.itemCount) mục, \(FileLayout.formattedBytes(current.estimatedBytes))."
            showScopeChangedAlert = true
            return
        }
        activePurgeScope = nil
        isPurging = true
        batchDetails = ""
        let service = env.trashService
        let environment = env
        Task.detached(priority: .utility) { [weak self] in
            let result = service.purgeConfirmed(plan)
            await MainActor.run {
                environment.endManualPurge(taskID: taskID)
                guard let self else { return }
                self.isPurging = false
                let processed = Set(result.results.compactMap { $0.value == .processed ? $0.key : nil })
                self.selection.subtract(processed)
                let names = Dictionary(uniqueKeysWithValues: (plan.targets + plan.includedChildren).map { ($0.id, $0.displayName) })
                self.batchDetails = plan.affectedIDs.sorted().map { id in
                    let label = names[id] ?? id
                    guard let value = result.results[id] else { return "\(label): Chưa xử lý" }
                    switch value {
                    case .processed: return "\(label): Đã xóa"
                    case .failed(let reason): return "\(label): Lỗi — \(reason)"
                    case .skipped(let reason): return "\(label): Bỏ qua — \(reason)"
                    }
                }.joined(separator: "\n")
                self.reload()
                self.env.showToast("Đã xóa \(processed.count)/\(plan.affectedIDs.count) mục", kind: processed.count == plan.affectedIDs.count ? .success : .warning)
                if result.scopeChanged {
                    // Keep remaining items selected; never continue after a changed destructive scope.
                    let remaining = (try? self.env.trashRepo.list())?.filter { scope.targetIDs.contains($0.id) } ?? []
                    self.activePurgeScope = self.makeScope(kind: .selection(items: remaining), items: remaining)
                    self.scopeChangedMessage = "Phạm vi đã thay đổi trong khi dọn. Các mục còn lại chưa được xóa."
                    self.showScopeChangedAlert = self.activePurgeScope != nil
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
        for item in validItems.sorted(by: { ($0.rootType == .session ? 0 : 1) < ($1.rootType == .session ? 0 : 1) }) {
            switch env.trashService.restoreResult(item) {
            case .processed:
                ok += 1
                selection.remove(item.id)
            case .skipped: skipped += 1
            case .failed: fail += 1
            }
        }
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
