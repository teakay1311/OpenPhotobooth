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
            // Overlay toast + banner không chặn hit-test
            VStack {
                if env.recoveryReport?.hasProblems == true {
                    RecoveryBanner(env: env)
                }
                Spacer()
                ToastOverlay(env: env)
            }
            .allowsHitTesting(true)
        }
        .animation(.easeInOut(duration: 0.18), value: env.route)
        // Áp dụng giao diện sau khi NSApp sẵn sàng (không chạm NSApp trong App.init — P3-21b)
        .onAppear {
            env.settings.applyAppearance(env.settings.appearance)
        }
    }

    // MARK: Sidebar

    @ViewBuilder private var sidebar: some View {
        List(selection: Binding<ScreenRoute?>(
            get: { env.route },
            set: { newValue in if let route = newValue { env.route = route } }
        )) {
            Section("Open Photobooth") {
                Label("Chụp ảnh", systemImage: "camera.viewfinder").tag(ScreenRoute.capture as ScreenRoute?)
                Label("Khung ảnh", systemImage: "photo.on.rectangle.angled").tag(ScreenRoute.frames as ScreenRoute?)
                Label("Thư viện", systemImage: "photo.stack").tag(ScreenRoute.library as ScreenRoute?)
                Label("Thùng rác", systemImage: "trash").tag(ScreenRoute.trash as ScreenRoute?)
                Label("Cài đặt", systemImage: "gearshape").tag(ScreenRoute.settings as ScreenRoute?)
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
