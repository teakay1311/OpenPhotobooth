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

    public var camera: CameraServing
    public let engine: CaptureEngine

    @Published public var route: ScreenRoute = .capture
    @Published public var recoveryReport: RecoveryService.Report?
    @Published public var bannerSessionID: String?
    @Published public var toast: ToastMessage?
    @Published public var showFullscreen = false
    @Published public var frameEditorDraft: FrameEditorContext?
    @Published public var showPackImport = false
    public var pendingPackURL: URL?
    /// Khung được chọn từ màn Khung ảnh ("Sử dụng") — màn Chụp nhận lại sau khi route đổi
    /// vì StateObject các màn bị hủy khi chuyển route (liên kết dữ liệu giữa các màn §2.3).
    @Published public var preferredFrameID: String?

    /// Forward thay đổi state engine sang env để mọi view observe env thấy cập nhật realtime
    /// (countdown từng giây, "Đang chụp…", thumbnail mới — P1-9).
    private var engineChangeCancellable: AnyCancellable?

    public struct FrameEditorContext: Equatable {
        public var frameID: String?
        public init(frameID: String?) { self.frameID = frameID }
    }

    public init(inMemory: Bool = false) {
        do {
            layout = try FileLayout()
        } catch {
            fatalError("Không tạo được thư mục dữ liệu: \(error)")
        }
        do {
            if inMemory {
                db = try SQLiteDatabase(path: ":memory:")
            } else {
                let dbURL = layout.databaseURL
                try dbURL.deletingLastPathComponent().ensureDirectory()
                db = try SQLiteDatabase(path: dbURL.path)
            }
        } catch {
            fatalError("Không mở được database: \(error) — không tự xóa DB (E-DB-01)")
        }
        try? Schema.migrate(db)

        assets = AssetStore(db: db, layout: layout)
        frames = FrameRepository(db: db, assets: assets, layout: layout)
        presets = PresetRepository(db: db)
        sessions = SessionRepository(db: db, layout: layout)
        trashRepo = TrashRepository(db: db)
        thumbnails = ThumbnailStore(layout: layout)

        settings = SettingsStore()
        audio = AudioService(settings: settings)
        faceAnalysis = FaceAnalysisService()
        renderBuilder = SessionRenderBuilder(sessions: sessions, assets: assets, layout: layout, faceAnalysis: faceAnalysis)
        safetySave = SafetySaveService(db: db, layout: layout, sessions: sessions, trashRepo: trashRepo)
        trashService = TrashService(db: db, layout: layout, trashRepo: trashRepo, assets: assets)
        clockSanity = ClockSanityMonitor()
        trashScheduler = TrashCleanupScheduler(trashService: trashService, trashRepo: trashRepo, clockSanity: clockSanity)
        exportService = ExportService(sessions: sessions, builder: renderBuilder, trashRepo: trashRepo, layout: layout)
        shareService = ShareService(layout: layout, sessions: sessions, builder: renderBuilder)
        packService = FramePackService(frames: frames, assets: assets, layout: layout, db: db)

        camera = CameraService()
        engine = CaptureEngine(camera: camera, safetySave: safetySave, sessions: sessions, audio: audio)
        engine.onSessionStatusChanged = { [weak self] _ in
            self?.objectWillChange.send()
        }
        engineChangeCancellable = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
        // 3.1.2: recovery trước khi phân loại; không tự dọn file ảnh nguồn chưa phân loại
        let recovery = RecoveryService(db: db, layout: layout, sessions: sessions,
                                       trashRepo: trashRepo)
        let report = await recovery.runOnLaunch()
        recoveryReport = report
        // 3.1.3: seed 3 khung + 8 preset (idempotent)
        do {
            try FrameSeeder.seedIfNeeded(db: db, frameRepo: frames, presetRepo: presets, assets: assets)
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
            toast = ToastMessage(text: "Khởi động an toàn: đã xử lý \(report.quarantinedFiles + report.orphanedFiles) tệp nghi vấn.", kind: .info)
        }
        EventBus.shared.post(.recoveryCompleted(issues: report.issues.count))
    }

    public func showToast(_ text: String, kind: ToastMessage.Kind = .success) {
        toast = ToastMessage(text: text, kind: kind)
    }

    /// Đóng banner phiên chưa hoàn thành (§3.1.6 — dùng bởi SessionBanner).
    public func dismissBanner() {
        bannerSessionID = nil
    }

    public func openReview(sessionID: String) {
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
}

extension URL {
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}
