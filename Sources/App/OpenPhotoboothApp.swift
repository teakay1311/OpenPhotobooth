import SwiftUI
import AppKit

/// Entry point §1.1, §17.1.
/// - Khởi tạo AppEnvironment (DI container, các repository + service).
/// - boot() chạy recovery + seed + trash scheduler khi cửa sổ chính xuất hiện.
/// - Host MainWindow và các sheet toàn cục (Fullscreen, PackImport).
@main
struct OpenPhotoboothApp: App {
    @StateObject private var env: AppEnvironment

    init() {
        let env = AppEnvironment()
        _env = StateObject(wrappedValue: env)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(env: env)
                .environmentObject(env)
                .task { await env.boot() }
                .sheet(isPresented: $env.showFullscreen) {
                    FullscreenView(env: env)
                        .frame(minWidth: 1000, minHeight: 700)
                }
                .sheet(isPresented: $env.showPackImport) {
                    if let url = env.pendingPackURL {
                        PackImportSheet(env: env, packURL: url)
                            .frame(minWidth: 600, minHeight: 480)
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Màn Chụp") { env.route = .capture }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Khung ảnh") { env.route = .frames }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Thư viện") { env.route = .library }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Thùng rác") { env.route = .trash }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Cài đặt") { env.route = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
