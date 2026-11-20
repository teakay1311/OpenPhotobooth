import SwiftUI
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// ReviewView (§2.8, §9.3): Xem và chỉnh ảnh sau khi chụp.
/// Layout: photo strip (trên) | preview (giữa) | inspector phải (tab Màu/Làm mịn/Crop).
/// Footer: Retake / Apply to all / Reset / Đổi khung / Xuất / Chia sẻ / Hoàn thành.
public struct ReviewView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: ReviewViewModel
    @State private var photoSelection: [Int] = []
    @State private var showExportSheet = false
    @State private var showFramePicker = false
    @State private var showSharePicker = false
    @State private var shareURL: URL?
    @State private var processedExportIntentID: String?
    let sessionID: String

    public init(env: AppEnvironment, sessionID: String) {
        self.env = env
        self.sessionID = sessionID
        _vm = StateObject(wrappedValue: ReviewViewModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.missingFrameResources {
                Label("Thiếu hoặc lỗi tài nguyên khung", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).padding(8)
            } else if vm.missingPhotos > 0 {
                Label("Thiếu ảnh trong khung · \(vm.missingPhotos) ảnh", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).padding(8)
            }
            if let detail = vm.detail, let count = detail.session.pendingSelectionCount {
                selectionPanel(detail: detail, captureCount: count)
            } else {
                photoStrip
                Divider()
                HStack(spacing: 0) {
                    previewArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    inspector
                        .frame(width: 320)
                }
                Divider()
                footer.fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            env.reviewHasPendingEdits = { [weak vm] in vm?.hasPendingEdits ?? false }
            env.reviewFlushHandler = { [weak vm] in await vm?.flushPendingEdits() ?? true }
            env.reviewDiscardHandler = { [weak vm] in vm?.discardPendingEdits() }
            Task {
                let loadSuccess = await vm.load(sessionID: sessionID)
                if env.reviewContext?.openFramePicker == true && env.reviewContext?.sessionID == sessionID {
                    env.reviewContext?.openFramePicker = false
                    showFramePicker = true
                }
                if loadSuccess {
                    await handleExportIntentIfPresent()
                }
            }
        }
        .task(id: sessionID) {
            for await event in EventBus.shared.stream {
                if case .sessionChanged(let changedID, _) = event, changedID == sessionID,
                   !vm.hasPendingEdits {
                    await vm.reload()
                }
            }
        }
        .onDisappear {
            vm.cancelPreviewPipeline()
            env.reviewHasPendingEdits = nil
            env.reviewFlushHandler = nil
            env.reviewDiscardHandler = nil
            if env.reviewContext?.sessionID == sessionID {
                env.reviewContext?.exportIntentID = nil
            }
        }
        .onChange(of: sessionID) { newID in
            photoSelection = []
            Task {
                let loadSuccess = await vm.load(sessionID: newID)
                if loadSuccess {
                    await handleExportIntentIfPresent()
                }
            }
        }
        .onChange(of: vm.detail?.snapshot.id) { _ in photoSelection = [] }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(env: env, reviewVM: vm)
        }
        .sheet(isPresented: $showFramePicker) {
            if vm.detail?.session.defaults.plannedCaptureCount != nil {
                CaptureFrameChooser(env: env, sessionID: sessionID,
                                    onClose: { showFramePicker = false },
                                    onApplied: {
                    showFramePicker = false
                    Task { await vm.load(sessionID: sessionID) }
                })
                .frame(minWidth: 780, minHeight: 560)
            } else {
                FrameSwitchSheet(env: env, currentFrameID: vm.detail?.snapshot.sourceFrameID) { newFrameID in
                    Task { await vm.changeFrame(to: newFrameID) }
                }
            }
        }
    }

    private func handleExportIntentIfPresent() async {
        guard let intentID = env.reviewContext?.exportIntentID,
              env.reviewContext?.sessionID == sessionID,
              processedExportIntentID != intentID else {
            return
        }
        guard case .review(let currentSessionID) = env.route, currentSessionID == sessionID else {
            return
        }

        guard let latestDetail = try? env.sessions.getDetail(sessionID: sessionID) else {
            env.reviewContext?.exportIntentID = nil
            processedExportIntentID = intentID
            env.showToast("Không tìm thấy phiên chụp", kind: .warning)
            return
        }

        if latestDetail.session.status == .trashed || latestDetail.session.status == .purging {
            env.reviewContext?.exportIntentID = nil
            processedExportIntentID = intentID
            env.showToast("Phiên chụp đã bị đưa vào Thùng rác", kind: .warning)
            return
        }

        guard latestDetail.hasEnoughPhotos else {
            env.reviewContext?.exportIntentID = nil
            processedExportIntentID = intentID
            env.showToast("Phiên chưa đủ ảnh để xuất", kind: .warning)
            return
        }

        let matches = (vm.detail?.session.id == latestDetail.session.id)
            && (vm.detail?.session.revisionNo == latestDetail.session.revisionNo)
            && (vm.detail?.snapshot.id == latestDetail.snapshot.id)
            && (latestDetail.snapshot.id == latestDetail.session.activeFrameSnapshotID)

        if !matches {
            let loadSuccess = await vm.load(sessionID: sessionID)
            guard case .review(let curID2) = env.route, curID2 == sessionID,
                  env.reviewContext?.exportIntentID == intentID else {
                return
            }

            guard loadSuccess,
                  let latestDetail2 = try? env.sessions.getDetail(sessionID: sessionID),
                  latestDetail2.session.status != .trashed && latestDetail2.session.status != .purging,
                  latestDetail2.hasEnoughPhotos else {
                env.reviewContext?.exportIntentID = nil
                processedExportIntentID = intentID
                env.showToast("Dữ liệu phiên đã thay đổi, vui lòng mở Xuất lại", kind: .warning)
                return
            }

            let matches2 = (vm.detail?.session.id == latestDetail2.session.id)
                && (vm.detail?.session.revisionNo == latestDetail2.session.revisionNo)
                && (vm.detail?.snapshot.id == latestDetail2.snapshot.id)
                && (latestDetail2.snapshot.id == latestDetail2.session.activeFrameSnapshotID)

            guard matches2 else {
                env.reviewContext?.exportIntentID = nil
                processedExportIntentID = intentID
                env.showToast("Dữ liệu phiên đã thay đổi, vui lòng mở Xuất lại", kind: .warning)
                return
            }
        }

        guard case .review(let finalID) = env.route, finalID == sessionID,
              env.reviewContext?.exportIntentID == intentID else {
            return
        }

        env.reviewContext?.exportIntentID = nil
        processedExportIntentID = intentID
        showExportSheet = true
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                let dest = env.reviewContext?.sourceRoute ?? .library
                env.requestNavigation(to: dest)
            } label: {
                Label(env.reviewContext?.sourceRoute == .capture ? "Màn Chụp" : "Thư viện", systemImage: "chevron.left")
            }
            Text(vm.detail?.session.pendingSelectionCount == nil ? "Xem và chỉnh" : "Chọn ảnh vào khung").font(.title3.weight(.semibold))
            if let detail = vm.detail {
                Text("\(detail.committedCount)/\(detail.session.captureCount) ảnh")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if vm.isSaving {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
                Text("Đang lưu…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func selectionPanel(detail: SessionDetail, captureCount: Int) -> some View {
        let required = detail.snapshot.requiredCaptureCount
        let shots = detail.currentRevisions()
        return VStack(alignment: .leading, spacing: 12) {
            if detail.missingIndices.isEmpty {
                Text("Chọn \(required) ảnh theo thứ tự đặt vào khung. Bấm lại ảnh đã chọn để bỏ chọn.")
            } else {
                Text("Đã chụp \(detail.committedCount)/\(captureCount) ảnh. Chụp đủ lượt để chọn ảnh.")
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 12) {
                    ForEach(1...captureCount, id: \.self) { index in
                        if let revision = shots[index], revision.state == .available {
                            let position = photoSelection.firstIndex(of: index).map { $0 + 1 }
                            Button {
                                if let offset = photoSelection.firstIndex(of: index) {
                                    photoSelection.remove(at: offset)
                                } else if photoSelection.count < required {
                                    photoSelection.append(index)
                                }
                            } label: {
                                VStack(spacing: 4) {
                                    AsyncThumbView(url: try? env.sessions.fileURL(for: revision), width: 128, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(position == nil ? Color.clear : Color.accentColor, lineWidth: 2))
                                        .overlay(alignment: .topTrailing) {
                                            if position != nil {
                                                Image(systemName: "xmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .black.opacity(0.75))
                                                    .padding(6)
                                                    .accessibilityHidden(true)
                                            }
                                        }
                                    Text(position.map { "Ảnh \(index) · Ô \($0)" } ?? "Ảnh \(index)")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(position.map { "Ảnh \(index), đã chọn cho ô \($0)" } ?? "Ảnh \(index)")
                            .help(position == nil ? "Chọn ảnh" : "Bỏ chọn ảnh")
                            .accessibilityHint(position == nil ? "Điền ảnh vào ô tiếp theo" : "Bỏ chọn ảnh này")
                            .disabled(vm.isSaving || !detail.missingIndices.isEmpty ||
                                      (position == nil && photoSelection.count >= required))
                        }
                    }
                }
            }
            HStack {
                if detail.missingIndices.isEmpty {
                    Button("Đổi khung") { showFramePicker = true }
                        .disabled(vm.isSaving)
                    Spacer()
                    PrimaryButton(title: "Xác nhận \(photoSelection.count)/\(required) ảnh",
                                  systemImage: "checkmark",
                                  disabledReason: photoSelection.count == required && !vm.isSaving
                                    ? nil : "Cần chọn đủ \(required) ảnh") {
                        let order = photoSelection
                        Task { await vm.confirmPhotoSelection(order: order) }
                    }
                } else {
                    Spacer()
                    Button("Chụp tiếp") { Task { await vm.continueCapture() } }
                }
            }
        }
        .padding(16)
    }

    // MARK: Photo strip (§9.3)

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let detail = vm.detail {
                    ForEach(orderedSlots(detail), id: \.id) { slot in
                        Button {
                            vm.selectSlot(id: slot.id)
                        } label: {
                            thumbnailCell(for: slot)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("Đang tải phiên…").foregroundStyle(.secondary).padding()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(height: 72)
    }

    private func orderedSlots(_ detail: SessionDetail) -> [SnapshotSlot] {
        let order = detail.session.defaults.selectedCaptureOrder ?? detail.snapshot.requiredIndices.sorted()
        return detail.snapshot.slots.sorted {
            (order.firstIndex(of: $0.captureIndex) ?? 0, $0.zOrder)
                < (order.firstIndex(of: $1.captureIndex) ?? 0, $1.zOrder)
        }
    }

    @ViewBuilder
    private func thumbnailCell(for slot: SnapshotSlot) -> some View {
        let isSelected = vm.selectedSlotID == slot.id || (vm.selectedSlotID == nil && vm.selectedPhotoIndex == slot.captureIndex)
        let hasPhoto = vm.detail?.currentRevisions()[slot.captureIndex]?.state == .available
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                if let rev = vm.detail?.currentRevisions()[slot.captureIndex],
                   let url = try? env.sessions.fileURL(for: rev) {
                    // Decode nền + cache (P3-11b) — không decode full-res trong body mỗi render
                    AsyncThumbView(url: url, width: 60, height: 60)
                } else {
                    Image(systemName: "camera.badge.ellipsis").foregroundStyle(.secondary)
                }
            }
            .frame(width: 60, height: 60)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5))
            let position = vm.detail?.session.defaults.selectedCaptureOrder?.firstIndex(of: slot.captureIndex)
            Text(position.map { "Ô \($0 + 1) · Ảnh \(slot.captureIndex)" } ?? "Lượt \(slot.captureIndex)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lượt \(slot.captureIndex), ô \(slot.id)\(hasPhoto ? "" : ", chưa có ảnh")")
        .accessibilityValue(isSelected ? "Đang chọn" : "Chưa chọn")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Preview

    private var previewArea: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Chế độ xem", selection: Binding(
                    get: { vm.previewMode },
                    set: { vm.setPreviewMode($0) })) {
                    ForEach(ReviewViewModel.PreviewDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: true)
                .accessibilityLabel("Chế độ xem trước")

                Spacer()

                if let saveErr = vm.saveErrorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(saveErr).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(saveErr)
                        Button("Thử lưu lại") {
                            Task { await vm.retrySave() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            Divider()

            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let errMsg = vm.previewError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(errMsg)
                            .font(.headline)
                        Text("Không thể hiển thị ảnh xem trước.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else if let img = vm.previewImage {
                    Image(nsImage: NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width), height: CGFloat(img.height))))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else if vm.detail == nil {
                    ProgressView("Đang tải phiên…")
                } else {
                    VStack(spacing: 12) {
                        EmptyStateView(systemImage: "photo",
                                       title: "Chưa có ảnh",
                                       message: "Phiên chưa đủ ảnh để hiển thị. Tiếp tục chụp để hoàn tất phiên.")
                        Button("Chụp tiếp") {
                            Task { await vm.continueCapture() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $vm.inspectorTab) {
                ForEach(ReviewViewModel.ReviewTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)
            ScrollView {
                switch vm.inspectorTab {
                case .color: colorInspector
                case .crop: cropInspector
                }
            }
        }
    }

    private var colorInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Màu sắc").font(.headline)

            // Preset & Cường độ
            VStack(alignment: .leading, spacing: 6) {
                Text("Preset").font(.subheadline.weight(.medium))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                    ForEach(BuiltinPreset.all, id: \.id) { p in
                        Button {
                            vm.setPreset(p.id)
                        } label: {
                            Text(p.nameVN).font(.caption).lineLimit(1)
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(vm.draftPresetID == p.id ? .accentColor : .secondary)
                        .disabled(!vm.hasValidSelectedPhoto)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Cường độ preset").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(vm.draftPresetIntensity * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { vm.draftPresetIntensity },
                    set: { vm.setPresetIntensity($0) }), in: 0...1, onEditingChanged: vm.setColorEditing)
                .disabled(!vm.hasValidSelectedPhoto)
            }

            Divider()

            // Nhóm Ánh sáng (§2)
            VStack(alignment: .leading, spacing: 8) {
                Text("Ánh sáng").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                sliderRow("Phơi sáng", key: "exposure")
                sliderRow("Tương phản", key: "contrast")
                sliderRow("Vùng sáng", key: "highlights")
                sliderRow("Vùng tối", key: "shadows")
            }

            Divider()

            // Nhóm Màu sắc (§2)
            VStack(alignment: .leading, spacing: 8) {
                Text("Màu sắc").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                sliderRow("Độ ấm", key: "temperature")
                sliderRow("Tint (xanh lá–hồng tím)", key: "tint")
                sliderRow("Bão hòa", key: "saturation")
                sliderRow("Độ tươi", key: "vibrance")
            }

            Divider()

            // Nhóm Chi tiết / Độ nét
            VStack(alignment: .leading, spacing: 8) {
                Text("Chi tiết").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                sliderRow("Độ nét", key: "sharpness")
            }

            Divider()

            // Các lệnh: Sao chép | Dán | Áp dụng cho tất cả | Reset (§2, §4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        vm.copyColorAdjustments()
                    } label: {
                        Label("Sao chép chỉnh sửa", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.hasValidSelectedPhoto)
                    .help("Sao chép các thông số chỉnh màu của ảnh này")

                    Button {
                        Task { await vm.pasteColorAdjustments() }
                    } label: {
                        Label("Dán chỉnh sửa", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(env.copiedColorAdjustments == nil || !vm.hasValidSelectedPhoto || vm.isSaving)
                    .help(env.copiedColorAdjustments == nil ? "Chưa có thông số chỉnh màu để dán" : "Dán thông số màu vào ảnh đang chọn")
                }

                Button("Áp dụng cho tất cả ảnh") {
                    vm.applyColorToAll()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!vm.hasValidSelectedPhoto || vm.isSaving)

                Button("Đặt lại ảnh này") {
                    vm.resetThisPhoto()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!vm.hasValidSelectedPhoto || vm.isSaving)
            }
        }
        .padding(12)
    }

    private func sliderRow(_ label: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(formattedValue(for: key)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(currentValue(for: key)) },
                set: { vm.setColorValue(key, $0) }), in: -100...100, onEditingChanged: vm.setColorEditing)
            .accessibilityLabel(label)
            .accessibilityValue(formattedValue(for: key))
            .disabled(!vm.hasValidSelectedPhoto)
        }
    }

    private func formattedValue(for key: String) -> String {
        let v = Int(currentValue(for: key))
        if v > 0 { return "+\(v)" }
        return "\(v)"
    }

    private func currentValue(for key: String) -> Double {
        switch key {
        case "exposure": return (vm.draftColor.exposure ?? 0) * 100
        case "contrast": return (vm.draftColor.contrast ?? 0) * 100
        case "highlights": return (vm.draftColor.highlights ?? 0) * 100
        case "shadows": return (vm.draftColor.shadows ?? 0) * 100
        case "saturation": return (vm.draftColor.saturation ?? 0) * 100
        case "temperature": return (vm.draftColor.temperature ?? 0) * 100
        case "tint": return (vm.draftColor.tint ?? 0) * 100
        case "vibrance": return (vm.draftColor.vibrance ?? 0) * 100
        case "sharpness": return ((vm.draftColor.sharpness ?? 0) * 200) - 100
        default: return 0
        }
    }

    private var cropInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crop / Vị trí").font(.headline)
            if vm.selectedSlotID == nil {
                Text("Chọn ô ảnh trong photo strip bên trên để chỉnh vị trí.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Chế độ", selection: Binding(get: { vm.draftCropMode ?? .autoFace },
                                                    set: { vm.setCropMode($0) })) {
                    ForEach(CropMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Scale").font(.subheadline.weight(.medium))
                        Spacer()
                        Text(String(format: "%.2f", vm.draftPlacement?.scale ?? 1.0)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { vm.draftPlacement?.scale ?? 1.0 },
                        set: { vm.updatePlacement(scale: $0) }), in: 0.5...3.0, onEditingChanged: vm.setPlacementEditing)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Offset X").font(.subheadline.weight(.medium))
                    Slider(value: Binding(
                        get: { vm.draftPlacement?.offsetX ?? 0 },
                        set: { vm.updatePlacement(offsetX: $0) }), in: -0.5...0.5, onEditingChanged: vm.setPlacementEditing)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Offset Y").font(.subheadline.weight(.medium))
                    Slider(value: Binding(
                        get: { vm.draftPlacement?.offsetY ?? 0 },
                        set: { vm.updatePlacement(offsetY: $0) }), in: -0.5...0.5, onEditingChanged: vm.setPlacementEditing)
                }
                HStack(spacing: 8) {
                    Button("Căn giữa") {
                        vm.centerPlacement()
                    }
                    .help("Đặt độ lệch X, Y về 0")
                    Button("Đặt lại") {
                        vm.resetPlacement()
                    }
                    .help("Đặt lại tỉ lệ về 1.0 và độ lệch X, Y về 0")
                    Spacer()
                    Button("Căn lại theo mặt") {
                        vm.recomputeAutoFace()
                    }
                }
            }
        }
        .padding(12)
        .disabled(!vm.canEditPlacement)
    }

    // MARK: Footer (§3.3 retake, §3.4 change frame, §11 export/share/complete)

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                if let idx = vm.selectedPhotoIndex {
                    Task { await vm.retake(index: idx, keepCrop: false) }
                }
            } label: {
                Label("Chụp lại", systemImage: "arrow.clockwise")
            }
            .disabled(vm.selectedPhotoIndex == nil)
            Button {
                Task { if await vm.flushPendingEdits() { showFramePicker = true } }
            } label: {
                Label("Đổi khung", systemImage: "rectangle.3.offgrid")
            }
            if vm.missingPhotos > 0 {
                Button {
                    Task { await vm.continueCapture() }
                } label: {
                    Label("Chụp tiếp", systemImage: "camera.badge.ellipsis")
                }
            }
            Spacer()
            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!vm.canUndo)
                .help("Undo (⌘Z)")
                .keyboardShortcut("z", modifiers: .command)
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!vm.canRedo)
                .help("Redo (⇧⌘Z)")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Divider()
            Button {
                Task {
                    if await vm.flushPendingEdits() { showExportSheet = true }
                }
            } label: {
                Label("Xuất", systemImage: "square.and.arrow.down")
            }
            .disabled(!vm.canExport)
            Button {
                Task {
                    if let url = await vm.prepareShare() {
                        shareURL = url
                        showSharePicker = true
                    }
                }
            } label: {
                Label("Chia sẻ", systemImage: "square.and.arrow.up")
            }
            .disabled(!vm.canExport)
            PrimaryButton(title: "Hoàn thành", systemImage: "checkmark.circle.fill",
                          disabledReason: vm.canExport ? nil : (vm.missingFrameResources ? "Thiếu tài nguyên khung" : "Chưa đủ ảnh")) {
                Task {
                    guard await vm.complete() else { return }
                    let dest = env.reviewContext?.sourceRoute ?? .library
                    env.requestNavigation(to: dest)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .sheet(isPresented: $showSharePicker) {
            VStack(spacing: 12) {
                Text("Chia sẻ ảnh").font(.headline)
                if let url = shareURL {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                ShareSheet(items: shareURL.map { [$0] } ?? [])
                    .frame(height: 32)
                Button("Đóng") { showSharePicker = false }
            }
            .padding()
            .frame(width: 420)
        }
    }
}

/// NSSharingServicePicker wrapper — đã chuyển sang CommonViews (ShareSheet dùng nút NSButton
/// thật làm anchor để picker luôn hiện được, P2-25).

/// Sheet đổi khung trong Review (§3.4).
public struct FrameSwitchSheet: View {
    @ObservedObject var env: AppEnvironment
    let currentFrameID: String?
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var frames: [FrameCardModel] = []

    public var body: some View {
        VStack(spacing: 0) {
            Text("Chọn khung mới").font(.headline).padding(.top, 12)
            Divider().padding(.top, 8)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(frames) { card in
                        Button {
                            onSelect(card.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ImageDataView(data: card.thumbnail)
                                    .frame(height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(card.frame.name).font(.caption.weight(.medium)).lineLimit(1)
                                Text("\(card.slotCount) ảnh").font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(card.id == currentFrameID ? Color.accentColor : Color.secondary.opacity(0.25),
                                              lineWidth: card.id == currentFrameID ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            Divider()
            HStack {
                Button("Hủy") { dismiss() }
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 600, height: 480)
        .onAppear { reload() }
    }

    private func reload() {
        let list = (try? env.frames.listReadyFrames()) ?? []
        frames = list.map { f in
            let slots = f.currentRevisionID.flatMap { (try? env.frames.getSlots(revisionID: $0)) ?? [] } ?? []
            let revID = f.currentRevisionID ?? f.id
            let thumb = env.frameThumbnails.cachedThumbnail(frameID: f.id, revisionID: revID)
            return FrameCardModel(frame: f, thumbnail: thumb, slotCount: slots.count)
        }
        for f in list {
            if let revID = f.currentRevisionID {
                if env.frameThumbnails.cachedThumbnail(frameID: f.id, revisionID: revID) == nil {
                    let fid = f.id
                    Task { @MainActor in
                        if let data = await env.frameThumbnails.requestThumbnail(frameID: fid, revisionID: revID) {
                            if let idx = frames.firstIndex(where: { $0.id == fid }) {
                                frames[idx].thumbnail = data
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Bộ chọn dùng chung cho phiên chụp trước, đổi khung và Kiosk.
struct CaptureFrameChooser: View {
    @ObservedObject var env: AppEnvironment
    let sessionID: String
    var kiosk = false
    var onMissingPhotos: ((SessionDetail) -> Void)? = nil
    let onClose: () -> Void
    let onApplied: () -> Void

    @State private var detail: SessionDetail?
    @State private var frames: [FrameCardModel] = []
    @State private var frame: FrameCardModel?
    @State private var selection: [Int] = []
    @Environment(\.displayScale) private var displayScale
    @State private var viewport = CGSize.zero
    @State private var framePreview: FramePreview?
    @State private var selectionPreview: (request: PreviewSelection, image: CGImage)?
    @State private var importDetail: SessionDetail?
    @State private var importURL: URL?
    @State private var error: String?
    @State private var previewError: String?
    @State private var applying = false
    @State private var loading = true

    private var photos: [Int: PhotoRevision] {
        detail?.currentRevisions(includeUnassigned: true).filter { $0.value.state == .available } ?? [:]
    }

    private var required: Int { frame?.slotCount ?? 0 }
    private var canConfirm: Bool {
        required > 0 && selection.count == required && Set(selection).isSubset(of: Set(photos.keys))
    }

    private struct PreviewFrame: Equatable {
        let id: String
        let revision: String
        let width: Int
        let height: Int
    }

    @State private var previewRetry = 0

    private struct PreviewSelection: Equatable {
        let retry: Int
        let sessionID: String
        let sessionRevision: Int
        let frame: PreviewFrame
        let order: [Int]
        let photoIDs: [String]
    }

    private struct FramePreview {
        let request: PreviewFrame
        let snapshot: FrameSnapshot
        let image: CGImage
    }

    private var previewRequest: PreviewSelection? {
        guard let detail, let frame, let revision = frame.frame.currentRevisionID,
              viewport.width >= 1, viewport.height >= 1 else { return nil }
        let pixelScale = min(displayScale, 1600 / max(viewport.width, viewport.height))
        let width = max(1, Int((viewport.width * pixelScale).rounded()))
        let height = max(1, Int((viewport.height * pixelScale).rounded()))
        return PreviewSelection(retry: previewRetry, sessionID: detail.session.id, sessionRevision: detail.session.revisionNo,
                                frame: PreviewFrame(id: frame.id, revision: revision, width: width, height: height),
                                order: selection, photoIDs: selection.compactMap { photos[$0]?.id })
    }

    private var previewVerified: Bool {
        guard let request = previewRequest else { return false }
        return selectionPreview?.request == request
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Quay lại", action: onClose)
                    .disabled(applying)
                Text("Chọn khung").font(.title2.bold())
                Spacer()
                Button("Nhập khung PNG", systemImage: "square.and.arrow.down", action: pickPNG)
                    .disabled(loading || applying || detail == nil)
            }
            if let error {
                Text(error).foregroundStyle(.red).accessibilityLabel(error)
            }
            if loading {
                ProgressView("Đang kiểm tra ảnh…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if detail != nil {
                HSplitView {
                    frameList
                        .frame(minWidth: 220, idealWidth: 300)
                    VStack(alignment: .leading, spacing: 10) {
                        photoStrip
                        previewPane
                    }
                    .padding(.leading, 12)
                    .frame(minWidth: 390, maxWidth: .infinity)
                }
                HStack {
                    Text(status).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dùng khung này") { Task { await apply() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canConfirm || !previewVerified || applying)
                }
            } else {
                Spacer()
            }
        }
        .padding(24)
        .background(.background)
        .task { await reload() }
        .task(id: previewRequest) { await updatePreview() }
        .sheet(isPresented: Binding(get: { importURL != nil }, set: { if !$0 { importURL = nil } })) {
            if let importURL {
                FrameImportSheet(env: env, urls: [importURL], sessionPhotoCount: photos.count,
                                 sessionDetail: importDetail, onSessionFrameSaved: { imported, canApply in
                    let shown = importDetail
                    Task {
                        if canApply, let shown, let revision = imported.currentRevisionID {
                            let ids = shown.currentRevisions(includeUnassigned: true)
                                .filter { $0.value.state == .available }
                                .sorted { $0.key < $1.key }.map { $0.value.id }
                            await commit(frameID: imported.id, frameRevision: revision, detail: shown,
                                         photoIDs: ids, imported: true)
                        } else {
                            await reload(preferredFrameID: imported.id)
                        }
                    }
                }, onFinished: {})
            }
        }
    }

    private var frameList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if frames.isEmpty { Text("Chưa có khung sẵn sàng").foregroundStyle(.secondary) }
                ForEach(frames) { card in
                    Button {
                        select(card)
                    } label: {
                        HStack {
                            ChooserFrameThumbnail(env: env, frame: card.frame)
                                .frame(width: 52, height: 50)
                            VStack(alignment: .leading) {
                                Text(card.frame.name).lineLimit(2)
                                Text("\(card.slotCount) ảnh").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if frame?.id == card.id { Image(systemName: "checkmark.circle.fill") }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(frame?.id == card.id ? .isSelected : [])
                }
            }
            .padding(4)
        }
        .disabled(applying)
    }

    private var photoStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(photos.keys.sorted(), id: \.self) { index in
                    if let photo = photos[index] {
                        Button {
                            selectionPreview = nil
                            if let old = selection.firstIndex(of: index) { selection.remove(at: old) }
                            else if selection.count < required { selection.append(index) }
                        } label: {
                            VStack {
                                ChooserPhotoThumbnail(env: env, revision: photo)
                                    .frame(width: 66, height: 52)
                                if let selected = selection.firstIndex(of: index) {
                                    Text("Ảnh \(index) · Ô \(selected + 1)").font(.caption)
                                } else {
                                    Text("Ảnh \(index)").font(.caption)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(selection.contains(index) ? .accentColor : nil)
                        .disabled(applying || required == 0 ||
                                  (selection.count == required && !selection.contains(index)))
                        .accessibilityAddTraits(selection.contains(index) ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var previewPane: some View {
        GeometryReader { geometry in
            Group {
                if let request = previewRequest, let base = framePreview,
                   base.request.id == request.frame.id, base.request.revision == request.frame.revision {
                    let rendered = selectionPreview?.request == request ? selectionPreview?.image : nil
                    let image = rendered ?? base.image
                    let scale = min(geometry.size.width / Double(image.width),
                                    geometry.size.height / Double(image.height))
                    let width = Double(image.width) * scale
                    let height = Double(image.height) * scale
                    let ranks = Dictionary(uniqueKeysWithValues: base.snapshot.requiredIndices.sorted()
                        .enumerated().map { ($0.element, $0.offset + 1) })
                    ZStack(alignment: .topLeading) {
                        Image(image, scale: 1, label: Text("Bản xem trước ảnh ghép"))
                            .resizable()
                            .accessibilityValue("\(rendered == nil ? 0 : selection.count)/\(required) ô đã điền")
                        ForEach(base.snapshot.slots) { slot in
                            if let rank = ranks[slot.captureIndex] {
                                let filled = rendered != nil && rank <= selection.count
                                Text("\(rank)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(.black.opacity(filled ? 0.7 : 0.45), in: Circle())
                                    .position(x: (slot.x + slot.width / 2) * width,
                                              y: (slot.y + slot.height / 2) * height)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .frame(width: width, height: height)
                } else if frame == nil {
                    Text("Chọn một khung để xem trước").foregroundStyle(.secondary)
                } else if previewError == nil {
                    ProgressView("Đang dựng khung…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: geometry.size, initial: true) { _, size in viewport = size }
        }
    }

    private var status: String {
        if applying { return "Đang áp dụng khung…" }
        if let previewError { return previewError }
        guard required > 0 else { return "\(photos.count) ảnh khả dụng" }
        if photos.count < required {
            return "Đã chọn \(selection.count)/\(required) · Cần thêm \(required - photos.count) ảnh"
        }
        if selection.count < required { return "Chọn ảnh theo thứ tự · \(selection.count)/\(required)" }
        return "\(required) ảnh dùng trong khung · \(photos.count) ảnh trong phiên"
    }

    private func select(_ card: FrameCardModel) {
        if frame?.id == card.id, frame?.frame.currentRevisionID == card.frame.currentRevisionID {
            if previewError != nil { previewRetry += 1 }
            return
        }
        frame = card
        if card.id == detail?.snapshot.sourceFrameID,
           card.frame.currentRevisionID == detail?.snapshot.sourceFrameRevisionID,
           let saved = detail?.session.defaults.selectedCaptureOrder,
           saved.count == required, Set(saved).isSubset(of: Set(photos.keys)) {
            selection = saved
        } else {
            selection = photos.count == required ? photos.keys.sorted() : []
        }
        selectionPreview = nil
        previewError = nil
    }

    private func reload(preferredFrameID: String? = nil, retainError: Bool = false) async {
        loading = true
        defer { loading = false }
        let repository = env.sessions
        let frameRepository = env.frames
        let filter = kiosk ? env.settings.fullscreenFrameFilter : "all"
        let id = sessionID
        let result = try? await Task.detached {
            let current = try repository.verifiedCaptureDetail(sessionID: id)
            let cards = try frameRepository.listReadyFrames()
                .filter { filter == "all" || $0.categoryID == filter || $0.id == preferredFrameID }
                .map { frame in
                    let slots = try frame.currentRevisionID.map { try frameRepository.getSlots(revisionID: $0) } ?? []
                    return FrameCardModel(frame: frame, thumbnail: nil,
                                          slotCount: Set(slots.map(\.captureIndex)).count)
                }
            return (current, cards)
        }.value
        guard !Task.isCancelled else { return }
        guard let result, let current = result.0 else {
            detail = nil
            error = "Không tìm thấy phiên chụp"
            return
        }
        if current.session.awaitsFrame && !current.missingIndices.isEmpty {
            if let onMissingPhotos { onMissingPhotos(current) }
            else { env.openReview(sessionID: sessionID, source: .library) }
            error = "Phiên còn thiếu ảnh"
            return
        }
        let previousFrame = frame
        let previousSelection = selection
        detail = current
        frames = result.1
        frame = nil
        selection = []
        framePreview = nil
        selectionPreview = nil
        if !retainError { error = nil }
        let wanted = preferredFrameID ?? previousFrame?.id ?? current.snapshot.sourceFrameID ??
            (kiosk ? env.settings.fullscreenDefaultFrame : nil)
        if let card = frames.first(where: { $0.id == wanted }) ?? frames.first {
            select(card)
            if retainError, card.id == previousFrame?.id,
               card.frame.currentRevisionID == previousFrame?.frame.currentRevisionID {
                let available = photos
                selection = previousSelection.filter { available[$0] != nil }
            }
        }
    }

    private func updatePreview() async {
        previewError = nil
        guard let request = previewRequest, let detail,
              request.photoIDs.count == request.order.count else { return }
        do {
            let result = try await env.chooserPreviews.render(detail: detail, frameID: request.frame.id,
                revision: request.frame.revision, order: request.order,
                width: request.frame.width, height: request.frame.height)
            guard !Task.isCancelled, previewRequest == request else { return }
            framePreview = FramePreview(request: request.frame, snapshot: result.snapshot, image: result.frame)
            selectionPreview = result.selection.map { (request, $0) }
        } catch {
            guard !Task.isCancelled, previewRequest == request else { return }
            selectionPreview = nil
            previewError = (error as? AppError)?.message ?? "Không thể xem trước. Kiểm tra ảnh hoặc tài nguyên khung."
        }
    }

    private func pickPNG() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            importDetail = detail
            importURL = panel.url
        }
    }

    private func apply() async {
        guard let detail, let frame, let revisionID = frame.frame.currentRevisionID,
              canConfirm, previewVerified else { return }
        await commit(frameID: frame.id, frameRevision: revisionID, detail: detail,
                     photoIDs: selection.compactMap { photos[$0]?.id }, imported: false)
    }

    private func commit(frameID: String, frameRevision: String, detail: SessionDetail,
                        photoIDs: [String], imported: Bool) async {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        let sessions = env.sessions
        let frames = env.frames
        let assets = env.assets
        let id = sessionID
        do {
            try await Task.detached {
                try sessions.applyCaptureFrame(sessionID: id, expectedRevision: detail.session.revisionNo,
                                               frameID: frameID, frameRevisionID: frameRevision,
                                               orderedPhotoIDs: photoIDs, frames: frames, assets: assets)
            }.value
            if env.engine.session?.id == id, let updated = try? sessions.getDetail(sessionID: id) {
                _ = env.engine.adoptSession(record: updated.session, snapshot: updated.snapshot,
                                            committed: updated.currentRevisions(), forReview: true)
            }
            onApplied()
        } catch {
            let message = (error as? AppError)?.message ?? error.localizedDescription
            self.error = imported ? "Đã lưu khung, chưa áp dụng. \(message)" : message
            await reload(preferredFrameID: frameID, retainError: true)
        }
    }
}

private struct ChooserFrameThumbnail: View {
    let env: AppEnvironment
    let frame: Frame
    @State private var thumbnail: Data?

    var body: some View {
        ImageDataView(data: thumbnail)
            .task(id: frame.currentRevisionID) {
                if let revision = frame.currentRevisionID {
                    thumbnail = await env.frameThumbnails.requestThumbnail(frameID: frame.id, revisionID: revision)
                }
            }
    }
}

private struct ChooserPhotoThumbnail: View {
    let env: AppEnvironment
    let revision: PhotoRevision
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .clipped()
        .task(id: revision.id) {
            let repository = env.sessions
            let photo = revision
            image = await Task.detached {
                guard let url = try? repository.fileURL(for: photo) else { return nil }
                return LibraryViewModel.downscaleThumbnail(url: url, maxDimension: 145)
                    .flatMap { CGImage.createFrom(data: $0) }
            }.value
        }
    }
}
