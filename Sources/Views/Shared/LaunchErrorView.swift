import SwiftUI
import AppKit

/// Màn hình hiển thị lỗi khởi động kho dữ liệu (§3.1, D2-A02)
/// Chặn hoàn toàn luồng nghiệp vụ khi kho dữ liệu hoặc database/migration gặp sự cố.
public struct LaunchErrorView: View {
    @ObservedObject var env: AppEnvironment
    let error: AppError
    let onRetry: () -> Void

    public init(env: AppEnvironment, error: AppError, onRetry: @escaping () -> Void) {
        self.env = env
        self.error = error
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("Không thể khởi động kho dữ liệu")
                    .font(.title2)
                    .fontWeight(.bold)

                Text(error.localizedDescription)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Đường dẫn kho dự kiến:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(env.layout.rootURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
            }
            .padding(.horizontal, 32)

            HStack(spacing: 16) {
                Button("Thử lại") {
                    onRetry()
                }
                .buttonStyle(.borderedProminent)

                Button("Mở thư mục trong Finder") {
                    env.revealDataFolderInFinder()
                }
                .buttonStyle(.bordered)

                Button("Thoát") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
