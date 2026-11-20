import SwiftUI
import AppKit

/// Màn hình A — Chụp ảnh (§2.2): FramePicker 240pt | CameraStage flex | QuickControls 280pt.
public struct CaptureView: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: CaptureViewModel
    @State private var isCompact: Bool = false
    @FocusState private var isSearchFocused: Bool

    enum ActivePopover: Identifiable {
        case framePicker
        case quickControls
        var id: Int { hashValue }
    }
    @State private var activePopover: ActivePopover? = nil

    public init(env: AppEnvironment) {
        self.env = env
        _vm = StateObject(wrappedValue: CaptureViewModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            SessionBanner(env: env,
                          onContinue: { bannerID in Task { await vm.continueBannerSession(sessionID: bannerID) } },
                          onView: { bannerID in vm.viewBannerSession(sessionID: bannerID) })
            HSplitLayout
            footer
        }
        .onExitCommand {
            vm.handleExitCommand()
        }
        .onAppear {
            Task {
                await vm.refreshCameraState()
                vm.reloadFrames()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await vm.refreshCameraState() }
        }
        .task { await vm.observeCameraEvents() }
        .onChange(of: env.engine.isCaptureBusy || env.engine.isCancellingSession) { _, busy in
            if !busy { Task { await vm.resumeDeferredCameraRefresh() } }
        }
        .onChange(of: env.route) { route in
            if route == .capture {
                vm.reloadFrames()
            }
        }
        .onChange(of: env.engine.snapshot?.id) { _ in vm.regeneratePreview() }
        .onChange(of: env.engine.state) { newState in
            if case .reviewing = newState, let retakeID = env.retakeSessionID {
                env.retakeSessionID = nil
                env.openReview(sessionID: retakeID, source: env.reviewContext?.sourceRoute ?? .capture)
            } else if case .reviewing = newState, let session = env.engine.session,
                      (session.awaitsFrame || session.pendingSelectionCount != nil), !env.showLeaveCaptureConfirmation {
                env.openReview(sessionID: session.id, source: .capture)
            }
        }
        .task {
            for await event in EventBus.shared.stream {
                if case .frameLibraryChanged = event {
                    vm.reloadFrames()
                }
            }
        }
    }

    private var HSplitLayout: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 1080
            HStack(spacing: 0) {
                if !compact, showsLegacyFrame {
                    FramePickerColumn(vm: vm, env: env, isSearchFocused: $isSearchFocused)
                        .frame(width: 240)
                    Divider()
                }
                CameraStageColumn(vm: vm, env: env)
                    .frame(maxWidth: .infinity)
                if !compact {
                    Divider()
                    QuickControlsColumn(vm: vm, env: env)
                        .frame(width: 280)
                }
            }
            .onAppear {
                isCompact = compact
            }
            .onChange(of: geo.size.width) { width in
                let newCompact = width < 1080
                if isCompact != newCompact {
                    isCompact = newCompact
                    if !newCompact {
                        activePopover = nil
                    }
                    isSearchFocused = false
                }
            }
        }
    }

    private var showsLegacyFrame: Bool {
        guard let session = env.engine.session else { return false }
        return session.defaults.plannedCaptureCount == nil
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Chụp ảnh").font(.title3.weight(.semibold))
            statusBadge
            Spacer()
            if env.engine.session == nil {
                CaptureCountPicker(count: $vm.plannedCaptureCount)
            }
            if isCompact {
                if showsLegacyFrame {
                    Button {
                        activePopover = activePopover == .framePicker ? nil : .framePicker
                    } label: {
                        Label("Khung ảnh", systemImage: "rectangle.3.offgrid")
                    }
                    .popover(isPresented: Binding(
                        get: { activePopover == .framePicker },
                        set: { if !$0 && activePopover == .framePicker { activePopover = nil; isSearchFocused = false } }
                    )) {
                        FramePickerColumn(vm: vm, env: env, isSearchFocused: $isSearchFocused)
                            .frame(width: 300, height: 450)
                    }
                    .help("Chọn khung ảnh")
                }

                Button {
                    activePopover = activePopover == .quickControls ? nil : .quickControls
                } label: {
                    Label("Cài đặt nhanh", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: Binding(
                    get: { activePopover == .quickControls },
                    set: { if !$0 && activePopover == .quickControls { activePopover = nil } }
                )) {
                    QuickControlsColumn(vm: vm, env: env)
                        .frame(width: 300, height: 450)
                }
                .help("Cài đặt nhanh")
            }
            Picker("Camera", selection: Binding(
                get: { vm.selectedDeviceID },
                set: { id in Task { await vm.selectCamera(id) } }
            )) {
                Text("Tự động").tag("auto")
                ForEach(vm.devices, id: \.uniqueID) { d in
                    Text(d.localizedName).tag(d.uniqueID)
                }
            }
            .accessibilityLabel("Chọn camera")
            .frame(width: 220)
            .disabled(!env.engine.canChangeCamera)
            .help(env.engine.canChangeCamera ? "Chọn camera (Mac/USB/Continuity)" : "Chờ hoàn tất lượt chụp")
            Button {
                if env.engine.session != nil && !env.engine.isCaptureBusy {
                    env.engine.keepSessionAndExit()
                }
                env.showFullscreen = true
            } label: {
                Label("Toàn màn hình", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Mở Fullscreen Photobooth")
            .disabled(env.engine.isCancellingSession || env.engine.isCaptureBusy || env.engine.hasPhotoToSave)
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
            if !vm.isCameraReady {
                Label(vm.cameraPreviewError == nil ? "Đang kết nối camera…" : "Preview camera chưa sẵn sàng",
                      systemImage: "video.slash").foregroundStyle(.orange)
            } else if vm.fallbackStillNotice {
                Label("Chỉ hỗ trợ chụp ở độ phân giải video (E-CAM-06)", systemImage: "video").foregroundStyle(.orange)
            } else {
                Label(vm.cameraName.isEmpty ? "Camera sẵn sàng" : vm.cameraName, systemImage: "video.fill").foregroundStyle(.green)
            }
        case .busy:
            Label("Camera bận", systemImage: "hourglass").foregroundStyle(.orange)
        }
    }

    private var isAnyTextEditorActive: Bool {
        if isSearchFocused { return true }
        if let responder = NSApp.keyWindow?.firstResponder {
            if responder is NSTextView || responder is NSTextField {
                return true
            }
        }
        return false
    }

    private var canUseSpace: Bool {
        guard !isAnyTextEditorActive else { return false }
        switch env.engine.state {
        case .idle, .ready, .paused:
            return true
        default:
            return false
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            progressText
            Spacer()
            CaptureCancellationButton(env: env)
            secondaryButtons.disabled(env.engine.isCancellingSession)
            primaryActionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var primaryActionButton: some View {
        let btn = PrimaryButton(title: vm.startButtonTitle,
                                systemImage: "camera.fill",
                                disabledReason: disabledReason) {
            Task { await vm.primaryAction() }
        }
        if case .countdown = env.engine.state {
            btn.keyboardShortcut(.cancelAction)
        } else if canUseSpace {
            btn.keyboardShortcut(.space, modifiers: [])
        } else {
            btn
        }
    }

    private var progressText: some View {
        Group {
            if let session = env.engine.session, session.awaitsFrame {
                HStack(spacing: 8) {
                    Text("Đã lưu \(env.engine.committedShots.count)/\(session.captureCount) ảnh")
                        .monospacedDigit()
                    if case .recoverableError(let message, _) = env.engine.state {
                        Text(message).foregroundStyle(.red)
                    } else if case .paused = env.engine.state {
                        Text("Đã tạm dừng").foregroundStyle(.orange)
                    }
                }
            } else {
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
    }

    @ViewBuilder private var secondaryButtons: some View {
        switch env.engine.state {
        case .paused:
            Button("Giữ phiên và thoát") {
                env.engine.keepSessionAndExit()
                env.requestNavigation(to: .library)
            }
        case .ready where env.engine.session != nil && env.engine.committedShots.isEmpty:
            Button("Đổi thiết lập phiên") { env.engine.keepSessionAndExit() }
        case .reviewing, .completed:
            Button("Thiết lập phiên mới") { env.engine.keepSessionAndExit() }
        case .capturing, .persisting:
            Button(env.engine.pauseRequested ? "Sẽ dừng sau lượt này" : "Tạm dừng sau lượt này") {
                env.engine.pause()
            }
            .disabled(env.engine.pauseRequested)
        case .recoverableError where !env.engine.hasPhotoToSave:
            Button("Chọn camera") { Task { await vm.refreshCameraState() } }
        default:
            EmptyView()
        }
    }

    private var disabledReason: String? {
        if env.engine.isCancellingSession { return "Đang xử lý yêu cầu hủy phiên" }
        switch env.engine.state {
        case .reviewing, .completed, .countdown, .intermission: return nil
        case .capturing, .persisting: return "Chờ hoàn tất lượt chụp"
        case .recoverableError where env.engine.hasPhotoToSave: return nil
        default: break
        }
        switch vm.permissionState {
        case .notDetermined, .denied: return "Cần bật camera trước"
        case .noDevice: return "Không có camera"
        default: break
        }
        guard vm.isCameraReady else { return "Chờ camera sẵn sàng" }
        return nil
    }
}

// MARK: - FramePicker (trái)

struct FramePickerColumn: View {
    @ObservedObject var vm: CaptureViewModel
    @ObservedObject var env: AppEnvironment
    @FocusState.Binding var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Khung ảnh").font(.headline)
                Spacer()
                Button {
                    env.requestNavigation(to: .frames)
                } label: {
                    Image(systemName: "plus")
                }
                .help("+ Thêm khung")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            TextField("Tìm kiếm", text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Tìm kiếm khung ảnh")
                .focused($isSearchFocused)
                .padding(.horizontal, 12)
                .onChange(of: vm.searchText) { _ in vm.reloadFrames() }
            Picker("", selection: $vm.categoryFilter) {
                Text("Tất cả danh mục").tag(String?.none)
                ForEach((try? env.frames.listCategories()) ?? [], id: \.id) { cat in
                    Text(cat.name).tag(String?.some(cat.id))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Lọc danh mục khung ảnh")
            .padding(.horizontal, 12)
            .onChange(of: vm.categoryFilter) { _ in vm.reloadFrames() }
            Picker("", selection: $vm.showFavoritesOnly) {
                Text("Tất cả").tag(false)
                Text("Yêu thích").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Lọc khung ảnh yêu thích")
            .padding(.horizontal, 12)
            .onChange(of: vm.showFavoritesOnly) { _ in vm.reloadFrames() }

            if !env.canSelectFrameForCapture {
                Text(env.engine.isCaptureBusy
                     ? "Khung được giữ nguyên trong lượt đang chạy."
                     : "Đổi khung trong Xem và chỉnh ảnh hoặc thiết lập phiên mới.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            if vm.frames.isEmpty {
                EmptyStateView(systemImage: "photo.on.rectangle.angled",
                               title: "Chưa có khung hợp lệ",
                               message: "Thêm khung hoặc thiết lập khung chưa hoàn chỉnh để bắt đầu chụp.",
                               actionTitle: "Mở Khung ảnh") {
                    env.requestNavigation(to: .frames)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(vm.frames) { card in
                            FramePickerCard(card: card,
                                            isSelected: vm.selectedFrameID == card.id,
                                            isLocked: !env.canSelectFrameForCapture) {
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
        VStack(alignment: .leading, spacing: 4) {
            ImageDataView(data: card.thumbnail)
                .frame(height: 92)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))

            Text(card.frame.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(isLocked ? "\(card.frame.name) (Đang khóa)" : card.frame.name)
                .accessibilityLabel(card.frame.name)

            HStack {
                Text("\(card.slotCount) ảnh")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onFavorite()
                } label: {
                    Image(systemName: card.frame.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(card.frame.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(card.frame.isFavorite ? "Bỏ yêu thích \(card.frame.name)" : "Yêu thích \(card.frame.name)")
                .help(card.frame.isFavorite ? "Bỏ yêu thích" : "Yêu thích")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isLocked && !isSelected { onSelect() }
        }
        .help(isLocked ? "Khung đang khóa. Đổi trong Xem và chỉnh ảnh hoặc thiết lập phiên mới." : "Chọn khung \(card.frame.name)")
    }
}

// MARK: - CameraStage (giữa)

struct PreviewShotItem: Identifiable {
    let id = UUID()
    let index: Int
    let url: URL
}

struct CameraStageColumn: View {
    @ObservedObject var vm: CaptureViewModel
    @ObservedObject var env: AppEnvironment
    @State private var previewItem: PreviewShotItem? = nil

    var body: some View {
        VStack(spacing: 10) {
            if env.engine.snapshot?.sourceFrameID != nil {
                Picker("", selection: Binding(
                    get: { vm.previewMode },
                    set: { vm.setPreviewMode($0) }
                )) {
                    ForEach(CaptureViewModel.PreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Chế độ xem trước camera")
                .frame(width: 220)
                .padding(.top, 12)
            }

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
                } else if !vm.isCameraReady {
                    VStack(spacing: 12) {
                        if vm.isConnectingCamera { ProgressView().tint(.white) }
                        Text(vm.cameraPreviewError ?? "Đang chờ khung hình từ camera…")
                            .multilineTextAlignment(.center)
                        if !vm.isConnectingCamera {
                            Button("Thử lại") { Task { await vm.retryCamera() } }
                        }
                    }
                    .padding()
                    .foregroundStyle(.white)
                } else if let service = env.camera as? CameraService {
                    CIPreviewView(cameraService: service,
                                  mirror: env.settings.previewMirror,
                                  inFrame: env.engine.snapshot?.sourceFrameID != nil && vm.previewMode == .inFrame ? inFrameSpec : nil,
                                  photoParameters: vm.livePhotoParameters, faceAnalysis: env.faceAnalysis)
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
        .popover(item: $previewItem) { item in
            VStack(spacing: 8) {
                HStack {
                    Text("Ảnh \(item.index)").font(.headline)
                    Spacer()
                    Button("Đóng") { previewItem = nil }
                }
                if let nsImg = NSImage(contentsOf: item.url) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 380, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(12)
            .frame(width: 400, height: 320)
        }
    }

    private var inFrameTargetIndex: Int? {
        guard let snapshot = vm.previewSnapshot else { return nil }
        let firstIndex = snapshot.requiredIndices.min() ?? 1

        switch env.engine.state {
        case .countdown(_, let index, let kind) where kind == .retake:
            return index
        case .capturing(let index, let kind) where kind == .retake:
            return index
        case .persisting(let index, let kind) where kind == .retake:
            return index
        case .paused(_, let nextIndex, let kind) where kind == .retake:
            return nextIndex
        default:
            break
        }

        let pendingSelection = env.engine.session?.pendingSelectionCount != nil
            || (env.engine.session == nil && vm.selectionCount != nil)
        if pendingSelection {
            return firstIndex
        }

        switch env.engine.state {
        case .countdown(_, let index, _), .capturing(let index, _), .persisting(let index, _):
            return index
        case .intermission(let nextIndex, _):
            return nextIndex
        case .paused(_, let nextIndex, _):
            return nextIndex
        default:
            return env.engine.nextPendingIndex ?? firstIndex
        }
    }

    var inFrameSpec: InFrameSpec? {
        guard let base = vm.previewFrameImage, let snapshot = vm.previewSnapshot else { return nil }
        guard let targetIndex = inFrameTargetIndex else { return nil }
        let rects = snapshot.slots.filter { $0.captureIndex == targetIndex }
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
                Text((env.engine.snapshot?.sourceFrameID == nil || vm.previewMode == .camera) ? "Xem trước camera" : "Xem trước trong khung")
                    .padding(6).background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
            }
            .padding(10)
            Spacer()
        }
    }

    private var currentScrollTargetKey: String {
        let sid = env.engine.session?.id ?? "none"
        let required = env.engine.session != nil ? env.engine.requiredIndices.sorted()
            : Array(1...vm.plannedCaptureCount)
        let activeIndex: Int
        switch env.engine.state {
        case .countdown(_, let idx, _), .capturing(let idx, _), .persisting(let idx, _):
            activeIndex = idx
        case .intermission(let nextIdx, _), .paused(_, let nextIdx, _):
            activeIndex = nextIdx
        default:
            activeIndex = env.engine.nextPendingIndex ?? required.first ?? 1
        }
        return "\(sid)-\(activeIndex)"
    }

    private var currentActiveIndex: Int {
        let required = env.engine.session != nil ? env.engine.requiredIndices.sorted()
            : Array(1...vm.plannedCaptureCount)
        switch env.engine.state {
        case .countdown(_, let idx, _), .capturing(let idx, _), .persisting(let idx, _):
            return idx
        case .intermission(let nextIdx, _), .paused(_, let nextIdx, _):
            return nextIdx
        default:
            return env.engine.nextPendingIndex ?? required.first ?? 1
        }
    }

    var thumbnailStrip: some View {
        let required = env.engine.session != nil ? env.engine.requiredIndices.sorted()
            : Array(1...vm.plannedCaptureCount)
        let count = required.count
        let totalContentWidth = CGFloat(count * 64 + max(count - 1, 0) * 8 + 32)

        return GeometryReader { geo in
            let isOverflowing = totalContentWidth > geo.size.width
            VStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) {
                            if required.isEmpty {
                                Text("Chọn khung để thấy các lượt chụp")
                                    .foregroundStyle(.secondary).font(.caption)
                            }
                            ForEach(required, id: \.self) { index in
                                if let rev = env.engine.committedShots[index],
                                   let url = try? env.sessions.fileURL(for: rev) {
                                    AsyncThumbView(url: url, width: 64, height: 48)
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.green, lineWidth: 2))
                                        .help("Ảnh \(index) — đã chụp (nhấp để xem phóng to)")
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            previewItem = PreviewShotItem(index: index, url: url)
                                        }
                                        .id(index)
                                } else {
                                    VStack {
                                        Spacer()
                                        Text("\(index)").font(.headline).foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .frame(width: 64, height: 48)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(currentActiveIndex == index ? Color.accentColor : Color.secondary.opacity(0.4),
                                                      style: StrokeStyle(lineWidth: 2, dash: [4])))
                                    .help("Lượt \(index) — chưa chụp")
                                    .id(index)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: currentScrollTargetKey) { _ in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(currentActiveIndex, anchor: .center)
                        }
                    }
                }
                if isOverflowing {
                    Text("Cuộn để xem các lượt còn lại")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 72)
    }
}

// MARK: - QuickControls (phải, §2.2)

struct QuickControlsColumn: View {
    @ObservedObject var vm: CaptureViewModel
    @ObservedObject var env: AppEnvironment
    @ObservedObject private var settings: SettingsStore

    init(vm: CaptureViewModel, env: AppEnvironment) {
        self.vm = vm
        self.env = env
        self.settings = env.settings
    }
    @State private var isCustomCountdown: Bool = false
    private let standardCountdowns = [0, 3, 5, 10]

    var sessionStarted: Bool { env.engine.session != nil }

    private var effectiveMode: CaptureMode {
        sessionStarted ? (env.engine.session?.captureMode ?? vm.mode) : vm.mode
    }

    private var modeBinding: Binding<CaptureMode> {
        Binding(
            get: { effectiveMode },
            set: { if !sessionStarted { vm.mode = $0 } }
        )
    }

    private var effectiveCountdown: Int {
        sessionStarted ? (env.engine.session?.countdownSeconds ?? vm.countdown) : vm.countdown
    }

    private var countdownSelection: Binding<Int> {
        Binding(
            get: {
                let current = effectiveCountdown
                if isCustomCountdown || !standardCountdowns.contains(current) {
                    return -1
                }
                return current
            },
            set: { newVal in
                guard !sessionStarted else { return }
                if newVal == -1 {
                    isCustomCountdown = true
                    if standardCountdowns.contains(vm.countdown) {
                        vm.countdown = 7
                    }
                } else {
                    isCustomCountdown = false
                    vm.countdown = newVal
                }
            }
        )
    }

    private var customCountdownBinding: Binding<Double> {
        Binding(
            get: { Double(max(effectiveCountdown, 1)) },
            set: { if !sessionStarted { vm.countdown = max(1, min(30, Int($0))) } }
        )
    }

    private var effectiveInterval: Int {
        sessionStarted ? (env.engine.session?.intermissionSeconds ?? vm.interval) : vm.interval
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { Double(effectiveInterval) },
            set: { if !sessionStarted { vm.interval = Int($0) } }
        )
    }

    private var effectivePresetID: String {
        sessionStarted ? (env.engine.session?.defaults.presetID ?? vm.selectedPresetID) : vm.selectedPresetID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cài đặt nhanh").font(.headline)
                // Chế độ
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chế độ").font(.subheadline.weight(.medium))
                    Picker("", selection: modeBinding) {
                        ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityLabel("Chế độ chụp")
                    .disabled(sessionStarted)
                    .help(sessionStarted ? "Áp dụng từ phiên tiếp theo" : "Tự động/Thủ công")
                }
                // Đếm ngược
                VStack(alignment: .leading, spacing: 4) {
                    Text("Đếm ngược").font(.subheadline.weight(.medium))
                    Picker("", selection: countdownSelection) {
                        Text("0 giây").tag(0)
                        Text("3 giây").tag(3)
                        Text("5 giây").tag(5)
                        Text("10 giây").tag(10)
                        Text("Tùy chỉnh…").tag(-1)
                    }
                    .labelsHidden()
                    .accessibilityLabel("Thời gian đếm ngược")
                    .frame(maxWidth: .infinity)
                    .disabled(sessionStarted)
                    .help(sessionStarted ? "Áp dụng từ phiên tiếp theo" : "0/3/5/10/tùy chỉnh 1..30 giây")
                    if isCustomCountdown || !standardCountdowns.contains(effectiveCountdown) {
                        HStack {
                            Slider(value: customCountdownBinding, in: 1...30)
                                .disabled(sessionStarted)
                            Text("\(max(effectiveCountdown, 1))s").monospacedDigit()
                        }
                    }
                }
                // Nghỉ giữa lượt
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Nghỉ giữa lượt").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(effectiveInterval)s").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: intervalBinding, in: 0...15)
                        .disabled(sessionStarted)
                        .help(sessionStarted ? "Áp dụng từ phiên tiếp theo" : "0–15 giây")
                }
                Divider()
                if let session = env.engine.session, let count = session.defaults.selectionCaptureCount {
                    Text("Chụp \(count) ảnh · chọn \(session.requiredCaptureCount)")
                        .foregroundStyle(.secondary)
                    Divider()
                }
                // Preset
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preset màu").font(.subheadline.weight(.medium))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(BuiltinPreset.all, id: \.id) { preset in
                            PresetChip(preset: preset, selected: effectivePresetID == preset.id) {
                                vm.selectedPresetID = preset.id
                                env.settings.defaultPreset = preset.id
                            }
                            .disabled(sessionStarted)
                        }
                    }
                    .disabled(sessionStarted)
                    .help(sessionStarted ? "Áp dụng từ phiên tiếp theo" : "Xem trước trực tiếp và áp dụng cho phiên mới")
                    if sessionStarted, !BuiltinPreset.all.contains(where: { $0.id == effectivePresetID }) {
                        Text("Preset đã lưu: \(env.engine.session?.defaults.presetName ?? effectivePresetID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Lật ngang ảnh thành phẩm", isOn: Binding(
                    get: { env.engine.session?.defaults.outputMirror ?? settings.outputMirror },
                    set: { if !sessionStarted { settings.outputMirror = $0 } }))
                    .disabled(sessionStarted)
                    .help(sessionStarted ? "Hướng ảnh đã được chốt cho phiên này." : "Áp dụng khi xem lại và xuất ảnh.")
                // Âm thanh
                Toggle("Âm thanh", isOn: Binding(get: { env.settings.soundEnabled },
                                                 set: { env.settings.soundEnabled = $0 }))
                    .help("Tiếng tick đếm ngược, shutter, hoàn thành")
                Divider()
                Button("Cài đặt camera…") { env.openSettings(section: .camera) }
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

    private var gradientColors: [Color] {
        switch preset.id {
        case "natural":
            return [Color(red: 0.95, green: 0.85, blue: 0.78), Color(red: 0.75, green: 0.82, blue: 0.88)]
        case "bright":
            return [Color(red: 1.0, green: 0.94, blue: 0.80), Color(red: 0.80, green: 0.92, blue: 1.0)]
        case "warm":
            return [Color(red: 1.0, green: 0.70, blue: 0.45), Color(red: 0.95, green: 0.50, blue: 0.35)]
        case "cool":
            return [Color(red: 0.65, green: 0.82, blue: 0.98), Color(red: 0.45, green: 0.65, blue: 0.90)]
        case "vintage":
            return [Color(red: 0.85, green: 0.75, blue: 0.55), Color(red: 0.60, green: 0.50, blue: 0.40)]
        case "film":
            return [Color(red: 0.45, green: 0.65, blue: 0.60), Color(red: 0.80, green: 0.60, blue: 0.45)]
        case "blackwhite":
            return [Color(white: 0.88), Color(white: 0.22)]
        case "soft":
            return [Color(red: 0.98, green: 0.88, blue: 0.88), Color(red: 0.88, green: 0.88, blue: 0.95)]
        default:
            return [Color.gray.opacity(0.6), Color.gray.opacity(0.3)]
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: gradientColors,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(preset.nameVN).font(.caption2).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preset màu \(preset.nameVN)")
        .help("Preset \(preset.nameVN)")
    }
}

struct CaptureCountPicker: View {
    @Binding var count: Int

    var body: some View {
        Picker("Số ảnh của phiên", selection: $count) {
            ForEach(1...ResourceLimits.maxCaptureIndices, id: \.self) { count in
                Text("\(count)").tag(count)
            }
        }
        .fixedSize()
    }
}
