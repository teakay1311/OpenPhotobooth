import Foundation
import SwiftUI
import AppKit
import Combine

/// AppEnvironment (§17.1): DI container — AppCoordinator/navigation, services, recovery banner.
@MainActor
public final class AppEnvironment: ObservableObject {
    public let layout: FileLayout
    public let db: SQLiteDatabase
    public let assets: AssetStore
    public let frames: FrameRepository
    public let presets: PresetRepository
    public let sessions: SessionRepository
    public let trashRepo: TrashRepository
    public let thumbnails: ThumbnailStore
    public let frameThumbnails: FrameThumbnailService

    public let settings: SettingsStore
    public let audio: AudioService
    public let faceAnalysis: FaceAnalysisService
    public let renderBuilder: SessionRenderBuilder
    public let safetySave: SafetySaveService
    public let trashService: TrashService
    public let trashScheduler: TrashCleanupScheduler
    public let exportService: ExportService
    public let shareService: ShareService
    public let packService: FramePackService
    public let clockSanity: ClockSanityMonitor
    public let coordinator: OperationCoordinator

    public var camera: CameraServing
    public let engine: CaptureEngine
    lazy var capturePreview = CapturePreviewCoordinator(env: self)

    @Published public var route: ScreenRoute = .capture
    @Published public var recoveryReport: RecoveryService.Report?
    @Published public var bannerSessionID: String?
    @Published public var isProcessingBannerAction: Bool = false
    @Published public var toast: ToastMessage?
    @Published public var showFullscreen = false
    @Published var nativeFullscreenExitRequest = 0
    @Published public var frameEditorDraft: FrameEditorContext?
    @Published public var showPackImport = false
    public var pendingPackURL: URL?
    @Published public var retakeSessionID: String?
    @Published public var launchError: AppError? = nil
    @Published public var showLeaveCaptureConfirmation = false
    @Published public var showFrameEditorLeaveConfirmation = false
    public var frameEditorHasChanges = false
    public var frameEditorSaveHandler: (() -> Bool)?
    @Published public var pendingNavigationRoute: ScreenRoute? = nil
    @Published public var copiedColorAdjustments: CopiedColorAdjustments? = nil
    private let effectiveRoot: URL?
    /// Khung được chọn từ màn Khung ảnh ("Sử dụng") — màn Chụp nhận lại sau khi route đổi
    /// vì StateObject các màn bị hủy khi chuyển route (liên kết dữ liệu giữa các màn §2.3).
    @Published public var preferredFrameID: String?

    // MARK: - Navigation Intent cho Cài đặt (TRS-02, T07)
    @Published public var pendingSettingsSection: SettingsView.SettingsSection? = nil

    public func openSettings(section: SettingsView.SettingsSection) {
        pendingSettingsSection = section
        requestNavigation(to: .settings)
    }

    public func consumePendingSettingsSection() -> SettingsView.SettingsSection? {
        let section = pendingSettingsSection
        pendingSettingsSection = nil
        return section
    }

    // MARK: - Trạng thái điều phối dọn thủ công cấp ứng dụng (TRS-03, T03)
    @Published public private(set) var manualPurgeTaskID: String? = nil
    public var isManualPurging: Bool { manualPurgeTaskID != nil }

    @discardableResult
    public func beginManualPurge() -> String? {
        guard manualPurgeTaskID == nil else { return nil }
        let id = IDFactory.new()
        manualPurgeTaskID = id
        return id
    }

    public func endManualPurge(taskID: String) {
        if manualPurgeTaskID == taskID {
            manualPurgeTaskID = nil
        }
    }

    // MARK: - Nơi sở hữu số đo Lưu trữ và Dọn cache (SET-02, §5.2, T09)
    public enum StorageMeasurementStatus: Equatable {
        case unmeasured
        case measuring
        case current(bytes: Int64, formatted: String)
        case stale(bytes: Int64, formatted: String)
        case failed(previous: (bytes: Int64, formatted: String)?)

        public var formattedText: String {
            switch self {
            case .unmeasured: return "Chưa đo"
            case .measuring: return "Đang tính…"
            case .current(_, let formatted): return formatted
            case .stale(_, let formatted): return "\(formatted) (Số đo trước lần dọn)"
            case .failed(let prev):
                if let prev {
                    return "\(prev.formatted) (Chưa đo lại được)"
                } else {
                    return "Chưa đo được"
                }
            }
        }

        public static func == (lhs: StorageMeasurementStatus, rhs: StorageMeasurementStatus) -> Bool {
            switch (lhs, rhs) {
            case (.unmeasured, .unmeasured): return true
            case (.measuring, .measuring): return true
            case (.current(let b1, let f1), .current(let b2, let f2)): return b1 == b2 && f1 == f2
            case (.stale(let b1, let f1), .stale(let b2, let f2)): return b1 == b2 && f1 == f2
            case (.failed(let p1), .failed(let p2)):
                if let p1, let p2 { return p1.bytes == p2.bytes && p1.formatted == p2.formatted }
                return p1 == nil && p2 == nil
            default: return false
            }
        }
    }

    @Published public private(set) var storageMeasurement: StorageMeasurementStatus = .unmeasured
    @Published public private(set) var cacheCleanTaskID: String? = nil
    public var isCleaningCache: Bool { cacheCleanTaskID != nil }
    private var currentStorageMeasurementID: Int = 0
    public var onStorageMeasurementFinished: ((Int, StorageMeasurementStatus) -> Void)?

    public func requestStorageMeasurement(isPostClean: Bool = false) {
        if !isPostClean {
            if case .measuring = storageMeasurement { return }
            if isCleaningCache { return }
        }
        currentStorageMeasurementID += 1
        let measureID = currentStorageMeasurementID
        storageMeasurement = .measuring
        let layout = self.layout

        Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            var totalBytes: Int64 = 0
            var measureFailed = false
            if let enumerator = fm.enumerator(at: layout.rootURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) {
                for case let fileURL as URL in enumerator {
                    do {
                        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if values.isRegularFile == true {
                            totalBytes += Int64(values.fileSize ?? 0)
                        }
                    } catch {
                        measureFailed = true
                        break
                    }
                }
            } else {
                measureFailed = true
            }

            await MainActor.run {
                guard let self, self.currentStorageMeasurementID == measureID else { return }
                let formatted = FileLayout.formattedBytes(totalBytes)
                let status: StorageMeasurementStatus
                if measureFailed {
                    let prev: (bytes: Int64, formatted: String)? = {
                        switch self.storageMeasurement {
                        case .current(let b, let f), .stale(let b, let f): return (b, f)
                        default: return nil
                        }
                    }()
                    status = .failed(previous: prev)
                } else {
                    status = .current(bytes: totalBytes, formatted: formatted)
                }
                self.storageMeasurement = status
                self.onStorageMeasurementFinished?(measureID, status)
            }
        }
    }

    public func cleanCache() {
        guard cacheCleanTaskID == nil else { return }
        let taskID = IDFactory.new()
        cacheCleanTaskID = taskID
        currentStorageMeasurementID += 1
        let postCleanMeasureID = currentStorageMeasurementID

        let thumbs = self.thumbnails
        let layout = self.layout
        Task.detached(priority: .utility) { [weak self] in
            let clearResult = thumbs.clearAllWithResult()

            // Đo dung lượng nghiêm ngặt sau khi dọn (§5.3)
            let fm = FileManager.default
            var totalBytes: Int64 = 0
            var measureFailed = false
            if let enumerator = fm.enumerator(at: layout.rootURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) {
                for case let fileURL as URL in enumerator {
                    do {
                        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if values.isRegularFile == true {
                            totalBytes += Int64(values.fileSize ?? 0)
                        }
                    } catch {
                        measureFailed = true
                        break
                    }
                }
            } else {
                measureFailed = true
            }

            await MainActor.run {
                guard let self, self.cacheCleanTaskID == taskID else { return }
                self.cacheCleanTaskID = nil

                let formatted = FileLayout.formattedBytes(totalBytes)
                var measurementSucceeded = false
                if !measureFailed && self.currentStorageMeasurementID == postCleanMeasureID {
                    self.storageMeasurement = .current(bytes: totalBytes, formatted: formatted)
                    measurementSucceeded = true
                } else {
                    let prev: (bytes: Int64, formatted: String)? = {
                        switch self.storageMeasurement {
                        case .current(let b, let f), .stale(let b, let f): return (b, f)
                        default: return nil
                        }
                    }()
                    if let prev {
                        self.storageMeasurement = .stale(bytes: prev.bytes, formatted: prev.formatted)
                    } else {
                        self.storageMeasurement = .failed(previous: nil)
                    }
                }

                switch clearResult {
                case .success:
                    if measurementSucceeded {
                        self.showToast("Đã dọn cache — không xóa ảnh/khung/phiên")
                    } else {
                        self.showToast("Đã dọn cache, chưa đo lại được dung lượng", kind: .warning)
                    }
                case .partial(let count, let err):
                    if measurementSucceeded {
                        self.showToast("Dọn cache một phần: \(count) mục lỗi (\(err))", kind: .warning)
                    } else {
                        self.showToast("Dọn cache một phần và chưa đo lại được dung lượng", kind: .warning)
                    }
                case .failure(let err):
                    self.showToast("Dọn cache thất bại: \(err)", kind: .warning)
                }
            }
        }
    }

    /// Forward thay đổi state engine sang env để mọi view observe env thấy cập nhật realtime
    /// (countdown từng giây, "Đang chụp…", thumbnail mới — P1-9).
    private var engineChangeCancellable: AnyCancellable?
    private var captureLeaveCancellable: AnyCancellable?

    public struct FrameEditorContext: Equatable {
        public var frameID: String?
        public init(frameID: String?) { self.frameID = frameID }
    }

    public init(inMemory: Bool = false, customRoot: URL? = nil, customDefaults: UserDefaults? = nil,
                camera: CameraServing = CameraService()) {
        if let customRoot {
            self.effectiveRoot = customRoot
        } else if inMemory {
            self.effectiveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPhotoboothTest-\(UUID().uuidString)", isDirectory: true)
        } else {
            self.effectiveRoot = nil
        }

        var currentLaunchError: AppError? = nil
        do {
            layout = try FileLayout(rootURL: effectiveRoot)
        } catch {
            layout = try! FileLayout(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("OpenPhotoboothFallback-\(UUID().uuidString)", isDirectory: true))
            currentLaunchError = .ioFailure("Không tạo được thư mục dữ liệu: \(error)")
        }

        var openedDB: SQLiteDatabase?
        var initError: AppError? = nil
        do {
            if inMemory {
                openedDB = try SQLiteDatabase(path: ":memory:")
            } else {
                let dbURL = layout.databaseURL
                try dbURL.deletingLastPathComponent().ensureDirectory()
                openedDB = try SQLiteDatabase(path: dbURL.path)
            }
        } catch {
            initError = .databaseCorrupt("Không mở được database: \(error.localizedDescription) (E-DB-01)")
            openedDB = try? SQLiteDatabase(path: ":memory:")
        }

        let database = openedDB ?? (try! SQLiteDatabase(path: ":memory:"))
        db = database

        if initError == nil {
            do {
                try Schema.migrate(database, backupFolder: layout.rootURL.appendingPathComponent("backups"))
            } catch {
                initError = .databaseCorrupt("Lỗi khởi tạo hoặc migration schema: \(error.localizedDescription)")
            }
        }
        if currentLaunchError == nil { currentLaunchError = initError }

        assets = AssetStore(db: db, layout: layout)
        frames = FrameRepository(db: db, assets: assets, layout: layout)
        presets = PresetRepository(db: db)
        sessions = SessionRepository(db: db, layout: layout)
        trashRepo = TrashRepository(db: db)
        thumbnails = ThumbnailStore(layout: layout)

        let defs = customDefaults ?? (inMemory ? (UserDefaults(suiteName: "test-\(UUID().uuidString)") ?? .standard) : .standard)
        settings = SettingsStore(defaults: defs)
        frameThumbnails = FrameThumbnailService(frames: frames, assets: assets, thumbnails: thumbnails, settings: settings)
        audio = AudioService(settings: settings, playback: inMemory ? { _, _ in } : nil)
        faceAnalysis = FaceAnalysisService()
        renderBuilder = SessionRenderBuilder(sessions: sessions, assets: assets, layout: layout, faceAnalysis: faceAnalysis)
        coordinator = OperationCoordinator.shared
        safetySave = SafetySaveService(db: db, layout: layout, sessions: sessions, trashRepo: trashRepo, coordinator: coordinator)
        trashService = TrashService(db: db, layout: layout, trashRepo: trashRepo, assets: assets)
        clockSanity = ClockSanityMonitor()
        trashScheduler = TrashCleanupScheduler(trashService: trashService, trashRepo: trashRepo, clockSanity: clockSanity)
        exportService = ExportService(sessions: sessions, builder: renderBuilder, trashRepo: trashRepo, layout: layout)
        shareService = ShareService(layout: layout, sessions: sessions, builder: renderBuilder)
        packService = FramePackService(frames: frames, assets: assets, layout: layout, db: db)

        self.camera = camera
        engine = CaptureEngine(camera: camera, safetySave: safetySave, sessions: sessions, audio: audio)
        engine.onSessionStatusChanged = { [weak self] _ in
            self?.objectWillChange.send()
        }
        engineChangeCancellable = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.launchError = currentLaunchError
        // Màn hình mở đầu theo Cài đặt (§15.1) — áp dụng khi khởi động app.
        switch settings.startupScreen {
        case "frames": route = .frames
        case "library": route = .library
        case "trash": route = .trash
        case "settings": route = .settings
        default: route = .capture
        }
        // Lưu ý: KHÔNG chạm NSApp tại đây (App.init có thể chạy trước khi NSApplication tồn tại).
        // applyAppearance được gọi từ onAppear của MainWindow.
    }

    /// Khởi động theo §3.1: migration xong → seed → recovery → dọn rác (ưu tiên thấp) → banner.
    public func boot() async {
        guard launchError == nil else {
            Log.app.warning("Bỏ qua boot vì launchError: \(String(describing: self.launchError))")
            return
        }
        // 3.1.2: recovery trước khi phân loại; không tự dọn file ảnh nguồn chưa phân loại
        let recovery = RecoveryService(db: db, layout: layout, sessions: sessions,
                                       trashRepo: trashRepo, trashService: trashService)
        var report = await recovery.runOnLaunch()
        do {
            let sessions = self.sessions
            let frames = self.frames
            let result = try await Task.detached(priority: .utility) {
                try sessions.repairLegacyFrameAssignments(using: frames)
            }.value
            if result.updated > 0 {
                Log.store.info("Đã khôi phục ánh xạ ảnh của \(result.updated) phiên")
            }
            report.issues += result.unresolved.map { "Cần kiểm tra ánh xạ ảnh của phiên \($0)" }
        } catch {
            report.issues.append("Không thể kiểm tra ánh xạ ảnh: \(error.localizedDescription)")
        }
        recoveryReport = report
        // 3.1.3: seed khung và preset tích hợp (idempotent)
        do {
            try FrameSeeder.seedIfNeeded(db: db, frameRepo: frames, presetRepo: presets, assets: assets)
            EventBus.shared.post(.frameLibraryChanged(frameID: nil))
        } catch {
            Log.app.error("Seed lỗi: \(error.localizedDescription, privacy: .public)")
        }
        // 3.1.4: dọn Thùng rác sau khi dữ liệu sẵn sàng, không block UI
        trashScheduler.start()
        // Dọn thumbnail cũ (>30 ngày) nền — cache có thể tạo lại, không thuộc vòng đời Trash (§10.5)
        let thumbStore = thumbnails
        Task.detached(priority: .utility) {
            thumbStore.pruneOlderThan(days: 30)
        }
        // 3.1.6: banner phiên chưa hoàn thành
        if let session = try? sessions.latestRecoverableSession() {
            bannerSessionID = session.id
        }
        // Dọn share cache cũ (§11.4)
        shareService.cleanupStaleShareCache()
        if report.hasProblems {
            let count = report.quarantinedFiles + report.orphanedFiles
            toast = ToastMessage(text: "Khởi động an toàn: \(count) tệp nghi vấn, \(report.issues.count) vấn đề cần kiểm tra.",
                                 kind: report.issues.isEmpty ? .info : .warning)
        }
        EventBus.shared.post(.recoveryCompleted(issues: report.issues.count))
    }

    @discardableResult
    func saveDefaultExportFolder(_ url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let blob = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let oldID = settings.exportFolderBookmarkID
        let newID = try trashRepo.saveBookmark(purpose: "exportFolder", blob: blob, displayPath: url.path)
        settings.exportFolderBookmarkID = newID
        if let oldID {
            do {
                try trashRepo.deleteBookmark(id: oldID)
            } catch {
                Log.export.error("Không thể dọn bookmark cũ: \(error.localizedDescription, privacy: .private)")
            }
        }
        return newID
    }

    public func showToast(_ text: String, kind: ToastMessage.Kind = .success) {
        toast = ToastMessage(text: text, kind: kind)
    }

    /// Đóng banner phiên chưa hoàn thành (§3.1.6 — dùng bởi SessionBanner).
    public func dismissBanner() {
        bannerSessionID = nil
    }

    /// Mở thư mục dữ liệu kho lưu trữ trong Finder (§3.1, D2-A02)
    public func revealDataFolderInFinder() {
        let folder = layout.rootURL
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        } else {
            let parent = folder.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: parent.path)
            }
        }
    }

    /// Tạo một instance AppEnvironment mới để thử khởi động lại kho dữ liệu (§3.1, D2-A02)
    public func makeRetriedEnvironment() -> AppEnvironment {
        AppEnvironment(customRoot: effectiveRoot)
    }

    public struct NavigationHoldState: Equatable {
        public let remainingSeconds: Int
        public let captureIndex: Int
        public let kind: CaptureEngine.ShotKind
        public let isIntermission: Bool
    }
    @Published public var navigationHold: NavigationHoldState?

    // Review pending edits guard (REV-01, NAV-02)
    public var reviewHasPendingEdits: (() -> Bool)?
    public var reviewFlushHandler: (() async -> Bool)?
    public var reviewDiscardHandler: (() -> Void)?
    @Published public var showReviewLeaveConfirmation = false

    var canSelectFrameForCapture: Bool {
        guard engine.session != nil else { return true }
        guard !engine.hasPhotoToSave, engine.committedShots.isEmpty else { return false }
        switch engine.state {
        case .ready, .paused: return true
        default: return false
        }
    }

    @discardableResult
    func selectFrameForCapture(_ frameID: String) throws -> Frame {
        guard let frame = try frames.getFrame(id: frameID), frame.lifecycle == .active else {
            throw AppError.notFound("Khung ảnh không còn khả dụng")
        }
        guard frame.validationStatus == .ready else { throw AppError.frameUnconfigured }
        if engine.snapshot?.sourceFrameID == frameID { return frame }
        guard canSelectFrameForCapture else { throw AppError.frameLockedDuringCapture }
        if let active = engine.session {
            let token = try coordinator.acquire(key: "session:\(active.id)", reason: "Chọn khung cho phiên mới")
            defer { token.release() }
            guard let detail = try sessions.getDetail(sessionID: active.id),
                  [.draft, .inProgress, .paused].contains(detail.session.status),
                  detail.photoRevisions.values.allSatisfy(\.isEmpty),
                  !(try trashRepo.pendingIntents(opType: "savePhoto")).contains(where: { $0.rootID == active.id }) else {
                throw AppError.frameLockedDuringCapture
            }
            try sessions.setStatus(sessionID: active.id, status: .paused)
            engine.resetToIdle()
        }
        preferredFrameID = frameID
        return frame
    }

    /// Điểm yêu cầu điều hướng thống nhất có bảo vệ an toàn chụp ảnh và Frame Editor (D2-A10, NAV-01, NAV-02, H-B4)
    public func requestNavigation(to targetRoute: ScreenRoute) {
        guard targetRoute != route else { return }
        if targetRoute != .settings {
            pendingSettingsSection = nil
        }
        if case .review = route {
            if let hasPending = reviewHasPendingEdits, hasPending() {
                pendingNavigationRoute = targetRoute
                Task { @MainActor in
                    if let flush = self.reviewFlushHandler {
                        let ok = await flush()
                        if ok {
                            self.reviewHasPendingEdits = nil
                            self.reviewFlushHandler = nil
                            self.reviewDiscardHandler = nil
                            if let target = self.pendingNavigationRoute {
                                self.pendingNavigationRoute = nil
                                self.route = target
                            }
                        } else {
                            self.showReviewLeaveConfirmation = true
                        }
                    } else {
                        self.route = targetRoute
                    }
                }
                return
            }
        }
        if case .frameEditor = route {
            if frameEditorHasChanges {
                pendingNavigationRoute = targetRoute
                showFrameEditorLeaveConfirmation = true
                return
            } else {
                closeFrameEditor()
            }
        }
        if route == .capture {
            switch engine.state {
            case .countdown(let remaining, let index, let kind):
                pendingNavigationRoute = targetRoute
                navigationHold = NavigationHoldState(remainingSeconds: remaining, captureIndex: index, kind: kind, isIntermission: false)
                engine.holdCountdownTimer()
                showLeaveCaptureConfirmation = true
                return
            case .intermission(let nextIndex, let remaining):
                pendingNavigationRoute = targetRoute
                navigationHold = NavigationHoldState(remainingSeconds: remaining, captureIndex: nextIndex, kind: .normal, isIntermission: true)
                engine.holdCountdownTimer()
                showLeaveCaptureConfirmation = true
                return
            case .capturing, .persisting:
                pendingNavigationRoute = targetRoute
                showLeaveCaptureConfirmation = true
                // KHÔNG gọi engine.pause() ngay (NAV-02) — để ảnh đang chụp/lưu hoàn tất an toàn
                engine.holdAtSafePoint()
                return
            default:
                break
            }
        }
        self.route = targetRoute
    }

    /// Thử lưu lại các thay đổi của Review khi rời view (REV-01, NAV-02)
    public func retryLeaveReviewSave() {
        Task { @MainActor in
            if let flush = self.reviewFlushHandler {
                let ok = await flush()
                if ok {
                    self.showReviewLeaveConfirmation = false
                    self.reviewHasPendingEdits = nil
                    self.reviewFlushHandler = nil
                    self.reviewDiscardHandler = nil
                    if let target = self.pendingNavigationRoute {
                        self.pendingNavigationRoute = nil
                        self.route = target
                    }
                }
            }
        }
    }

    /// Bỏ qua các thay đổi chưa lưu và rời Review (REV-01, NAV-02)
    public func confirmLeaveReviewDiscard() {
        showReviewLeaveConfirmation = false
        reviewDiscardHandler?()
        reviewHasPendingEdits = nil
        reviewFlushHandler = nil
        reviewDiscardHandler = nil
        if let target = pendingNavigationRoute {
            pendingNavigationRoute = nil
            self.route = target
        }
    }

    /// Hủy yêu cầu rời Review, ở lại màn hình Xem lại (REV-01, NAV-02)
    public func cancelLeaveReview() {
        showReviewLeaveConfirmation = false
        pendingNavigationRoute = nil
        pendingSettingsSection = nil
    }

    /// Người dùng chọn "Lưu" hoặc "Bỏ thay đổi" khi rời Frame Editor (H-B4)
    public func confirmLeaveFrameEditor() {
        showFrameEditorLeaveConfirmation = false
        frameEditorHasChanges = false
        frameEditorSaveHandler = nil
        closeFrameEditor()
        if let target = pendingNavigationRoute {
            pendingNavigationRoute = nil
            self.route = target
        }
    }

    /// Người dùng chọn "Hủy" giữ nguyên Frame Editor (H-B4)
    public func cancelLeaveFrameEditor() {
        showFrameEditorLeaveConfirmation = false
        pendingNavigationRoute = nil
        pendingSettingsSection = nil
    }

    /// Người dùng chọn "Tạm dừng và rời màn hình" (D2-A10, NAV-02)
    public func confirmLeaveCapture() {
        showLeaveCaptureConfirmation = false
        if let hold = navigationHold {
            navigationHold = nil
            engine.pauseFromNavigationHold(nextIndex: hold.captureIndex, kind: hold.kind)
        } else {
            engine.pause(reason: .user)
            if engine.isCaptureBusy {
                captureLeaveCancellable = engine.$state.dropFirst().sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.finishCaptureLeaveIfReady() }
                }
                return
            }
        }
        finishCaptureLeaveIfReady()
    }

    private func finishCaptureLeaveIfReady() {
        guard !engine.isCaptureBusy else { return }
        captureLeaveCancellable = nil
        if engine.hasPhotoToSave {
            pendingNavigationRoute = nil
            pendingSettingsSection = nil
            return
        }
        if let target = pendingNavigationRoute {
            pendingNavigationRoute = nil
            self.route = target
        }
    }

    /// Người dùng chọn "Ở lại" giữ nguyên phiên chụp (D2-A10, NAV-02)
    public func stayInCapture() {
        showLeaveCaptureConfirmation = false
        pendingNavigationRoute = nil
        pendingSettingsSection = nil
        if let hold = navigationHold {
            navigationHold = nil
            engine.resumeFromNavigationHold(remainingSeconds: hold.remainingSeconds,
                                           captureIndex: hold.captureIndex,
                                           kind: hold.kind,
                                           isIntermission: hold.isIntermission)
        } else {
            engine.releaseSafePointHold()
        }
    }

    public struct ReviewContext: Equatable {
        public var sessionID: String
        public var sourceRoute: ScreenRoute
        public var openFramePicker: Bool
        public var exportIntentID: String?
        public init(sessionID: String, sourceRoute: ScreenRoute = .library, openFramePicker: Bool = false, exportIntentID: String? = nil) {
            self.sessionID = sessionID
            self.sourceRoute = sourceRoute
            self.openFramePicker = openFramePicker
            self.exportIntentID = exportIntentID
        }
    }

    @Published public var reviewContext: ReviewContext?

    public func openReview(sessionID: String, source: ScreenRoute = .library, openFramePicker: Bool = false, openExport: Bool = false) {
        let intentID = openExport ? IDFactory.new() : nil
        reviewContext = ReviewContext(sessionID: sessionID, sourceRoute: source, openFramePicker: openFramePicker, exportIntentID: intentID)
        route = .review(sessionID: sessionID)
    }

    public func openFrameEditor(frameID: String?) {
        frameEditorDraft = FrameEditorContext(frameID: frameID)
        route = .frameEditor(frameID: frameID)
    }

    public func closeFrameEditor() {
        frameEditorDraft = nil
        route = .frames
    }

    /// Hoàn thành phiên và Auto Export đúng một lần cho mỗi lần chuyển trạng thái (A8).
    /// Nhận token cha hoặc tự lấy khóa `session:<id>`.
    @discardableResult
    public func completeSession(sessionID: String, parentToken: OperationCoordinator.OperationToken? = nil) async throws -> Bool {
        let token = try coordinator.acquire(key: "session:\(sessionID)", reason: "completeSession", parentToken: parentToken)
        defer { token.release() }

        guard let detail = try sessions.activeCaptureDetail(sessionID: sessionID) else {
            throw AppError.notFound("Phiên chụp không tồn tại hoặc đã bị đưa vào Thùng rác")
        }
        if detail.needsPhotoSelection { throw AppError.invalidState("Chọn ảnh vào khung trước") }
        guard detail.hasEnoughPhotos else {
            throw AppError.notEnoughPhotos(missing: detail.missingCount)
        }

        let didTransition = try db.withTransaction { tx -> Bool in
            let rows = try tx.query("SELECT status, completed_at_ms FROM sessions WHERE id=?", [.text(sessionID)])
            guard let row = rows.first else { throw AppError.notFound("session \(sessionID)") }
            if row["status"]?.stringValue == "completed" {
                return false
            }
            let now = Time.nowMs()
            try tx.run("""
                UPDATE sessions
                SET status='completed', completed_at_ms=?, updated_at_ms=?, revision_no=revision_no+1
                WHERE id=?
                """, [.int(now), .int(now), .text(sessionID)])
            return true
        }

        if didTransition {
            EventBus.shared.post(.sessionChanged(sessionID: sessionID, revision: 0))
            if engine.session?.id == sessionID {
                engine.complete()
            }
            if settings.autoExport {
                if let freshDetail = try? sessions.getDetail(sessionID: sessionID) {
                    let exportResult = await exportService.autoExport(
                        detail: freshDetail,
                        folderBookmarkID: settings.exportFolderBookmarkID,
                        format: settings.exportFormat, quality: settings.jpegQuality,
                        parentToken: token
                    )
                    switch exportResult {
                    case .success(let url):
                        showToast("Auto Export xong: \(url.lastPathComponent)")
                    case .failure(.exportHistoryNotSaved(let url)):
                        showToast("Auto Export đã lưu \(url.lastPathComponent), chưa ghi được lịch sử", kind: .warning)
                    case .failure(let error):
                        showToast("Auto Export lỗi: \(error.message) — phiên vẫn an toàn trong Thư viện", kind: .warning)
                    }
                }
            }
        }
        return didTransition
    }
}

extension URL {
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}
