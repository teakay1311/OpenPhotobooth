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
    @Published public var aspectLocked = true {
        didSet {
            if aspectLocked && !oldValue { setWidth(width) }
        }
    }
    @Published public var filename: String = ""
    @Published private var selectedFolder: FolderSelection?
    public var folderURL: URL? { selectedFolder?.url }
    @Published public var replaceExisting = false
    @Published public private(set) var isExporting = false
    @Published private var lastResult: ExportResult?
    public var lastResultURL: URL? { lastResult?.file.url }
    var historySaveFailed: Bool { lastResult?.historySaveFailed == true }
    @Published public private(set) var errorMessage: String?
    @Published private(set) var finderWarning: String?
    @Published public private(set) var previewImage: CGImage?
    @Published public private(set) var isPreviewLoading = false

    public let env: AppEnvironment
    public var review: ReviewViewModel?
    private var previewTask: Task<Void, Never>?
    private var acceptedPreview: ExportService.PreviewIdentity?
    private var finderRequestID: UUID?
    private var finderRequestTask: Task<Void, Never>?
    #if DEBUG
    var onFinderHashForTesting: (@Sendable (URL) throws -> Void)?
    #endif
    var canExportPreview: Bool { acceptedPreview != nil && !isPreviewLoading }
    var previewUnavailable: Bool { !isPreviewLoading && previewImage == nil }

    private struct ExportResult {
        let file: ExportedFile
        let folder: FolderSelection
        let historySaveFailed: Bool
    }

    private struct FolderSelection {
        let url: URL
        let identity: ExportService.DirectoryIdentity
        var bookmark: TrashRepository.BookmarkUse?

        init(url: URL, bookmark: TrashRepository.BookmarkUse? = nil) throws {
            self.url = url
            self.identity = try ExportService.DirectoryIdentity.read(url)
            self.bookmark = bookmark
        }
    }

    public init(env: AppEnvironment) {
        self.env = env
        format = env.settings.exportFormat
        quality = env.settings.jpegQuality
    }

    public func configure(detail: SessionDetail) {
        width = detail.snapshot.canvasWidth
        height = detail.snapshot.canvasHeight
        filename = ExportService.defaultFilenameBase()
        selectedFolder = nil
        if let bookmarkID = env.settings.exportFolderBookmarkID {
            do {
                let use = try env.trashRepo.useBookmark(id: bookmarkID)
                let url = try env.exportService.resolveExportFolder(bookmarkID: use.id)
                selectedFolder = try FolderSelection(url: url, bookmark: use)
            } catch {
                errorMessage = "Không còn quyền truy cập thư mục mặc định. Hãy chọn lại."
            }
        }
        updatePreview()
    }

    public func setWidth(_ w: Int) {
        setSize(w, editingWidth: true)
    }

    public func setHeight(_ h: Int) {
        setSize(h, editingWidth: false)
    }

    private func setSize(_ requested: Int, editingWidth: Bool) {
        let lower = ResourceLimits.canvasMin, upper = ResourceLimits.canvasMax
        if aspectLocked, let snapshot = currentDetail()?.snapshot,
           snapshot.canvasWidth > 0, snapshot.canvasHeight > 0 {
            let primary = Double(editingWidth ? snapshot.canvasWidth : snapshot.canvasHeight)
            let secondary = Double(editingWidth ? snapshot.canvasHeight : snapshot.canvasWidth)
            let ratio = secondary / primary
            let minimum = max(lower, Int(ceil(Double(lower) / ratio)))
            let maximum = min(upper, Int(floor(Double(upper) / ratio)))
            if minimum <= maximum {
                var low = minimum
                var high = min(maximum, max(minimum, requested))
                let maxArea = ResourceLimits.maxMegapixels * 1_000_000
                // Find the greatest valid primary size at or below the request.
                while low < high {
                    let mid = (low + high + 1) / 2
                    let paired = (Double(mid) * ratio).rounded()
                    if Double(mid) * paired <= maxArea { low = mid }
                    else { high = mid - 1 }
                }
                let paired = Int((Double(low) * ratio).rounded())
                if editingWidth { (width, height) = (low, paired) }
                else { (width, height) = (paired, low) }
            }
        } else if editingWidth {
            width = min(max(requested, lower), upper)
        } else {
            height = min(max(requested, lower), upper)
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
            Task { @MainActor in self.selectFolder(url) }
        }
    }

    func selectFolder(_ url: URL) {
        guard !isExporting else { return }
        do {
            var selection = try FolderSelection(url: url)
            errorMessage = nil
            let bookmarkID: String
            do {
                bookmarkID = try env.saveDefaultExportFolder(url)
            } catch {
                selectedFolder = selection
                errorMessage = "Không lưu được thư mục mặc định. Bạn vẫn có thể thử xuất lần này."
                return
            }
            selection.bookmark = try env.trashRepo.useBookmark(id: bookmarkID)
            selectedFolder = selection
        } catch {
            selectedFolder = nil
            errorMessage = AppError.exportFolderChanged.message
        }
    }

    public func runExport() async {
        guard !isExporting, let review, let detail = currentDetail() else { return }
        cancelResultReveal()
        lastResult = nil
        finderWarning = nil
        errorMessage = nil
        guard let acceptedPreview, acceptedPreview == previewIdentity(detail) else {
            errorMessage = AppError.exportPreviewChanged.message
            updatePreview()
            return
        }
        guard let folder = selectedFolder else {
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
            destinationFolder: folder.url, securityScoped: true, replaceExisting: replaceExisting)
        request.acceptedPreview = acceptedPreview
        request.destinationBookmark = folder.bookmark
        request.selectedFolderIdentity = folder.identity
        let result = await review.runExportFile(request: request)
        isExporting = false
        switch result {
        case .success(let file):
            lastResult = ExportResult(file: file, folder: folder, historySaveFailed: false)
        case .failure(.exportHistoryNotSaved(let file)):
            lastResult = ExportResult(file: file, folder: folder, historySaveFailed: true)
            errorMessage = AppError.exportHistoryNotSaved(file).message
        case .failure(.exportPreviewChanged):
            errorMessage = AppError.exportPreviewChanged.message
            updatePreview()
        case .failure(.exportFolderChanged):
            selectedFolder = nil
            errorMessage = AppError.exportFolderChanged.message
        case .failure(let error):
            errorMessage = error.message   // không đóng sheet, không ghi success giả (§2.9)
        }
    }

    func cancelResultReveal() {
        finderRequestID = nil
        finderRequestTask?.cancel()
        finderRequestTask = nil
    }

    @discardableResult
    public func revealResult() -> Task<Void, Never>? {
        guard let result = lastResult else { return nil }
        cancelResultReveal()
        finderWarning = nil
        let requestID = UUID()
        finderRequestID = requestID
        let task = Task<Void, Never> { [weak self] in
            await self?.reveal(result, requestID: requestID)
        }
        finderRequestTask = task
        return task
    }

    private func reveal(_ result: ExportResult, requestID: UUID) async {
        guard finderRequestID == requestID, !Task.isCancelled else { return }
        defer { if finderRequestID == requestID { finderRequestTask = nil } }
        let bookmark = result.folder.bookmark
        defer { withExtendedLifetime(bookmark) {} }
        do {
            let resolvedFolder = try bookmark.map { try env.exportService.resolveExportFolder(bookmarkID: $0.id) }
            let folder = resolvedFolder ?? result.folder.url
            let url = resolvedFolder?.appendingPathComponent(result.file.url.lastPathComponent) ?? result.file.url
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let sha256 = result.file.sha256
            #if DEBUG
            let beforeHash = onFinderHashForTesting
            #else
            let beforeHash: (@Sendable (URL) throws -> Void)? = nil
            #endif
            let check = Task.detached(priority: .userInitiated) {
                try ExportFileVerifier.check(url, expectedHash: sha256, beforeHash: beforeHash)
            }
            let checked = try await withTaskCancellationHandler {
                try await check.value
            } onCancel: {
                check.cancel()
            }
            guard finderRequestID == requestID, !Task.isCancelled else { return }
            switch checked {
            case .verified(let version):
                if try ExportFileVerifier.matchesCurrentVersion(url, version) {
                    env.shareService.revealInFinder(url)
                } else {
                    finderWarning = "Tệp xuất đã bị thay thế hoặc chỉnh sửa"
                }
            case .modified:
                finderWarning = "Tệp xuất đã bị thay thế hoặc chỉnh sửa"
            case .missingOrInvalid:
                finderWarning = "Không còn tìm thấy tệp xuất tại vị trí đã lưu"
            }
        } catch is CancellationError {
            return
        } catch {
            guard finderRequestID == requestID, !Task.isCancelled else { return }
            switch ExportFileVerifier.classifyFileError(error) {
            case .inaccessible: finderWarning = "Không thể truy cập tệp xuất"
            case .missingOrInvalid: finderWarning = "Không còn tìm thấy tệp xuất tại vị trí đã lưu"
            }
        }
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
        packData = nil
        packResult = nil
        packName = ""
        warnings = []
        choices = [:]
        replaceConfirmPending = nil
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
    @Published public private(set) var idleSecondsLeft: Int?
    @Published public private(set) var isStarting = false
    @Published public private(set) var isFinishing = false
    @Published public private(set) var exitRequested = false
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
        captureVM.plannedCaptureCount = 4
        step = .welcome
    }

    public func beginShooting() async {
        guard !exitRequested, !isStarting, !engine.isCaptureBusy, !engine.hasPhotoToSave,
              captureVM.isCameraReady else { return }
        isStarting = true
        defer {
            isStarting = false
            finishExitIfReady()
        }
        guard await env.capturePreview.confirmVideoFallback(), !exitRequested, !Task.isCancelled else { return }

        engine.keepSessionAndExit()
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
        guard !exitRequested, !engine.isCancellingSession, reviewVM == nil, let id = engine.session?.id else { return }
        guard let session = try? env.sessions.getSession(id: id) else { return }
        if session.awaitsFrame {
            step = .chooseFrame
            return
        }
        let vm = ReviewViewModel(env: env)
        reviewVM = vm
        await vm.load(sessionID: id)
        guard env.showFullscreen, !exitRequested, engine.session?.id == id else { return }
        step = .review
    }

    public func finish() async {
        guard !exitRequested, !isFinishing, let id = reviewVM?.detail?.session.id else { return }
        isFinishing = true
        defer {
            isFinishing = false
            finishExitIfReady()
        }
        do {
            _ = try await env.completeSession(sessionID: id)
            if env.showFullscreen, !exitRequested { step = .finish }
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

    func returnToCaptureSetupAfterCancellation() {
        guard step == .live else { return }
        reviewVM = nil
        step = .captureSetup
    }

    public func exitFullscreenRequested() {
        guard !engine.isCancellingSession, !exitRequested else { return }
        exitRequested = true
        pauseIdleTimer()
        if engine.isCaptureBusy { engine.pause() }
        finishExitIfReady()
    }

    func finishExitIfReady() {
        guard exitRequested, !engine.isCancellingSession, !engine.isCaptureBusy, !isStarting, !isFinishing else { return }
        if engine.hasPhotoToSave {
            exitRequested = false
            env.showToast("Thử lưu lại ảnh trước khi thoát toàn màn hình", kind: .warning)
            return
        }
        if engine.session != nil { engine.keepSessionAndExit() }
        env.showFullscreen = false
    }
}
