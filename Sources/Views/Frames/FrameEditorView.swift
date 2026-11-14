import SwiftUI
import AppKit

/// Workspace F — Frame Editor (§2.7): canvas + handles + inspector + validator.
public struct FrameEditorView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: FrameEditorViewModel
    @State private var inspectorTab: EditorTab = .slot
    @State private var showCloseConfirm = false

    public enum EditorTab: String, CaseIterable {
        case canvas = "Canvas"
        case slot = "Ô ảnh"
        case layers = "Lớp"
    }

    public init(env: AppEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: FrameEditorViewModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                slotList.frame(width: 190)
                Divider()
                EditorCanvasView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector.frame(width: 290)
            }
            Divider()
            statusBar
        }
        .onAppear {
            vm.load(frameID: env.frameEditorDraft?.frameID)
        }
        .onDisappear { env.frameEditorDraft = nil }
    }

    // MARK: Toolbar (§2.7)

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                if vm.hasChanges {
                    showCloseConfirm = true
                } else {
                    env.closeFrameEditor()
                }
            } label: {
                Label("Quay lại", systemImage: "chevron.left")
            }
            .confirmationDialog("Có thay đổi chưa lưu", isPresented: $showCloseConfirm) {
                Button("Lưu") {
                    if vm.save() { env.closeFrameEditor() }
                }
                Button("Bỏ thay đổi", role: .destructive) { env.closeFrameEditor() }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("Lưu / Bỏ thay đổi / Hủy")
            }
            TextField("Tên khung", text: $vm.draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .help("Tên chỉ được lưu khi bấm Lưu")
            PrimaryButton(title: "Lưu", systemImage: "checkmark",
                          disabledReason: vm.canSave ? nil : (vm.hasChanges ? "Validator chưa pass" : "Chưa có thay đổi")) {
                if vm.save() { env.closeFrameEditor() }
            }
            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!vm.canUndo)
                .help("⌘Z Undo (một lần kéo = một Undo)")
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!vm.canRedo)
                .help("⇧⌘Z Redo")
            Divider()
            Button { vm.addSlot() } label: { Label("Thêm ô", systemImage: "plus.rectangle") }
                .help("Thêm ô ảnh (tối đa 24 ô, 12 lượt)")
            if let sel = vm.selectedSlotID {
                Button { vm.duplicateSlot(sel) } label: { Image(systemName: "plus.square.on.square") }
                    .help("Nhân bản ô")
                Button { vm.deleteSlot(sel) } label: { Image(systemName: "trash") }
                    .disabled(vm.slots.count <= 1)
                    .help("Xóa ô (giữ lại ít nhất 1 ô)")
                Menu {
                    Button("Lên trên") { vm.moveZOrder(sel, up: true) }
                    Button("Xuống dưới") { vm.moveZOrder(sel, up: false) }
                } label: {
                    Image(systemName: "square.3.layers.3d")
                }
                .help("Z-order")
            }
            Divider()
            Toggle(isOn: $vm.showGuides) { Image(systemName: "ruler") }
                .toggleStyle(.button).help("Guides/ruler")
            Toggle(isOn: $vm.snapEnabled) { Image(systemName: "magnet") }
                .toggleStyle(.button).help("Snap 6–8pt")
            Spacer()
            Button { vm.regeneratePreview() } label: { Label("Preview", systemImage: "eye") }
                .help("Preview dùng cùng renderer geometry với export (I-05)")
        }
        .padding(10)
    }

    // MARK: Slot list (z-order §7.2)

    private var slotList: some View {
        List {
            Section("Cấu trúc ô (z-order)") {
                ForEach(vm.slots.sorted { $0.zOrder > $1.zOrder }) { slot in
                    HStack {
                        Text("Ô #\(slot.zOrder + 1)")
                        Spacer()
                        Text("Ảnh \(slot.captureIndex)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let issues = issueFor(slot) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(issues.message)
                        }
                    }
                    .tag(slot.id)
                    .background(vm.selectedSlotID == slot.id ? Color.accentColor.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.selectedSlotID = slot.id }
                }
            }
        }
        .listStyle(.plain)
    }

    private func issueFor(_ slot: FrameSlot) -> ValidationIssue? {
        vm.validationIssues.first { $0.slotID == slot.id }
    }

    // MARK: Inspector (tabs §2.7)

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $inspectorTab) {
                ForEach(EditorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)
            ScrollView {
                switch inspectorTab {
                case .canvas: canvasInspector
                case .slot: slotInspector
                case .layers: layersInspector
                }
            }
        }
    }

    private var canvasInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Canvas (pixel output)").font(.headline)
            HStack {
                Stepper(value: Binding(get: { vm.canvasWidth },
                                       set: { vm.setCanvas(width: $0, height: vm.canvasHeight) }),
                        in: ResourceLimits.canvasMin...ResourceLimits.canvasMax, step: 50) {
                    Text("Rộng: \(vm.canvasWidth)")
                }
            }
            HStack {
                Stepper(value: Binding(get: { vm.canvasHeight },
                                       set: { vm.setCanvas(width: vm.canvasWidth, height: $0) }),
                        in: ResourceLimits.canvasMin...ResourceLimits.canvasMax, step: 50) {
                    Text("Cao: \(vm.canvasHeight)")
                }
            }
            Text("Tối đa \(Int(ResourceLimits.maxMegapixels))MP · 256–8192 px mỗi chiều")
                .font(.caption).foregroundStyle(.secondary)
            ColorPicker("Màu nền canvas", selection: Binding(
                get: { Color(ColorHex.toCGColor(vm.backgroundColorHex)) },
                set: { vm.setBackgroundColor($0.toHex()) }))
            if vm.previewImage != nil {
                Text("Preview (mẫu):").font(.subheadline.weight(.medium))
                ImageDataView(image: vm.previewImage)
                    .frame(maxHeight: 220)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var slotInspector: some View {
        if let sel = vm.selectedSlotID, let slot = vm.slots.first(where: { $0.id == sel }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ô #\(slot.zOrder + 1)").font(.headline)
                NumericRow(label: "X", value: slot.x) { v in
                    var s = slot; s.x = v; vm.updateSlotFromInspector(s)
                }
                NumericRow(label: "Y", value: slot.y) { v in
                    var s = slot; s.y = v; vm.updateSlotFromInspector(s)
                }
                NumericRow(label: "W", value: slot.width) { v in
                    var s = slot; s.width = max(v, 0.01); vm.updateSlotFromInspector(s)
                }
                NumericRow(label: "H", value: slot.height) { v in
                    var s = slot; s.height = max(v, 0.01); vm.updateSlotFromInspector(s)
                }
                NumericRow(label: "Rotation°", value: slot.rotationDegrees, range: -180...180) { v in
                    var s = slot; s.rotationDegrees = v; vm.updateSlotFromInspector(s)
                }
                Stepper(value: Binding(get: { slot.captureIndex },
                                       set: { var s = slot; s.captureIndex = $0; vm.updateSlotFromInspector(s) }),
                        in: 1...ResourceLimits.maxCaptureIndices) {
                    Text("Lượt chụp: \(slot.captureIndex)")
                }
                Picker("Mask", selection: Binding(get: { slot.maskType },
                                                  set: { var s = slot; s.maskType = $0; vm.updateSlotFromInspector(s) })) {
                    ForEach(MaskType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if slot.maskType == .roundedRectangle {
                    HStack {
                        Text("Bo góc")
                        Slider(value: Binding(get: { slot.cornerRadius },
                                              set: { var s = slot; s.cornerRadius = $0; vm.updateSlotFromInspector(s) }),
                               in: 0...0.5)
                        Text(String(format: "%.2f", slot.cornerRadius)).monospacedDigit()
                    }
                }
                Picker("Crop mặc định", selection: Binding(get: { slot.defaultCropMode },
                                                           set: { var s = slot; s.defaultCropMode = $0; vm.updateSlotFromInspector(s) })) {
                    ForEach(CropMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            .padding(12)
        } else {
            EmptyStateView(systemImage: "square.dashed",
                           title: "Chưa chọn ô ảnh",
                           message: "Nhấp vào ô trên canvas hoặc trong danh sách để chỉnh thông số.")
        }
    }

    private var layersInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lớp (§7.2)").font(.headline)
            Text("Thứ tự render: Nền → Ô ảnh (zOrder) → Foreground overlay")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Background").font(.subheadline.weight(.medium))
            if vm.backgroundAssetID != nil {
                Text("Đã có ảnh nền").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Dùng màu nền canvas").font(.caption).foregroundStyle(.secondary)
            }
            Button("Nhập ảnh nền…") {
                chooseImage(role: .frameBackground)
            }
            Picker("Đặt nền", selection: Binding(get: { vm.backgroundPlacement },
                                                 set: { vm.setPlacement(kind: $0, isBackground: true) })) {
                ForEach([PlacementKind.aspectFill, .aspectFit], id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            Text("Foreground overlay").font(.subheadline.weight(.medium))
            if vm.foregroundAssetID != nil {
                Text("Đã có overlay").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Chưa có (khuyến nghị PNG alpha)").font(.caption).foregroundStyle(.secondary)
            }
            Button("Nhập foreground…") {
                chooseImage(role: .frameForeground)
            }
            Picker("Đặt overlay", selection: Binding(get: { vm.foregroundPlacement },
                                                     set: { vm.setPlacement(kind: $0, isBackground: false) })) {
                ForEach([PlacementKind.stretchToCanvas, .aspectFit, .fillCrop], id: \.self) { Text($0.label).tag($0) }
            }
        }
        .padding(12)
    }

    private func chooseImage(role: AssetKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            vm.importLayer(url: url, role: role)
        }
    }

    private var statusBar: some View {
        HStack {
            if vm.validationIssues.isEmpty {
                Label("Validator: hợp lệ", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Menu {
                    ForEach(vm.validationIssues) { issue in
                        Text("\(issue.code): \(issue.message)")
                    }
                } label: {
                    Label("\(vm.validationIssues.count) vấn đề — bấm xem chi tiết", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .help("Lưu bị chặn cho tới khi pass F-VAL-01..08")
            }
            Spacer()
            Text("Zoom: \(Int(vm.zoom * 100))%").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct NumericRow: View {
    var label: String
    var value: Double
    var range: ClosedRange<Double> = -1...2
    var onChange: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onAppear { text = String(format: "%.3f", value) }
                .onChange(of: value) { newValue in
                    if !focused { text = String(format: "%.3f", newValue) }
                }
                .onSubmit { commit() }
                .onExitCommand { // Esc revert trường đang nhập (§7.4)
                    text = String(format: "%.3f", value)
                    focused = false
                }
            Spacer()
        }
    }

    private func commit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(normalized), v.isFinite else {
            text = String(format: "%.3f", value)
            return
        }
        onChange(min(max(v, range.lowerBound), range.upperBound))
    }
}

extension Color {
    func toHex() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02XFF", r, g, b)
    }
}

// MARK: - Canvas tương tác (drag/resize/rotate §7.4)

public struct EditorCanvasView: View {
    @ObservedObject var vm: FrameEditorViewModel
    @State private var dragStart: FrameSlot?
    @State private var dragMode: DragMode = .none
    @State private var lastDragLocation: CGPoint = .zero

    enum DragMode: Equatable { case none, move, resize(Int), rotate }

    public init(vm: FrameEditorViewModel) { self.vm = vm }

    public var body: some View {
        GeometryReader { geo in
            let fit = min(geo.size.width / Double(vm.canvasWidth), geo.size.height / Double(vm.canvasHeight)) * 0.92 * vm.zoom
            let cw = Double(vm.canvasWidth) * fit
            let ch = Double(vm.canvasHeight) * fit
            let origin = CGPoint(x: (geo.size.width - cw) / 2, y: (geo.size.height - ch) / 2)
            ZStack {
                // Canvas nền
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(ColorHex.toCGColor(vm.backgroundColorHex)))
                    .frame(width: cw, height: ch)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
                    .position(x: origin.x + cw / 2, y: origin.y + ch / 2)
                // Slots
                ForEach(vm.slots) { slot in
                    slotView(slot, fit: fit, origin: origin)
                }
                // Guides
                if vm.showGuides {
                    Canvas { ctx, size in
                        var line = Path()
                        line.move(to: CGPoint(x: size.width / 2, y: 0))
                        line.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                        ctx.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                        var line2 = Path()
                        line2.move(to: CGPoint(x: 0, y: size.height / 2))
                        line2.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        ctx.stroke(line2, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(backgroundTap)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func slotView(_ slot: FrameSlot, fit: Double, origin: CGPoint) -> some View {
        let rect = slotPixelRect(slot, fit: fit, origin: origin)
        let isSelected = vm.selectedSlotID == slot.id
        ZStack {
            // Thân slot
            RoundedRectangle(cornerRadius: slot.maskType == .ellipse ? min(rect.width, rect.height) / 2 : 2)
                .fill(Color.white.opacity(0.35))
                .frame(width: rect.width, height: rect.height)
                .overlay(
                    RoundedRectangle(cornerRadius: slot.maskType == .ellipse ? min(rect.width, rect.height) / 2 : 2)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary, style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1, dash: [5, 3]))
                )
                .overlay(
                    Text("Ảnh \(slot.captureIndex)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                )
                .rotationEffect(.degrees(slot.rotationDegrees))
                .position(x: rect.midX, y: rect.midY)
            if isSelected {
                // 8 resize handles + rotation handle (§7.4)
                ForEach(0..<8, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .position(handlePosition(i, rect: rect, rotation: slot.rotationDegrees))
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    if dragMode == .none || dragStart == nil {
                                        dragStart = slot
                                        dragMode = .resize(i)
                                        vm.beginUndoGroup()
                                    }
                                    handleResize(base: dragStart ?? slot, index: i,
                                                 location: value.location, fit: fit, origin: origin)
                                }
                                .onEnded { _ in dragStart = nil; dragMode = .none }
                        )
                }
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 12, height: 12)
                    .position(rotationHandlePosition(rect: rect, rotation: slot.rotationDegrees))
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragMode == .none || dragStart == nil {
                                    dragStart = slot
                                    dragMode = .rotate
                                    vm.beginUndoGroup()
                                }
                                handleRotate(base: dragStart ?? slot, location: value.location, rect: rect)
                            }
                            .onEnded { _ in dragStart = nil; dragMode = .none }
                    )
                    .help("Xoay (-180..180°)")
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragMode == .none || dragStart == nil {
                        dragStart = slot
                        dragMode = .move
                        vm.selectedSlotID = slot.id
                        vm.beginUndoGroup()
                    }
                    handleMove(base: dragStart ?? slot, translation: value.translation, fit: fit)
                }
                .onEnded { _ in dragStart = nil; dragMode = .none }
        )
        .onTapGesture { vm.selectedSlotID = slot.id }
    }

    private var backgroundTap: some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { _ in
                if dragMode == .none { vm.selectedSlotID = nil }
            }
    }

    private func slotPixelRect(_ slot: FrameSlot, fit: Double, origin: CGPoint) -> CGRect {
        let w = slot.width * Double(vm.canvasWidth) * fit
        let h = slot.height * Double(vm.canvasHeight) * fit
        let x = origin.x + slot.x * Double(vm.canvasWidth) * fit
        let y = origin.y + slot.y * Double(vm.canvasHeight) * fit
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func handlePosition(_ index: Int, rect: CGRect, rotation: Double) -> CGPoint {
        let offsets: [(CGFloat, CGFloat)] = [
            (0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5)
        ]
        let (fx, fy) = offsets[index]
        let p = CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radians = rotation * Double.pi / 180
        let dx = p.x - center.x, dy = p.y - center.y
        let c = cos(radians), s = sin(radians)
        return CGPoint(x: center.x + dx * CGFloat(c) - dy * CGFloat(s),
                       y: center.y + dx * CGFloat(s) + dy * CGFloat(c))
    }

    private func rotationHandlePosition(rect: CGRect, rotation: Double) -> CGPoint {
        var p = CGPoint(x: rect.midX, y: rect.minY - 24)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radians = rotation * Double.pi / 180
        let dx = p.x - center.x, dy = p.y - center.y
        let c = cos(radians), s = sin(radians)
        p = CGPoint(x: center.x + dx * CGFloat(c) - dy * CGFloat(s),
                    y: center.y + dx * CGFloat(s) + dy * CGFloat(c))
        return p
    }

    private func handleMove(base: FrameSlot, translation: CGSize, fit: Double) {
        var s = base
        let dx = translation.width / (Double(vm.canvasWidth) * fit)
        let dy = translation.height / (Double(vm.canvasHeight) * fit)
        s.x = base.x + dx
        s.y = base.y + dy
        if vm.snapEnabled { s = applySnap(s) }
        vm.updateSlot(s)
    }

    private func handleResize(base: FrameSlot, index: Int, location: CGPoint, fit: Double, origin: CGPoint) {
        var s = base
        let cw = Double(vm.canvasWidth) * fit
        let ch = Double(vm.canvasHeight) * fit
        // Đưa con trỏ về hệ toạ độ CHƯA XOAY của slot (P3-8b): handle được vẽ ở vị trí
        // đã xoay quanh tâm slot — phải quay ngược lại để chỉnh đúng cạnh theo hướng handle.
        let center = CGPoint(x: origin.x + (base.x + base.width / 2) * cw,
                             y: origin.y + (base.y + base.height / 2) * ch)
        let radians = base.rotationDegrees * Double.pi / 180
        let dx = location.x - center.x
        let dy = location.y - center.y
        let c = CGFloat(cos(radians)), sn = CGFloat(sin(radians))
        let local = CGPoint(x: center.x + dx * c + dy * sn,
                            y: center.y - dx * sn + dy * c)
        let lx = (local.x - origin.x) / cw
        let ly = (local.y - origin.y) / ch
        switch index {
        case 0, 6, 7: // trái
            let newX = min(lx, base.x + base.width - 0.01)
            s.width = base.x + base.width - newX
            s.x = newX
        default: break
        }
        switch index {
        case 0, 1, 2: // trên
            let newY = min(ly, base.y + base.height - 0.01)
            s.height = base.y + base.height - newY
            s.y = newY
        default: break
        }
        switch index {
        case 2, 3, 4: // phải
            s.width = max(lx - base.x, 0.01)
        default: break
        }
        switch index {
        case 4, 5, 6: // dưới
            s.height = max(ly - base.y, 0.01)
        default: break
        }
        vm.updateSlot(s)
    }

    private func handleRotate(base: FrameSlot, location: CGPoint, rect: CGRect) {
        var s = base
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angle = atan2(Double(location.y - center.y), Double(location.x - center.x))
        var degrees = angle * 180 / .pi + 90
        if degrees > 180 { degrees -= 360 }
        if degrees < -180 { degrees += 360 }
        s.rotationDegrees = degrees
        vm.updateSlot(s)
    }

    /// Snap căn cạnh/tâm 6–8pt quy về normalized (§7.4).
    private func applySnap(_ slot: FrameSlot) -> FrameSlot {
        var s = slot
        let thresholdX = 7.0 / Double(vm.canvasWidth)
        let thresholdY = 7.0 / Double(vm.canvasHeight)
        let snapTargetsX: [Double] = [0, 0.5, 1]
        let snapTargetsY: [Double] = [0, 0.5, 1]
        for t in snapTargetsX {
            if abs(s.x - t) < thresholdX { s.x = t }
            if abs(s.x + s.width - t) < thresholdX { s.x = t - s.width }
            if abs(s.x + s.width / 2 - t) < thresholdX { s.x = t - s.width / 2 }
        }
        for t in snapTargetsY {
            if abs(s.y - t) < thresholdY { s.y = t }
            if abs(s.y + s.height - t) < thresholdY { s.y = t - s.height }
            if abs(s.y + s.height / 2 - t) < thresholdY { s.y = t - s.height / 2 }
        }
        return s
    }
}
