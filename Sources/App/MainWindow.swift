import SwiftUI
import AppKit

/// MainWindow (§2.1, §3.1): sidebar điều hướng + nội dung route + ToastOverlay + banner recovery.
/// Route `.frameEditor` và `.review` phủ toàn cửa sổ (che sidebar); các route chính thay nội dung.
public struct MainWindow: View {
    @ObservedObject var env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var body: some View {
        ZStack {
            // Route phủ toàn màn hình (Editor / Review) ưu tiên trước
            switch env.route {
            case .frameEditor:
                FrameEditorView(env: env)
                    .transition(.opacity)
            case .chooseFrame(let sessionID, let source):
                CaptureFrameChooser(env: env, sessionID: sessionID,
                                    onClose: {
                    if env.engine.session?.id == sessionID { env.engine.keepSessionAndExit() }
                    env.route = .library
                },
                                    onApplied: { env.finishFrameChoice(sessionID: sessionID, source: source) })
                    .id(sessionID)
            case .review(let sessionID):
                ReviewView(env: env, sessionID: sessionID)
                    .transition(.opacity)
            default:
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
                } detail: {
                    detailView
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if env.recoveryReport?.hasProblems == true {
                RecoveryBanner(env: env)
            }
        }
        .overlay(alignment: .bottom) {
            ToastOverlay(env: env)
        }
        .animation(.easeInOut(duration: 0.18), value: env.route)
        .frame(minWidth: 1024, minHeight: 680)
        // Áp dụng giao diện sau khi NSApp sẵn sàng (không chạm NSApp trong App.init — P3-21b)
        .onAppear {
            env.settings.applyAppearance(env.settings.appearance)
        }
        .confirmationDialog(
            "Đang trong quá trình chụp ảnh",
            isPresented: $env.showLeaveCaptureConfirmation,
            titleVisibility: .visible
        ) {
            Button("Ở lại", role: .cancel) {
                env.stayInCapture()
            }
            Button("Tạm dừng và rời màn hình", role: .destructive) {
                env.confirmLeaveCapture()
            }
        } message: {
            Text("Bạn có chắc chắn muốn rời màn hình Chụp? Phiên chụp hiện tại sẽ được tạm dừng an toàn.")
        }
        .confirmationDialog(
            "Có thay đổi chưa lưu",
            isPresented: $env.showFrameEditorLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Lưu") {
                Task {
                    if await env.frameEditorSaveHandler?() == true { env.confirmLeaveFrameEditor() }
                }
            }
            Button("Bỏ thay đổi", role: .destructive) {
                env.confirmLeaveFrameEditor()
            }
            Button("Hủy", role: .cancel) {
                env.cancelLeaveFrameEditor()
            }
        } message: {
            Text("Lưu / Bỏ thay đổi / Hủy")
        }
        .confirmationDialog(
            "Chưa thể lưu hoàn tất các chỉnh sửa",
            isPresented: $env.showReviewLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Thử lưu lại") {
                env.retryLeaveReviewSave()
            }
            Button("Bỏ phần chưa lưu", role: .destructive) {
                env.confirmLeaveReviewDiscard()
            }
            Button("Ở lại", role: .cancel) {
                env.cancelLeaveReview()
            }
        } message: {
            Text("Không thể lưu các chỉnh sửa vào cơ sở dữ liệu. Bạn có muốn thử lưu lại, bỏ qua các thay đổi chưa lưu hay ở lại màn hình Xem lại?")
        }
    }

    // MARK: Sidebar

    @ViewBuilder private var sidebar: some View {
        List(selection: Binding<ScreenRoute?>(
            get: { env.route },
            set: { newValue in if let route = newValue { env.requestNavigation(to: route) } }
        )) {
            Section("Open Photobooth") {
                Label("Chụp ảnh", systemImage: "camera.viewfinder").tag(ScreenRoute.capture)
                Label("Khung ảnh", systemImage: "photo.on.rectangle.angled").tag(ScreenRoute.frames)
                Label("Thư viện", systemImage: "photo.stack").tag(ScreenRoute.library)
                Label("Thùng rác", systemImage: "trash").tag(ScreenRoute.trash)
                Label("Cài đặt", systemImage: "gearshape").tag(ScreenRoute.settings)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var detailView: some View {
        switch env.route {
        case .capture: CaptureView(env: env)
        case .frames: FramesView(env: env)
        case .library: LibraryView(env: env)
        case .trash: TrashView(env: env)
        case .settings: SettingsView(env: env)
        default: EmptyView()
        }
    }
}

/// Banner hiển thị kết quả Recovery khi launch phát hiện vấn đề (§3.1.5).
public struct RecoveryBanner: View {
    @ObservedObject var env: AppEnvironment

    public var body: some View {
        if let report = env.recoveryReport, report.hasProblems {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Khởi động an toàn").font(.headline)
                    Text("Đã xử lý \(report.quarantinedFiles + report.orphanedFiles) tệp nghi vấn; \(report.issues.count) vấn đề.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Đã hiểu") {
                    env.recoveryReport = nil
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }
}
