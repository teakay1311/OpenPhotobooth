import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import Combine

/// CaptureViewModel (§2.2): điều phối màn hình Chụp — frame picker, camera stage, quick controls.
/// State machine thật nằm ở CaptureEngine; VM chỉ ánh xạ state → UI và thực hiện tiền điều kiện.
@MainActor
public final class CaptureViewModel: ObservableObject {
    public enum CameraUIState: Equatable {
        case notDetermined
        case authorized
        case denied
        case noDevice
        case busy
    }

    private var previewObserver: AnyCancellable?
    public var permissionState: CameraUIState { env.capturePreview.permission }
    public var devices: [CameraDescriptor] { env.capturePreview.devices }
    public var selectedDeviceID: String { env.capturePreview.selection }
    public var cameraName: String { env.capturePreview.name }
    public var fallbackStillNotice: Bool { env.capturePreview.isFallback }
    public var isCameraReady: Bool { env.capturePreview.isReady }
    public var isConnectingCamera: Bool { env.capturePreview.isConnecting }
    public var cameraPreviewError: String? { env.capturePreview.error }

    @Published public private(set) var frames: [FrameCardModel] = []
    @Published public var searchText: String = ""
    @Published public var categoryFilter: String? = nil
    @Published public var showFavoritesOnly: Bool = false
    @Published public var selectedFrameID: String? = nil

    public enum PreviewMode: String, CaseIterable, Identifiable {
        case camera = "camera"
        case inFrame = "inFrame"
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .camera: return "Camera"
            case .inFrame: return "Trong khung"
            }
        }
    }

    @Published public var previewMode: PreviewMode = .camera
    public var userOverrodePreviewMode: Bool = false

    @Published public var mode: CaptureMode = .automatic
    @Published public var countdown: Int = 3
    @Published public var interval: Int = 2
    @Published public var selectedPresetID: String = "natural"
    @Published public var requestedSelectionCount: Int?
    @Published public var liveFramePreview: Bool = false

    private var stagedPreviewSnapshot: FrameSnapshot?
    @Published public private(set) var previewFrameImage: CGImage? = nil
    @Published public private(set) var lastError: AppError?

    public let env: AppEnvironment
    public var engine: CaptureEngine { env.engine }

    public init(env: AppEnvironment) {
        self.env = env
        previewObserver = env.capturePreview.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        mode = env.settings.captureMode
        countdown = env.settings.countdown
        interval = env.settings.interval
        selectedPresetID = env.settings.defaultPreset
        liveFramePreview = env.settings.liveFramePreview
        previewMode = env.settings.liveFramePreview ? .inFrame : .camera
    }

    public func setPreviewMode(_ mode: PreviewMode) {
        previewMode = mode
        userOverrodePreviewMode = true
    }

    // MARK: - Camera states (§2.2, §4.3, BUG-CAM-01)

    public func refreshCameraState() async { await env.capturePreview.refresh() }

    public func enableCamera() async { await env.capturePreview.refresh(requestAccess: true) }

    public func retryCamera() async { await env.capturePreview.refresh() }

    func resumeDeferredCameraRefresh() async { await env.capturePreview.resumeDeferredRefresh() }

    public func selectCamera(_ id: String) async { await env.capturePreview.choose(id) }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func observeCameraEvents() async {
        for await event in env.camera.events {
            if Task.isCancelled { return }
            switch event {
            case .interruptionStarted(let reason), .fatalFailure(let reason):
                env.capturePreview.interrupted(reason)
            case .interruptionEnded, .deviceConnected, .deviceDisconnected:
                await refreshCameraState()
            default:
                break
            }
        }
    }

    // MARK: - Frames picker (§2.2)

    public func reloadFrames() {
        let list = (try? env.frames.listReadyFrames()) ?? []
        var models: [FrameCardModel] = []
        for frame in list {
            if showFavoritesOnly && !frame.isFavorite { continue }
            if let cat = categoryFilter, frame.categoryID != cat { continue }
            if !searchText.isEmpty,
               !frame.name.localizedCaseInsensitiveContains(searchText) { continue }
            let slots = frame.currentRevisionID.flatMap { (try? env.frames.getSlots(revisionID: $0)) ?? [] } ?? []
            let revID = frame.currentRevisionID ?? frame.id
            let thumb = env.frameThumbnails.cachedThumbnail(frameID: frame.id, revisionID: revID)
            models.append(FrameCardModel(frame: frame, thumbnail: thumb, slotCount: Set(slots.map(\.captureIndex)).count))
            if thumb == nil, let rev = frame.currentRevisionID {
                let fid = frame.id
                Task { @MainActor [weak self] in
                    if let data = await self?.env.frameThumbnails.requestThumbnail(frameID: fid, revisionID: rev) {
                        if let idx = self?.frames.firstIndex(where: { $0.id == fid && $0.frame.currentRevisionID == rev }) {
                            self?.frames[idx].thumbnail = data
                        }
                    }
                }
            }
        }
        frames = models
        // Quy tắc chọn khung ưu tiên chuẩn §6.1 / INIT-01:
        // 1. Snapshot của phiên đang mở (nếu hợp lệ)
        // 2. Lựa chọn hiện hành (nếu còn hợp lệ trong DB)
        // 3. Preferred frame từ AppEnvironment (nếu hợp lệ)
        // 4. Khung built-in sẵn sàng có tên "Dải 3 ảnh"
        // 5. Khung sẵn sàng đầu tiên theo thứ tự repository
        let allFrames = (try? env.frames.listFrames()) ?? []
        let readyFrames = allFrames.filter { $0.validationStatus == .ready }

        let targetCandidate: String?
        if let snap = engine.snapshot,
           let sourceID = snap.sourceFrameID, readyFrames.contains(where: { $0.id == sourceID }) {
            targetCandidate = sourceID
        } else if let preferred = env.preferredFrameID, readyFrames.contains(where: { $0.id == preferred }) {
            targetCandidate = preferred
        } else if let sel = selectedFrameID, readyFrames.contains(where: { $0.id == sel }) {
            targetCandidate = sel
        } else if let builtIn3 = readyFrames.first(where: { $0.isBuiltIn && $0.name == "Dải 3 ảnh" }) {
            targetCandidate = builtIn3.id
        } else if let firstReady = readyFrames.first {
            targetCandidate = firstReady.id
        } else {
            targetCandidate = nil
        }

        let targetRevisionID = readyFrames.first { $0.id == targetCandidate }?.currentRevisionID
        if selectedFrameID != targetCandidate || stagedPreviewSnapshot?.sourceFrameRevisionID != targetRevisionID
            || (previewFrameImage == nil && engine.snapshot != nil) {
            selectedFrameID = targetCandidate
            regeneratePreview()
        }
    }

    public func toggleFavorite(_ frameID: String) {
        guard let frame = try? env.frames.getFrame(id: frameID) else { return }
        try? env.frames.setFavorite(id: frameID, !frame.isFavorite)
        reloadFrames()
        EventBus.shared.post(.frameLibraryChanged(frameID: frameID))
    }

    public func selectFrame(_ id: String?) {
        guard let id else { return }
        do {
            _ = try env.selectFrameForCapture(id)
        } catch {
            lastError = (error as? AppError) ?? .ioFailure(error.localizedDescription)
            env.showToast(lastError?.message ?? "Không thể chọn khung", kind: .warning)
            return
        }
        guard selectedFrameID != id else { return }
        selectedFrameID = id
        if !userOverrodePreviewMode {
            previewMode = (selectedFrameID != nil && env.settings.liveFramePreview) ? .inFrame : .camera
        }
        regeneratePreview()
    }

    public var selectedFrame: Frame? {
        guard let id = selectedFrameID else { return nil }
        return try? env.frames.getFrame(id: id)
    }

    public var selectedFrameIndices: [Int] {
        previewSnapshot?.requiredIndices.sorted() ?? []
    }

    public var previewSnapshot: FrameSnapshot? {
        if let snapshot = engine.snapshot { return snapshot }
        return stagedPreviewSnapshot
    }

    public var selectionCount: Int? {
        guard let requestedSelectionCount else { return nil }
        let minimum = selectedFrameIndices.count
        guard (1...ResourceLimits.maxCaptureIndices).contains(minimum) else { return nil }
        return max(minimum, min(requestedSelectionCount, ResourceLimits.maxCaptureIndices))
    }

    public var livePhotoParameters: ResolvedPhotoParams {
        ResolvedPhotoParams.resolve(defaults: engine.session?.defaults ?? quickDefaults(), override: nil)
    }

    private func quickDefaults() -> SessionDefaultsSnapshot {
        var defaults = env.settings.sessionDefaultsSnapshot()
        defaults.presetID = selectedPresetID
        if let preset = BuiltinPreset.byID(selectedPresetID) {
            defaults.presetName = preset.nameVN
            defaults.presetResolvedParameters = preset.parameters
        }
        return defaults
    }

    public func regeneratePreview() {
        if let frame = selectedFrame {
            stagedPreviewSnapshot = try? env.frames.createSnapshot(frameID: frame.id, persist: false)
        } else {
            stagedPreviewSnapshot = nil
        }
        guard let snap = previewSnapshot else {
            previewFrameImage = nil
            return
        }
        var assetImages: [String: CGImage] = [:]
        for layer in [snap.background, snap.foreground].compactMap({ $0 }) {
            if let image = try? env.assets.loadImage(assetID: layer.assetID) {
                assetImages[layer.assetID] = image
            }
        }
        let maxDim = 640
        let aspect = Double(snap.canvasWidth) / Double(max(snap.canvasHeight, 1))
        var w = maxDim, h = maxDim
        if aspect >= 1 { h = Int(Double(maxDim) / aspect) } else { w = Int(Double(maxDim) * aspect) }
        var sources: [Int: RenderSource] = [:]
        for index in snap.requiredIndices {
            if let sample = SampleImageFactory.shared.sample(index: index, size: CGSize(width: 480, height: 480)) {
                sources[index] = RenderSource(image: sample)
            }
        }
        let model = CompositionModel(snapshot: snap, sources: sources, faces: [:],
                                     defaults: env.settings.sessionDefaultsSnapshot(),
                                     overrides: [:], placements: [:],
                                     cropModes: [:], assetImages: assetImages,
                                     options: RenderOptions(targetWidth: w, targetHeight: h))
        previewFrameImage = try? CompositeRenderer.render(model: model)
    }

    // MARK: - Session lifecycle (§3.2)

    public var canStartSession: Bool {
        isCameraReady &&
        selectedFrame != nil &&
        selectedFrame?.validationStatus == .ready
    }

    public var startButtonTitle: String {
        switch engine.state {
        case .ready: return engine.committedShots.isEmpty ? "Bắt đầu chụp" : "Chụp tiếp"
        case .countdown: return "Hủy đếm ngược"
        case .capturing: return "Đang chụp"
        case .persisting: return "Đang lưu"
        case .intermission: return "Tạm dừng"
        case .paused: return "Tiếp tục"
        case .recoverableError: return engine.hasPhotoToSave ? "Thử lưu lại" : "Thử chụp lại lượt"
        case .reviewing, .completed: return engine.session?.pendingSelectionCount == nil ? "Xem và chỉnh ảnh" : "Chọn ảnh vào khung"
        default: return "Bắt đầu chụp"
        }
    }

    public func primaryAction() async {
        switch engine.state {
        case .idle:
            await startNewSession()
        case .ready:
            if let sid = engine.session?.id,
               let s = try? env.sessions.getSession(id: sid),
               s.status == .completed {
                env.openReview(sessionID: sid, source: .capture)
                return
            }
            guard isCameraReady, await env.capturePreview.confirmVideoFallback(), engine.state == .ready else { return }
            if engine.committedShots.isEmpty {
                await startNewSessionIfNeeded()
            } else {
                // Phân biệt chế độ tự động vs thủ công khi bấm "Chụp tiếp" (CAP-02)
                do {
                    if engine.session?.captureMode == .manual {
                        try engine.captureNextManual()
                    } else {
                        try engine.startOrContinue()
                    }
                } catch {
                    lastError = (error as? AppError) ?? .invalidState(error.localizedDescription)
                    env.showToast(lastError?.message ?? "Không thể tiếp tục chụp", kind: .warning)
                }
            }
        case .countdown, .intermission:
            if case .countdown = engine.state {
                let isRetake = (env.retakeSessionID != nil) || (engine.lastShotContext?.kind == .retake)
                let retakeID = env.retakeSessionID ?? engine.session?.id
                let source = env.reviewContext?.sourceRoute ?? .capture
                engine.cancelCountdown()
                if isRetake, let retakeID {
                    env.retakeSessionID = nil
                    env.openReview(sessionID: retakeID, source: source)
                }
            } else {
                engine.pause()
            }
        case .paused:
            guard isCameraReady, await env.capturePreview.confirmVideoFallback() else { return }
            do { try engine.resume() }
            catch { env.showToast(error.localizedDescription, kind: .warning) }
        case .recoverableError:
            if engine.hasPhotoToSave {
                await engine.retryPendingSave()
                return
            }
            guard isCameraReady, await env.capturePreview.confirmVideoFallback() else { return }
            engine.retryFromError()
            if case .ready = engine.state {
                try? engine.startOrContinue()
            }
        case .reviewing, .completed:
            if let id = engine.session?.id { env.openReview(sessionID: id, source: .capture) }
        default:
            break
        }
    }

    /// Xử lý phím Esc hủy đếm ngược hoặc thoát an toàn (AG-2).
    public func handleExitCommand() {
        if case .countdown = engine.state {
            let isRetake = (env.retakeSessionID != nil) || (engine.lastShotContext?.kind == .retake)
            let retakeID = env.retakeSessionID ?? engine.session?.id
            let source = env.reviewContext?.sourceRoute ?? .capture
            engine.cancelCountdown()
            if isRetake, let retakeID {
                env.retakeSessionID = nil
                env.openReview(sessionID: retakeID, source: source)
            }
        }
    }

    /// Kiểm tra tiền điều kiện §17.3 CreateSession: frame ready + camera usable + storage writable.
    public func startNewSession() async {
        guard canStartSession, await env.capturePreview.confirmVideoFallback(),
              canStartSession, let frame = selectedFrame, !Task.isCancelled else { return }
        // Nếu có phiên paused khác → lựa chọn (§10.3)
        if engine.session != nil, engine.state != .idle {
            env.showToast("Đang có phiên hoạt động", kind: .warning)
            return
        }
        do {
            // Kiểm tra bộ nhớ ghi được (E-STO-01)
            guard SafetySaveService.isWritable(env.layout.rootURL) else {
                throw AppError.diskFull
            }
            let cameraID = selectedDeviceID == "auto" ? await env.camera.currentDevice?.uniqueID : selectedDeviceID
            try Task.checkCancellation()
            let snapshot = try env.frames.createSnapshot(frameID: frame.id)
            var defaults = quickDefaults()
            defaults.selectionCaptureCount = selectionCount
            _ = try engine.beginSession(snapshot: snapshot, mode: mode,
                                        cameraID: cameraID,
                                        defaults: defaults,
                                        countdown: countdown, interval: interval,
                                        frameName: frame.name)
            try engine.startOrContinue()
        } catch is CancellationError {
            return
        } catch let e as AppError {
            lastError = e
            env.showToast(e.message, kind: .warning)
        } catch {
            env.showToast(error.localizedDescription, kind: .warning)
        }
    }

    private func startNewSessionIfNeeded() async {
        if engine.session == nil {
            await startNewSession()
        } else {
            try? engine.startOrContinue()
        }
    }

    public func newSessionAction() async {
        // Phiên mới: nếu có phiên paused → giữ phiên cũ và tạo phiên mới (mặc định §10.3)
        engine.keepSessionAndExit()
        await startNewSession()
    }

    // MARK: - Banner recovery (§3.1.6)

    public func continueBannerSession(sessionID: String) async {
        guard !env.isProcessingBannerAction else { return }
        guard env.bannerSessionID == sessionID else { return }
        guard !env.showLeaveCaptureConfirmation else { return }
        guard env.engine.canAdoptSession else {
            if env.engine.hasPhotoToSave {
                env.showToast("Thử lưu lại ảnh của phiên đang mở trước", kind: .warning)
            } else if env.engine.isCaptureBusy {
                env.showToast("Chờ hoàn tất lượt chụp trước khi chuyển phiên", kind: .warning)
            }
            return
        }
        env.isProcessingBannerAction = true
        defer { env.isProcessingBannerAction = false }

        guard let detail = try? env.sessions.getDetail(sessionID: sessionID) else {
            env.showToast("Không tìm thấy dữ liệu phiên cần phục hồi", kind: .warning)
            return
        }

        guard env.route == .capture,
              env.bannerSessionID == sessionID,
              !env.showLeaveCaptureConfirmation,
              env.engine.canAdoptSession else { return }

        if detail.missingIndices.isEmpty {
            env.openReview(sessionID: sessionID, source: .capture)
            if env.bannerSessionID == sessionID {
                env.dismissBanner()
            }
        } else {
            let adopted = await adoptForCapture(detail: detail)
            if adopted && env.bannerSessionID == sessionID {
                env.dismissBanner()
            }
        }
    }

    @discardableResult
    public func adoptForCapture(detail: SessionDetail) async -> Bool {
        guard env.engine.canAdoptSession else { return false }
        let committed = detail.currentRevisions()
        let adopted = env.engine.adoptSession(record: detail.session, snapshot: detail.snapshot, committed: committed)
        guard adopted else { return false }
        selectedFrameID = detail.snapshot.sourceFrameID
        regeneratePreview()
        await refreshCameraState()
        return true
    }

    public func viewBannerSession(sessionID: String) {
        guard !env.isProcessingBannerAction else { return }
        guard env.bannerSessionID == sessionID else { return }
        guard !env.showLeaveCaptureConfirmation else { return }
        guard !env.engine.isCaptureBusy, !env.engine.hasPhotoToSave else {
            env.showToast(env.engine.hasPhotoToSave ? "Thử lưu lại ảnh của phiên đang mở trước" : "Chờ hoàn tất lượt chụp", kind: .warning)
            return
        }
        env.isProcessingBannerAction = true
        defer { env.isProcessingBannerAction = false }

        guard (try? env.sessions.getDetail(sessionID: sessionID)) != nil else {
            env.showToast("Không tìm thấy phiên cần xem", kind: .warning)
            return
        }

        guard env.route == .capture,
              env.bannerSessionID == sessionID,
              !env.showLeaveCaptureConfirmation,
              !env.engine.isCaptureBusy, !env.engine.hasPhotoToSave else { return }

        env.openReview(sessionID: sessionID, source: .capture)
        if env.bannerSessionID == sessionID {
            env.dismissBanner()
        }
    }

    public func dismissBanner() {
        env.bannerSessionID = nil
    }
}

/// Dùng chung camera giữa màn Chụp, Cài đặt và Kiosk.
@MainActor
final class CapturePreviewCoordinator: ObservableObject {
    @Published private(set) var permission: CaptureViewModel.CameraUIState = .notDetermined
    @Published private(set) var devices: [CameraDescriptor] = []
    @Published private(set) var selection = "auto"
    @Published private(set) var name = ""
    @Published private(set) var isFallback = false
    @Published private(set) var appliedResolution: String?
    @Published private(set) var isReady = false
    @Published private(set) var isConnecting = false
    @Published private(set) var error: String?

    private unowned let env: AppEnvironment
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var requestingPermission = false
    private var deferredRefresh = false
    private var readyPreference: String?
    private var readyResolution: String?
    private var confirmedFallbackGeneration: Int?
    private var isConfirmingFallback = false

    init(env: AppEnvironment) { self.env = env }

    private var needsPreview: Bool { env.showFullscreen || env.route == .capture }

    func refresh(requestAccess: Bool = false, forRetake: Bool = false) async {
        let retakeRoute = forRetake ? env.route : nil
        guard needsPreview || retakeRoute != nil else { return }
        if env.engine.isCaptureBusy {
            deferredRefresh = needsPreview
            return
        }
        deferredRefresh = false
        if !requestAccess, pending == nil, isReady, readyPreference == env.settings.cameraSelection,
           readyResolution == env.settings.cameraResolution, await env.camera.isPreviewRunning { return }
        if let pending, !pending.isCancelled, !requestAccess || requestingPermission {
            await pending.value
            return
        }
        await enqueue(requestAccess: requestAccess, explicitSelection: nil, retakeRoute: retakeRoute)
    }

    func confirmVideoFallback() async -> Bool {
        guard isReady else { return false }
        guard isFallback else { return true }
        if confirmedFallbackGeneration == generation { return true }
        guard !isConfirmingFallback, let window = NSApp?.keyWindow else { return false }
        isConfirmingFallback = true
        defer { isConfirmingFallback = false }
        let requestedGeneration = generation
        let route = env.route
        let fullscreen = env.showFullscreen
        let alert = NSAlert()
        alert.messageText = "Camera chỉ chụp ở độ phân giải video"
        alert.informativeText = "Ảnh sẽ được lấy từ khung hình video của camera đang chọn."
        alert.addButton(withTitle: "Tiếp tục")
        alert.addButton(withTitle: "Hủy")
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn, !Task.isCancelled, isReady, isFallback,
              generation == requestedGeneration, env.route == route, env.showFullscreen == fullscreen else { return false }
        confirmedFallbackGeneration = requestedGeneration
        return true
    }

    func resumeDeferredRefresh() async {
        guard deferredRefresh else { return }
        await refresh()
    }

    func choose(_ id: String) async {
        guard env.engine.canChangeCamera else { return }
        env.settings.cameraSelection = id
        selection = id
        isReady = false
        await enqueue(requestAccess: false, explicitSelection: id)
    }

    func interrupted(_ message: String) {
        isReady = false
        confirmedFallbackGeneration = nil
        appliedResolution = nil
        error = message
        pending?.cancel()
    }

    private func enqueue(requestAccess: Bool, explicitSelection: String?, retakeRoute: ScreenRoute? = nil) async {
        let previous = pending
        previous?.cancel()
        generation += 1
        let token = generation
        requestingPermission = requestAccess
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.prepare(requestAccess: requestAccess, explicitSelection: explicitSelection, retakeRoute: retakeRoute)
        }
        pending = task
        await task.value
        if generation == token {
            pending = nil
            requestingPermission = false
            isConnecting = false
        }
    }

    private func prepare(requestAccess: Bool, explicitSelection: String?, retakeRoute: ScreenRoute?) async {
        var mayStartPreview: Bool { needsPreview || retakeRoute == env.route }
        guard env.engine.canChangeCamera, mayStartPreview || explicitSelection != nil else { return }
        let camera = env.camera
        let status = requestAccess ? await camera.requestAccessIfNeeded() : await camera.cameraPermissionState()
        guard !Task.isCancelled else { return }
        switch status {
        case .notDetermined: permission = .notDetermined
        case .denied, .restricted: permission = .denied
        case .authorized: permission = .authorized
        }
        guard status == .authorized else {
            isReady = false
            name = ""
            error = nil
            return
        }

        let preferred = explicitSelection ?? env.settings.cameraSelection
        let resolution = env.settings.cameraResolution
        if isReady, readyPreference == preferred, readyResolution == resolution, await camera.isPreviewRunning { return }
        guard !Task.isCancelled else { return }

        isReady = false
        appliedResolution = nil
        isConnecting = true
        error = nil
        do {
            let discovered = await camera.discoverDevices()
            try Task.checkCancellation()
            devices = discovered
            guard !discovered.isEmpty else { throw AppError.noCamera }
            guard env.engine.canChangeCamera else { return }

            var actualSelection = preferred
            if preferred == "auto" {
                _ = try await camera.selectAutoDevice()
            } else if discovered.contains(where: { $0.uniqueID == preferred }) {
                do {
                    _ = try await camera.selectDevice(preferred)
                } catch {
                    try Task.checkCancellation()
                    guard explicitSelection == nil, env.engine.canChangeCamera else { throw error }
                    _ = try await camera.selectAutoDevice()
                    actualSelection = "auto"
                }
            } else if explicitSelection != nil {
                throw AppError.noCamera
            } else {
                _ = try await camera.selectAutoDevice()
                actualSelection = "auto"
            }
            try Task.checkCancellation()
            guard let device = await camera.currentDevice else { throw AppError.noCamera }
            try Task.checkCancellation()
            selection = actualSelection
            name = device.localizedName
            if actualSelection != preferred {
                env.showToast("Camera đã lưu không khả dụng, tạm dùng Tự động", kind: .warning)
            }
            guard mayStartPreview, env.engine.canChangeCamera else { return }
            do {
                try await camera.setResolution(resolution)
            } catch {
                try Task.checkCancellation()
                guard resolution != "best" else { throw error }
                try await camera.setResolution("best")
            }
            try Task.checkCancellation()
            guard mayStartPreview, env.engine.canChangeCamera else { return }
            try await camera.startPreview()
            try Task.checkCancellation()
            let applied = await camera.activeResolution
            let fallback = await camera.isFallbackVideoStill
            try Task.checkCancellation()
            guard mayStartPreview else { return }
            isFallback = fallback
            appliedResolution = applied
            if resolution != "best", let applied, applied != resolution {
                env.showToast("Không áp dụng được \(resolution). Camera đang dùng \(applied).", kind: .warning)
            }
            readyPreference = preferred
            readyResolution = resolution
            isReady = true
            Log.camera.info("Preview đã nhận frame đầu tiên: \(self.name, privacy: .public)")
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? AppError)?.message ?? error.localizedDescription
            self.error = message
            if error as? AppError == .noCamera, devices.isEmpty { permission = .noDevice }
            Log.camera.error("Preview lỗi: \(message, privacy: .public)")
        }
    }
}

/// Ảnh mẫu generic cho preview khung (không dùng ảnh người dùng — §6.1).
public final class SampleImageFactory: @unchecked Sendable {
    public static let shared = SampleImageFactory()
    private var cache: [Int: CGImage] = [:]
    private let lock = NSLock()

    public func sample(index: Int, size: CGSize) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[index] { return hit }
        let w = Int(size.width), h = Int(size.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let hue = (0.55 + 0.11 * Double(index)).truncatingRemainder(dividingBy: 1)
        let colors = [NSColor(hue: CGFloat(hue), saturation: 0.45, brightness: 0.92, alpha: 1).cgColor,
                      NSColor(hue: CGFloat((hue + 0.08).truncatingRemainder(dividingBy: 1)), saturation: 0.35, brightness: 0.75, alpha: 1).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        ctx.setFillColor(CGColor(red: 0.92, green: 0.78, blue: 0.66, alpha: 1))
        let face = CGRect(x: CGFloat(w) * 0.32, y: CGFloat(h) * 0.25, width: CGFloat(w) * 0.36, height: CGFloat(w) * 0.36)
        ctx.fillEllipse(in: face)
        let text = "Ảnh mẫu \(index)"
        let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(w) / 12, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: NSColor(white: 1, alpha: 0.95).cgColor]
        if let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) {
            let line = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: (CGFloat(w) - bounds.width) / 2, y: CGFloat(h) * 0.08)
            CTLineDraw(line, ctx)
        }
        let img = ctx.makeImage()
        if let img { cache[index] = img }
        return img
    }
}
