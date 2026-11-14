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
    @Published public private(set) var errorMessage: String?

    public let env: AppEnvironment
    public var review: ReviewViewModel?

    public init(env: AppEnvironment) {
        self.env = env
        format = env.settings.exportFormat
        quality = env.settings.jpegQuality
    }

    public func configure(detail: SessionDetail) {
        width = detail.snapshot.canvasWidth
        height = detail.snapshot.canvasHeight
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        filename = "Photobooth_\(df.string(from: Date()))"
        if let bmID = env.settings.exportFolderBookmarkID,
           let stored = try? env.trashRepo.bookmark(id: bmID) {
            var stale = false
            folderURL = try? URL(resolvingBookmarkData: stored.blob, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    public func setWidth(_ w: Int) {
        width = min(max(w, ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        if aspectLocked, let detail = currentDetail() {
            let ratio = Double(detail.snapshot.canvasHeight) / Double(detail.snapshot.canvasWidth)
            height = min(max(Int(Double(width) * ratio), ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        }
    }

    public func setHeight(_ h: Int) {
        height = min(max(h, ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        if aspectLocked, let detail = currentDetail() {
            let ratio = Double(detail.snapshot.canvasWidth) / Double(detail.snapshot.canvasHeight)
            width = min(max(Int(Double(height) * ratio), ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        }
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
                // Lưu security-scoped bookmark (§10.4) — xóa bookmark cũ để không tích lũy row mồ côi
                if let blob = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil, relativeTo: nil) {
                    let oldID = self.env.settings.exportFolderBookmarkID
                    if let id = try? self.env.trashRepo.saveBookmark(purpose: "exportFolder", blob: blob, displayPath: url.path) {
                        self.env.settings.exportFolderBookmarkID = id
                        if let oldID, oldID != id {
                            try? self.env.trashRepo.deleteBookmark(id: oldID)
                        }
                    }
                }
            }
        }
    }

    public func runExport() async {
        guard let review, let detail = review.detail else { return }
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
        let request = ExportService.ExportRequest(
            sessionID: detail.session.id, format: format, quality: quality,
            width: width, height: height, filenameBase: filename,
            destinationFolder: folder, securityScoped: true, replaceExisting: replaceExisting)
        let result = await review.runExport(request: request)
        isExporting = false
        switch result {
        case .success(let url):
            lastResultURL = url
        case .failure(let error):
            errorMessage = error.message   // không đóng sheet, không ghi success giả (§2.9)
        }
    }

    public func revealResult() {
        guard let url = lastResultURL else { return }
        env.shareService.revealInFinder(url)
    }
}

/// FramePackImportViewModel (Sheet I §2.10): verify trước, preview, policy từng khung.
@MainActor
public final class FramePackImportViewModel: ObservableObject {
    @Published public private(set) var packResult: PackValidationResult?
    @Published public private(set) var packName: String = ""
    @Published public private(set) var warnings: [String] = []
    @Published public var choices: [String: (policy: PackDuplicatePolicy, selected: Bool)] = [:]
    @Published public private(set) var isImporting = false
    @Published public private(set) var results: [String: Result<String, String>]?
    @Published public private(set) var fatalMessage: String?
    @Published public var replaceConfirmPending: String? = nil

    public let env: AppEnvironment
    private var packData: Data?

    public init(env: AppEnvironment) { self.env = env }

    /// Xác minh gói TRƯỚC preview (§2.10); không giải nén trực tiếp vào thư viện.
    /// Verify + giải nén + SHA256 chạy nền để không block MainActor (P3).
    public func loadAndValidate(url: URL) async {
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
        } catch let e as AppError {
            fatalMessage = e.message   // E-FRM-05: không import
        } catch {
            fatalMessage = error.localizedDescription
        }
    }

    public func applyImport() {
        guard let result = packResult, let data = packData else { return }
        isImporting = true
        let list = result.entries.map { entry in
            FramePackService.ImportChoice(packFrameID: entry.frame.frameId,
                                          policy: choices[entry.frame.frameId]?.policy ?? .skip,
                                          selected: choices[entry.frame.frameId]?.selected ?? false)
        }
        let packService = env.packService
        Task {
            do {
                // Import (extract + store assets + transactions) chạy nền để không block UI
                let outcomes = try await Task.detached(priority: .userInitiated) {
                    try packService.applyImport(result: result, choices: list, data: data)
                }.value
                await MainActor.run {
                    results = outcomes
                    isImporting = false
                    let okCount = outcomes.values.filter { if case .success = $0 { return true }; return false }.count
                    env.showToast("Nhập gói: \(okCount)/\(outcomes.count) mục thành công")
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    fatalMessage = "Nhập thất bại: \((error as? AppError)?.message ?? error.localizedDescription)"
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
        readyFrames = filtered.map { f in
            let slots = f.currentRevisionID.flatMap { (try? env.frames.getSlots(revisionID: $0)) ?? [] } ?? []
            return FrameCardModel(frame: f, thumbnail: nil, slotCount: slots.count)
        }
    }

    public func startCapture() {
        guard selectedFrameID != nil || captureVM.selectedFrameID != nil else { return }
        if selectedFrameID != nil { captureVM.selectFrame(selectedFrameID) }
        step = .live
    }

    public func beginShooting() {
        Task {
            await captureVM.startNewSession()
            if engine.session != nil {
                // Giữ step = .live: liveStep hiển thị camera + countdown;
                // khi engine vào .reviewing thì onChange sẽ gọi openReview() (P1-11).
                // Đặt .review ngay tại đây sẽ unmount liveStep → reviewVM không bao giờ được tạo.
            } else {
                env.showToast("Không bắt đầu được phiên — kiểm tra camera/khung", kind: .warning)
                step = .selectFrame
            }
        }
    }

    public func openReview() {
        guard let id = engine.session?.id else { return }
        let vm = ReviewViewModel(env: env)
        reviewVM = vm
        Task {
            await vm.load(sessionID: id)
            step = .review
        }
    }

    public func finish() {
        Task {
            await reviewVM?.complete()
            if reviewVM == nil, let id = engine.session?.id {
                // reviewVM chưa kịp tạo (engine chuyển .reviewing khi không có view lắng nghe):
                // cập nhật trạng thái phiên trực tiếp để không kẹt reviewable.
                try? env.sessions.setStatus(sessionID: id, status: .completed)
            }
            step = .finish
            startIdleTimer()
        }
    }

    public func backToWelcome() {
        step = .welcome
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: - Idle return (§14.3 — chỉ áp dụng ở màn Finish)

    public func startIdleTimer(seconds: Int? = nil) {
        idleTimer?.invalidate()
        let total = seconds ?? env.settings.fullscreenIdleReturn
        guard total > 0 else { return }
        idleSecondsLeft = total
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
        }
        pauseIdleTimer()
    }
}
