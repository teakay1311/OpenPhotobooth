import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

/// Sheet nhập khung hình từ PNG/JPG với tự căn ô, xem trước composite và hỗ trợ nhiều tệp (§4.1, §4.2, §4.3).
public struct FrameImportSheet: View {
    @ObservedObject var env: AppEnvironment
    let urls: [URL]
    let categoryID: String?
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int = 0
    @State private var frameName: String = ""
    @State private var selectedLayout: FrameImportLayoutKind = .grid2x2
    @State private var currentImage: CGImage?
    @State private var currentData: Data?
    @State private var alpha: PNGAutoAlignmentService.AlphaGrid?
    private var hasAlpha: Bool { alpha?.hasTransparency == true }
    @State private var previewTask: Task<Void, Never>?
    @State private var previewGeneration = 0
    @State private var previewPending = false
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
    @State private var savedFrameIDs: [String] = []
    @State private var isSaving: Bool = false
    @State private var showConfirmStop: Bool = false

    public init(env: AppEnvironment, urls: [URL], categoryID: String? = nil, onFinished: @escaping () -> Void) {
        self.env = env
        self.urls = urls
        self.categoryID = categoryID
        self.onFinished = onFinished
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let err = fileError {
                errorStateView(err)
            } else if currentImage != nil {
                mainContent
            } else {
                ProgressView("Đang nạp tệp…").padding(40)
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: 840, idealWidth: 960, maxWidth: 1100, minHeight: 640, idealHeight: 720, maxHeight: 860)
        .onAppear {
            loadCurrentFile()
        }
        .onDisappear { invalidateCompositePreview() }
        .sheet(item: $advancedDraft) { draft in
            FrameEditorView(env: env, imported: draft) { frame in
                advancedDraft = nil
                if let frame { didSave(frame) }
            }
            .frame(minWidth: 840, minHeight: 580)
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
                    Text("Tự căn 4 ô thành công từ vùng trong suốt của PNG")
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
                    Text("Kiểm tra vị trí ô: \(inspectionReason ?? "Chưa đạt điều kiện tự căn")")
                        .font(.caption.weight(.medium))
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

            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let preview = compositePreview {
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
                                            isSelected ? Color.accentColor.opacity(0.1) : Color.clear
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

                // Chỉnh vị trí ô
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

                        Button("Đặt lại mẫu") {
                            slots = PNGAutoAlignmentService.defaultSlots(for: selectedLayout)
                            isAutoAligned = false
                            requiresInspection = false
                            inspectionReason = nil
                            revalidateBlockage()
                            updateCompositePreview()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
            Button("Chỉnh nâng cao…") {
                openInFrameEditor()
            }
            .buttonStyle(.bordered)
            .disabled(currentImage == nil || isSaving)
            .help("Mở trình biên tập khung nâng cao để chỉnh chi tiết các lớp và tỷ lệ")

            Spacer()

            if isSaving {
                ProgressView().scaleEffect(0.8)
                Text("Đang lưu…").font(.caption).foregroundStyle(.secondary)
            }

            Button {
                saveAndUse()
            } label: {
                Label(urls.count > 1 && currentIndex < urls.count - 1 ? "Lưu và tiếp tục" : "Lưu và dùng",
                      systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canSave: Bool {
        fileError == nil && currentImage != nil && !frameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && blockedSlots.isEmpty
    }

    // MARK: Actions & Logic

    private func loadCurrentFile() {
        guard currentIndex < urls.count else {
            finishAndDismiss()
            return
        }
        let url = urls[currentIndex]
        invalidateCompositePreview()
        fileError = nil
        alpha = nil
        currentImage = nil
        currentData = nil
        compositePreview = nil
        frameName = url.deletingPathExtension().lastPathComponent

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            fileError = "Không thể đọc tệp: \(url.lastPathComponent)"
            return
        }

        // Kiểm tra magic bytes
        guard FramesViewModel.validateMagicBytes(data) else {
            fileError = "Tệp '\(url.lastPathComponent)' bị hỏng hoặc không đúng định dạng PNG/JPEG"
            return
        }

        guard let image = CGImage.createFrom(data: data) else {
            fileError = "Không thể giải mã hình ảnh từ tệp: \(url.lastPathComponent)"
            return
        }

        let w = image.width
        let h = image.height

        // Kiểm tra giới hạn canvas (§4.1)
        if w < ResourceLimits.canvasMin || w > ResourceLimits.canvasMax ||
           h < ResourceLimits.canvasMin || h > ResourceLimits.canvasMax ||
           Double(w) * Double(h) > ResourceLimits.maxMegapixels * 1_000_000 {
            fileError = "Kích thước canvas (\(w) × \(h) px) vượt giới hạn cho phép (256–8192 px, tối đa 40 MP)"
            return
        }

        currentData = data
        currentImage = image
        canvasWidth = w
        canvasHeight = h
        isPNG = data.starts(with: Data([0x89, 0x50, 0x4E, 0x47]))
        if isPNG && FramesViewModel.hasAlphaChannel(data: data) {
            alpha = PNGAutoAlignmentService.AlphaGrid(image: image)
        }

        // Tự động suy luận bố cục phù hợp dựa trên tỷ lệ canvas
        let aspect = Double(w) / Double(max(h, 1))
        if aspect < 0.65 {
            selectedLayout = .strip1x4
        } else {
            selectedLayout = .grid2x2
        }

        runAutoAlignment(layout: selectedLayout)
    }

    private func onLayoutChanged(_ layout: FrameImportLayoutKind) {
        invalidateCompositePreview()
        runAutoAlignment(layout: layout)
    }

    private func runAutoAlignment(layout: FrameImportLayoutKind) {
        guard currentImage != nil else { return }
        let result = PNGAutoAlignmentService.align(alpha: alpha, layout: layout)
        slots = result.slots
        isAutoAligned = result.isAutoAligned
        requiresInspection = result.requiresInspection
        inspectionReason = result.inspectionReason
        blockedSlots = result.blockedSlotIndices
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
        if let x { s.x = max(0, min(1 - s.width, x)) }
        if let y { s.y = max(0, min(1 - s.height, y)) }
        if let width { s.width = max(0.05, min(1.0 - s.x, width)) }
        if let height { s.height = max(0.05, min(1.0 - s.y, height)) }
        slots[index] = s
        revalidateBlockage()
        updateCompositePreview()
    }

    private func revalidateBlockage() {
        blockedSlots = hasAlpha ? alpha?.blockedSlots(slots) ?? [] : []
    }

    private var frameSlots: [FrameSlot] {
        slots.enumerated().map { index, slot in
            FrameSlot(captureIndex: index + 1, x: slot.x, y: slot.y, width: slot.width, height: slot.height,
                      zOrder: index, maskType: .rectangle, cornerRadius: 0, defaultCropMode: .autoFace)
        }
    }

    private func updateCompositePreview() {
        guard let image = currentImage else { return }
        guard previewTask == nil else {
            previewPending = true
            return
        }
        let generation = previewGeneration
        let isOverlay = hasAlpha
        let width = canvasWidth
        let height = canvasHeight
        let slots = frameSlots.map(SnapshotSlot.init(from:))
        let defaults = env.settings.sessionDefaultsSnapshot()
        previewTask = Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                let layer = SnapshotLayer(assetID: "prepared-import",
                                          placement: isOverlay ? .stretchToCanvas : .aspectFill)
                let snapshot = FrameSnapshot(sourceFrameID: nil, sourceFrameRevisionID: nil,
                                             canvasWidth: width, canvasHeight: height,
                                             background: isOverlay ? nil : layer, foreground: isOverlay ? layer : nil,
                                             backgroundColorHex: "#FFFFFFFF", slots: slots, snapshotHash: "import-preview")
                let sources = Dictionary(uniqueKeysWithValues: slots.compactMap { slot in
                    SampleImageFactory.shared.sample(index: slot.captureIndex, size: CGSize(width: 400, height: 400))
                        .map { (slot.captureIndex, RenderSource(image: $0)) }
                })
                let scale = min(1, 1024.0 / Double(max(width, height)))
                let model = CompositionModel(snapshot: snapshot, sources: sources, faces: [:], defaults: defaults,
                                             overrides: [:], placements: [:], cropModes: [:],
                                             assetImages: [layer.assetID: image],
                                             options: RenderOptions(targetWidth: max(1, Int((Double(width) * scale).rounded())),
                                                                    targetHeight: max(1, Int((Double(height) * scale).rounded()))))
                return try? CompositeRenderer.render(model: model)
            }.value
            guard !Task.isCancelled, previewGeneration == generation else { return }
            compositePreview = rendered
            previewTask = nil
            if previewPending {
                previewPending = false
                updateCompositePreview()
            }
        }
    }

    private func invalidateCompositePreview() {
        previewGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        previewPending = false
    }

    private func saveAndUse() {
        guard let data = currentData, canSave else { return }
        isSaving = true

        let name = frameName.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaType = isPNG ? "image/png" : "image/jpeg"
        let role: AssetKind = hasAlpha ? .frameForeground : .frameBackground

        do {
            let frame = try env.frames.createConfiguredFrame(
                name: name,
                imageData: data,
                mediaType: mediaType,
                role: role,
                categoryID: categoryID,
                slots: frameSlots
            )
            isSaving = false
            didSave(frame)
        } catch {
            isSaving = false
            env.showToast("Không thể lưu khung '\(name)': \((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
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

    private func didSave(_ frame: Frame) {
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
            slots: frameSlots
        )
    }

    private func finishAndDismiss() {
        if let lastID = savedFrameIDs.last {
            do {
                let frame = try env.selectFrameForCapture(lastID)
                env.requestNavigation(to: .capture)
                env.showToast("Đã nhập \(savedFrameIDs.count) khung và chọn \(frame.name) cho màn Chụp")
            } catch AppError.frameLockedDuringCapture {
                env.showToast("Đã lưu khung vào thư viện để dùng từ phiên sau")
            } catch {
                env.showToast("Đã lưu khung. Không thể chọn: \(error.localizedDescription)", kind: .warning)
            }
        }
        EventBus.shared.post(.frameLibraryChanged(frameID: nil))
        onFinished()
        dismiss()
    }
}
