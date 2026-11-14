import SwiftUI
import AppKit

/// Màn hình A — Chụp ảnh (§2.2): FramePicker 240pt | CameraStage flex | QuickControls 280pt.
public struct CaptureView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: CaptureViewModel

    public init(env: AppEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: CaptureViewModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            SessionBanner(env: env,
                          onContinue: { Task { await vm.continueBannerSession() } },
                          onView: { vm.viewBannerSession() })
            HSplitLayout
            footer
        }
        .onAppear {
            Task {
                await vm.refreshCameraState()
                await vm.startPreviewIfPossible()
                vm.reloadFrames()
                vm.regeneratePreview()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await vm.refreshCameraState() }
        }
        .onChange(of: env.route) { route in
            if route == .capture {
                vm.reloadFrames()
            }
        }
    }

    private var HSplitLayout: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 1080
            HStack(spacing: 0) {
                if !compact {
                    FramePickerColumn(vm: vm, env: env)
                        .frame(width: 240)
                    Divider()
                }
                CameraStageColumn(vm: vm, env: env)
                    .frame(maxWidth: .infinity)
                Divider()
                if geo.size.width >= 1180 || compact == false {
                    QuickControlsColumn(vm: vm, env: env)
                        .frame(width: 280)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Chụp ảnh").font(.title3.weight(.semibold))
            statusBadge
            Spacer()
            Picker("Camera", selection: $vm.selectedDeviceID) {
                Text("Tự động").tag("auto")
                ForEach(vm.devices, id: \.uniqueID) { d in
                    Text(d.localizedName).tag(d.uniqueID)
                }
            }
            .frame(width: 220)
            .disabled(!env.engine.canChangeCamera)
            .help(env.engine.canChangeCamera ? "Chọn camera (Mac/USB/Continuity)" : "Chờ hoàn tất lượt chụp")
            .onChange(of: vm.selectedDeviceID) { id in
                Task { await vm.selectCamera(id) }
            }
            Button {
                env.showFullscreen = true
            } label: {
                Label("Toàn màn hình", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Mở Fullscreen Photobooth")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var statusBadge: some View {
        switch vm.permissionState {
        case .notDetermined:
            Label("Chưa cấp quyền camera", systemImage: "camera.badge.ellipsis").foregroundStyle(.orange)
        case .denied:
            Label("Camera chưa được cho phép (E-CAM-02)", systemImage: "camera.badge.ellipsis").foregroundStyle(.red)
        case .noDevice:
            Label("Không có camera (E-CAM-03)", systemImage: "video.slash").foregroundStyle(.red)
        case .authorized:
            if vm.fallbackStillNotice {
                Label("Chỉ hỗ trợ chụp ở độ phân giải video (E-CAM-06)", systemImage: "video").foregroundStyle(.orange)
            } else {
                Label(vm.cameraName.isEmpty ? "Camera sẵn sàng" : vm.cameraName, systemImage: "video.fill").foregroundStyle(.green)
            }
        case .busy:
            Label("Camera bận", systemImage: "hourglass").foregroundStyle(.orange)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            progressText
            Spacer()
            secondaryButtons
            PrimaryButton(title: vm.startButtonTitle,
                          systemImage: "camera.fill",
                          disabledReason: disabledReason) {
                Task { await vm.primaryAction() }
            }
            .keyboardShortcut(.space, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var progressText: some View {
        Group {
            switch env.engine.state {
            case .countdown(_, let index, _), .capturing(let index, _), .persisting(let index, _):
                Text("Ảnh \(index)/\(max(env.engine.requiredIndices.count, 1))").font(.headline)
            case .intermission:
                Text("Nghỉ \(env.engine.intervalSeconds)s…").foregroundStyle(.secondary)
            case .paused:
                Text("Đã tạm dừng — ảnh đã chụp vẫn được giữ").foregroundStyle(.orange)
            case .recoverableError(let message, _):
                Text(message).foregroundStyle(.red)
            default:
                Text(env.engine.committedShots.isEmpty
                     ? "Chưa chụp ảnh nào"
                     : "Đã chụp \(env.engine.committedShots.count)/\(env.engine.requiredIndices.count)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var secondaryButtons: some View {
        switch env.engine.state {
        case .paused:
            Button("Giữ phiên và thoát") {
                env.engine.keepSessionAndExit()
                env.route = .library
            }
        case .recoverableError:
            Button("Chọn camera") { Task { await vm.refreshCameraState() } }
        default:
            EmptyView()
        }
    }

    private var disabledReason: String? {
        switch vm.permissionState {
        case .notDetermined, .denied: return "Cần bật camera trước"
        case .noDevice: return "Không có camera"
        default: break
        }
        switch env.engine.state {
        case .idle:
            if vm.selectedFrame == nil { return "Chọn/thiết lập khung trước" }
            if vm.selectedFrame?.validationStatus != .ready { return "Khung chưa thiết lập (E-FRM-02)" }
            return nil
        case .countdown: return nil
        case .capturing, .persisting: return "Chờ hoàn tất lượt chụp"
        default: return nil
        }
    }
}

// MARK: - FramePicker (trái)

struct FramePickerColumn: View {
    @ObservedObject var vm: CaptureViewModel
    @ObservedObject var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Khung ảnh").font(.headline)
                Spacer()
                Button {
                    env.route = .frames
                } label: {
                    Image(systemName: "plus")
                }
                .help("+ Thêm khung")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            TextField("Tìm kiếm", text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .onChange(of: vm.searchText) { _ in vm.reloadFrames() }
            Picker("", selection: $vm.categoryFilter) {
                Text("Tất cả danh mục").tag(String?.none)
                ForEach((try? env.frames.listCategories()) ?? [], id: \.id) { cat in
                    Text(cat.name).tag(String?.some(cat.id))
                }
            }
            .labelsHidden()
            .padding(.horizontal, 12)
            .onChange(of: vm.categoryFilter) { _ in vm.reloadFrames() }
            Picker("", selection: $vm.showFavoritesOnly) {
                Text("Tất cả").tag(false)
                Text("Yêu thích").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .onChange(of: vm.showFavoritesOnly) { _ in vm.reloadFrames() }

            if vm.frames.isEmpty {
                EmptyStateView(systemImage: "photo.on.rectangle.angled",
                               title: "Chưa có khung hợp lệ",
                               message: "Thêm khung hoặc thiết lập khung chưa hoàn chỉnh để bắt đầu chụp.",
                               actionTitle: "Mở Khung ảnh") {
                    env.route = .frames
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(vm.frames) { card in
                            FramePickerCard(card: card,
                                            isSelected: vm.selectedFrameID == card.id,
                                            isLocked: !env.engine.committedShots.isEmpty) {
                                vm.selectFrame(card.id)
                            } onFavorite: {
                                vm.toggleFavorite(card.id)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct FramePickerCard: View {
    var card: FrameCardModel
    var isSelected: Bool
    var isLocked: Bool
    var onSelect: () -> Void
    var onFavorite: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ImageDataView(data: card.thumbnail)
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))
            HStack {
                Text(card.frame.name).lineLimit(1).font(.caption)
                Spacer()
                Text("\(card.slotCount) ảnh").font(.caption2).foregroundStyle(.secondary)
                Button {
                    onFavorite()
                } label: {
                    Image(systemName: card.frame.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(card.frame.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("Yêu thích")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(isLocked ? "Đã bắt đầu phiên — đổi khung ở bước chỉnh ảnh" : "Chọn khung này")
    }
}

// MARK: - CameraStage (giữa)

struct CameraStageColumn: View {
    @ObservedObject var vm: CaptureViewModel
    @ObservedObject var env: AppEnvironment
    @State private var previewMode: PreviewMode = .camera

    enum PreviewMode: String, CaseIterable {
        case camera = "Camera"
        case inFrame = "Trong khung"
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $previewMode) {
                ForEach(PreviewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.top, 12)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.85))
                if vm.permissionState == .notDetermined {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.badge.ellipsis").font(.system(size: 40))
                        Text("Photobooth Studio cần quyền camera để chụp ảnh.")
                        PrimaryButton(title: "Bật camera", systemImage: "camera") {
                            Task { await vm.enableCamera() }
                        }
                    }
                    .foregroundStyle(.white)
                } else if vm.permissionState == .denied {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield").font(.system(size: 40))
                        Text("Camera chưa được cho phép.")
                        HStack {
                            PrimaryButton(title: "Mở Cài đặt hệ thống") { vm.openSystemSettings() }
                            Button("Thử lại") { Task { await vm.retryCamera() } }
                        }
                    }
                    .foregroundStyle(.white)
                } else if vm.permissionState == .noDevice {
                    VStack(spacing: 12) {
                        Image(systemName: "video.slash").font(.system(size: 40))
                        Text("Không tìm thấy camera.")
                        Button("Thử lại") { Task { await vm.retryCamera() } }
                    }
                    .foregroundStyle(.white)
                } else if let service = env.camera as? CameraService {
                    CIPreviewView(cameraService: service,
                                  mirror: env.settings.previewMirror,
                                  inFrame: previewMode == .inFrame ? inFrameSpec : nil)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    countdownOverlay
                    statusOverlay
                } else {
                    Text("Camera giả lập không hỗ trợ preview Metal")
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)

            thumbnailStrip
            Spacer(minLength: 0)
        }
    }

    var inFrameSpec: InFrameSpec? {
        guard let base = vm.previewFrameImage,
              let frame = vm.selectedFrame,
              let revID = frame.currentRevisionID,
              let slots = try? env.frames.getSlots(revisionID: revID) else { return nil }
        let currentIndex = env.engine.nextPendingIndex ?? 1
        let rects = slots.filter { $0.captureIndex == currentIndex }
            .map { $0.rect }
            .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        guard !rects.isEmpty else { return nil }
        return InFrameSpec(base: base, slotRects: rects)
    }

    @ViewBuilder var countdownOverlay: some View {
        switch env.engine.state {
        case .countdown(let remaining, let index, _):
            VStack {
                Spacer()
                Text("\(remaining)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 12)
                Text("Ảnh \(index)/\(env.engine.requiredIndices.count)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
                Spacer()
            }
        case .capturing:
            VStack { Spacer(); Text("Đang chụp…").font(.title3).foregroundStyle(.white); Spacer() }
        case .persisting:
            VStack { Spacer(); Text("Đang lưu…").font(.title3).foregroundStyle(.white); Spacer() }
        case .paused(_, let nextIndex, _):
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "pause.circle").font(.system(size: 44)).foregroundStyle(.white)
                Text("Tạm dừng — lượt tiếp theo: ảnh \(nextIndex)")
                    .foregroundStyle(.white)
                Spacer()
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder var statusOverlay: some View {
        VStack {
            HStack {
                if case .intermission = env.engine.state {
                    Text("Đang nghỉ").padding(6).background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                }
                Spacer()
                Text(previewMode == .camera ? "Xem trước camera" : "Xem trước trong khung")
                    .padding(6).background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
            }
            .padding(10)
            Spacer()
        }
    }

    var thumbnailStrip: some View {
        HStack(spacing: 8) {
            let required = env.engine.requiredIndices.sorted()
            if required.isEmpty {
                Text("Chọn khung để thấy các lượt chụp")
                    .foregroundStyle(.secondary).font(.caption)
            }
            ForEach(required, id: \.self) { index in
                if let rev = env.engine.committedShots[index],
                   let url = try? env.sessions.fileURL(for: rev) {
                    // Decode nền + cache (P3-11b) — không decode full-res đồng bộ trong body
                    AsyncThumbView(url: url, width: 64, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.green, lineWidth: 2))
                        .help("Ảnh \(index) — đã chụp (chỉ xem)")
                } else {
                    VStack {
                        Spacer()
                        Text("\(index)").font(.headline).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(width: 64, height: 48)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(env.engine.nextPendingIndex == index ? Color.accentColor : Color.secondary.opacity(0.4),
                                      style: StrokeStyle(lineWidth: 2, dash: [4])))
                    .help("Lượt \(index) — chưa chụp")
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - QuickControls (phải, §2.2)

struct QuickControlsColumn: View {
    @ObservedObject var vm: CaptureViewModel
    @ObservedObject var env: AppEnvironment

    var busy: Bool { env.engine.isCaptureBusy }
    var busyTooltip: String { "Chờ hoàn tất lượt chụp" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cài đặt nhanh").font(.headline)
                // Chế độ
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chế độ").font(.subheadline.weight(.medium))
                    Picker("", selection: $vm.mode) {
                        ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(busy)
                    .help(busy ? busyTooltip : "Tự động/Thủ công (khóa sau khi bắt đầu phiên)")
                }
                // Đếm ngược
                VStack(alignment: .leading, spacing: 4) {
                    Text("Đếm ngược").font(.subheadline.weight(.medium))
                    Picker("", selection: $vm.countdown) {
                        Text("0 giây").tag(0)
                        Text("3 giây").tag(3)
                        Text("5 giây").tag(5)
                        Text("10 giây").tag(10)
                        Text("Tùy chỉnh…").tag(-1)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(busy)
                    .help(busy ? busyTooltip : "0/3/5/10/tùy chỉnh 1..30 giây")
                    if vm.countdown == -1 {
                        HStack {
                            Slider(value: Binding(
                                get: { Double(max(vm.countdown, 0)) },
                                set: { vm.countdown = Int($0) }), in: 1...30)
                            Text("\(max(vm.countdown, 0))s").monospacedDigit()
                        }
                    }
                }
                // Nghỉ giữa lượt
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Nghỉ giữa lượt").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(vm.interval)s").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(vm.interval) }, set: { vm.interval = Int($0) }), in: 0...15)
                        .disabled(busy)
                        .help(busy ? busyTooltip : "0–15 giây")
                }
                Divider()
                // Preset
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preset màu").font(.subheadline.weight(.medium))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(BuiltinPreset.all, id: \.id) { preset in
                            PresetChip(preset: preset, selected: vm.selectedPresetID == preset.id) {
                                vm.selectedPresetID = preset.id
                                env.settings.defaultPreset = preset.id
                            }
                            .disabled(busy)
                        }
                    }
                    .disabled(busy)
                    .help(busy ? busyTooltip : "Áp dụng cho phiên mới")
                }
                // Làm mịn
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Làm mịn da").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int(vm.skinSmooth * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $vm.skinSmooth, in: 0...1)
                        .disabled(busy)
                        .help(busy ? busyTooltip : "0–100% (mặc định 25%)")
                }
                // Âm thanh
                Toggle("Âm thanh", isOn: Binding(get: { env.settings.soundEnabled },
                                                 set: { env.settings.soundEnabled = $0 }))
                    .help("Tiếng tick đếm ngược, shutter, hoàn thành")
                Divider()
                Button("Cài đặt camera…") { env.route = .settings }
                    .help("Mở Cài đặt → Camera")
                Spacer()
            }
            .padding(14)
        }
    }
}

struct PresetChip: View {
    var preset: BuiltinPreset
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(hue: 0.08 + 0.4 * abs(preset.parameters.temperature), saturation: 0.5 + 0.3 * abs(preset.parameters.saturation), brightness: 0.9 + 0.1 * preset.parameters.exposure),
                                                  Color(hue: 0.6, saturation: 0.2, brightness: 0.85)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(preset.nameVN).font(.caption2).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
