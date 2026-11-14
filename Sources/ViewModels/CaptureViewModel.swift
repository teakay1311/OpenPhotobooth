import Foundation
import SwiftUI
import AppKit
import CoreGraphics

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

    @Published public private(set) var permissionState: CameraUIState = .notDetermined
    @Published public private(set) var devices: [CameraDescriptor] = []
    @Published public var selectedDeviceID: String = "auto"
    @Published public private(set) var cameraName: String = ""
    @Published public private(set) var fallbackStillNotice = false

    @Published public private(set) var frames: [FrameCardModel] = []
    @Published public var searchText: String = ""
    @Published public var categoryFilter: String? = nil
    @Published public var showFavoritesOnly: Bool = false
    @Published public var selectedFrameID: String? = nil

    @Published public var mode: CaptureMode = .automatic
    @Published public var countdown: Int = 3
    @Published public var interval: Int = 2
    @Published public var selectedPresetID: String = "natural"
    @Published public var skinSmooth: Double = 0.25
    @Published public var liveFramePreview: Bool = false

    @Published public private(set) var previewFrameImage: CGImage? = nil
    @Published public private(set) var lastError: AppError?

    public let env: AppEnvironment
    public var engine: CaptureEngine { env.engine }

    public init(env: AppEnvironment) {
        self.env = env
        mode = env.settings.captureMode
        countdown = env.settings.countdown
        interval = env.settings.interval
        selectedPresetID = env.settings.defaultPreset
        skinSmooth = Double(env.settings.defaultSkinSmooth) / 100.0
        liveFramePreview = env.settings.liveFramePreview
    }

    // MARK: - Camera states (§2.2, §4.3)

    public func refreshCameraState() async {
        let state = await env.camera.requestAccessIfNeeded()
        switch state {
        case .notDetermined: permissionState = .notDetermined
        case .authorized:
            permissionState = .authorized
            devices = await env.camera.discoverDevices()
            if devices.isEmpty {
                permissionState = .noDevice
            } else if await env.camera.currentDevice == nil {
                await autoSelectCamera()
            }
        case .denied: permissionState = .denied
        case .restricted: permissionState = .denied
        }
        if let current = await env.camera.currentDevice {
            cameraName = current.localizedName
            fallbackStillNotice = await env.camera.isFallbackVideoStill
        } else {
            cameraName = ""
        }
    }

    public func enableCamera() async {
        _ = await env.camera.requestAccessIfNeeded()
        await refreshCameraState()
    }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    public func retryCamera() async {
        await refreshCameraState()
    }

    public func autoSelectCamera() async {
        do {
            _ = try await env.camera.selectAutoDevice()
            selectedDeviceID = "auto"
            if let current = await env.camera.currentDevice { cameraName = current.localizedName }
        } catch {
            permissionState = .noDevice
        }
    }

    public func selectCamera(_ id: String) async {
        guard engine.canChangeCamera else { return }
        selectedDeviceID = id
        if id == "auto" {
            await autoSelectCamera()
        } else {
            do {
                _ = try await env.camera.selectDevice(id)
                if let current = await env.camera.currentDevice { cameraName = current.localizedName }
            } catch {
                env.showToast((error as? AppError)?.message ?? "Không chọn được camera", kind: .warning)
            }
        }
    }

    public func startPreviewIfPossible() async {
        guard permissionState == .authorized else { return }
        do {
            try await env.camera.startPreview()
        } catch {
            Log.camera.error("Preview lỗi: \(error.localizedDescription, privacy: .public)")
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
            let thumb = env.thumbnails.cachedData(key: "frame-\(frame.currentRevisionID ?? frame.id)")
            models.append(FrameCardModel(frame: frame, thumbnail: thumb, slotCount: slots.count))
        }
        frames = models
        if let sel = selectedFrameID, !frames.contains(where: { $0.id == sel }) {
            selectedFrameID = nil
        }
        // Nhận lại khung được chọn từ màn Khung ảnh ("Sử dụng") — StateObject màn Chụp bị hủy
        // mỗi lần đổi route nên selection phải đến qua env (liên kết dữ liệu §2.3, P2-23).
        if selectedFrameID == nil,
           let preferred = env.preferredFrameID,
           frames.contains(where: { $0.id == preferred }) {
            selectedFrameID = preferred
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
        // Đổi khung chỉ khi chưa bắt đầu (I-05 §3.2: sau khi chụp ≥1 ảnh khóa đổi khung tại màn Chụp)
        guard engine.committedShots.isEmpty else {
            lastError = .frameLockedDuringCapture
            env.showToast(AppError.frameLockedDuringCapture.message, kind: .warning)
            return
        }
        selectedFrameID = id
        regeneratePreview()
    }

    public var selectedFrame: Frame? {
        guard let id = selectedFrameID else { return nil }
        return frames.first { $0.id == id }?.frame
    }

    public func regeneratePreview() {
        guard let frame = selectedFrame, let revID = frame.currentRevisionID,
              let rev = try? env.frames.getRevision(id: revID) else {
            previewFrameImage = nil
            return
        }
        let slots = (try? env.frames.getSlots(revisionID: revID)) ?? []
        var assetImages: [String: CGImage] = [:]
        if let bg = rev.backgroundAssetID, let img = try? env.assets.loadImage(assetID: bg) {
            assetImages[bg] = img
        }
        if let fg = rev.foregroundAssetID, let img = try? env.assets.loadImage(assetID: fg) {
            assetImages[fg] = img
        }
        let maxDim = 640
        let aspect = Double(rev.canvasWidth) / Double(max(rev.canvasHeight, 1))
        var w = maxDim, h = maxDim
        if aspect >= 1 { h = Int(Double(maxDim) / aspect) } else { w = Int(Double(maxDim) * aspect) }
        var sources: [Int: RenderSource] = [:]
        for idx in Set(slots.map(\.captureIndex)) {
            if let sample = SampleImageFactory.shared.sample(index: idx, size: CGSize(width: 480, height: 480)) {
                sources[idx] = RenderSource(image: sample)
            }
        }
        let snapSlots = slots.map { SnapshotSlot(from: $0) }
        let snap = FrameSnapshot(sourceFrameID: frame.id, sourceFrameRevisionID: revID,
                                 canvasWidth: rev.canvasWidth, canvasHeight: rev.canvasHeight,
                                 background: rev.backgroundAssetID.map { SnapshotLayer(assetID: $0, placement: rev.backgroundPlacement) },
                                 foreground: rev.foregroundAssetID.map { SnapshotLayer(assetID: $0, placement: rev.foregroundPlacement) },
                                 backgroundColorHex: rev.backgroundColorHex,
                                 slots: snapSlots, snapshotHash: "preview")
        let model = CompositionModel(snapshot: snap, sources: sources, faces: [:],
                                     defaults: env.settings.sessionDefaultsSnapshot(),
                                     overrides: [:], placements: [:],
                                     cropModes: [:], assetImages: assetImages,
                                     options: RenderOptions(targetWidth: w, targetHeight: h))
        previewFrameImage = try? CompositeRenderer.render(model: model)
    }

    // MARK: - Session lifecycle (§3.2)

    public var canStartSession: Bool {
        permissionState == .authorized &&
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
        case .recoverableError: return "Thử lại lượt"
        case .reviewing, .completed: return "Xem và chỉnh ảnh"
        default: return "Bắt đầu chụp"
        }
    }

    public func primaryAction() async {
        switch engine.state {
        case .idle:
            await startNewSession()
        case .ready:
            if engine.committedShots.isEmpty {
                await startNewSessionIfNeeded()
            } else {
                try? engine.captureNextManual()
            }
        case .countdown, .intermission:
            if case .countdown = engine.state { engine.cancelCountdown() } else { engine.pause() }
        case .paused:
            try? engine.resume()
        case .recoverableError:
            engine.retryFromError()
            try? engine.startOrContinue()
        case .reviewing, .completed:
            if let id = engine.session?.id { env.openReview(sessionID: id) }
        default:
            break
        }
    }

    /// Kiểm tra tiền điều kiện §17.3 CreateSession: frame ready + camera usable + storage writable.
    public func startNewSession() async {
        guard canStartSession, let frame = selectedFrame else { return }
        // Nếu có phiên paused khác → lựa chọn (§10.3)
        if let existing = engine.session, engine.state != .idle {
            env.showToast("Đang có phiên hoạt động", kind: .warning)
            return
        }
        do {
            // Kiểm tra bộ nhớ ghi được (E-STO-01)
            guard SafetySaveService.isWritable(env.layout.rootURL) else {
                throw AppError.diskFull
            }
            let snapshot = try env.frames.createSnapshot(frameID: frame.id)
            let defaults = env.settings.sessionDefaultsSnapshot()
            _ = try engine.beginSession(snapshot: snapshot, mode: mode,
                                        cameraID: selectedDeviceID == "auto" ? await env.camera.currentDevice?.uniqueID : selectedDeviceID,
                                        defaults: defaults,
                                        countdown: countdown, interval: interval)
            try engine.startOrContinue()
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

    public func continueBannerSession() async {
        guard let sessionID = env.bannerSessionID,
              let detail = try? env.sessions.getDetail(sessionID: sessionID) else { return }
        if detail.hasEnoughPhotos {
            env.openReview(sessionID: sessionID)
        } else {
            await adoptForCapture(detail: detail)
        }
        env.bannerSessionID = nil
    }

    public func adoptForCapture(detail: SessionDetail) async {
        let committed = detail.currentRevisions()
        env.engine.adoptSession(record: detail.session, snapshot: detail.snapshot, committed: committed)
        selectedFrameID = detail.snapshot.sourceFrameID
        regeneratePreview()
        _ = try? env.camera.startPreview()
    }

    public func viewBannerSession() {
        guard let sessionID = env.bannerSessionID else { return }
        env.openReview(sessionID: sessionID)
        env.bannerSessionID = nil
    }

    public func dismissBanner() {
        env.bannerSessionID = nil
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
        let colors = [CGColor(hue: hue, saturation: 0.45, brightness: 0.92, alpha: 1),
                      CGColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 0.75, alpha: 1)] as CFArray
        if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        ctx.setFillColor(CGColor(red: 0.92, green: 0.78, blue: 0.66, alpha: 1))
        let face = CGRect(x: CGFloat(w) * 0.32, y: CGFloat(h) * 0.25, width: CGFloat(w) * 0.36, height: CGFloat(w) * 0.36)
        ctx.fillEllipse(in: face)
        let text = "Ảnh mẫu \(index)"
        let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(w) / 12, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(white: 1, alpha: 0.95)]
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
