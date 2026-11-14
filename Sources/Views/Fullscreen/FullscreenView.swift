import SwiftUI
import AppKit

/// FullscreenView (§14): Welcome → Chọn khung → Live → Review → Kết thúc.
/// Sử dụng FullscreenViewModel + CaptureViewModel đã có.
public struct FullscreenView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var captureVM: CaptureViewModel
    @StateObject private var vm: FullscreenViewModel
    @Environment(\.dismiss) private var dismiss

    public init(env: AppEnvironment) {
        self.env = env
        let cap = CaptureViewModel(env: env)
        _captureVM = StateObject(wrappedValue: cap)
        _vm = StateObject(wrappedValue: FullscreenViewModel(env: env, captureVM: cap))
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch vm.step {
            case .welcome: welcomeStep
            case .selectFrame: selectFrameStep
            case .live: liveStep
            case .review: reviewStep
            case .finish: finishStep
            }
            // Exit button (top-right)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        vm.exitFullscreenRequested()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                }
                Spacer()
            }
        }
        .onAppear {
            vm.enterFullscreen()
            captureVM.reloadFrames()
            // P1-10: refresh quyền/thiết bị camera — permissionState mặc định .notDetermined
            // khiến startNewSession guard-fail thầm lặng và màn Live đứng yên vĩnh viễn.
            Task {
                await captureVM.refreshCameraState()
                await captureVM.startPreviewIfPossible()
            }
        }
        .onDisappear {
            vm.pauseIdleTimer()
        }
    }

    // MARK: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Text("Photobooth").font(.system(size: 56, weight: .bold)).foregroundStyle(.white)
            Text("Chạm để bắt đầu").font(.title2).foregroundStyle(.white.opacity(0.7))
            PrimaryButton(title: "Bắt đầu", systemImage: "play.fill") {
                vm.step = .selectFrame
            }
            .controlSize(.large)
        }
    }

    // MARK: Select frame

    private var selectFrameStep: some View {
        VStack(spacing: 0) {
            Text("Chọn khung").font(.title).foregroundStyle(.white).padding(.top, 20)
            if vm.readyFrames.isEmpty {
                Spacer()
                Text("Chưa có khung hợp lệ. Mở màn Khung ảnh để thêm.").foregroundStyle(.white.opacity(0.6))
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(vm.readyFrames) { card in
                            Button {
                                vm.selectedFrameID = card.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    ImageDataView(data: card.thumbnail)
                                        .frame(height: 160)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(card.frame.name).foregroundStyle(.white).font(.headline)
                                    Text("\(card.slotCount) ảnh").foregroundStyle(.white.opacity(0.6)).font(.caption)
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(vm.selectedFrameID == card.id ? Color.accentColor : Color.white.opacity(0.2),
                                                  lineWidth: vm.selectedFrameID == card.id ? 3 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            HStack {
                Button("Quay lại") { vm.step = .welcome }
                    .buttonStyle(.borderedProminent)
                Spacer()
                PrimaryButton(title: "Bắt đầu chụp", systemImage: "camera.fill",
                              disabledReason: vm.selectedFrameID == nil ? "Chọn khung" : nil) {
                    vm.startCapture()
                    vm.beginShooting()
                }
            }
            .padding(20)
        }
    }

    // MARK: Live (chờ chụp xong, hiện countdown overlay)

    private var liveStep: some View {
        VStack(spacing: 12) {
            if let service = env.camera as? CameraService {
                CIPreviewView(cameraService: service,
                              mirror: env.settings.previewMirror,
                              inFrame: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Camera không khả dụng").foregroundStyle(.white)
            }
            // Overlay countdown
            if case .countdown(let remaining, let index, _) = env.engine.state {
                VStack(spacing: 6) {
                    Text("\(remaining)").font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(.white).shadow(radius: 8)
                    Text("Ảnh \(index)/\(env.engine.requiredIndices.count)")
                        .font(.title3).foregroundStyle(.white)
                }
            }
        }
        .onChange(of: env.engine.state) { newState in
            if case .reviewing = newState {
                vm.openReview()
            }
        }
    }

    // MARK: Review

    private var reviewStep: some View {
        VStack(spacing: 0) {
            if let reviewVM = vm.reviewVM, let img = reviewVM.previewImage {
                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width), height: CGFloat(img.height))))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(20)
            } else {
                ProgressView().tint(.white)
            }
            HStack {
                Spacer()
                PrimaryButton(title: "Hoàn thành", systemImage: "checkmark.circle.fill") {
                    Task {
                        await vm.finish()
                    }
                }
            }
            .padding(20)
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
