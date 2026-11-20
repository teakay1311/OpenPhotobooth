import SwiftUI
import AppKit

/// FullscreenView (§14): Welcome → Chọn khung → Live → Review → Kết thúc.
/// Sử dụng FullscreenViewModel + CaptureViewModel đã có.
public struct FullscreenView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var captureVM: CaptureViewModel
    @StateObject private var vm: FullscreenViewModel
    @State private var shootingTask: Task<Void, Never>?

    public init(env: AppEnvironment) {
        self.env = env
        let cap = CaptureViewModel(env: env)
        _captureVM = StateObject(wrappedValue: cap)
        _vm = StateObject(wrappedValue: FullscreenViewModel(env: env, captureVM: cap))
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch vm.step {
                case .welcome: welcomeStep
                case .captureSetup: captureSetupStep
                case .chooseFrame: chooseFrameStep
                case .live: liveStep
                case .review: reviewStep
                case .finish: finishStep
                }
            }
            .disabled(vm.exitRequested)
            // Exit button (top-right)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        requestExit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.exitRequested || env.engine.isCancellingSession)
                    .help("Đóng chế độ toàn màn hình (Esc)")
                    .accessibilityLabel("Đóng chế độ toàn màn hình")
                    .padding(14)
                }
                Spacer()
            }
        }
        .onExitCommand { requestExit() }
        .onChange(of: env.nativeFullscreenExitRequest) { requestExit() }
        .onChange(of: env.engine.state) { vm.finishExitIfReady() }
        .onChange(of: env.lastCancelledCaptureID) { vm.returnToCaptureSetupAfterCancellation() }
        .overlay(alignment: .bottom) {
            ToastOverlay(env: env).allowsHitTesting(false)
        }
        .task {
            vm.enterFullscreen()
            await captureVM.retryCamera()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await captureVM.refreshCameraState() }
        }
        .task { await captureVM.observeCameraEvents() }
        .onChange(of: env.engine.isCaptureBusy || env.engine.isCancellingSession) { _, busy in
            if !busy { Task { await captureVM.resumeDeferredCameraRefresh() } }
        }
        .onDisappear {
            shootingTask?.cancel()
        }
    }

    private func requestExit() {
        guard !env.engine.isCancellingSession else { return }
        shootingTask?.cancel()
        vm.exitFullscreenRequested()
    }

    // MARK: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Text("Photobooth").font(.system(size: 56, weight: .bold)).foregroundStyle(.white)
            Text("Chạm để bắt đầu").font(.title2).foregroundStyle(.white.opacity(0.7))
            PrimaryButton(title: "Bắt đầu", systemImage: "play.fill") {
                vm.step = .captureSetup
            }
            .controlSize(.large)
        }
    }

    // MARK: Thiết lập chụp

    private var captureSetupStep: some View {
        VStack(spacing: 20) {
            Text("Thiết lập chụp").font(.title).foregroundStyle(.white)
            CaptureCountPicker(count: $captureVM.plannedCaptureCount)
                .foregroundStyle(.white)
            HStack(spacing: 12) {
                Button("Quay lại") { vm.step = .welcome }
                    .buttonStyle(.borderedProminent)
                Spacer()
                if captureVM.permissionState == .notDetermined {
                    PrimaryButton(title: "Bật camera", systemImage: "camera") {
                        Task {
                            await captureVM.enableCamera()
                        }
                    }
                } else if captureVM.permissionState == .denied {
                    HStack(spacing: 8) {
                        PrimaryButton(title: "Mở Cài đặt hệ thống") { captureVM.openSystemSettings() }
                        Button("Thử lại") {
                            Task {
                                await captureVM.retryCamera()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                } else if !captureVM.isCameraReady {
                    cameraConnectionStatus
                }
                PrimaryButton(title: "Bắt đầu chụp", systemImage: "camera.fill",
                              disabledReason: shootDisabledReason) {
                    shootingTask = Task { await vm.beginShooting() }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private var chooseFrameStep: some View {
        if let id = env.engine.session?.id {
            CaptureFrameChooser(env: env, sessionID: id, kiosk: true, onMissingPhotos: { detail in
                if env.engine.adoptSession(record: detail.session, snapshot: detail.snapshot,
                                           committed: detail.currentRevisions()) {
                    vm.step = .live
                }
            }, onClose: { requestExit() },
                                onApplied: { Task { await vm.openReview() } })
                .padding(.top, 38)
        }
    }

    private var shootDisabledReason: String? {
        if vm.isStarting { return "Đang chuẩn bị phiên chụp" }
        if captureVM.permissionState != .authorized { return "Cần bật camera trước" }
        if !captureVM.isCameraReady { return "Chờ camera sẵn sàng" }
        return nil
    }

    private var cameraConnectionStatus: some View {
        HStack(spacing: 8) {
            if captureVM.isConnectingCamera { ProgressView().tint(.white) }
            Text(captureVM.cameraPreviewError ?? "Đang chờ khung hình từ camera…")
                .foregroundStyle(.white)
            if !captureVM.isConnectingCamera {
                Button("Thử lại camera") { Task { await captureVM.retryCamera() } }
            }
        }
    }

    // MARK: Live (chờ chụp xong, hiện countdown overlay)

    private var liveStep: some View {
        VStack(spacing: 12) {
            if !captureVM.isCameraReady {
                cameraConnectionStatus.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let service = env.camera as? CameraService {
                CIPreviewView(cameraService: service,
                              mirror: env.settings.previewMirror,
                              photoParameters: captureVM.livePhotoParameters, faceAnalysis: env.faceAnalysis)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Camera không khả dụng").foregroundStyle(.white)
            }
            // Overlay countdown
            if let session = env.engine.session {
                Text("Đã lưu \(env.engine.committedShots.count)/\(session.captureCount) ảnh")
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            if case .countdown(let remaining, let index, _) = env.engine.state {
                VStack(spacing: 6) {
                    Text("\(remaining)").font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(.white).shadow(radius: 8)
                    Text("Ảnh \(index)/\(env.engine.requiredIndices.count)")
                        .font(.title3).foregroundStyle(.white)
                }
            }
            CaptureCancellationButton(env: env)
            switch env.engine.state {
            case .ready where !env.engine.isCancellingSession:
                PrimaryButton(title: "Chụp tiếp", systemImage: "camera",
                              disabledReason: captureVM.isCameraReady ? nil : "Chờ camera sẵn sàng") {
                    Task {
                        guard await env.capturePreview.confirmVideoFallback(), env.showFullscreen, !vm.exitRequested else { return }
                        do {
                            if env.engine.session?.captureMode == .manual { try env.engine.captureNextManual() }
                            else { try env.engine.startOrContinue() }
                        } catch { env.showToast(error.localizedDescription, kind: .warning) }
                    }
                }
            case .paused where !env.engine.isCancellingSession:
                PrimaryButton(title: "Tiếp tục", systemImage: "play.fill",
                              disabledReason: captureVM.isCameraReady ? nil : "Chờ camera sẵn sàng") {
                    Task {
                        guard await env.capturePreview.confirmVideoFallback(), env.showFullscreen, !vm.exitRequested else { return }
                        do { try env.engine.resume() }
                        catch { env.showToast(error.localizedDescription, kind: .warning) }
                    }
                }
            case .recoverableError(let message, _) where !env.engine.isCancellingSession:
                Text(message).foregroundStyle(.white)
                PrimaryButton(title: captureVM.startButtonTitle, systemImage: "arrow.clockwise",
                              disabledReason: env.engine.hasPhotoToSave || captureVM.isCameraReady ? nil : "Chờ camera sẵn sàng") {
                    Task { await captureVM.primaryAction() }
                }
            default:
                EmptyView()
            }
        }
        .onChange(of: env.engine.state) { _, state in
            if state == .reviewing { Task { await vm.openReview() } }
        }
        .task {
            if env.engine.state == .reviewing { await vm.openReview() }
        }
    }

    // MARK: Review

    private var reviewStep: some View {
        Group {
            if let reviewVM = vm.reviewVM {
                FullscreenReviewContent(reviewVM: reviewVM, fullscreenVM: vm)
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    // MARK: Finish

    private var finishStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72)).foregroundStyle(.green)
            Text("Hoàn thành").font(.title).foregroundStyle(.white)
            if let sec = vm.idleSecondsLeft {
                Text("Tự quay lại sau \(sec)s").foregroundStyle(.white.opacity(0.6)).font(.caption)
            }
            HStack {
                Button("Quay lại màn Chụp") { vm.backToWelcome() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            vm.startIdleTimer()
        }
    }
}


private struct FullscreenReviewContent: View {
    @ObservedObject var reviewVM: ReviewViewModel
    @ObservedObject var fullscreenVM: FullscreenViewModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image = reviewVM.previewImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(20)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                PrimaryButton(title: "Hoàn thành", systemImage: "checkmark.circle.fill",
                              disabledReason: reviewVM.canExport && !fullscreenVM.isFinishing ? nil : "Chờ ảnh sẵn sàng") {
                    Task { await fullscreenVM.finish() }
                }
            }
            .padding(20)
        }
    }
}
