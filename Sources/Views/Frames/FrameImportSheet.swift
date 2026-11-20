import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

/// Sheet nhập khung hình từ PNG/JPG với tự căn ô, xem trước composite và hỗ trợ nhiều tệp (§4.1, §4.2, §4.3).
public struct FrameImportSheet: View {
    @ObservedObject var env: AppEnvironment
    let urls: [URL]
    let categoryID: String?
    let onFinished: () -> Void
    let sessionPhotoCount: Int?
    let sessionDetail: SessionDetail?
    let onSessionFrameSaved: ((Frame, Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int = 0
    @State private var frameName: String = ""
    @State private var selectedLayout: FrameImportLayoutKind = .grid2x2
    @State private var currentImage: CGImage?
    @State private var imageOrientation: Int?
    @State private var currentData: Data?
    @State private var alpha: PNGAutoAlignmentService.AlphaGrid?
    @State private var hasAlpha = false
    @State private var detected: AutoAlignmentResult?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadGeneration = 0
    @State private var showManualControls = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewGeneration = 0
    @State private var dragOrigin: SlotRect?
    @State private var advancedDraft: FrameEditorImportDraft?
    @State private var isPNG: Bool = false
    @State private var canvasWidth: Int = 1200
    @State private var canvasHeight: Int = 1800
    @State private var slots: [SlotRect] = []
    @State private var isAutoAligned: Bool = false
    @State private var requiresInspection: Bool = false
    @State private var inspectionReason: String? = nil
    @State private var blockedSlots: [Int] = []
    @State private var fileError: String? = nil
    @State private var selectedSlotIndex: Int = 0
    @State private var compositePreview: CGImage?
    @State private var clarityResult: PNGSlotClarity.Result?
    @State private var clarityAutomatic: PNGSlotClarity.Result?
    @State private var clarityError: String?
    @State private var clarityProgress: String?
    @State private var clarityEdits: [PNGSlotClarity.Edit] = []
    @State private var clarityApprovals: PNGSlotClarity.Approvals = [:]
    @State private var beforeBulkApproval: PNGSlotClarity.Approvals?
    @State private var clarityReview: FrameClaritySheet.ImportInput?
    @State private var slotIDs: [String] = []
    @State private var savedFrameIDs: [String] = []
    @State private var isSaving: Bool = false
    @State private var failedSave: SaveAttempt?
    @State private var saveError: String?
    @State private var showConfirmStop: Bool = false

    public init(env: AppEnvironment, urls: [URL], categoryID: String? = nil,
                sessionPhotoCount: Int? = nil, sessionDetail: SessionDetail? = nil,
                onSessionFrameSaved: ((Frame, Bool) -> Void)? = nil, onFinished: @escaping () -> Void) {
        self.env = env
        self.urls = urls
        self.categoryID = categoryID
        self.sessionPhotoCount = sessionPhotoCount
        self.sessionDetail = sessionDetail
        self.onSessionFrameSaved = onSessionFrameSaved
        self.onFinished = onFinished
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let err = fileError {
                errorStateView(err)
            } else if currentImage != nil {
                mainContent.disabled(isSaving)
            } else {
                ProgressView("Đang phân tích khung…").padding(40)
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: 840, idealWidth: 960, maxWidth: 1100, minHeight: 640, idealHeight: 720, maxHeight: 860)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            loadCurrentFile()
        }
        .onDisappear {
            loadTask?.cancel()
            loadGeneration += 1
            invalidateCompositePreview()
        }
        .sheet(item: $advancedDraft) { draft in
            FrameEditorView(env: env, imported: draft) { frame in
                advancedDraft = nil
                if let frame { didSave(frame) }
            }
            .frame(minWidth: 840, minHeight: 580)
        }
        .sheet(item: $clarityReview) { input in
            FrameClaritySheet(env: env, input: input) { submission in
                guard input.importGeneration == previewGeneration, input.original == currentData,
                      input.snapshot.slots == previewSnapshot.slots else { return false }
                let approvalsChanged = clarityApprovals != submission.state.approvals
                clarityEdits = submission.state.edits
                clarityApprovals = submission.state.approvals
                if clarityResult?.data == submission.result.data, compositePreview != nil {
                    clarityResult = submission.result
                    if approvalsChanged {
                        beforeBulkApproval = submission.beforeBulkApproval
                        saveError = nil
                    }
                } else {
                    updateCompositePreview(approved: submission.result, automatic: submission.automatic)
                    beforeBulkApproval = submission.beforeBulkApproval
                }
                return true
            }
        }
        .confirmationDialog("Huỷ bản nháp khung?", isPresented: $showConfirmStop) {
            Button("Tiếp tục nhập", role: .cancel) { }
            if currentIndex + 1 < urls.count {
                Button("Bỏ qua tệp này") { skipCurrentFile() }
            }
            Button("Dừng nhập", role: .destructive) {
                finishAndDismiss()
            }
        } message: {
            Text("Các khung đã lưu trước đó vẫn được giữ lại.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Thêm khung ảnh").font(.title3.weight(.semibold))
            if urls.count > 1 {
                Text("Tệp \(currentIndex + 1) / \(urls.count)")
                    .font(.subheadline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            if urls.count > 1 {
                Button("Bỏ qua tệp này") {
                    skipCurrentFile()
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)

                Button("Dừng nhập") {
                    showConfirmStop = true
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)
            }
            Button("Huỷ") {
                if urls.count > 1 || !savedFrameIDs.isEmpty {
                    showConfirmStop = true
                } else {
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Main Content

    private var mainContent: some View {
        HStack(spacing: 0) {
            previewPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspectorPanel
                .frame(width: 330)
        }
    }

    // MARK: Preview Panel

    private var previewPanel: some View {
        VStack(spacing: 8) {
            if isAutoAligned {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Đã tìm thấy \(slots.count) ô ảnh")
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 14)
                .padding(.top, 8)
            } else if requiresInspection {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(slots.isEmpty ? "Chọn vị trí đặt ảnh" : "Kiểm tra các ô được gợi ý")
                            .font(.caption.weight(.medium))
                        if let inspectionReason, inspectionReason != "Chọn vị trí đặt ảnh" {
                            Text(inspectionReason).font(.caption)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            if !blockedSlots.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("Lớp phủ che kín ô \(blockedSlots.map(String.init).joined(separator: ", ")). Cần điều chỉnh để ô nhìn thấy ảnh.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 14)
            }
            if let error = clarityError {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button("Thử lại") { updateCompositePreview() }
                }
            } else if let result = clarityResult {
                let pending = result.pending(clarityApprovals)
                if pending.isEmpty {
                    Button("Đã kiểm tra \(result.slots.count)/\(result.slots.count) ô ảnh") {
                        openClarityReview()
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Xem lại ô \(pending.map { String($0.number) }.joined(separator: ", "))") {
                        openClarityReview()
                    }
                }
            } else if let clarityProgress {
                ProgressView(clarityProgress).controlSize(.small)
            }

            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let preview = compositePreview ?? (imageOrientation == nil ? currentImage : nil) {
                    GeometryReader { geo in
                        let fitSize = calculateAspectFitSize(
                            contentWidth: CGFloat(canvasWidth),
                            contentHeight: CGFloat(canvasHeight),
                            containerSize: geo.size
                        )
                        let originX = (geo.size.width - fitSize.width) / 2.0
                        let originY = (geo.size.height - fitSize.height) / 2.0

                        ZStack(alignment: .topLeading) {
                            Image(nsImage: NSImage(cgImage: preview, size: fitSize))
                                .resizable()
                                .frame(width: fitSize.width, height: fitSize.height)

                            // Interactive overlays for slots
                            ForEach(0..<slots.count, id: \.self) { idx in
                                let slot = slots[idx]
                                let slotRect = CGRect(
                                    x: slot.x * fitSize.width,
                                    y: slot.y * fitSize.height,
                                    width: slot.width * fitSize.width,
                                    height: slot.height * fitSize.height
                                )
                                let isSelected = (selectedSlotIndex == idx)
                                let isBlocked = blockedSlots.contains(idx + 1)

                                ZStack(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(
                                            isBlocked ? Color.red : (isSelected ? Color.accentColor : Color.blue.opacity(0.6)),
                                            lineWidth: isSelected ? 2.5 : 1.5
                                        )
                                        .background(
                                            showManualControls && isSelected ? Color.accentColor.opacity(0.1) : Color.clear
                                        )

                                    Text("Ô \(idx + 1)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(isBlocked ? Color.red : (isSelected ? Color.accentColor : Color.blue))
                                        .foregroundStyle(.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .padding(4)
                                }
                                .frame(width: slotRect.width, height: slotRect.height)
                                .contentShape(Rectangle())
                                .gesture(slotDrag(idx, fitSize: fitSize, resizing: false))
                                .overlay(alignment: .bottomTrailing) {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 14, height: 14)
                                        .padding(4)
                                        .highPriorityGesture(slotDrag(idx, fitSize: fitSize, resizing: true))
                                        .accessibilityLabel("Đổi kích thước ô \(idx + 1)")
                                }
                                .offset(x: slotRect.minX, y: slotRect.minY)
                                .onTapGesture { selectedSlotIndex = idx }
                            }
                        }
                        .frame(width: fitSize.width, height: fitSize.height)
                        .offset(x: originX, y: originY)
                    }
                    .padding(14)
                } else {
                    ProgressView("Đang dựng bản xem trước…")
                }
            }
        }
    }

    private func calculateAspectFitSize(contentWidth: CGFloat, contentHeight: CGFloat, containerSize: CGSize) -> CGSize {
        guard contentWidth > 0, contentHeight > 0, containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let scale = min(containerSize.width / contentWidth, containerSize.height / contentHeight)
        return CGSize(width: contentWidth * scale, height: contentHeight * scale)
    }

    // MARK: Inspector Panel

    private var inspectorPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Tên khung
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tên khung").font(.subheadline.weight(.medium))
                    TextField("Tên khung", text: $frameName)
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                if !hasAlpha {
                    // Chọn bố cục
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bố cục").font(.subheadline.weight(.medium))
                        Picker("", selection: $selectedLayout) {
                            ForEach(FrameImportLayoutKind.allCases) { layout in
                                Text(layout.rawValue).tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedLayout) { _, newLayout in
                            onLayoutChanged(newLayout)
                        }

                        // Layout Diagram
                        layoutDiagram(selectedLayout)
                            .frame(height: 60)
                            .frame(maxWidth: .infinity)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(.top, 4)
                    }

                    Divider()

                }

                if !hasAlpha || !slots.isEmpty {
                    DisclosureGroup("Chỉnh vị trí ô", isExpanded: $showManualControls) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Chỉnh ô ảnh").font(.subheadline.weight(.semibold))
                                Spacer()
                                Picker("Ô", selection: $selectedSlotIndex) {
                                    ForEach(0..<slots.count, id: \.self) { i in
                                        Text("Ô \(i + 1)").tag(i)
                                    }
                                }
                                .frame(width: 90)
                            }

                            if selectedSlotIndex >= 0 && selectedSlotIndex < slots.count {
                                let curSlot = slots[selectedSlotIndex]
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Vị trí X").font(.caption)
                                        Spacer()
                                        Text(String(format: "%.1f%%", curSlot.x * 100)).font(.caption.monospacedDigit())
                                    }
                                    Slider(value: Binding(
                                        get: { curSlot.x },
                                        set: { updateSlot(selectedSlotIndex, x: $0) }
                                    ), in: 0...0.9)

                                    HStack {
                                        Text("Vị trí Y").font(.caption)
                                        Spacer()
                                        Text(String(format: "%.1f%%", curSlot.y * 100)).font(.caption.monospacedDigit())
                                    }
                                    Slider(value: Binding(
                                        get: { curSlot.y },
                                        set: { updateSlot(selectedSlotIndex, y: $0) }
                                    ), in: 0...0.9)

                                    HStack {
                                        Text("Chiều rộng").font(.caption)
                                        Spacer()
                                        Text(String(format: "%.1f%%", curSlot.width * 100)).font(.caption.monospacedDigit())
                                    }
                                    Slider(value: Binding(
                                        get: { curSlot.width },
                                        set: { updateSlot(selectedSlotIndex, width: $0) }
                                    ), in: 0.05...1.0)

                                    HStack {
                                        Text("Chiều cao").font(.caption)
                                        Spacer()
                                        Text(String(format: "%.1f%%", curSlot.height * 100)).font(.caption.monospacedDigit())
                                    }
                                    Slider(value: Binding(
                                        get: { curSlot.height },
                                        set: { updateSlot(selectedSlotIndex, height: $0) }
                                    ), in: 0.05...1.0)
                                }
                            }

                            HStack(spacing: 8) {
                                Button("Tự căn lại") {
                                    runAutoAlignment(layout: selectedLayout)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if !hasAlpha {
                                    Button("Đặt lại mẫu") {
                                        slots = PNGAutoAlignmentService.defaultSlots(for: selectedLayout)
                                        slotIDs = slots.map { _ in IDFactory.new() }
                                        isAutoAligned = false
                                        requiresInspection = false
                                        inspectionReason = nil
                                        updateCompositePreview()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Divider()

                // Thông tin tệp
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thông tin tệp").font(.subheadline.weight(.semibold))
                    Text("Kích thước: \(canvasWidth) × \(canvasHeight) px").font(.caption).foregroundStyle(.secondary)
                    Text("Định dạng: \(isPNG ? "PNG" : "JPEG")\(hasAlpha ? " (có alpha)" : " (ảnh nền)")").font(.caption).foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func layoutDiagram(_ layout: FrameImportLayoutKind) -> some View {
        switch layout {
        case .grid2x2:
            HStack(spacing: 6) {
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: 24, height: 20)
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: 24, height: 20)
                }
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: 24, height: 20)
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: 24, height: 20)
                }
                Text("Lưới 2 hàng 2 cột, đánh số từ trái sang phải, trên xuống dưới")
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 4)
            }
            .padding(6)
        case .strip1x4:
            HStack(spacing: 6) {
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: 32, height: 10)
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: 32, height: 10)
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: 32, height: 10)
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: 32, height: 10)
                }
                Text("Dải dọc 4 ảnh xếp từ trên xuống dưới")
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 4)
            }
            .padding(6)
        }
    }

    // MARK: Error State View

    private func errorStateView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Không thể nhập tệp")
                .font(.headline)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            HStack(spacing: 12) {
                if currentIndex < urls.count - 1 {
                    Button("Bỏ qua tệp này") {
                        skipCurrentFile()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Dừng nhập") {
                        finishAndDismiss()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Đóng") {
                        finishAndDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("Chỉnh bố cục…") {
                openInFrameEditor()
            }
            .buttonStyle(.bordered)
            .disabled(currentImage == nil || isSaving)
            .help("Mở trình biên tập khung nâng cao để chỉnh chi tiết các lớp và tỷ lệ")

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let reason = saveBlockReason, !isSaving {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if isRetryingSave, let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                } else if pendingSlotCount > 0 {
                    Text("Còn \(pendingSlotCount) ô cần xem lại. Xác nhận sẽ giữ các vùng đó như trong bản xem trước.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if beforeBulkApproval != nil && compositePreview != nil {
                        Button("Hoàn tác xác nhận") {
                            guard let previous = beforeBulkApproval, let clarityResult else { return }
                            clarityApprovals = clarityResult.retained(previous)
                            beforeBulkApproval = nil
                            saveError = nil
                        }
                        .disabled(isSaving)
                    }
                    if isSaving {
                        ProgressView().controlSize(.small)
                        Text("Đang lưu…").font(.caption)
                    }
                    Button { saveAndUse() } label: {
                        Label(primarySaveTitle, systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saveBlockReason != nil || isSaving)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // Each generated slot has a distinct capture index. Edited frames return through the chooser.
    private var requiredPhotoCount: Int { slots.count }

    private var saveTitle: String {
        guard let count = sessionPhotoCount else {
            return urls.count > 1 && currentIndex < urls.count - 1 ? "Lưu và tiếp tục" : "Lưu khung"
        }
        if count == requiredPhotoCount { return "Lưu và dùng cho phiên này" }
        return count > requiredPhotoCount ? "Lưu khung và chọn ảnh" : "Lưu khung"
    }

    private var pendingSlotCount: Int {
        clarityResult?.pending(clarityApprovals).count ?? 0
    }

    private var primarySaveTitle: String {
        if isRetryingSave { return "Thử lưu lại" }
        guard pendingSlotCount > 0 else { return saveTitle }
        if sessionPhotoCount == requiredPhotoCount { return "Xác nhận, lưu và dùng cho phiên này" }
        if let count = sessionPhotoCount, count > requiredPhotoCount { return "Xác nhận, lưu và chọn ảnh" }
        if sessionPhotoCount == nil, currentIndex + 1 < urls.count { return "Xác nhận, lưu và tiếp tục" }
        return "Xác nhận và lưu khung"
    }

    private var saveBlockReason: String? {
        if fileError != nil { return "Không thể đọc tệp khung." }
        if currentImage == nil { return "Đang đọc tệp khung…" }
        if frameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Nhập tên khung để lưu." }
        if slots.isEmpty || requiresInspection { return "Hãy xác nhận bố cục các ô ảnh." }
        if let issue = FrameValidator.validate(canvasWidth: canvasWidth, canvasHeight: canvasHeight, slots: frameSlots,
                                               hasBackground: !hasAlpha, hasForeground: hasAlpha,
                                               backgroundColorHex: "#FFFFFFFF").first { return issue.message }
        if let clarityError { return clarityError }
        if !blockedSlots.isEmpty { return "Lớp phủ che kín ô \(blockedSlots.map(String.init).joined(separator: ", "))." }
        if (hasAlpha || sessionPhotoCount == requiredPhotoCount) && compositePreview == nil {
            return "Đang dựng bản xem trước…"
        }
        if hasAlpha && (clarityResult?.slots.isEmpty != false ||
                        clarityResult?.slots.count != slots.count) { return "Chưa có kết quả kiểm tra ô ảnh." }
        return nil
    }

    // MARK: Actions & Logic

    private func loadCurrentFile() {
        guard currentIndex < urls.count else {
            finishAndDismiss()
            return
        }
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let url = urls[currentIndex]
        invalidateCompositePreview()
        fileError = nil
        alpha = nil
        hasAlpha = false
        detected = nil
        currentImage = nil
        imageOrientation = nil
        currentData = nil
        slots = []
        slotIDs = []
        clarityEdits = []
        clarityApprovals = [:]
        failedSave = nil
        saveError = nil
        dragOrigin = nil
        selectedSlotIndex = 0
        showManualControls = false
        compositePreview = nil
        frameName = url.deletingPathExtension().lastPathComponent

        loadTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > ResourceLimits.maxAssetBytes {
                    throw AppError.resourceLimitExceeded("Tệp ảnh vượt giới hạn dung lượng")
                }
                let data = try Data(contentsOf: url)
                let validated = try AssetStore.validatedFrameImport(data, minimumDimension: ResourceLimits.canvasMin)
                let detection = validated.mediaType == "image/png"
                    ? PNGAutoAlignmentService.detectOpenings(validated.image) : nil
                let alpha = detection.flatMap { result in
                    result.pngStatus == .opaque
                        ? nil : PNGAutoAlignmentService.AlphaGrid(image: validated.image)
                }
                return (data, validated, alpha, detection)
            }
            do {
                let (data, validated, grid, result) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, loadGeneration == generation else { return }
                currentData = data
                currentImage = validated.image
                imageOrientation = validated.orientation
                canvasWidth = validated.width
                canvasHeight = validated.height
                isPNG = validated.mediaType == "image/png"
                alpha = grid
                hasAlpha = result.map { $0.pngStatus != .opaque } ?? false
                detected = hasAlpha ? result : nil
                selectedLayout = Double(validated.width) / Double(validated.height) < 0.65 ? .strip1x4 : .grid2x2
                runAutoAlignment(layout: selectedLayout)
            } catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                let message = (error as? AppError)?.message ?? error.localizedDescription
                fileError = "\(url.lastPathComponent): \(message)"
            }
        }
    }

    private func onLayoutChanged(_ layout: FrameImportLayoutKind) {
        runAutoAlignment(layout: layout)
    }

    private func runAutoAlignment(layout: FrameImportLayoutKind) {
        guard currentImage != nil else { return }
        let result = detected ?? PNGAutoAlignmentService.align(alpha: alpha, layout: layout)
        slots = result.slots
        slotIDs = slots.map { _ in IDFactory.new() }
        clarityEdits = []
        clarityApprovals = [:]
        selectedSlotIndex = 0
        isAutoAligned = result.isAutoAligned
        requiresInspection = result.requiresInspection
        inspectionReason = result.inspectionReason
        updateCompositePreview()
    }

    private func slotDrag(_ index: Int, fitSize: CGSize, resizing: Bool) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard slots.indices.contains(index), fitSize.width > 0, fitSize.height > 0 else { return }
                selectedSlotIndex = index
                if dragOrigin == nil { dragOrigin = slots[index] }
                guard let start = dragOrigin else { return }
                let dx = value.translation.width / fitSize.width
                let dy = value.translation.height / fitSize.height
                if resizing {
                    updateSlot(index, width: start.width + dx, height: start.height + dy)
                } else {
                    updateSlot(index, x: start.x + dx, y: start.y + dy)
                }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func updateSlot(_ index: Int, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil) {
        guard index >= 0 && index < slots.count else { return }
        var s = slots[index]
        let old = s
        if let x { s.x = max(0, min(1 - s.width, x)) }
        if let y { s.y = max(0, min(1 - s.height, y)) }
        if let width {
            s.width = hasAlpha ? min(1.0 - s.x, max(1.0 / Double(canvasWidth), width))
                : max(0.05, min(1.0 - s.x, width))
        }
        if let height {
            s.height = hasAlpha ? min(1.0 - s.y, max(1.0 / Double(canvasHeight), height))
                : max(0.05, min(1.0 - s.y, height))
        }
        guard s != old else { return }
        let previous = frameSlots
        slots[index] = s
        clarityEdits = SlotClarityApprovals.retained(clarityEdits, from: previous, to: frameSlots,
                                                   canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        clarityApprovals = SlotClarityApprovals.retained(clarityApprovals, from: previous, to: frameSlots,
                                                       canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        updateCompositePreview()
    }

    private var frameSlots: [FrameSlot] {
        slots.enumerated().map { index, slot in
            FrameSlot(id: slotIDs[index], captureIndex: index + 1, x: slot.x, y: slot.y, width: slot.width, height: slot.height,
                      zOrder: index, maskType: .rectangle, cornerRadius: 0, defaultCropMode: .autoFace)
        }
    }

    private var previewSnapshot: FrameSnapshot {
        let layer = SnapshotLayer(assetID: "prepared-import", placement: hasAlpha ? .stretchToCanvas : .aspectFill, imageOrientation: imageOrientation)
        return FrameSnapshot(sourceFrameID: nil, sourceFrameRevisionID: nil,
                             canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                             background: hasAlpha ? nil : layer, foreground: hasAlpha ? layer : nil,
                             backgroundColorHex: "#FFFFFFFF", slots: frameSlots.map(SnapshotSlot.init(from:)),
                             snapshotHash: "import-preview")
    }

    private func openClarityReview() {
        guard let currentData, hasAlpha, !requiresInspection, !slots.isEmpty, !isSaving else { return }
        clarityReview = FrameClaritySheet.ImportInput(name: frameName, original: currentData,
            snapshot: previewSnapshot, edits: clarityEdits, approvals: clarityApprovals,
            automatic: clarityAutomatic, currentResult: clarityResult, importGeneration: previewGeneration)
    }

    private struct ImportPreview {
        let image: CGImage
        let clarity: PNGSlotClarity.Result?
        let automatic: PNGSlotClarity.Result?
        let blocked: [Int]?
    }

    private func updateCompositePreview(approved: PNGSlotClarity.Result? = nil,
                                        automatic approvedAutomatic: PNGSlotClarity.Result? = nil) {
        invalidateCompositePreview()
        guard let originalImage = currentImage, let data = currentData else { return }
        if hasAlpha && (slots.isEmpty || requiresInspection) { return }
        previewGeneration += 1
        let generation = previewGeneration
        let isOverlay = hasAlpha
        let width = canvasWidth
        let height = canvasHeight
        let snapshot = previewSnapshot
        let slots = snapshot.slots
        let configuredSlots = frameSlots
        let edits = clarityEdits
        let defaults = env.settings.sessionDefaultsSnapshot()
        let sessionDetail = sessionPhotoCount == requiredPhotoCount ? sessionDetail : nil
        let builder = env.renderBuilder
        if isOverlay { clarityProgress = "Đang kiểm tra \(slots.count) ô ảnh…" }
        let report: @Sendable (Int, Int) -> Void = { index, count in
            Task { @MainActor in
                if previewGeneration == generation, previewTask != nil {
                    clarityProgress = "Đang xử lý ô \(index)/\(count)"
                }
            }
        }
        previewTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () throws -> ImportPreview in
                let clarity: PNGSlotClarity.Result?
                let automatic: PNGSlotClarity.Result?
                let image: CGImage
                if isOverlay {
                    let result: PNGSlotClarity.Result
                    if let approved, let approvedAutomatic {
                        automatic = approvedAutomatic
                        result = approved
                    } else {
                        let base = try PNGSlotClarity.prepare(data: data, snapshot: snapshot, progress: report)
                        automatic = base
                        result = try PNGSlotClarity.refine(data: data, snapshot: snapshot, automatic: base,
                                                           edits: edits)
                    }
                    guard let cleaned = CGImage.createFrom(data: result.data) else { throw AppError.frameFileCorrupt }
                    clarity = result
                    image = cleaned
                } else {
                    clarity = nil
                    automatic = nil
                    image = originalImage
                }
                try Task.checkCancellation()
                let blocked: [Int]?
                if isOverlay {
                    let layout = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: width, canvasHeight: height,
                                               foregroundPlacement: .stretchToCanvas)
                    blocked = try PNGAutoAlignmentService.blockedSlots(overlay: image, draft: layout, slots: configuredSlots)
                } else {
                    blocked = nil
                }
                guard let layer = snapshot.foreground ?? snapshot.background else { throw AppError.missingFrameAssets }
                let scale = min(1, 1024.0 / Double(max(width, height)))
                let options = RenderOptions(targetWidth: max(1, Int((Double(width) * scale).rounded())),
                                            targetHeight: max(1, Int((Double(height) * scale).rounded())),
                                            transparentBackground: isOverlay)
                if var draft = sessionDetail {
                    let order = draft.currentRevisions(includeUnassigned: true)
                        .filter { $0.value.state == .available }.keys.sorted()
                    let assigned = try snapshot.assigningPhotos(in: order)
                    draft.session.defaults.selectedCaptureOrder = order
                    draft.snapshot = assigned
                    draft.placements = [:]
                    var model = await builder.buildModel(detail: draft, targetWidth: options.targetWidth,
                                                         targetHeight: options.targetHeight,
                                                         transparentBackground: isOverlay)
                    guard model.sources.count == order.count else {
                        throw AppError.invalidState("Không thể dựng bản xem trước từ ảnh của phiên.")
                    }
                    model.assetImages[layer.assetID] = image
                    return ImportPreview(image: try CompositeRenderer.render(model: model), clarity: clarity, automatic: automatic, blocked: blocked)
                }
                let sources = Dictionary(uniqueKeysWithValues: slots.compactMap { slot in
                    SampleImageFactory.shared.sample(index: slot.captureIndex, size: CGSize(width: 400, height: 400))
                        .map { (slot.captureIndex, RenderSource(image: $0)) }
                })
                let model = CompositionModel(snapshot: snapshot, sources: sources, faces: [:], defaults: defaults,
                                             overrides: [:], placements: [:],
                                             cropModes: [:], assetImages: [layer.assetID: image], options: options)
                return ImportPreview(image: try CompositeRenderer.render(model: model), clarity: clarity, automatic: automatic, blocked: blocked)
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, previewGeneration == generation else { return }
                compositePreview = result.image
                clarityResult = result.clarity
                clarityAutomatic = result.automatic
                clarityApprovals = result.clarity?.retained(clarityApprovals) ?? [:]
                if let blocked = result.blocked { blockedSlots = blocked }
            } catch {
                guard !Task.isCancelled, previewGeneration == generation else { return }
                clarityError = (error as? AppError)?.message ?? error.localizedDescription
            }
            previewTask = nil
            clarityProgress = nil
        }
    }

    private func invalidateCompositePreview() {
        previewGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        compositePreview = nil
        clarityResult = nil
        clarityAutomatic = nil
        blockedSlots = []
        beforeBulkApproval = nil
        saveError = nil
        clarityError = nil
        clarityProgress = nil
    }

    private struct SavePayload: Equatable, Sendable {
        let name: String
        let data: Data
        let mediaType: String
        let role: AssetKind
        let categoryID: String?
        let slots: [FrameSlot]
    }

    private struct SaveAttempt {
        let id = IDFactory.new()
        let payload: SavePayload
    }

    private var savePayload: SavePayload? {
        guard let data = hasAlpha ? clarityResult?.data : currentData else { return nil }
        return SavePayload(name: frameName.trimmingCharacters(in: .whitespacesAndNewlines), data: data,
                           mediaType: isPNG ? "image/png" : "image/jpeg",
                           role: hasAlpha ? .frameForeground : .frameBackground, categoryID: categoryID, slots: frameSlots)
    }

    private var isRetryingSave: Bool {
        guard saveError != nil, pendingSlotCount == 0, let failedSave, let savePayload else { return false }
        return failedSave.payload == savePayload
    }

    private func saveAndUse() {
        guard !isSaving, saveBlockReason == nil, let payload = savePayload else { return }
        if let result = clarityResult {
            let approved = result.approving(clarityApprovals)
            guard result.pending(approved).isEmpty else { return }
            if approved != clarityApprovals, beforeBulkApproval == nil {
                beforeBulkApproval = clarityApprovals
            }
            clarityApprovals = approved
        }
        let attempt = failedSave.flatMap { $0.payload == payload ? $0 : nil } ?? SaveAttempt(payload: payload)
        let destination = attempt.id
        let useInSession = sessionPhotoCount == requiredPhotoCount
        let repository = env.frames
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                let frame = try await Task.detached(priority: .userInitiated) {
                    try repository.createConfiguredFrame(name: payload.name, imageData: payload.data,
                        mediaType: payload.mediaType, role: payload.role, categoryID: payload.categoryID,
                        slots: payload.slots, retryID: destination)
                }.value
                failedSave = nil
                beforeBulkApproval = nil
                didSave(frame, applyToSession: useInSession)
            } catch {
                failedSave = attempt
                saveError = "Không thể lưu khung: \((error as? AppError)?.message ?? error.localizedDescription)"
            }
        }
    }

    private func skipCurrentFile() {
        if currentIndex < urls.count - 1 {
            currentIndex += 1
            loadCurrentFile()
        } else {
            finishAndDismiss()
        }
    }

    private func didSave(_ frame: Frame, applyToSession: Bool = false) {
        if let onSessionFrameSaved {
            onSessionFrameSaved(frame, applyToSession)
            dismiss()
            return
        }
        savedFrameIDs.append(frame.id)
        if currentIndex + 1 < urls.count {
            currentIndex += 1
            loadCurrentFile()
        } else {
            finishAndDismiss()
        }
    }

    private func openInFrameEditor() {
        guard let data = currentData else { return }
        advancedDraft = FrameEditorImportDraft(
            name: frameName, categoryID: categoryID, data: data, mediaType: isPNG ? "image/png" : "image/jpeg",
            role: hasAlpha ? .frameForeground : .frameBackground, width: canvasWidth, height: canvasHeight,
            slots: frameSlots, imageOrientation: imageOrientation, claritySHA256: hasAlpha ? Hashing.sha256Hex(data) : nil,
            clarityEdits: clarityEdits, clarityApprovals: clarityApprovals
        )
    }

    private func finishAndDismiss() {
        if !savedFrameIDs.isEmpty {
            env.showToast("Đã lưu \(savedFrameIDs.count) khung vào thư viện")
        }
        EventBus.shared.post(.frameLibraryChanged(frameID: nil))
        onFinished()
        dismiss()
    }
}
