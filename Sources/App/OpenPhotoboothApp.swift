import SwiftUI
import AppKit

/// Quản lý vòng đời môi trường app và hỗ trợ thử lại khi lỗi khởi động kho (§3.1, D2-A02)
@MainActor
final class AppHolder: ObservableObject {
    @Published var env: AppEnvironment = AppEnvironment()

    func retry() {
        env = env.makeRetriedEnvironment()
    }
}

/// Entry point §1.1, §17.1.
/// - Khởi tạo AppEnvironment (DI container, các repository + service).
/// - boot() chạy recovery + seed + trash scheduler khi cửa sổ chính xuất hiện.
/// - Host MainWindow và các sheet toàn cục (Fullscreen, PackImport).
#if PHOTOBOOTH_QA_HOST
@main
enum PhotoboothTestHost {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.run()
    }
}
#else
@main
struct OpenPhotoboothApp: App {
    @StateObject private var holder = AppHolder()

    var body: some Scene {
        WindowGroup {
            AppContainerView(holder: holder)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1280, height: 820)
        .commands {
            if holder.env.launchError == nil {
                CommandGroup(after: .newItem) {
                    Button("Màn Chụp") { holder.env.requestNavigation(to: .capture) }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Khung ảnh") { holder.env.requestNavigation(to: .frames) }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("Thư viện") { holder.env.requestNavigation(to: .library) }
                        .keyboardShortcut("3", modifiers: .command)
                    Button("Thùng rác") { holder.env.requestNavigation(to: .trash) }
                        .keyboardShortcut("4", modifiers: .command)
                    Button("Cài đặt") { holder.env.requestNavigation(to: .settings) }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
        }
    }
}
#endif

struct AppContainerView: View {
    @ObservedObject var holder: AppHolder

    var body: some View {
        let env = holder.env
        Group {
            if let error = env.launchError {
                LaunchErrorView(env: env, error: error, onRetry: {
                    holder.retry()
                })
            } else {
                PhotoboothWindowContent(env: env)
            }
        }
    }
}

private struct PhotoboothWindowContent: View {
    @ObservedObject var env: AppEnvironment

    var body: some View {
        ZStack {
            if env.showFullscreen {
                FullscreenView(env: env)
            } else {
                MainWindow(env: env)
            }
        }
        .background(NativeFullscreenBinding(isPresented: $env.showFullscreen))
        .environmentObject(env)
        .task { await env.boot() }
        .sheet(isPresented: $env.showPackImport) {
            if let url = env.pendingPackURL {
                PackImportSheet(env: env, packURL: url)
                    .frame(minWidth: 600, minHeight: 480)
            }
        }
    }
}

private struct NativeFullscreenBinding: NSViewRepresentable {
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> FullscreenWindowObserver { FullscreenWindowObserver() }

    func updateNSView(_ view: FullscreenWindowObserver, context: Context) {
        view.isPresented = $isPresented
        view.scheduleUpdate()
    }
}

/// The kiosk uses the host window's native fullscreen space.
private final class FullscreenWindowObserver: NSView {
    var isPresented: Binding<Bool>?
    private var requestedFullscreen = false
    private var isTransitioning = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        requestedFullscreen = false
        isTransitioning = false
        guard let window else { return }
        center.addObserver(self, selector: #selector(willTransition),
                           name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(willTransition),
                           name: NSWindow.willExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didEnterFullscreen),
                           name: NSWindow.didEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didExitFullscreen),
                           name: NSWindow.didExitFullScreenNotification, object: window)
        scheduleUpdate()
    }

    func scheduleUpdate() {
        DispatchQueue.main.async { [weak self] in self?.updateWindow() }
    }

    private func updateWindow() {
        guard let window, let isPresented, !isTransitioning else { return }
        let isFullscreen = window.styleMask.contains(.fullScreen)
        if isPresented.wrappedValue && !isFullscreen {
            requestedFullscreen = true
            window.toggleFullScreen(nil)
        } else if !isPresented.wrappedValue && requestedFullscreen && isFullscreen {
            window.toggleFullScreen(nil)
        }
    }

    @objc private func willTransition(_ notification: Notification) {
        isTransitioning = true
    }

    @objc private func didEnterFullscreen(_ notification: Notification) {
        isTransitioning = false
        scheduleUpdate()
    }

    @objc private func didExitFullscreen(_ notification: Notification) {
        requestedFullscreen = false
        isTransitioning = false
        isPresented?.wrappedValue = false
    }

}
