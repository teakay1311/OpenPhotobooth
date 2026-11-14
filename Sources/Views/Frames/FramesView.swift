import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Màn hình B — Khung ảnh (§2.3): toolbar, sidebar danh mục, grid, inspector.
public struct FramesView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: FramesViewModel
    @State private var showRenameField = false
    @State private var renameText = ""
    @State private var newCategoryName = ""
    @State private var showPackExport = false

    public init(env: AppEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: FramesViewModel(env: env))
    }

    public var body: some View {
        NavigationSplitView {
            categorySidebar
        } detail: {
            VStack(spacing: 0) {
                toolbar
                HStack(spacing: 0) {
                    gridArea
                    .frame(maxWidth: .infinity)
                    if vm.selection.count == 1 {
                        Divider()
                        inspectorView
                            .frame(width: 300)
                    } else if !vm.selection.isEmpty {
                        Divider()
                        batchBar.frame(width: 300)
                    }
                }
            }
        }
        .onAppear { vm.reload() }
        .onChange(of: env.route) { r in
            if r == .frames { vm.reload() }
        }
        .task {
            for await event in EventBus.shared.stream {
                if case .frameLibraryChanged = event { vm.reload() }
                if case .categoryChanged = event { vm.reload() }
            }
        }
        .sheet(isPresented: $showPackExport) { packExportSheet }
    }

    // MARK: Sidebar danh mục

    private var categorySidebar: some View {
        List(selection: Binding(get: { vm.selectedCategoryID },
                                set: { vm.selectedCategoryID = $0; vm.reload() })) {
            Section("Danh mục") {
                Label("Tất cả", systemImage: "square.grid.2x2")
                    .tag(String?.none)
                Label("Yêu thích", systemImage: "star.fill")
                    .tag(String?.some("__favorites__"))
                Label("Chưa phân loại", systemImage: "tray")
                    .tag(String?.some("unclassified"))
                ForEach(vm.categories) { cat in
                    HStack {
                        Text(cat.name)
                        Spacer()
                        Menu {
                            Button("Đổi tên") { renameCategory(cat) }
                            Button("Chuyển vào Thùng rác", role: .destructive) {
                                vm.trashCategory(cat.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                    }
                    .tag(String?.some(cat.id))
                }
                Button {
                    promptNewCategory()
                } label: {
                    Label("Thêm danh mục", systemImage: "plus")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    private func renameCategory(_ cat: Category) {
        let alert = NSAlert()
        alert.messageText = "Đổi tên danh mục"
        alert.addButton(withTitle: "Lưu")
        alert.addButton(withTitle: "Hủy")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = cat.name
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            try? env.frames.renameCategory(id: cat.id, to: input.stringValue)
            vm.reload()
        }
    }

    private func promptNewCategory() {
        let alert = NSAlert()
        alert.messageText = "Tên danh mục mới"
        alert.addButton(withTitle: "Thêm")
        alert.addButton(withTitle: "Hủy")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            vm.createCategory(named: input.stringValue)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                vm.importViaOpenPanel()
            } label: {
                Label("Thêm khung", systemImage: "plus")
            }
            .help("Nhập PNG/JPG — PNG alpha là Foreground Overlay (§6.1)")
            Button {
                importPack()
            } label: {
                Label("Nhập Frame Pack", systemImage: "shippingbox")
            }
            TextField("Tìm kiếm", text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onChange(of: vm.searchText) { _ in vm.reload() }
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

    private func importPack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "photoframepack") ?? .data]
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                env.pendingPackURL = url
                env.route = .frames
                env.showPackImport = true
            }
        }
    }

    // MARK: Grid

    private var gridArea: some View {
        Group {
            if vm.frames.isEmpty {
                EmptyStateView(systemImage: "photo.on.rectangle.angled",
                               title: "Không có khung",
                               message: "Thêm khung bằng nút “Thêm khung”, hoặc xóa bộ lọc để xem tất cả.",
                               actionTitle: "Thêm khung") {
                    vm.importViaOpenPanel()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(vm.frames) { card in
                            FrameLibraryCard(card: card,
                                             selected: vm.selection.contains(card.id),
                                             thumbnailProvider: { vm.generateThumbnailIfNeeded(for: card) },
                                             onTap: { toggleSelect(card.id) },
                                             onFavorite: { vm.toggleFavorite(card.id) })
                                .contextMenu {
                                    Button("Sử dụng") { useFrame(card) }
                                    Button("Chỉnh bố cục") { env.openFrameEditor(frameID: card.id) }
                                    Button("Đổi tên") { promptRename(card) }
                                    Button("Nhân bản") { vm.duplicate(card.id) }
                                    Menu("Di chuyển") {
                                        Button("Chưa phân loại") { vm.moveToCategory([card.id], categoryID: nil) }
                                        ForEach(vm.categories) { c in
                                            Button(c.name) { vm.moveToCategory([card.id], categoryID: c.id) }
                                        }
                                    }
                                    Button("Xuất gói") { showPackExport = true }
                                    Divider()
                                    Button("Chuyển vào Thùng rác", role: .destructive) { vm.trash(card.id) }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func toggleSelect(_ id: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if vm.selection.contains(id) { vm.selection.remove(id) } else { vm.selection.insert(id) }
        } else {
            vm.selection = [id]
        }
    }

    private func useFrame(_ card: FrameCardModel) {
        guard card.frame.validationStatus == .ready else {
            env.showToast("Khung chưa thiết lập (E-FRM-02) — mở Frame Editor", kind: .warning)
            env.openFrameEditor(frameID: card.id)
            return
        }
        // Ghi vào env để màn Chụp nhận lại sau khi route đổi (StateObject màn Chụp bị hủy khi chuyển route)
        env.preferredFrameID = card.id
        env.route = .capture
        env.showToast("Đã chọn khung \(card.frame.name) — quay lại màn Chụp")
    }

    private func promptRename(_ card: FrameCardModel) {
        let alert = NSAlert()
        alert.messageText = "Đổi tên khung"
        alert.addButton(withTitle: "Lưu")
        alert.addButton(withTitle: "Hủy")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = card.frame.name
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            vm.rename(card.id, to: input.stringValue)
        }
    }

    // MARK: Inspector

    @ViewBuilder private var inspectorView: some View {
        if vm.selection.count == 1, let id = vm.selection.first,
           let card = vm.frames.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ImageDataView(data: vm.generateThumbnailIfNeeded(for: card))
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(card.frame.name).font(.headline)
                    infoRow("Kích thước canvas", canvasSizeText(card))
                    infoRow("Số ảnh", "\(card.slotCount)")
                    infoRow("Danh mục", categoryName(card.frame.categoryID))
                    infoRow("Trạng thái", card.frame.validationStatus == .ready ? "Sẵn sàng" :
                            card.frame.validationStatus == .invalid ? "Không hợp lệ" : "Chưa thiết lập")
                    infoRow("Cập nhật", formatDate(card.frame.updatedAtMs))
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        PrimaryButton(title: "Sử dụng", systemImage: "checkmark.circle",
                                      disabledReason: card.frame.validationStatus != .ready ? "Khung chưa thiết lập" : nil) {
                            useFrame(card)
                        }
                        Button("Chỉnh bố cục") { env.openFrameEditor(frameID: card.id) }
                        Button("Đổi tên") { promptRename(card) }
                        Button("Nhân bản") { vm.duplicate(card.id) }
                        Button("Xuất gói") { showPackExport = true }
                        Button("Chuyển vào Thùng rác", role: .destructive) { vm.trash(card.id) }
                            .help("Xóa mềm — giữ 30 ngày trong Thùng rác nội bộ")
                    }
                }
                .padding(14)
            }
        }
    }

    private var batchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Đã chọn \(vm.selection.count) khung").font(.headline)
            Button("Yêu thích tất cả") {
                for id in vm.selection { vm.toggleFavorite(id) }
            }
            Menu("Di chuyển vào danh mục") {
                Button("Chưa phân loại") { vm.moveToCategory(Array(vm.selection), categoryID: nil) }
                ForEach(vm.categories) { c in
                    Button(c.name) { vm.moveToCategory(Array(vm.selection), categoryID: c.id) }
                }
            }
            Button("Chuyển vào Thùng rác", role: .destructive) { vm.trashSelection() }
            Spacer()
        }
        .padding(14)
    }

    private func canvasSizeText(_ card: FrameCardModel) -> String {
        guard let revID = card.frame.currentRevisionID, let rev = try? env.frames.getRevision(id: revID) else { return "—" }
        return "\(rev.canvasWidth) × \(rev.canvasHeight) px"
    }

        @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.caption)
    }

        private func formatDate(_ ms: Int64) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: Time.date(ms: ms))
    }

    private func categoryName(_ id: String?) -> String {
        guard let id else { return "Chưa phân loại" }
        return vm.categories.first { $0.id == id }?.name ?? "—"
    }

    private var packExportSheet: some View {
        PackExportSheet(env: env, framesVM: vm)
    }
}

struct FrameLibraryCard: View {
    var card: FrameCardModel
    var selected: Bool
    var thumbnailProvider: () -> Data?
    var onTap: () -> Void
    var onFavorite: () -> Void
    @State private var thumb: Data?

    var body: some View {
        VStack(spacing: 6) {
            ImageDataView(data: thumb ?? thumbnailProvider())
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1))
            HStack {
                Text(card.frame.name).lineLimit(1).font(.caption.weight(.medium))
                Spacer()
                if card.frame.validationStatus != .ready {
                    Text("Chưa thiết lập").font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("\(card.slotCount) ảnh").font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    onFavorite()
                } label: {
                    Image(systemName: card.frame.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(card.frame.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Xuất Frame Pack (§13.3).
struct PackExportSheet: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var framesVM: FramesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var packName = "Khung của tôi"
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(spacing: 12) {
            Text("Xuất Frame Pack").font(.headline)
            HStack {
                Text("Tên gói:")
                TextField("Tên", text: $packName).textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            List(framesVM.frames, selection: $selected) { card in
                HStack {
                    ImageDataView(data: card.thumbnail).frame(width: 40, height: 40)
                    Text(card.frame.name)
                    Spacer()
                    Text("\(card.slotCount) ảnh").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 240)
            HStack {
                Button("Hủy") { dismiss() }
                Spacer()
                Button("Xuất…") { exportPack() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || packName.isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 420)
        .onAppear { selected = Set(framesVM.frames.map(\.id)) }
    }

    private func exportPack() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "photoframepack") ?? .data]
        panel.nameFieldStringValue = "\(packName).photoframepack"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                // Ghi trực tiếp vào URL người dùng đã chọn (đã được panel cấp quyền sandbox)
                let ok = framesVM.exportPack(frameIDs: Array(selected), name: packName, saveTo: url)
                if ok {
                    dismiss()
                }
            }
        }
    }
}
