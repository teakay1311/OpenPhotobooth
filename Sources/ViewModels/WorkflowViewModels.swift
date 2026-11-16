import Foundation
import SwiftUI
import AppKit
import CoreGraphics

/// ExportViewModel (Sheet H §2.9): format/quality/size/name/folder + tiến độ.
@MainActor
public final class ExportViewModel: ObservableObject {
    @Published public var format: ExportImageFormat = .jpeg
    @Published public var quality: Int = 95
    @Published public var width: Int = 1200
    @Published public var height: Int = 1800
    @Published public var aspectLocked = true
    @Published public var filename: String = ""
    @Published public var folderURL: URL?
    @Published public var replaceExisting = false
    @Published public private(set) var isExporting = false
    @Published public private(set) var lastResultURL: URL?
    @Published private(set) var historySaveFailed = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var previewImage: CGImage?
    @Published public private(set) var isPreviewLoading = false

    public let env: AppEnvironment
    public var review: ReviewViewModel?
    private var previewTask: Task<Void, Never>?
    private var acceptedPreview: ExportService.PreviewIdentity?
    private var destinationBookmark: TrashRepository.BookmarkUse?
    private var resultBookmark: TrashRepository.BookmarkUse?
    var canExportPreview: Bool { acceptedPreview != nil && !isPreviewLoading }
    var previewUnavailable: Bool { !isPreviewLoading && previewImage == nil }

    public init(env: AppEnvironment) {
        self.env = env
        format = env.settings.exportFormat
        quality = env.settings.jpegQuality
    }

    public func configure(detail: SessionDetail) {
        width = detail.snapshot.canvasWidth
        height = detail.snapshot.canvasHeight
        filename = ExportService.defaultFilenameBase()
        if let bookmarkID = env.settings.exportFolderBookmarkID {
            do {
                let use = try env.trashRepo.useBookmark(id: bookmarkID)
                folderURL = try env.exportService.resolveExportFolder(bookmarkID: use.id)
                destinationBookmark = use
            } catch {
                folderURL = nil
                errorMessage = "Không còn quyền truy cập thư mục mặc định. Hãy chọn lại."
            }
        }
        updatePreview()
    }

    public func setWidth(_ w: Int) {
        width = min(max(w, ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        if aspectLocked, let detail = currentDetail() {
            let ratio = Double(detail.snapshot.canvasHeight) / Double(detail.snapshot.canvasWidth)
            height = min(max(Int(Double(width) * ratio), ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        }
        updatePreview()
    }

    public func setHeight(_ h: Int) {
        height = min(max(h, ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        if aspectLocked, let detail = currentDetail() {
            let ratio = Double(detail.snapshot.canvasWidth) / Double(detail.snapshot.canvasHeight)
            width = min(max(Int(Double(height) * ratio), ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        }
        updatePreview()
    }

    public func updatePreview() {
        previewTask?.cancel()
        acceptedPreview = nil
        previewImage = nil
        guard let detail = currentDetail() else {
            isPreviewLoading = false
            return
        }
        let identity = previewIdentity(detail)
        isPreviewLoading = true
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let image = await env.renderBuilder.renderPreview(
                detail: detail, maxDimension: 480, format: identity.format,
                outputSize: (identity.width, identity.height), verifiedSources: true)
            guard !Task.isCancelled else { return }
            guard let latest = currentDetail(), previewIdentity(latest) == identity else {
                updatePreview()
                return
            }
            previewImage = image
            acceptedPreview = image == nil ? nil : identity
            isPreviewLoading = false
        }
    }

    private func previewIdentity(_ detail: SessionDetail) -> ExportService.PreviewIdentity {
        ExportService.PreviewIdentity(detail: detail, format: format, width: width, height: height, quality: quality)
    }

    private func currentDetail() -> SessionDetail? {
        guard let id = review?.detail?.session.id else { return nil }
        return try? env.sessions.getDetail(sessionID: id)
    }

    public func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Chọn thư mục"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.folderURL = url
                self.destinationBookmark = nil
                do {
                    let id = try self.env.saveDefaultExportFolder(url)
                    self.destinationBookmark = try self.env.trashRepo.useBookmark(id: id)
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = "Không lưu được thư mục mặc định. Bạn vẫn có thể thử xuất lần này."
                }
            }
        }
    }

    public func runExport() async {
        guard !isExporting, let review, let detail = currentDetail() else { return }
        lastResultURL = nil
        historySaveFailed = false
        resultBookmark = nil
        errorMessage = nil
        guard let acceptedPreview, acceptedPreview == previewIdentity(detail) else {
            errorMessage = AppError.exportPreviewChanged.message
            updatePreview()
            return
        }
        guard let folder = folderURL else {
            errorMessage = "Chọn thư mục xuất"
            return
        }
        isExporting = true
        errorMessage = nil
        env.settings.exportFormat = format
        env.settings.jpegQuality = quality
        env.settings.exportWidth = width
        env.settings.exportHeight = height
        var request = ExportService.ExportRequest(
            sessionID: detail.session.id, format: format, quality: quality,
            width: width, height: height, filenameBase: filename,
            destinationFolder: folder, securityScoped: true, replaceExisting: replaceExisting)
        request.acceptedPreview = acceptedPreview
        request.destinationBookmark = destinationBookmark
        let result = await review.runExport(request: request)
        isExporting = false
        switch result {
        case .success(let url):
            lastResultURL = url
            resultBookmark = request.destinationBookmark
        case .failure(.exportHistoryNotSaved(let url)):
            historySaveFailed = true
            lastResultURL = url
            resultBookmark = request.destinationBookmark
            errorMessage = AppError.exportHistoryNotSaved(url).message
        case .failure(.exportPreviewChanged):
            errorMessage = AppError.exportPreviewChanged.message
            updatePreview()
        case .failure(let error):
            errorMessage = error.message   // không đóng sheet, không ghi success giả (§2.9)
        }
    }

    public func revealResult() {
        guard let url = lastResultURL else { return }
        let folder = resultBookmark.flatMap { try? env.exportService.resolveExportFolder(bookmarkID: $0.id) }
        let accessing = folder?.startAccessingSecurityScopedResource() == true
        defer { if accessing { folder?.stopAccessingSecurityScopedResource() } }
        env.shareService.revealInFinder(url)
    }
}

/// FramePackImportViewModel (Sheet I §2.10): verify trước, preview, policy từng khung.
@MainActor
public final class FramePackImportViewModel: ObservableObject {
    public enum ImportPhase: Equatable {
        case idle
        case verifying
        case ready
        case importing
        case completed
        case failedBeforeWrite(String)
        case failedUnknown(String)
    }

    @Published public private(set) var phase: ImportPhase = .idle
    @Published public private(set) var packResult: PackValidationResult?
    @Published public private(set) var packName: String = ""
    @Published public private(set) var warnings: [String] = []
    @Published public var choices: [String: (policy: PackDuplicatePolicy, selected: Bool)] = [:]
    @Published public private(set) var isImporting = false
    @Published public private(set) var results: [String: Result<String, String>]?
    @Published public private(set) var itemStatuses: [String: FramePackService.PackItemStatus]?
    @Published public private(set) var partiallyWrittenCount: Int = 0
    @Published public private(set) var fatalMessage: String?
    @Published public var replaceConfirmPending: String? = nil

    public let env: AppEnvironment
    private var packData: Data?

    public init(env: AppEnvironment) { self.env = env }

    /// Xác minh gói TRƯỚC preview (§2.10); không giải nén trực tiếp vào thư viện.
    /// Verify + giải nén + SHA256 chạy nền để không block MainActor (P3).
    public func loadAndValidate(url: URL) async {
        phase = .verifying
        fatalMessage = nil
        results = nil
        itemStatuses = nil
        partiallyWrittenCount = 0
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let packService = env.packService
            let result = try await Task.detached(priority: .userInitiated) {
                try packService.loadPack(data: data)
            }.value
            packData = data
            packResult = result
            packName = result.manifest.name
            warnings = result.warnings
            var map: [String: (policy: PackDuplicatePolicy, selected: Bool)] = [:]
            for entry in result.entries {
                let policy: PackDuplicatePolicy = entry.isDuplicate ? .skip : .copy
                map[entry.frame.frameId] = (policy, true)
            }
            choices = map
            phase = .ready
        } catch let e as AppError {
            fatalMessage = e.message   // E-FRM-05: không import
            phase = .failedBeforeWrite(e.message)
        } catch {
            fatalMessage = error.localizedDescription
            phase = .failedBeforeWrite(error.localizedDescription)
        }
    }

    public func applyImport() {
        // FRM-01: Ngăn nhập lại khi đang áp dụng hoặc đã có kết quả
        guard !isImporting, results == nil else { return }
        switch phase {
        case .ready, .failedBeforeWrite: break
        default: return
        }
        guard let result = packResult, let data = packData else { return }
        let selectedList = choices.filter { $0.value.selected }
        guard !selectedList.isEmpty else { return }

        isImporting = true
        phase = .importing
        fatalMessage = nil
        let list = result.entries.map { entry in
            FramePackService.ImportChoice(packFrameID: entry.frame.frameId,
                                          policy: choices[entry.frame.frameId]?.policy ?? .skip,
                                          selected: choices[entry.frame.frameId]?.selected ?? false)
        }
        let packService = env.packService
        Task {
            do {
                // Import (extract + store assets + transactions) chạy nền để không block UI
                let statuses = try await Task.detached(priority: .userInitiated) {
                    try packService.applyImportDetailed(result: result, choices: list, data: data)
                }.value
                await MainActor.run {
                    self.itemStatuses = statuses
                    var outMap: [String: Result<String, String>] = [:]
                    for (id, s) in statuses {
                        switch s {
                        case .imported(let fid), .replaced(let fid):
                            outMap[id] = .success(fid)
                        case .skipped:
                            outMap[id] = .success("Bỏ qua")
                        case .unselected:
                            outMap[id] = .success("Đã bỏ chọn")
                        case .failedBeforeWrite(let r):
                            outMap[id] = .failure("Thất bại trước khi ghi: \(r)")
                        case .partiallyWritten(let r):
                            outMap[id] = .failure("Có thể đã ghi một phần: \(r)")
                        }
                    }
                    self.results = outMap
                    self.isImporting = false
                    self.phase = .completed
                    let okCount = statuses.values.filter(\.isSuccess).count
                    self.partiallyWrittenCount = statuses.values.filter {
                        if case .partiallyWritten = $0 { return true }; return false
                    }.count
                    self.env.showToast("Nhập gói: \(okCount)/\(statuses.count) mục thành công")
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    let msg = (error as? AppError)?.message ?? error.localizedDescription
                    self.fatalMessage = "Nhập thất bại: \(msg)"
                    self.phase = .failedBeforeWrite(msg)
                }
            }
        }
    }
}

/// FullscreenViewModel (§14): Welcome → Chọn khung → Live → Countdown/Chụp → Review → Kết thúc.
@MainActor
public final class FullscreenViewModel: ObservableObject {
    @Published public var step: FullscreenStep = .welcome
    @Published public private(set) var readyFrames: [FrameCardModel] = []
    @Published public var selectedFrameID: String?
    @Published public private(set) var idleSecondsLeft: Int?
    @Published public private(set) var isStarting = false
    @Published public private(set) var isFinishing = false
    @Published public var shareSheetOpen = false
    @Published public private(set) var reviewVM: ReviewViewModel?

    public let env: AppEnvironment
    public var engine: CaptureEngine { env.engine }
    private var idleTimer: Timer?
    private let captureVM: CaptureViewModel

    public init(env: AppEnvironment, captureVM: CaptureViewModel) {
        self.env = env
        self.captureVM = captureVM
    }

    public func enterFullscreen() {
        selectedFrameID = env.settings.fullscreenDefaultFrame.isEmpty ? nil : env.settings.fullscreenDefaultFrame
        reloadFrames()
        step = .welcome
    }

    public func reloadFrames() {
        let list = (try? env.frames.listReadyFrames()) ?? []
        var filtered = list
        if env.settings.fullscreenFrameFilter != "all" {
            filtered = filtered.filter { $0.categoryID == env.settings.fullscreenFrameFilter }
        }
        if !filtered.contains(where: { $0.id == selectedFrameID }) {
            selectedFrameID = nil
        }
        readyFrames = filtered.map { f in
            let slots = f.currentRevisionID.flatMap { (try? env.frames.getSlots(revisionID: $0)) ?? [] } ?? []
            let revID = f.currentRevisionID ?? f.id
            let thumb = env.frameThumbnails.cachedThumbnail(frameID: f.id, revisionID: revID)
            return FrameCardModel(frame: f, thumbnail: thumb, slotCount: Set(slots.map(\.captureIndex)).count)
        }
        for f in filtered {
            if let revID = f.currentRevisionID {
                if env.frameThumbnails.cachedThumbnail(frameID: f.id, revisionID: revID) == nil {
                    let fid = f.id
                    Task { @MainActor [weak self] in
                        if let data = await self?.env.frameThumbnails.requestThumbnail(frameID: fid, revisionID: revID) {
                            if let idx = self?.readyFrames.firstIndex(where: { $0.id == fid }) {
                                self?.readyFrames[idx].thumbnail = data
                            }
                        }
                    }
                }
            }
        }
    }

    public func beginShooting() async {
        guard !isStarting, !engine.isCaptureBusy, !engine.hasPhotoToSave,
              let selectedFrameID, readyFrames.contains(where: { $0.id == selectedFrameID }),
              captureVM.isCameraReady else { return }
        isStarting = true
        defer { isStarting = false }

        engine.keepSessionAndExit()
        captureVM.selectFrame(selectedFrameID)
        await captureVM.startNewSession()
        guard env.showFullscreen, !Task.isCancelled else {
            if engine.isCaptureBusy { engine.pause() }
            return
        }
        if engine.state == .reviewing {
            await openReview()
        } else if engine.session != nil {
            step = .live
        } else {
            env.showToast("Không bắt đầu được phiên chụp", kind: .warning)
        }
    }

    public func openReview() async {
        guard reviewVM == nil, let id = engine.session?.id else { return }
        let vm = ReviewViewModel(env: env)
        reviewVM = vm
        await vm.load(sessionID: id)
        guard env.showFullscreen, engine.session?.id == id else { return }
        step = .review
    }

    public func finish() async {
        guard !isFinishing, let id = reviewVM?.detail?.session.id else { return }
        isFinishing = true
        defer { isFinishing = false }
        do {
            _ = try await env.completeSession(sessionID: id)
            if env.showFullscreen { step = .finish }
        } catch {
            env.showToast((error as? AppError)?.message ?? "Không thể hoàn thành phiên", kind: .warning)
        }
    }

    public func backToWelcome() {
        step = .welcome
        reviewVM = nil
        pauseIdleTimer()
    }

    // MARK: - Idle return (§14.3 — chỉ áp dụng ở màn Finish)

    public func startIdleTimer(seconds: Int? = nil) {
        idleTimer?.invalidate()
        let total = seconds ?? env.settings.fullscreenIdleReturn
        idleSecondsLeft = total > 0 ? total : nil
        guard total > 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                // Không timeout khi share picker mở / sheet / đang chụp (FS-03)
                if self.shareSheetOpen || self.engine.isCaptureBusy {
                    return
                }
                guard self.step == .finish else { t.invalidate(); return }
                self.idleSecondsLeft = (self.idleSecondsLeft ?? 1) - 1
                if self.idleSecondsLeft ?? 0 <= 0 {
                    t.invalidate()
                    self.backToWelcome()
                }
            }
        }
    }

    public func pauseIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    public func userInteracted() {
        if step == .finish { startIdleTimer() }
    }

    public func exitFullscreenRequested() {
        // Đang capture → tạm dừng và giữ phiên, không tự hủy (§14.1, FS-02)
        if engine.isCaptureBusy {
            engine.pause()
        } else if engine.session != nil {
            engine.keepSessionAndExit()
        }
        pauseIdleTimer()
    }
}
