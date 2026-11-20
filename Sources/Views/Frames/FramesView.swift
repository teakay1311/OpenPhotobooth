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
    private struct PackExportRequest: Identifiable {
        let id = UUID()
        let frameIDs: [String]
    }
    @State private var packExportRequest: PackExportRequest?
    @State private var clarityFrame: Frame?
    @State private var selectingMany = false
    @State private var trashRequest: FrameTrashConfirmation.Request?

    public init(env: AppEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: FramesViewModel(env: env))
    }

    public var body: some View {
        HStack(spacing: 0) {
            categorySidebar.frame(width: 200)
            Divider()
            VStack(spacing: 0) {
                toolbar
                GeometryReader { geometry in
                    if vm.selection.isEmpty || selectingMany {
                        gridArea.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if geometry.size.width < 700 {
                        VStack(spacing: 0) {
                            gridArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                            Divider()
                            selectionPanel
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(maxHeight: min(300, geometry.size.height * 0.42))
                        }
                    } else {
                        HStack(spacing: 0) {
                            gridArea.frame(maxWidth: .infinity)
                            Divider()
                            selectionPanel.frame(width: 300)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .sheet(item: $packExportRequest) { request in
            PackExportSheet(env: env, framesVM: vm, initialSelectedIDs: request.frameIDs)
        }
        .sheet(item: $trashRequest) { request in
            FrameTrashConfirmation(request: request, service: env.trashService) { moved in
                vm.selection.subtract(moved)
            }
        }
        .sheet(item: $clarityFrame) { frame in
            FrameClaritySheet(env: env, frame: frame) { saved in
                vm.reload()
                if !vm.frames.contains(where: { $0.id == saved.id }) {
                    vm.selectedCategoryID = nil
                    vm.searchText = ""
                    vm.reload()
                }
                vm.selection = [saved.id]
                EventBus.shared.post(.frameLibraryChanged(frameID: saved.id))
            }
        }
        .sheet(isPresented: $vm.showImportSheet) {
            FrameImportSheet(env: env, urls: vm.importQueueURLs, categoryID: vm.selectedCategoryID) {
                vm.reload()
            }
        }
    }

    @ViewBuilder private var selectionPanel: some View {
        if vm.selection.count == 1 {
            inspectorView
        } else {
            ScrollView { batchBar }
        }
    }

    // MARK: Sidebar danh mục

    private var categorySidebar: some View {
        List(selection: Binding<String?>(
            get: { vm.selectedCategoryID ?? "__all__" },
            set: { value in
                guard let value else { return }
                vm.selectedCategoryID = value == "__all__" ? nil : value
                vm.reload()
            }
        )) {
            Section("Danh mục") {
                Label("Tất cả", systemImage: "square.grid.2x2")
                    .tag("__all__")
                Label("Yêu thích", systemImage: "star.fill")
                    .tag("__favorites__")
                Label("Chưa phân loại", systemImage: "tray")
                    .tag("unclassified")
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
                    .tag(cat.id)
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
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                env.showToast("Tên danh mục không được để trống", kind: .warning)
                return
            }
            if trimmed.count > 80 {
                env.showToast("Tên danh mục không được vượt quá 80 ký tự", kind: .warning)
                return
            }
            do {
                try env.frames.renameCategory(id: cat.id, to: trimmed)
                vm.reload()
                env.showToast("Đã đổi tên danh mục")
            } catch {
                env.showToast("\((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
            }
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
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    toolbarActions
                    toolbarFilters
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    toolbarActions
                    toolbarFilters
                }
            }
            if selectingMany {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { selectionActions }
                    VStack(alignment: .leading, spacing: 8) { selectionActions }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var selectionActions: some View {
        Text("Đã chọn \(vm.selection.count) khung")
        Button("Chọn tất cả kết quả") { vm.selection = Set(vm.frames.map(\.id)) }
            .disabled(vm.frames.isEmpty)
        Button("Bỏ chọn tất cả") { vm.selection.removeAll() }
            .disabled(vm.selection.isEmpty)
        Button("Chuyển \(vm.selection.count) khung vào Thùng rác", role: .destructive) {
            beginTrashConfirmation()
        }
        .disabled(vm.selection.isEmpty)
    }

    private var toolbarActions: some View {
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
            Button(selectingMany ? "Xong" : "Chọn nhiều") {
                selectingMany.toggle()
                if !selectingMany { vm.selection.removeAll() }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var toolbarFilters: some View {
        HStack(spacing: 10) {
            TextField("Tìm kiếm", text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100, idealWidth: 180, maxWidth: 240)
                .onChange(of: vm.searchText) { _ in vm.reload() }
            Picker("Sắp xếp", selection: $vm.sortNewest) {
                Text("Mới nhất").tag(true)
                Text("Cũ nhất").tag(false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .onChange(of: vm.sortNewest) { _ in vm.reload() }
        }
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
                                .overlay(alignment: .topLeading) {
                                    if selectingMany {
                                        Toggle(isOn: Binding(
                                            get: { vm.selection.contains(card.id) },
                                            set: { selected in
                                                if selected { vm.selection.insert(card.id) }
                                                else { vm.selection.remove(card.id) }
                                            }
                                        )) { Text("Chọn \(card.frame.name)") }
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                        .padding(6)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                                        .padding(4)
                                    }
                                }
                                .contextMenu {
                                    Button("Chỉnh bố cục") { env.openFrameEditor(frameID: card.id) }
                                    Button("Đổi tên") { promptRename(card) }
                                    Button("Nhân bản") { Task { await vm.duplicate(card.id) } }
                                        .disabled(vm.duplicatingFrameIDs.contains(card.id))
                                    Menu("Di chuyển") {
                                        Button("Chưa phân loại") { vm.moveToCategory([card.id], categoryID: nil) }
                                        ForEach(vm.categories) { c in
                                            Button(c.name) { vm.moveToCategory([card.id], categoryID: c.id) }
                                        }
                                    }
                                    Button("Xuất gói") {
                                        packExportRequest = PackExportRequest(frameIDs: [card.id])
                                    }
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
        if selectingMany || NSEvent.modifierFlags.contains(.command) {
            if vm.selection.contains(id) { vm.selection.remove(id) } else { vm.selection.insert(id) }
        } else {
            vm.selection = [id]
        }
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
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                env.showToast("Tên khung không được để trống", kind: .warning)
                return
            }
            vm.rename(card.id, to: trimmed)
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
                        Button("Chỉnh bố cục") { env.openFrameEditor(frameID: card.id) }
                        Button("Đổi tên") { promptRename(card) }
                        Button("Nhân bản") { Task { await vm.duplicate(card.id) } }
                            .disabled(vm.duplicatingFrameIDs.contains(card.id))
                        if card.frame.validationStatus == .ready, let revisionID = card.frame.currentRevisionID,
                           let revision = try? env.frames.getRevision(id: revisionID),
                           let foregroundID = revision.foregroundAssetID,
                           env.assets.assetInfo(assetID: foregroundID)?.relativePath.lowercased().hasSuffix(".png") == true {
                            Button("Làm trong ô ảnh") { clarityFrame = card.frame }
                        }
                        Button("Xuất gói") {
                            packExportRequest = PackExportRequest(frameIDs: [card.id])
                        }
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
                vm.favoriteSelection()
            }
            Menu("Di chuyển vào danh mục") {
                Button("Chưa phân loại") { vm.moveToCategory(Array(vm.selection), categoryID: nil) }
                ForEach(vm.categories) { c in
                    Button(c.name) { vm.moveToCategory(Array(vm.selection), categoryID: c.id) }
                }
            }
            Button("Chuyển vào Thùng rác", role: .destructive) { beginTrashConfirmation() }
            Spacer()
        }
        .padding(14)
    }

    private func beginTrashConfirmation() {
        let targets = vm.selectedTrashTargets
        guard !targets.isEmpty, trashRequest == nil else { return }
        trashRequest = FrameTrashConfirmation.Request(targets: targets)
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

}

private struct FrameTrashConfirmation: View {
    struct Request: Identifiable {
        let id = UUID()
        let targets: [TrashService.FrameTarget]
    }

    @Environment(\.dismiss) private var dismiss
    let service: TrashService
    let onMoved: ([String]) -> Void
    @State private var trashTargets: [TrashService.FrameTarget]
    @State private var trashRunning = false
    @State private var skippedTrashTargets: [String] = []
    @State private var trashNotice: String?
    @State private var trashSummary: String?

    init(request: Request, service: TrashService, onMoved: @escaping ([String]) -> Void) {
        self.service = service
        self.onMoved = onMoved
        _trashTargets = State(initialValue: request.targets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
          if let trashSummary {
            Text("Kết quả chuyển vào Thùng rác").font(.headline)
            ScrollView { Text(trashSummary).frame(maxWidth: .infinity, alignment: .leading) }
            Button("Đóng") { dismiss() }.keyboardShortcut(.defaultAction)
          } else {
            Text("Chuyển \(trashTargets.count) khung vào Thùng rác").font(.headline)
            Text("Bạn có thể khôi phục các khung từ Thùng rác trong 30 ngày.")
            if let trashNotice { Text(trashNotice).foregroundStyle(.orange) }
            List(trashTargets) { target in Text(target.name) }
            HStack {
                Button("Hủy", role: .cancel) { dismiss() }.disabled(trashRunning)
                Spacer()
                if trashRunning { ProgressView().controlSize(.small) }
                Button("Chuyển vào Thùng rác", role: .destructive) {
                    Task { await confirmTrash() }
                }
                .disabled(trashRunning || trashTargets.isEmpty)
            }
          }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 260)
        .interactiveDismissDisabled(trashRunning)
    }

    private func confirmTrash() async {
        guard !trashRunning, !trashTargets.isEmpty else { return }
        trashRunning = true
        defer { trashRunning = false }
        let service = service
        let shown = trashTargets
        do {
            let current = try await Task.detached {
                try service.activeFrameTargets(shown.map(\.id))
            }.value
            if current != shown {
                let names = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.name) })
                let removed = shown.filter { names[$0.id] == nil }
                skippedTrashTargets += removed.map { "\($0.name): Khung đã rời thư viện" }
                let renamed = shown.compactMap { target in
                    names[target.id].flatMap { $0 == target.name ? nil : "\(target.name) → \($0)" }
                }
                trashTargets = current
                trashNotice = (skippedTrashTargets + renamed).joined(separator: "\n")
                if current.isEmpty {
                    trashSummary = (["Đã chuyển 0/\(skippedTrashTargets.count) khung."] +
                                    skippedTrashTargets).joined(separator: "\n")
                }
                return
            }
            let result = await Task.detached { service.trashFrames(shown) }.value
            onMoved(result.moved)
            let failures = shown.compactMap { target in
                result.failures[target.id].map { "\(target.name): \($0)" }
            }
            let count = shown.count + skippedTrashTargets.count
            trashSummary = (["Đã chuyển \(result.moved.count)/\(count) khung."] +
                            skippedTrashTargets + failures).joined(separator: "\n")
        } catch {
            trashNotice = (error as? AppError)?.message ?? error.localizedDescription
        }
    }
}

struct FrameClaritySheet: View {
    struct ImportInput: Identifiable {
        let id = UUID()
        let name: String
        let original: Data
        let snapshot: FrameSnapshot
        var edits: [PNGSlotClarity.Edit] = []
        var approvals: PNGSlotClarity.Approvals = [:]
        var automatic: PNGSlotClarity.Result?
        var currentResult: PNGSlotClarity.Result?
        var importGeneration: Int?
    }

    struct Submission {
        let result: PNGSlotClarity.Result
        let automatic: PNGSlotClarity.Result
        let state: PNGSlotClarity.ReviewState
        var beforeBulkApproval: PNGSlotClarity.Approvals?
    }

    @Environment(\.dismiss) private var dismiss
    let env: AppEnvironment
    private let frame: Frame?
    private let importInput: ImportInput?
    private let onSaved: ((Frame) -> Void)?
    private let onApproved: ((Submission) async -> Bool)?

    init(env: AppEnvironment, frame: Frame, onSaved: @escaping (Frame) -> Void) {
        self.env = env
        self.frame = frame
        self.onSaved = onSaved
        importInput = nil
        onApproved = nil
    }

    init(env: AppEnvironment, input: ImportInput,
         onApproved: @escaping (Submission) async -> Bool) {
        self.env = env
        frame = nil
        onSaved = nil
        importInput = input
        self.onApproved = onApproved
        _review = State(initialValue: PNGSlotClarity.ReviewState(edits: input.edits, approvals: input.approvals))
    }

    @State private var preview: Preview?
    @State private var message: String?
    @State private var loading = true
    @State private var saving = false
    @State private var retrySave = false
    @State private var progress: String?
    @State private var review = PNGSlotClarity.ReviewState()
    @State private var history: [ReviewStep] = []
    @State private var focusedID: String?
    @State private var selection: CGRect?
    @State private var pending: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var copyID = IDFactory.new()

    private enum ReviewStep {
        case approval(PNGSlotClarity.Approvals, String?)
        case pixelEdit(PNGSlotClarity.ReviewState)
    }

    private struct Preview {
        let original: Data
        let model: CompositionModel
        let automatic: PNGSlotClarity.Result
        let before: CGImage
        var result: PNGSlotClarity.Result
        var after: CGImage
        var blockedSlots: [Int]
    }

    private var focused: PNGSlotClarity.SlotResult? {
        preview?.result.displayedSlots(review.approvals).first { $0.id == focusedID }
    }

    private var canSave: Bool {
        guard !loading, !saving, let preview, preview.blockedSlots.isEmpty else { return false }
        let result = preview.result
        guard
              !result.slots.isEmpty, result.pending(review.approvals).isEmpty else { return false }
        return importInput != nil || result.hasChanges
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Làm trong ô ảnh").font(.title2.bold())
            Text(frame?.name ?? importInput?.name ?? "").foregroundStyle(.secondary)
            if let preview {
                let images = displayedImages(preview)
                HStack(alignment: .top, spacing: 16) {
                    comparison("Trước", image: images.before, crop: images.crop, canSelect: false)
                    comparison("Sau", image: images.after, crop: images.crop, canSelect: focused != nil)
                }
                .frame(height: 420)
                reviewControls(preview)
            } else if loading {
                ProgressView(progress ?? "Đang kiểm tra lớp phủ PNG…")
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            }
            if let message {
                Text(message)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Hủy") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(retrySave ? "Thử lại" : (importInput == nil ? "Lưu bản đã làm trong" : "Xác nhận các ô")) {
                    Task { await save() }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 330)
        .interactiveDismissDisabled(saving)
        .task { await prepare() }
        .onDisappear { generation = UUID(); pending?.cancel() }
    }

    private func reviewControls(_ preview: Preview) -> some View {
        let slots = preview.result.displayedSlots(review.approvals)
        let done = slots.filter { $0.status != .needsReview }.count
        return VStack(alignment: .leading, spacing: 8) {
            Text(loading ? "Đang cập nhật bản xem thử…" :
                 "\(done == slots.count ? "Xong" : "Đã đạt") \(done)/\(slots.count) ô")
                .foregroundStyle(.secondary)
            if !preview.result.hasChanges && done == slots.count {
                Text(slots.allSatisfy { $0.status == .alreadyClear }
                     ? "Toàn bộ ô đã trong sẵn. Bạn có thể dùng khung hiện tại."
                     : "PNG giữ nguyên sau khi xác nhận. Bạn có thể dùng khung hiện tại.")
                    .foregroundStyle(.secondary)
            } else if done == slots.count {
                let ready = slots.filter { $0.status == .cleared }.map { String($0.number) }
                let clear = slots.filter { $0.status == .alreadyClear }.map { String($0.number) }
                let kept = slots.filter { $0.status == .detailKept }.map { String($0.number) }
                if !ready.isEmpty {
                    Text("Đã làm trong · Ô \(ready.joined(separator: ", "))").font(.caption)
                }
                if !clear.isEmpty {
                    Text("Đã trong sẵn · Ô \(clear.joined(separator: ", "))").font(.caption)
                }
                if !kept.isEmpty {
                    Text("Đã xác nhận chi tiết cần giữ · Ô \(kept.joined(separator: ", "))").font(.caption)
                }
            }
            let approved = slots.filter { $0.status == .previewApproved }.map { String($0.number) }
            if !approved.isEmpty {
                Text("Đã duyệt theo bản xem trước · Ô \(approved.joined(separator: ", "))").font(.caption)
            }
            if !preview.blockedSlots.isEmpty {
                Text("Lớp phủ che kín ô \(preview.blockedSlots.map(String.init).joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Picker("Ô ảnh", selection: $focusedID) {
                    Text("Toàn bộ khung").tag(nil as String?)
                    ForEach(slots) { slot in
                        Text("Ô \(slot.number) · \(slot.status.rawValue)").tag(Optional(slot.id))
                    }
                }
                .accessibilityIdentifier("frameClarity.slotPicker")
                .help("Chọn bất kỳ ô nào để kiểm tra hoặc chỉnh lại, kể cả khi đã báo xong.")
                .onChange(of: focusedID) { _, _ in selection = nil }
                if !history.isEmpty {
                    Button("Hoàn tác") { undoReview() }
                }
            }
            if focusedID == nil && done < slots.count {
                Button("Xác nhận toàn bộ theo bản Sau") { Task { await approvePreview(slotID: nil) } }
                    .disabled(!preview.blockedSlots.isEmpty)
            }
            if let focused {
                Text("Ô \(focused.number) · \(focused.issues.first?.location ?? focused.status.rawValue)")
                Text("Kéo trên bản Sau để chọn vùng cần chỉnh. Giữ vùng này sẽ khôi phục vùng đã chọn theo bản gốc.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Làm trong vùng này") { apply(.clear, to: focused) }
                    Button("Giữ vùng này") { apply(.keep, to: focused) }
                }
                .disabled((selection ?? focused.issues.first?.bounds) == nil)
                if focused.status == .needsReview {
                    Button("Xác nhận ô này theo bản Sau") { Task { await approvePreview(slotID: focused.id) } }
                        .disabled(preview.blockedSlots.contains(focused.number))
                }
            }
        }
        .disabled(loading || saving || retrySave)
    }

    private func apply(_ action: PNGSlotClarity.Edit.Action, to slot: PNGSlotClarity.SlotResult) {
        guard !loading, !saving, !retrySave, let bounds = selection ?? slot.issues.first?.bounds else { return }
        let pixels = selection == nil ? slot.issues.first?.pixels ?? [] : []
        var next = review
        next.edits.append(PNGSlotClarity.Edit(slotID: slot.id, bounds: bounds, action: action, pixels: pixels))
        updatePreview(next, history: history + [.pixelEdit(review)])
    }

    private func approvePreview(slotID: String?) async {
        guard !loading, !saving, !retrySave, let preview else { return }
        if let slotID {
            guard let number = preview.result.slots.first(where: { $0.id == slotID })?.number,
                  !preview.blockedSlots.contains(number) else { return }
        } else if !preview.blockedSlots.isEmpty {
            return
        }
        let previous = review.approvals
        let updated = preview.result.approving(previous, slotID: slotID)
        guard updated != previous else { return }
        review.approvals = updated
        history.append(.approval(previous, focusedID))
        if slotID == nil, importInput?.importGeneration != nil, let onApproved {
            saving = true
            let accepted = await onApproved(Submission(result: preview.result, automatic: preview.automatic,
                                                       state: review, beforeBulkApproval: previous))
            saving = false
            if accepted {
                dismiss()
            } else {
                undoReview()
                message = "Bản xem trước đã thay đổi. Hãy mở lại ô ảnh."
            }
            return
        }
        if let slotID {
            let pending = preview.result.pending(updated)
            let number = preview.result.slots.first { $0.id == slotID }?.number ?? 0
            focusedID = (pending.first { $0.number > number } ?? pending.first)?.id ?? slotID
            selection = nil
        }
    }

    private func undoReview() {
        guard !loading, !saving, !retrySave, let step = history.last else { return }
        switch step {
        case .approval(let previous, let focus):
            history.removeLast()
            review.approvals = previous
            focusedID = focus
            selection = nil
        case .pixelEdit(let previous):
            updatePreview(previous, history: Array(history.dropLast()))
        }
    }

    private func displayedImages(_ preview: Preview) -> (before: CGImage, after: CGImage, crop: CGRect) {
        let full = CGRect(x: 0, y: 0, width: preview.model.snapshot.canvasWidth,
                          height: preview.model.snapshot.canvasHeight)
        guard let focused else { return (preview.before, preview.after, full) }
        let crop = focused.bounds.integral.intersection(full)
        let sx = Double(preview.before.width) / full.width
        let sy = Double(preview.before.height) / full.height
        let pixels = CGRect(x: crop.minX * sx, y: crop.minY * sy,
                            width: crop.width * sx, height: crop.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: preview.before.width, height: preview.before.height))
        guard let before = preview.before.cropping(to: pixels), let after = preview.after.cropping(to: pixels) else {
            return (preview.before, preview.after, full)
        }
        return (before, after, CGRect(x: pixels.minX / sx, y: pixels.minY / sy,
                                      width: pixels.width / sx, height: pixels.height / sy))
    }

    private func comparison(_ title: String, image: CGImage, crop: CGRect, canSelect: Bool) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            GeometryReader { geometry in
                let scale = min(geometry.size.width / Double(image.width),
                                geometry.size.height / Double(image.height))
                let width = Double(image.width) * scale
                let height = Double(image.height) * scale
                Image(image, scale: 1, label: Text(title))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
                    .overlay(alignment: .topLeading) {
                        if let marked = selection ?? focused?.issues.first?.bounds {
                            let visible = marked.intersection(crop)
                            if !visible.isEmpty {
                                Rectangle()
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .background(Color.accentColor.opacity(0.12))
                                    .frame(width: visible.width / crop.width * width,
                                           height: visible.height / crop.height * height)
                                    .offset(x: (visible.minX - crop.minX) / crop.width * width,
                                            y: (visible.minY - crop.minY) / crop.height * height)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                        guard canSelect, !loading, !saving, !retrySave, width > 0, height > 0 else { return }
                        let x0 = crop.minX + drag.startLocation.x / width * crop.width
                        let y0 = crop.minY + drag.startLocation.y / height * crop.height
                        let x1 = crop.minX + drag.location.x / width * crop.width
                        let y1 = crop.minY + drag.location.y / height * crop.height
                        let rect = CGRect(x: min(x0, x1), y: min(y0, y1),
                                          width: abs(x1 - x0), height: abs(y1 - y0)).intersection(crop)
                        if !rect.isEmpty { selection = rect }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func prepare() async {
        defer { loading = false }
        let repository = env.frames
        let assets = env.assets
        let frameID = frame?.id
        let revisionID = frame?.currentRevisionID
        let importInput = importInput
        let request = generation
        var defaults = env.settings.sessionDefaultsSnapshot()
        defaults.color = .neutral
        defaults.presetIntensity = 0
        defaults.skinSmooth = 0
        let sampleDefaults = defaults
        let report: @Sendable (Int, Int) -> Void = { current, total in
            Task { @MainActor in
                if generation == request, loading { progress = "Đang xử lý ô \(current)/\(total)" }
            }
        }
        let task = Task.detached(priority: .userInitiated) { () throws -> Preview in
            let snapshot: FrameSnapshot
            if let importInput {
                snapshot = importInput.snapshot
            } else {
                guard let frameID else { throw AppError.frameUnconfigured }
                snapshot = try repository.createSnapshot(frameID: frameID, persist: false)
                guard snapshot.sourceFrameRevisionID == revisionID else {
                    throw AppError.invalidState("Khung gốc đã thay đổi. Hãy mở lại bản xem thử.")
                }
            }
            guard let foreground = snapshot.foreground else { throw AppError.missingFrameAssets }
            let original: Data
            if let importInput {
                original = importInput.original
            } else {
                original = try assets.loadData(assetID: foreground.assetID)
                guard assets.assetInfo(assetID: foreground.assetID)?.sha256 == Hashing.sha256Hex(original) else {
                    throw AppError.frameFileCorrupt
                }
            }
            guard let beforeOverlay = CGImage.createFrom(data: original) else { throw AppError.frameFileCorrupt }
            let automatic = try importInput?.automatic ??
                PNGSlotClarity.prepare(data: original, snapshot: snapshot, progress: report)
            let result = try importInput?.currentResult ??
                PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: automatic,
                                     edits: importInput?.edits ?? [])
            let scale = min(1, 1400.0 / Double(max(snapshot.canvasWidth, snapshot.canvasHeight)))
            let options = RenderOptions(targetWidth: max(1, Int((Double(snapshot.canvasWidth) * scale).rounded())),
                                        targetHeight: max(1, Int((Double(snapshot.canvasHeight) * scale).rounded())))
            var sources: [Int: RenderSource] = [:]
            for index in snapshot.requiredIndices.sorted() {
                try Task.checkCancellation()
                if let image = SampleImageFactory.shared.sample(index: index, size: CGSize(width: 640, height: 640)) {
                    sources[index] = RenderSource(image: image)
                }
            }
            var images = [foreground.assetID: beforeOverlay]
            if let background = snapshot.background {
                images[background.assetID] = try assets.loadVerifiedImage(assetID: background.assetID)
            }
            let model = CompositionModel(snapshot: snapshot, sources: sources, defaults: sampleDefaults,
                                         overrides: [:], placements: [:], cropModes: [:],
                                         assetImages: images, options: options)
            let before = try CompositeRenderer.render(model: model)
            let overlay = result.hasChanges ? CGImage.createFrom(data: result.data) : beforeOverlay
            guard let overlay else { throw AppError.frameFileCorrupt }
            let blocked = try Self.blockedSlots(overlay, snapshot: snapshot)
            let after = result.hasChanges ? try Self.render(overlay, model: model) : before
            return Preview(original: original, model: model, automatic: automatic,
                           before: before, result: result, after: after, blockedSlots: blocked)
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, generation == request else { return }
            preview = result
            review.approvals = result.result.retained(review.approvals)
            focusedID = result.result.pending(review.approvals).first?.id
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            message = (error as? AppError)?.message ?? error.localizedDescription
        }
    }

    private nonisolated static func blockedSlots(_ overlay: CGImage, snapshot: FrameSnapshot) throws -> [Int] {
        guard let placement = snapshot.foreground?.placement else { throw AppError.missingFrameAssets }
        let draft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: snapshot.canvasWidth,
                                  canvasHeight: snapshot.canvasHeight, foregroundPlacement: placement)
        let slots = snapshot.slots.sorted { ($0.zOrder, $0.captureIndex, $0.id) < ($1.zOrder, $1.captureIndex, $1.id) }
            .map { slot in
                FrameSlot(id: slot.id, captureIndex: slot.captureIndex, x: slot.x, y: slot.y, width: slot.width,
                          height: slot.height, rotationDegrees: slot.rotationDegrees, zOrder: slot.zOrder,
                          maskType: slot.maskType, cornerRadius: slot.cornerRadius, defaultCropMode: slot.defaultCropMode)
            }
        return try PNGAutoAlignmentService.blockedSlots(overlay: overlay, draft: draft, slots: slots)
    }

    private nonisolated static func render(_ overlay: CGImage, model: CompositionModel) throws -> CGImage {
        try Task.checkCancellation()
        guard let id = model.snapshot.foreground?.assetID else { throw AppError.missingFrameAssets }
        var model = model
        model.assetImages[id] = overlay
        return try CompositeRenderer.render(model: model)
    }

    private func updatePreview(_ next: PNGSlotClarity.ReviewState, history nextHistory: [ReviewStep]) {
        guard let current = preview else { return }
        pending?.cancel()
        let request = UUID()
        generation = request
        loading = true
        message = nil
        pending = Task {
            let task = Task.detached(priority: .userInitiated) {
                let result = try PNGSlotClarity.refine(data: current.original, snapshot: current.model.snapshot,
                                                       automatic: current.automatic, edits: next.edits)
                guard let overlay = CGImage.createFrom(data: result.data) else { throw AppError.frameFileCorrupt }
                let image = try Self.render(overlay, model: current.model)
                let blocked = try Self.blockedSlots(overlay, snapshot: current.model.snapshot)
                return (result, image, blocked)
            }
            do {
                let (result, image, blocked) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled, generation == request else { return }
                var updated = current
                updated.result = result
                updated.after = image
                updated.blockedSlots = blocked
                preview = updated
                review = next
                review.approvals = result.retained(next.approvals)
                history = nextHistory
                selection = nil
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                message = (error as? AppError)?.message ?? error.localizedDescription
            }
            if generation == request { loading = false }
        }
    }

    private func save() async {
        guard canSave, let preview else { return }
        saving = true
        message = nil
        defer { saving = false }
        if let onApproved {
            if await onApproved(Submission(result: preview.result, automatic: preview.automatic, state: review)) {
                dismiss()
            }
            return
        }
        guard let frame, let revisionID = frame.currentRevisionID else { return }
        let repository = env.frames
        let frameID = frame.id
        let destinationID = copyID
        let data = preview.result.data
        do {
            let saved = try await Task.detached(priority: .userInitiated) {
                try repository.saveClearSlotCopy(sourceID: frameID, revisionID: revisionID,
                                                 copyID: destinationID, png: data)
            }.value
            dismiss()
            onSaved?(saved)
        } catch {
            retrySave = true
            message = (error as? AppError)?.message ?? error.localizedDescription
        }
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
                Text(card.frame.name).lineLimit(2).font(.caption.weight(.medium))
                    .help(card.frame.name)
                    .layoutPriority(1)
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

/// Xuất Frame Pack (§13.3, §4, FRM-02).
struct PackExportSheet: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var framesVM: FramesViewModel
    let initialSelectedIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var packName = "Khung của tôi"
    @State private var selected: Set<String>
    @State private var isExporting = false
    @State private var errorMessage: String? = nil

    init(env: AppEnvironment, framesVM: FramesViewModel, initialSelectedIDs: [String]) {
        self.env = env
        self.framesVM = framesVM
        self.initialSelectedIDs = initialSelectedIDs
        _selected = State(initialValue: Set(initialSelectedIDs))
    }

    private var invalidInitialSelection: Bool {
        initialSelectedIDs.isEmpty || initialSelectedIDs.contains { id in
            !framesVM.frames.contains { $0.id == id }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Xuất Frame Pack").font(.headline)
            if let err = invalidInitialSelection ? "Khung được chọn không còn tồn tại hoặc không hợp lệ" : errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            HStack {
                Text("Tên gói:")
                TextField("Tên", text: $packName).textFieldStyle(.roundedBorder)
                    .disabled(isExporting)
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
            .disabled(isExporting)
            HStack {
                Button("Hủy") { dismiss() }
                    .disabled(isExporting)
                Spacer()
                if isExporting {
                    ProgressView().controlSize(.small)
                }
                Button("Xuất…") { exportPack() }
                    .buttonStyle(.borderedProminent)
                    .disabled(invalidInitialSelection || selected.isEmpty || packName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isExporting)
            }
            .padding()
        }
        .frame(width: 460, height: 420)
    }

    private func exportPack() {
        let trimmedName = packName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invalidInitialSelection, !trimmedName.isEmpty, !selected.isEmpty, !isExporting else { return }
        isExporting = true
        errorMessage = nil
        let targetIDs = Array(selected)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "photoframepack") ?? .data]
        panel.nameFieldStringValue = "\(trimmedName).photoframepack"
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                Task { @MainActor in
                    self.isExporting = false
                }
                return
            }
            Task { @MainActor in
                let ok = framesVM.exportPack(frameIDs: targetIDs, name: trimmedName, saveTo: url)
                if ok {
                    dismiss()
                } else {
                    self.isExporting = false
                    self.errorMessage = "Xuất gói không thành công. Vui lòng kiểm tra lại trạng thái khung."
                }
            }
        }
    }
}
