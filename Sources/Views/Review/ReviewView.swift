import SwiftUI
import AppKit
import CoreGraphics

/// ReviewView (§2.8, §9.3): Xem và chỉnh ảnh sau khi chụp.
/// Layout: photo strip (trên) | preview (giữa) | inspector phải (tab Màu/Làm mịn/Crop).
/// Footer: Retake / Apply to all / Reset / Đổi khung / Xuất / Chia sẻ / Hoàn thành.
public struct ReviewView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: ReviewViewModel
    @State private var showExportSheet = false
    @State private var showFramePicker = false
    @State private var showSharePicker = false
    @State private var shareURL: URL?
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
            footer
        }
        .onAppear { Task { await vm.load(sessionID: sessionID) } }
        .onChange(of: sessionID) { newID in Task { await vm.load(sessionID: newID) } }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(env: env, reviewVM: vm)
        }
        .sheet(isPresented: $showFramePicker) {
            FrameSwitchSheet(env: env, currentFrameID: vm.detail?.snapshot.sourceFrameID) { newFrameID in
                Task { await vm.changeFrame(to: newFrameID) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                env.route = .library
            } label: {
                Label("Thư viện", systemImage: "chevron.left")
            }
            Text("Xem và chỉnh").font(.title3.weight(.semibold))
            if let detail = vm.detail {
                Text("\(detail.committedCount)/\(detail.snapshot.requiredCaptureCount) ảnh")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if vm.isSaving {
                ProgressView().scaleEffect(0.7)
                Text("Đang lưu…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Photo strip (§9.3)

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let detail = vm.detail {
                    ForEach(detail.snapshot.slots.sorted(by: { $0.captureIndex < $1.captureIndex }), id: \.id) { slot in
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
            .padding(10)
        }
        .frame(height: 80)
    }

    @ViewBuilder
    private func thumbnailCell(for slot: SnapshotSlot) -> some View {
        let isSelected = vm.selectedSlotID == slot.id
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
            Text("Lượt \(slot.captureIndex)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Preview

    private var previewArea: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let img = vm.previewImage {
                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width), height: CGFloat(img.height))))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
            } else if vm.detail == nil {
                ProgressView("Đang tải phiên…")
            } else {
                EmptyStateView(systemImage: "photo",
                               title: "Chưa có ảnh",
                               message: "Phiên chưa đủ ảnh để hiển thị. Quay lại màn Chụp để chụp bổ sung.")
            }
            if vm.showBeforeAfter, let _ = vm.previewImage {
                // Toggle before/after — tạm dùng text overlay
                Text("SAU").font(.caption.weight(.bold)).padding(6)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
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
                case .beauty: beautyInspector
                case .crop: cropInspector
                }
            }
        }
    }

    private var colorInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Màu sắc").font(.headline)
            // Preset
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
                    }
                }
            }
            // Intensity
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Cường độ preset").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(vm.draftPresetIntensity * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { vm.draftPresetIntensity },
                    set: { vm.setPresetIntensity($0) }), in: 0...1)
            }
            Divider()
            // Adjustments
            sliderRow("Độ phơi", key: "exposure")
            sliderRow("Tương phản", key: "contrast")
            sliderRow("Bão hòa", key: "saturation")
            sliderRow("Nhiệt độ", key: "temperature")
            sliderRow("Sắc màu", key: "tint")
            sliderRow("Độ nét", key: "sharpness")
            Divider()
            Button("Áp dụng cho tất cả ảnh") {
                vm.applyColorToAll()
            }
            Button("Reset ảnh này") {
                vm.resetThisPhoto()
            }
        }
        .padding(12)
    }

    private func sliderRow(_ label: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(currentValue(for: key) * 100))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(currentValue(for: key)) },
                set: { vm.setColorValue(key, $0) }), in: -100...100)
        }
    }

    private func currentValue(for key: String) -> Double {
        switch key {
        case "exposure": return (vm.draftColor.exposure ?? 0) * 100
        case "contrast": return (vm.draftColor.contrast ?? 0) * 100
        case "saturation": return (vm.draftColor.saturation ?? 0) * 100
        case "temperature": return (vm.draftColor.temperature ?? 0) * 100
        case "tint": return (vm.draftColor.tint ?? 0) * 100
        case "sharpness": return ((vm.draftColor.sharpness ?? 0) * 200) - 100
        default: return 0
        }
    }

    private var beautyInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Làm mịn da").font(.headline)
            HStack {
                Text("Cường độ").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((vm.draftSkinSmooth ?? 0) * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { vm.draftSkinSmooth ?? 0 },
                set: { vm.setSkinSmooth($0) }), in: 0...1)
            Text("Auto Face dùng Vision để căn mặt — bật ở tab Crop/Vị trí.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
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
                        set: { vm.updatePlacement(scale: $0) }), in: 0.5...3.0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Offset X").font(.subheadline.weight(.medium))
                    Slider(value: Binding(
                        get: { vm.draftPlacement?.offsetX ?? 0 },
                        set: { vm.updatePlacement(offsetX: $0) }), in: -0.5...0.5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Offset Y").font(.subheadline.weight(.medium))
                    Slider(value: Binding(
                        get: { vm.draftPlacement?.offsetY ?? 0 },
                        set: { vm.updatePlacement(offsetY: $0) }), in: -0.5...0.5)
                }
                Button("Căn lại theo mặt") {
                    vm.recomputeAutoFace()
                }
            }
        }
        .padding(12)
    }

    // MARK: Footer (§3.3 retake, §3.4 change frame, §11 export/share/complete)

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                if let idx = vm.selectedPhotoIndex {
                    vm.retake(index: idx, keepCrop: false)
                }
            } label: {
                Label("Chụp lại", systemImage: "arrow.clockwise")
            }
            .disabled(vm.selectedPhotoIndex == nil)
            Button {
                showFramePicker = true
            } label: {
                Label("Đổi khung", systemImage: "rectangle.3.offgrid")
            }
            Spacer()
            Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(false)
                .help("Undo")
            Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(false)
                .help("Redo")
            Divider()
            Button {
                showExportSheet = true
            } label: {
                Label("Xuất", systemImage: "square.and.arrow.up")
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
                Label("Chia sẻ", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(!vm.canExport)
            PrimaryButton(title: "Hoàn thành", systemImage: "checkmark.circle.fill",
                          disabledReason: vm.canExport ? nil : "Chưa đủ ảnh") {
                Task {
                    await vm.complete()
                    env.route = .library
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
            let thumb = env.thumbnails.cachedData(key: "frame-\(f.currentRevisionID ?? f.id)")
            return FrameCardModel(frame: f, thumbnail: thumb, slotCount: slots.count)
        }
    }
}
