import SwiftUI
import AppKit

/// Màn hình C — Thư viện (§2.4).
public struct LibraryView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: LibraryViewModel
    @State private var shareItems: [URL] = []

    public init(env: AppEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: LibraryViewModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if vm.cards.isEmpty {
                EmptyStateView(systemImage: "photo.stack",
                               title: "Thư viện trống",
                               message: "Các phiên chụp sẽ xuất hiện ở đây. Bắt đầu bằng một phiên mới ở màn Chụp.",
                               actionTitle: "Mở màn Chụp") {
                    env.route = .capture
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(vm.cards) { card in
                            SessionCardView(card: card, vm: vm)
                                .contextMenu { contextMenu(card) }
                                .onTapGesture { vm.openSession(card.id) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { vm.reload() }
        .onChange(of: env.route) { r in
            if r == .library { vm.reload() }
        }
        // Chia sẻ từ context menu (P2-22): trình picker qua sheet — trước đây file được render
        // ngầm nhưng không có UI nào xuất hiện.
        .sheet(isPresented: Binding(get: { !shareItems.isEmpty },
                                    set: { if !$0 { shareItems = [] } })) {
            VStack(spacing: 12) {
                Text("Chia sẻ ảnh").font(.headline)
                if let url = shareItems.first {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                ShareSheet(items: shareItems)
                    .frame(height: 32)
                Button("Đóng") { shareItems = [] }
            }
            .padding()
            .frame(width: 420)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Tìm theo khung/ngày", text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onChange(of: vm.searchText) { _ in vm.reload() }
            Picker("Lọc", selection: $vm.filter) {
                ForEach(LibraryViewModel.LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 160)
            .onChange(of: vm.filter) { _ in vm.reload() }
            Picker("Sắp xếp", selection: $vm.sortNewest) {
                Text("Mới nhất").tag(true)
                Text("Cũ nhất").tag(false)
            }
            .frame(width: 130)
            .onChange(of: vm.sortNewest) { _ in vm.reload() }
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder private func contextMenu(_ card: SessionCardModel) -> some View {
        Button("Mở phiên") { vm.openSession(card.id) }
        Button("Đổi khung") {
            env.route = .frames
        }
        Button("Chia sẻ") { shareSession(card) }
        Button("Hiện file xuất trong Finder") {
            if let record = vm.exportRecords(sessionID: card.id).first {
                vm.revealExport(record: record)
            } else {
                env.showToast("Chưa có file xuất nào", kind: .info)
            }
        }
        Divider()
        Button("Chuyển vào Thùng rác", role: .destructive) { vm.trashSession(card.id) }
    }

    private func shareSession(_ card: SessionCardModel) {
        Task {
            guard let detail = try? env.sessions.getDetail(sessionID: card.id), detail.hasEnoughPhotos else {
                env.showToast("Phiên chưa đủ ảnh để chia sẻ", kind: .warning)
                return
            }
            if let url = try? await env.shareService.prepareShareFile(detail: detail, filenameBase: card.frameName) {
                shareItems = [url]
            }
        }
    }
}

struct SessionCardView: View {
    var card: SessionCardModel
    var vm: LibraryViewModel
    @State private var previewData: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                CheckeredBackground()
                ImageDataView(data: previewData ?? card.preview)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            .task {
                if previewData == nil, let data = await vm.generatePreview(for: card) {
                    previewData = data
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.formattedDate).font(.caption.weight(.medium))
                    Text(card.frameName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                let c = card.card
                if c.session.status != .completed {
                    Text("Chưa hoàn thành")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Text("\(c.committedCount)/\(c.session.requiredCaptureCount)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

/// Màn hình D — Thùng rác (§2.5, §12).
public struct TrashView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: TrashViewModel
    @State private var showPurgeConfirm = false
    @State private var purgeTarget: TrashItem?
    // Sentinel riêng cho nút toolbar "Xóa vĩnh viễn" (mục đang chọn) —
    // trước đây trùng sentinel "purgeTarget = nil" của "Dọn sạch" → xóa nhầm TOÀN BỘ thùng rác.
    @State private var showPurgeSelectionConfirm = false

    public init(env: AppEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: TrashViewModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if vm.items.isEmpty {
                EmptyStateView(systemImage: "trash",
                               title: "Thùng rác trống",
                               message: "Các mục đã xóa được giữ tối đa 30 ngày khi ứng dụng có thể chạy tác vụ dọn.")
            } else {
                List(selection: $vm.selection) {
                    ForEach(vm.items) { item in
                        TrashRowView(item: item, vm: vm)
                            .tag(item.id)
                            .contextMenu {
                                Button("Khôi phục") { vm.selection = [item.id]; vm.restoreSelected() }
                                Button("Xóa vĩnh viễn", role: .destructive) { purgeTarget = item; showPurgeConfirm = true }
                            }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .onAppear { vm.reload() }
        .onChange(of: env.route) { r in
            if r == .trash { vm.reload() }
        }
        .confirmationDialog("Không thể khôi phục sau thao tác này",
                            isPresented: $showPurgeConfirm) {
            Button("Xóa vĩnh viễn", role: .destructive) {
                if let target = purgeTarget {
                    vm.selection = [target.id]
                    vm.purgeSelected()
                } else {
                    vm.emptyTrash()
                }
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text(purgeTarget != nil
                 ? "Xóa vĩnh viễn '\(purgeTarget?.displayName ?? "")'?"
                 : "Dọn sạch toàn bộ Thùng rác?")
        }
        // Xác nhận riêng cho nút toolbar "Xóa vĩnh viễn" — chỉ xóa các mục đang CHỌN
        .confirmationDialog("Không thể khôi phục sau thao tác này",
                            isPresented: $showPurgeSelectionConfirm) {
            Button("Xóa \(vm.selection.count) mục đã chọn", role: .destructive) {
                vm.purgeSelected()
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Xóa vĩnh viễn \(vm.selection.count) mục đang chọn?")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(vm.items.count) mục").font(.headline)
            Picker("Lọc", selection: $vm.filter) {
                Text("Tất cả").tag(TrashRootType?.none)
                ForEach(TrashRootType.allCases, id: \.self) { Text($0.label).tag(TrashRootType?.some($0)) }
            }
            .frame(width: 160)
            .onChange(of: vm.filter) { _ in vm.reload() }
            TextField("Tìm kiếm", text: $vm.searchText)
                .textFieldStyle(.roundedBorder).frame(width: 180)
                .onChange(of: vm.searchText) { _ in vm.reload() }
            Picker("Sắp xếp", selection: $vm.sortByExpiry) {
                Text("Sắp hết hạn").tag(true)
                Text("Mới xóa").tag(false)
            }
            .frame(width: 130)
            .onChange(of: vm.sortByExpiry) { _ in vm.reload() }
            Spacer()
            Button("Khôi phục") { vm.restoreSelected() }
                .disabled(vm.selection.isEmpty)
            Button("Xóa vĩnh viễn", role: .destructive) {
                showPurgeSelectionConfirm = true
            }
            .disabled(vm.selection.isEmpty)
            .help("Xóa vĩnh viễn các mục đang chọn")
            Button("Dọn sạch") {
                purgeTarget = nil
                showPurgeConfirm = true
            }
            .disabled(vm.items.isEmpty)
            .help("Hiển thị số mục + dung lượng và xác nhận")
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Text("Dung lượng Thùng rác: \(vm.totalBytesText)").foregroundStyle(.secondary)
            Spacer()
            Button("Mở Cài đặt → Dữ liệu") { env.route = .settings }
        }
        .font(.caption)
        .padding(10)
    }
}

struct TrashRowView: View {
    var item: TrashItem
    var vm: TrashViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1)
                Text("\(item.rootType.label) · Đã xóa: \(deletedText) · \(FileLayout.formattedBytes(item.estimatedBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.status == .purgeFailed {
                Label("Lỗi dọn — thử lại", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .help(item.lastError ?? "")
            } else {
                Text(vm.remainingText(for: item))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(item.expiresAtMs <= Time.nowMs() ? .orange : .secondary)
            }
        }
        .padding(.vertical, 3)
    }

    var icon: String {
        switch item.rootType {
        case .session: return "photo.stack"
        case .frame: return "photo.on.rectangle"
        case .category: return "folder"
        case .preset: return "camera.filters"
        }
    }

    var deletedText: String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: Time.date(ms: item.deletedAtMs))
    }
}
