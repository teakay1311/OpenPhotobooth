import SwiftUI
import AppKit

/// Màn hình C — Thư viện (§2.4).
public struct LibraryView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: LibraryViewModel
    @State private var shareItems: [URL] = []
    @State private var sessionPhotosID: String? = nil
    @State private var sessionToDelete: SessionCardModel? = nil

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
                            SessionCardView(card: card, vm: vm,
                                            onOpenPhotos: { sessionPhotosID = card.id },
                                            onDeleteSession: { sessionToDelete = card })
                                .contextMenu { contextMenu(card) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task { await vm.startEventMonitoring().value }
        .onDisappear { vm.stopEventMonitoring() }
        .onChange(of: env.route) { r in
            if r == .library {
                vm.startEventMonitoring()
            } else {
                vm.stopEventMonitoring()
            }
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
        .sheet(isPresented: Binding(get: { sessionPhotosID != nil },
                                    set: { if !$0 { sessionPhotosID = nil } })) {
            if let sid = sessionPhotosID {
                SessionPhotosSheet(env: env, sessionID: sid) {
                    sessionPhotosID = nil
                    vm.reload()
                }
            }
        }
        .confirmationDialog("Xoá cả phiên…", isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }), presenting: sessionToDelete) { card in
            Button("Huỷ", role: .cancel) { sessionToDelete = nil }
            Button("Chuyển cả phiên vào Thùng rác", role: .destructive) {
                vm.trashSession(card.id)
                sessionToDelete = nil
            }
        } message: { card in
            Text("Ngày giờ: \(card.formattedDate)\nTên khung: \(card.frameName)\nSố ảnh hiện hành: \(card.card.committedCount)/\(card.card.session.captureCount)\n\nBạn có chắc muốn chuyển cả phiên vào Thùng rác?")
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                searchField
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
                filterPicker
                sortPicker
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                searchField
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    filterPicker
                    sortPicker
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private var searchField: some View {
        TextField("Tìm theo khung/ngày", text: $vm.searchText)
            .textFieldStyle(.roundedBorder)
            .onChange(of: vm.searchText) { _ in vm.reload() }
    }

    private var filterPicker: some View {
        Picker("Lọc", selection: $vm.filter) {
            ForEach(LibraryViewModel.LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
        .onChange(of: vm.filter) { _ in vm.reload() }
    }

    private var sortPicker: some View {
        Picker("Sắp xếp", selection: $vm.sortNewest) {
            Text("Mới nhất").tag(true)
            Text("Cũ nhất").tag(false)
        }
        .fixedSize()
        .onChange(of: vm.sortNewest) { _ in vm.reload() }
    }

    @ViewBuilder private func contextMenu(_ card: SessionCardModel) -> some View {
        Button("Ảnh trong phiên…") { sessionPhotosID = card.id }
        Divider()
        Button {
            env.openReview(sessionID: card.id, source: .library)
        } label: {
            Label("Chỉnh ảnh", systemImage: "slider.horizontal.3")
        }
        .disabled(card.card.committedCount == 0)
        .help(card.card.committedCount == 0 ? "Phiên chưa có ảnh" : "Chỉnh ảnh")

        if card.card.session.status != .completed {
            Button("Chụp tiếp phiên này") {
                Task {
                    await vm.continueSession(card.id)
                }
            }
        }
        Button("Mở phiên") { env.openReview(sessionID: card.id, source: .library) }
        Button("Đổi khung") {
            env.openReview(sessionID: card.id, source: .library, openFramePicker: true)
        }
        let canShare = card.card.committedCount >= card.card.session.captureCount && card.card.session.pendingSelectionCount == nil && !card.card.session.awaitsFrame
        Button("Chia sẻ") { shareSession(card) }
            .disabled(!canShare)

        Button("Hiện file xuất trong Finder") {
            Task { await vm.revealRecentExport(sessionID: card.id) }
        }
        Divider()
        Button("Xoá cả phiên…", role: .destructive) { sessionToDelete = card }
    }

    private func shareSession(_ card: SessionCardModel) {
        Task {
            if let url = await vm.prepareShareFile(for: card) {
                shareItems = [url]
            }
        }
    }
}

struct SessionCardView: View {
    var card: SessionCardModel
    var vm: LibraryViewModel
    var onOpenPhotos: () -> Void = {}
    var onDeleteSession: () -> Void = {}
    @State private var previewData: Data?
    @State private var renderedRevisionNo: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    CheckeredBackground()
                    ImageDataView(data: previewData ?? card.preview)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                .task {
                    let rev = card.card.session.revisionNo
                    if previewData == nil, let data = await vm.generatePreview(for: card) {
                        if rev >= (renderedRevisionNo ?? 0) {
                            previewData = data
                            renderedRevisionNo = rev
                        }
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
                        Text(c.session.awaitsFrame
                             ? (c.committedCount == c.session.captureCount ? "Đã chụp đủ · Chưa chọn khung" : "Chụp dở")
                             : "Chưa hoàn thành")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Text(c.session.defaults.plannedCaptureCount != nil && !c.session.awaitsFrame
                         ? "\(c.committedCount)/\(c.session.captureCount) dùng · \(c.totalCapturedCount) ảnh"
                         : "\(c.committedCount)/\(c.session.captureCount)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { vm.openSession(card.id) }

            cardButtons
        }
        .onChange(of: card.card.session.revisionNo) { newRev in
            previewData = nil
            Task {
                if let data = await vm.generatePreview(for: card) {
                    if newRev >= (renderedRevisionNo ?? 0) {
                        previewData = data
                        renderedRevisionNo = newRev
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cardButtons: some View {
        if card.card.session.awaitsFrame && card.card.committedCount >= card.card.session.captureCount {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    editButton.fixedSize()
                    actionButton.fixedSize()
                    Spacer(minLength: 0)
                    moreMenu.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { editButton.fixedSize(); Spacer(minLength: 0); moreMenu.fixedSize() }
                    actionButton.fixedSize()
                }
            }
        } else {
            HStack(spacing: 8) { editButton; actionButton; Spacer(); moreMenu }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Ảnh trong phiên…") { onOpenPhotos() }
            Button("Chỉnh ảnh") {
                vm.env.openReview(sessionID: card.id, source: .library)
            }
            .disabled(card.card.committedCount == 0)

            if card.card.session.status != .completed {
                Button("Chụp tiếp phiên này") {
                    Task { await vm.continueSession(card.id) }
                }
            }
            Button("Đổi khung") {
                vm.env.openReview(sessionID: card.id, source: .library, openFramePicker: true)
            }
            let canShare = card.card.committedCount >= card.card.session.captureCount && card.card.session.pendingSelectionCount == nil && !card.card.session.awaitsFrame
            Button("Chia sẻ") {
                Task {
                    if let url = await vm.prepareShareFile(for: card) {
                        NSSharingServicePicker(items: [url]).show(relativeTo: .zero, of: NSApp.keyWindow?.contentView ?? NSView(), preferredEdge: .minY)
                    }
                }
            }
            .disabled(!canShare)

            Button("Hiện file xuất trong Finder") {
                Task { await vm.revealRecentExport(sessionID: card.id) }
            }
            Divider()
            Button("Xoá cả phiên…", role: .destructive) { onDeleteSession() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Tùy chọn khác")
    }

    private var editButton: some View {
        Button {
            vm.env.openReview(sessionID: card.id, source: .library)
        } label: {
            Label("Chỉnh ảnh", systemImage: "slider.horizontal.3")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(card.card.committedCount == 0)
        .help(card.card.committedCount == 0 ? "Phiên chưa có ảnh" : "Chỉnh ảnh phiên này")
        .accessibilityLabel("Chỉnh ảnh")
    }

    @ViewBuilder private var actionButton: some View {
        let committed = card.card.committedCount
        let captureCount = card.card.session.captureCount
        let pendingSelection = card.card.session.pendingSelectionCount != nil

        if committed < captureCount {
            Button {
                Task {
                    await vm.continueSession(card.id, requiresMissingPhotos: true)
                }
            } label: {
                Label("Chụp tiếp", systemImage: "camera")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Chụp tiếp")
        } else if card.card.session.awaitsFrame {
            Button {
                vm.openSession(card.id)
            } label: {
                Label("Chọn khung", systemImage: "rectangle.3.offgrid")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if pendingSelection {
            Button {
                vm.selectPhotosForSession(card.id)
            } label: {
                Label("Chọn ảnh", systemImage: "checkmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Chọn ảnh")
        } else {
            Button {
                vm.openExportForSession(card.id)
            } label: {
                Label("Xuất ảnh", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Xuất ảnh")
        }
    }
}

/// Màn hình D — Thùng rác (§2.5, §12).
public struct TrashView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: TrashViewModel
    @State private var showPurgeConfirm = false
    @State private var previewItem: TrashItem?
    @State private var showBatchResults = false

    public init(env: AppEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: TrashViewModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar.disabled(env.isManualPurging || vm.isPurging)
            if env.isManualPurging || vm.isPurging {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Đang dọn Thùng rác…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
            }
            HStack {
                Button("Chọn tất cả đang hiển thị", action: vm.selectAllVisible)
                    .disabled(vm.selectableIDs.isEmpty)
                Button("Bỏ chọn", action: vm.clearSelection).disabled(vm.selection.isEmpty)
                Text("Đã chọn \(vm.selection.count)/\(vm.items.count) mục").font(.caption)
                Spacer()
                if !vm.batchDetails.isEmpty {
                    Button("Kết quả xóa") { showBatchResults = true }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            .disabled(env.isManualPurging || vm.isPurging)
            Divider()
            if vm.items.isEmpty {
                if vm.totalRepoCount > 0 {
                    EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                                   title: "Không tìm thấy mục phù hợp",
                                   message: "Thử đổi bộ lọc hoặc từ khóa tìm kiếm.")
                } else {
                    EmptyStateView(systemImage: "trash",
                                   title: "Thùng rác trống",
                                   message: "Các mục đã xóa được giữ tối đa 30 ngày khi ứng dụng có thể chạy tác vụ dọn.")
                }
            } else {
                List(selection: $vm.selection) {
                    ForEach(vm.items) { item in
                        TrashRowView(item: item, vm: vm, onPreview: { previewItem = item }, onRetryPurge: { retryItem in
                            if let scope = vm.prepareSinglePurgeScope(item: retryItem) {
                                vm.activePurgeScope = scope
                                showPurgeConfirm = true
                            }
                        })
                        .tag(item.id)
                        .contextMenu {
                            Button("Khôi phục") { vm.restore(item: item) }
                                .disabled(item.expiresAtMs <= Time.nowMs() || env.isManualPurging || vm.isPurging)
                            Button("Xóa vĩnh viễn", role: .destructive) {
                                if let scope = vm.prepareSinglePurgeScope(item: item) {
                                    vm.activePurgeScope = scope
                                    showPurgeConfirm = true
                                }
                            }
                            .disabled(env.isManualPurging || vm.isPurging)
                        }
                    }
                }
                .listStyle(.inset)
                .disabled(env.isManualPurging || vm.isPurging)
            }
            Divider()
            footer
        }
        .onAppear {
            vm.reload()
            Task.detached(priority: .utility) { [env] in
                env.trashScheduler.runOnce(manual: false)
            }
        }
        .onChange(of: env.route) { r in
            if r == .trash {
                vm.reload()
                Task.detached(priority: .utility) { [env] in
                    env.trashScheduler.runOnce(manual: false)
                }
            }
        }
        .task {
            for await event in EventBus.shared.stream {
                if case .trashChanged = event {
                    vm.reload()
                } else if case .settingsChanged(let key) = event, key == "trashAutoCleanFrozen" {
                    env.showToast("Tự động dọn rác bị tạm dừng do đồng hồ hệ thống bất thường (E-TRS-04)", kind: .warning)
                }
            }
        }
        .sheet(isPresented: $showBatchResults) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Kết quả xóa").font(.headline)
                ScrollView { Text(vm.batchDetails).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Đóng") { showBatchResults = false }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(width: 560, height: 400)
        }
        .sheet(item: $previewItem) { item in
            TrashPreviewSheet(item: item, env: env, onClose: { previewItem = nil })
        }
        .onChange(of: vm.items) { _, items in
            if let previewItem, !items.contains(where: { $0.id == previewItem.id }) { self.previewItem = nil }
        }
        .confirmationDialog("Không thể khôi phục sau thao tác này",
                            isPresented: $showPurgeConfirm,
                            presenting: vm.activePurgeScope) { scope in
            Button(purgeButtonTitle(for: scope), role: .destructive) {
                vm.executePurge(scope: scope)
            }
            Button("Hủy", role: .cancel) {
                vm.activePurgeScope = nil
            }
        } message: { scope in
            Text(purgeMessage(for: scope))
        }
        .alert("Danh sách đã thay đổi", isPresented: $vm.showScopeChangedAlert) {
            Button("Xác nhận lại", role: .destructive) {
                if let scope = vm.activePurgeScope {
                    vm.executePurge(scope: scope)
                }
            }
            Button("Hủy", role: .cancel) {
                vm.activePurgeScope = nil
            }
        } message: {
            Text(vm.scopeChangedMessage + "\nKhông thể khôi phục sau thao tác này.")
        }
    }

    private func purgeButtonTitle(for scope: TrashViewModel.PurgeConfirmationScope) -> String {
        switch scope.kind {
        case .single: return "Xóa vĩnh viễn"
        case .selection: return "Xóa \(scope.itemCount) mục đã chọn"
        case .all: return "Dọn sạch \(scope.itemCount) mục"
        }
    }

    private func purgeMessage(for scope: TrashViewModel.PurgeConfirmationScope) -> String {
        let bytesText = FileLayout.formattedBytes(scope.estimatedBytes)
        let children = scope.plan?.includedChildren.count ?? 0
        let childNotice = children > 0 ? "\nBao gồm \(children) ảnh đã xóa nằm trong phiên được chọn; không tính dung lượng hai lần." : ""
        switch scope.kind {
        case .single:
            return "Xóa vĩnh viễn '\(scope.displayName ?? "")' (\(bytesText))?\(childNotice)\nKhông thể khôi phục sau thao tác này."
        case .selection:
            return "Xóa vĩnh viễn \(scope.itemCount) mục đang chọn (\(bytesText))?\(childNotice)\nKhông thể khôi phục sau thao tác này."
        case .all:
            return "Dọn sạch toàn bộ \(scope.itemCount) mục trong Thùng rác (\(bytesText))?\(childNotice)\nKhông thể khôi phục sau thao tác này."
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text("\(vm.items.count) mục").font(.headline)
                filterPicker.frame(width: 140)
                searchField.frame(width: 160)
                sortPicker.fixedSize()
                Spacer()
                actionButtons
            }
            .padding(12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(vm.items.count) mục").font(.headline)
                    filterPicker.frame(width: 130)
                    searchField.frame(minWidth: 120)
                    sortPicker.fixedSize()
                }
                HStack(spacing: 8) {
                    Spacer()
                    actionButtons
                }
            }
            .padding(12)
        }
    }

    private var filterPicker: some View {
        Picker("Lọc", selection: $vm.filter) {
            Text("Tất cả").tag(TrashRootType?.none)
            ForEach(TrashRootType.allCases, id: \.self) { Text($0.label).tag(TrashRootType?.some($0)) }
        }
        .onChange(of: vm.filter) { _ in vm.reload() }
    }

    private var searchField: some View {
        TextField("Tìm kiếm", text: $vm.searchText)
            .textFieldStyle(.roundedBorder)
            .onChange(of: vm.searchText) { _ in vm.reload() }
    }

    private var sortPicker: some View {
        Picker("Sắp xếp", selection: $vm.sortByExpiry) {
            Text("Sắp hết hạn").tag(true)
            Text("Mới xóa").tag(false)
        }
        .onChange(of: vm.sortByExpiry) { _ in vm.reload() }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Khôi phục") { vm.restoreSelected() }
            .disabled(vm.restorableSelectedCount == 0 || env.isManualPurging || vm.isPurging)
        Button("Xóa vĩnh viễn", role: .destructive) {
            if let scope = vm.prepareSelectionPurgeScope() {
                vm.activePurgeScope = scope
                showPurgeConfirm = true
            }
        }
        .disabled(vm.selection.isEmpty || env.isManualPurging || vm.isPurging)
        .help("Xóa vĩnh viễn các mục đang chọn")
        Button("Dọn sạch") {
            if let scope = vm.prepareAllPurgeScope() {
                vm.activePurgeScope = scope
                showPurgeConfirm = true
            }
        }
        .disabled(vm.totalRepoCount == 0 || env.isManualPurging || vm.isPurging)
        .help("Hiển thị số mục + dung lượng và xác nhận")
    }

    private var footer: some View {
        HStack {
            Text("Dung lượng Thùng rác: \(vm.totalBytesText)").foregroundStyle(.secondary)
            Spacer()
            Button("Mở Cài đặt → Dữ liệu") { env.openSettings(section: .data) }
        }
        .font(.caption)
        .padding(10)
    }
}

struct TrashRowView: View {
    var item: TrashItem
    var vm: TrashViewModel
    var onPreview: () -> Void = {}
    var onRetryPurge: ((TrashItem) -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Chọn \(item.displayName)", isOn: Binding(
                get: { vm.selection.contains(item.id) },
                set: { selected in
                    if selected { vm.selection.insert(item.id) } else { vm.selection.remove(item.id) }
                }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!(item.status == .trashed || item.status == .purgeFailed) || vm.env.isManualPurging || vm.isPurging)
            if [.frame, .session, .photo].contains(item.rootType) {
                Button(action: onPreview) {
                    TrashPreviewImage(item: item, env: vm.env, maxPixel: 120)
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.plain).help("Xem trước \(item.displayName)")
                .accessibilityLabel("Xem trước \(item.displayName)")
            } else {
                Image(systemName: icon).frame(width: 60, height: 60)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1)
                Text("\(item.rootType.label) · Đã xóa: \(deletedText) · \(FileLayout.formattedBytes(item.estimatedBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.status == .purgeFailed {
                HStack(spacing: 8) {
                    Label(item.lastError ?? "Lỗi dọn — thử lại", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .help(item.lastError ?? "")
                    Button("Thử dọn lại") {
                        onRetryPurge?(item)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.env.isManualPurging || vm.isPurging)
                }
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
        case .photo: return "photo"
        }
    }

    var deletedText: String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: Time.date(ms: item.deletedAtMs))
    }
}

// MARK: - Bảng Ảnh trong phiên (§2.1, §2.2)

public struct SessionPhotosSheet: View {
    @ObservedObject var env: AppEnvironment
    let sessionID: String
    var onDismiss: () -> Void

    @State private var detail: SessionDetail?
    @State private var selectedPhotoIDs: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var selectingMultiple = false
    @State private var confirmedEntries: [PhotoEntry] = []
    @State private var isProcessing = false
    @State private var photoThumbnailData: [String: Data] = [:]

    public init(env: AppEnvironment, sessionID: String, onDismiss: @escaping () -> Void) {
        self.env = env
        self.sessionID = sessionID
        self.onDismiss = onDismiss
    }

    public struct PhotoEntry: Identifiable {
        public let id: String
        public let shotID: String
        public let captureIndex: Int
        public let slotNumber: Int?
        public let isBackup: Bool
        public let relativePath: String
    }

    private var entries: [PhotoEntry] {
        guard let detail else { return [] }
        var result: [PhotoEntry] = []
        let requiredIndices = detail.session.captureIndices(in: detail.snapshot)
        let selectedOrder = detail.session.defaults.selectedCaptureOrder

        for shot in detail.shots.sorted(by: { $0.captureIndex < $1.captureIndex }) {
            guard let revID = shot.currentPhotoRevisionID,
                  let rev = detail.photoRevisions[shot.id]?.first(where: { $0.id == revID && $0.state == .available }) else {
                continue
            }
            let isReq = requiredIndices.contains(shot.captureIndex)
            let slotNum: Int?
            if isReq {
                if let order = selectedOrder, let idx = order.firstIndex(of: shot.captureIndex) {
                    slotNum = idx + 1
                } else if let sIdx = detail.snapshot.slots.firstIndex(where: { $0.captureIndex == shot.captureIndex }) {
                    slotNum = sIdx + 1
                } else {
                    slotNum = shot.captureIndex
                }
            } else {
                slotNum = nil
            }
            result.append(PhotoEntry(
                id: rev.id,
                shotID: shot.id,
                captureIndex: shot.captureIndex,
                slotNumber: slotNum,
                isBackup: !isReq,
                relativePath: rev.relativePath
            ))
        }
        return result
    }

    private var emptySlotsSummary: String {
        let slots = confirmedEntries.compactMap { $0.slotNumber }.sorted()
        if slots.isEmpty {
            return "Không có ô nào bị trống (chỉ xoá ảnh dự phòng)"
        } else {
            return slots.map { "Ô số \($0)" }.joined(separator: ", ")
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 520)
        .task {
            loadDetail()
        }
        .confirmationDialog(
            confirmedEntries.count == 1 ? "Xoá ảnh…" : "Xoá \(confirmedEntries.count) ảnh",
            isPresented: $showDeleteConfirm,
            actions: {
                Button("Huỷ", role: .cancel) {}
                Button("Chuyển vào Thùng rác", role: .destructive) {
                    performDelete()
                }
            },
            message: {
                if confirmedEntries.count == 1 {
                    let entry = confirmedEntries.first
                    if let slot = entry?.slotNumber {
                        Text("Ảnh được chọn sẽ được chuyển vào Thùng rác. Ô số \(slot) sẽ trống nếu ảnh đang dùng.")
                    } else {
                        Text("Ảnh dự phòng được chọn sẽ được chuyển vào Thùng rác.")
                    }
                } else {
                    let shortSession = String(sessionID.prefix(8))
                    Text("Số ảnh: \(confirmedEntries.count). Phiên đang thao tác: \(shortSession).\nCác ô sẽ trống: \(emptySlotsSummary).")
                }
            }
        )
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ảnh trong phiên").font(.headline)
                if let detail {
                    let frameName = detail.session.awaitsFrame ? "Chưa chọn khung"
                        : detail.session.defaults.appliedFrameName ?? detail.session.frameNameAtCapture ?? "Khung ảnh"
                    Text("\(frameName) · \(entries.count) ảnh hiện hành")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selectingMultiple {
                Button("Chọn tất cả") { selectedPhotoIDs = Set(entries.map(\.id)) }
                    .disabled(entries.isEmpty || isProcessing)
                Button("Bỏ chọn tất cả") { selectedPhotoIDs.removeAll() }
                    .disabled(selectedPhotoIDs.isEmpty || isProcessing)
            } else {
                Button("Chọn nhiều") { selectingMultiple = true }
                    .disabled(entries.isEmpty || isProcessing)
            }
        }
        .padding(14)
    }

    @ViewBuilder private var content: some View {
        if entries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Không có ảnh trong phiên")
                    .font(.subheadline.weight(.medium))
                Text("Toàn bộ ảnh của phiên đã được chuyển vào Thùng rác hoặc chưa chụp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(entries) { entry in
                        photoCell(entry)
                    }
                }
                .padding(14)
            }
        }
    }

    private func photoCell(_ entry: PhotoEntry) -> some View {
        let isSelected = selectedPhotoIDs.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.secondary.opacity(0.1)
                    if let data = photoThumbnailData[entry.id] {
                        ImageDataView(data: data)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                )

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelected {
                    selectedPhotoIDs.remove(entry.id)
                } else {
                    selectingMultiple = true
                    selectedPhotoIDs.insert(entry.id)
                }
            }

            HStack {
                if let slot = entry.slotNumber {
                    Text("Ô số \(slot)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                } else {
                    Text("Ảnh dự phòng")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    requestDelete([entry])
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Xoá ảnh này")
            }
        }
        .task {
            if photoThumbnailData[entry.id] == nil {
                let key = "shot-\(entry.id)"
                let thumbnails = env.thumbnails
                if let cached = thumbnails.cachedData(key: key) {
                    photoThumbnailData[entry.id] = cached
                } else if let url = try? env.layout.absoluteURL(forRelativePath: entry.relativePath) {
                    let data = await Task.detached(priority: .utility) {
                        LibraryViewModel.downscaleThumbnail(url: url)
                    }.value
                    if !Task.isCancelled, let data {
                        thumbnails.store(data: data, key: key)
                        photoThumbnailData[entry.id] = data
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Đóng") { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            let count = selectedPhotoIDs.count
            let label = count > 1 ? "Xoá \(count) ảnh" : "Xoá ảnh…"
            Button(label, role: .destructive) {
                requestDelete(entries.filter { selectedPhotoIDs.contains($0.id) })
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedPhotoIDs.isEmpty || isProcessing)
        }
        .padding(14)
    }

    private func loadDetail() {
        if let d = try? env.sessions.getDetail(sessionID: sessionID) {
            detail = d
        }
    }

    private func requestDelete(_ entries: [PhotoEntry]) {
        guard !entries.isEmpty else { return }
        confirmedEntries = entries
        showDeleteConfirm = true
    }

    private func performDelete() {
        guard !confirmedEntries.isEmpty, !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        let pairs = confirmedEntries.map { (shotID: $0.shotID, photoRevisionID: $0.id) }
        confirmedEntries = []
        do {
            try env.sessions.trashPhotos(sessionID: sessionID, pairs: pairs)
            selectedPhotoIDs.removeAll()
            loadDetail()
            env.showToast("Đã chuyển ảnh vào Thùng rác")
        } catch {
            loadDetail()
            selectedPhotoIDs.formIntersection(Set(entries.map(\.id)))
            env.showToast("\((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
        }
    }
}
