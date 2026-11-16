import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Màn hình E — Cài đặt (§2.6, §15): 8 trang, auto-persist, không có tab Quản trị/PIN.
public struct SettingsView: View {
    @ObservedObject var env: AppEnvironment
    @State private var selectedSection: SettingsSection = .general

    public enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "Chung"
        case camera = "Camera"
        case capture = "Chụp"
        case color = "Màu sắc"
        case sound = "Âm thanh"
        case storage = "Lưu trữ"
        case fullscreen = "Toàn màn hình"
        case data = "Dữ liệu"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .camera: return "camera"
            case .capture: return "timer"
            case .color: return "camera.filters"
            case .sound: return "speaker.wave.2"
            case .storage: return "internaldrive"
            case .fullscreen: return "rectangle.expand.vertical"
            case .data: return "externaldrive.badge.timemachine"
            }
        }
        public var id: String { rawValue }
    }

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            ScrollView {
                Group {
                    switch selectedSection {
                    case .general: GeneralPane(env: env)
                    case .camera: CameraPane(env: env)
                    case .capture: CapturePane(env: env)
                    case .color: ColorPane(env: env)
                    case .sound: SoundPane(env: env)
                    case .storage: StoragePane(env: env)
                    case .fullscreen: FullscreenPane(env: env)
                    case .data: DataPane(env: env)
                    }
                }
                .frame(maxWidth: 640, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if let section = env.consumePendingSettingsSection() {
                selectedSection = section
            }
        }
        .onChange(of: env.route) { r in
            if r == .settings {
                if let section = env.consumePendingSettingsSection() {
                    selectedSection = section
                }
            }
        }
    }
}

// MARK: - Rows dùng chung

struct SettingsRow<Content: View>: View {
    var label: String
    var description: String? = nil
    var tooltip: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                rowLabel.frame(width: 250, alignment: .leading)
                Spacer(minLength: 0)
                content.help(tooltip ?? label)
            }
            VStack(alignment: .leading, spacing: 8) {
                rowLabel
                content.help(tooltip ?? label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var rowLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            if let description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsSectionTitle: View {
    var text: String
    var body: some View {
        Text(text).font(.headline).padding(.bottom, 4)
    }
}

// MARK: - Chung

struct GeneralPane: View {
    @ObservedObject var env: AppEnvironment
    @State private var appearance: AppearanceMode = .system
    @State private var startupScreen = "capture"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Giao diện & khởi động")
            SettingsRow(label: "Giao diện", description: "Light/Dark/System, áp dụng ngay") {
                Picker("", selection: $appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 180)
                .onChange(of: appearance) { env.settings.appearance = $0 }
            }
            SettingsRow(label: "Màn hình mở đầu", description: "Áp dụng lần mở tiếp theo") {
                Picker("", selection: $startupScreen) {
                    Text("Chụp").tag("capture")
                    Text("Khung").tag("frames")
                    Text("Thư viện").tag("library")
                }
                .frame(width: 180)
                .onChange(of: startupScreen) { env.settings.startupScreen = $0 }
            }
            // "Ghi nhớ cửa sổ" đã ẩn: cài đặt chưa được wire (không lưu/phục hồi khung cửa sổ)
            // — không hiển thị toggle không có tác dụng.
            Divider()
            SettingsRow(label: "Ngôn ngữ", description: "UI tiếng Việt (đặc tả v1.2)") {
                Text("Tiếng Việt").foregroundStyle(.secondary)
            }
            Divider()
            SettingsRow(label: "Lưu an toàn (Safety Save)",
                        description: "Bắt buộc — không có nút tắt. Ảnh gốc luôn được lưu để chỉnh lại và khôi phục.") {
                Label("Luôn bật", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            SettingsRow(label: "Thùng rác nội bộ", description: "Tự dọn sau 30 × 24 giờ (chỉ đọc)") {
                Text("30 ngày").foregroundStyle(.secondary)
            }
        }
        .onAppear {
            appearance = env.settings.appearance
            startupScreen = env.settings.startupScreen
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: - Camera (§15.2)

struct CameraPane: View {
    @ObservedObject var env: AppEnvironment
    @State private var devices: [CameraDescriptor] = []
    @State private var selection = "auto"
    @State private var previewMirror = true
    @State private var outputMirror = false
    @State private var rotation = 0
    @State private var caps: CameraCapabilities?

    var busy: Bool { env.engine.isCaptureBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Camera (§4)")
            SettingsRow(label: "Thiết bị", description: "Mac, USB, Continuity Camera") {
                Picker("", selection: Binding(
                    get: { selection },
                    set: { id in
                        selection = id
                        Task {
                            await env.capturePreview.choose(id)
                            await reloadCaps()
                        }
                    }
                )) {
                    Text("Tự động (systemPreferred)").tag("auto")
                    ForEach(devices, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(d.uniqueID)
                    }
                }
                .frame(width: 260)
                .disabled(busy)
                .help(busy ? "Thay đổi sau khi kết thúc phiên" : "Áp dụng ở safe point")
            }
            SettingsRow(label: "Độ phân giải", description: "Best stable khi khả dụng") {
                Picker("", selection: Binding(get: { env.settings.cameraResolution },
                                              set: { env.settings.cameraResolution = $0 })) {
                    Text("Best stable").tag("best")
                    if let caps {
                        ForEach(caps.resolutions, id: \.self) { r in
                            Text("\(Int(r.width))×\(Int(r.height))").tag("\(Int(r.width))x\(Int(r.height))")
                        }
                    }
                }
                .frame(width: 260)
                .disabled(caps == nil || busy)
            }
            SettingsRow(label: "Lật preview", description: "Chỉ đổi cách nhìn, không ảnh hưởng ảnh xuất (§4.4)") {
                Toggle("", isOn: $previewMirror).onChange(of: previewMirror) { env.settings.previewMirror = $0 }
            }
            SettingsRow(label: "Lật ảnh xuất (OutputMirror)",
                        description: "Snapshot vào phiên mới; metadata đầu vào đã flip một lần duy nhất") {
                Toggle("", isOn: $outputMirror)
                    .disabled(busy)
                    .onChange(of: outputMirror) { env.settings.outputMirror = $0 }
            }
            SettingsRow(label: "Xoay", description: "Safe point") {
                Picker("", selection: $rotation) {
                    Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
                }
                .frame(width: 120)
                .disabled(busy)
                .onChange(of: rotation) { env.settings.rotation = $0 }
            }
            Divider()
            SettingsSectionTitle(text: "Nâng cao — chỉ hiện khi phần cứng hỗ trợ (CAM-06)")
            if let caps {
                SettingsRow(label: "Khóa Focus/Exposure/WB",
                            description: caps.supportsFocus || caps.supportsExposure || caps.supportsWhiteBalance
                                ? "Áp dụng lên thiết bị đang chọn"
                                : "Camera này không hỗ trợ điều khiển nâng cao") {
                    HStack {
                        Button("Áp dụng") {
                            Task {
                                _ = try? await env.camera.applyControls(
                                    CameraControls(focusLocked: caps.supportsFocus ? true : nil,
                                                   exposureLocked: caps.supportsExposure ? true : nil,
                                                   whiteBalanceLocked: caps.supportsWhiteBalance ? true : nil))
                            }
                        }
                        .disabled(!caps.supportsFocus && !caps.supportsExposure && !caps.supportsWhiteBalance)
                        Button("Đặt lại camera") {
                            Task {
                                _ = try? await env.camera.applyControls(
                                    CameraControls(focusLocked: false, exposureLocked: false, whiteBalanceLocked: false))
                            }
                        }
                        .help("Chỉ reset các thông số app điều khiển (§4.4)")
                    }
                }
            } else {
                Text("Chưa có camera — cắm camera hoặc cấp quyền để xem điều khiển nâng cao.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            selection = env.settings.cameraSelection
            previewMirror = env.settings.previewMirror
            outputMirror = env.settings.outputMirror
            rotation = env.settings.rotation
            Task {
                devices = await env.camera.discoverDevices()
                await reloadCaps()
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func reloadCaps() async {
        caps = await env.camera.currentDevice?.capabilities
    }
}

// MARK: - Chụp

struct CapturePane: View {
    @ObservedObject var env: AppEnvironment
    @State private var mode = CaptureMode.automatic
    @State private var countdown = 3
    @State private var interval = 2
    @State private var liveFramePreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Chụp (§15.1)")
            SettingsRow(label: "Chế độ", description: "Phiên mới") {
                Picker("", selection: $mode) {
                    ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 200)
                .onChange(of: mode) { env.settings.captureMode = $0 }
            }
            SettingsRow(label: "Đếm ngược", description: "0/3/5/10/tùy chỉnh 1..30") {
                Stepper("\(countdown)s", value: $countdown, in: 0...30)
                    .onChange(of: countdown) { env.settings.countdown = $0 }
            }
            SettingsRow(label: "Nghỉ giữa lượt", description: "0–15 giây") {
                Stepper("\(interval)s", value: $interval, in: 0...15)
                    .onChange(of: interval) { env.settings.interval = $0 }
            }
            SettingsRow(label: "Live Frame Preview",
                        description: "Xem trước trong khung khi chụp (giảm chất lượng để đạt FPS §8.1)") {
                Toggle("", isOn: $liveFramePreview).onChange(of: liveFramePreview) { env.settings.liveFramePreview = $0 }
            }
            Divider()
            Button("Khôi phục mặc định nhóm này") {
                env.settings.captureMode = .automatic
                env.settings.countdown = 3
                env.settings.interval = 2
                env.settings.liveFramePreview = false
                mode = .automatic; countdown = 3; interval = 2; liveFramePreview = false
            }
        }
        .onAppear {
            mode = env.settings.captureMode
            countdown = env.settings.countdown
            interval = env.settings.interval
            liveFramePreview = env.settings.liveFramePreview
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: - Màu & làm đẹp

struct ColorPane: View {
    @ObservedObject var env: AppEnvironment
    @State private var preset = "natural"
    @State private var intensity = 100
    @State private var smartFace = true
    @State private var defaultCrop = CropMode.autoFace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Màu sắc (§8, §9)")
            SettingsRow(label: "Preset mặc định", description: "Áp dụng cho phiên mới") {
                Picker("", selection: $preset) {
                    ForEach(BuiltinPreset.all, id: \.id) { Text($0.nameVN).tag($0.id) }
                }
                .frame(width: 180)
                .onChange(of: preset) { env.settings.defaultPreset = $0 }
            }
            SettingsRow(label: "Preset Intensity", description: "0–100") {
                Slider(value: Binding(get: { Double(intensity) }, set: { intensity = Int($0) }), in: 0...100)
                    .frame(width: 200)
                Text("\(intensity)%").monospacedDigit()
            }
            .onChange(of: intensity) { env.settings.presetIntensity = $0 }
            SettingsRow(label: "Smart Face Positioning", description: "Tự crop theo khuôn mặt (§9.1)") {
                Toggle("", isOn: $smartFace).onChange(of: smartFace) { env.settings.smartFace = $0 }
            }
            SettingsRow(label: "Crop mặc định", description: "Slot placement mới") {
                Picker("", selection: $defaultCrop) {
                    ForEach(CropMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 200)
                .onChange(of: defaultCrop) { env.settings.defaultCrop = $0 }
            }
        }
        .onAppear {
            preset = env.settings.defaultPreset
            intensity = env.settings.presetIntensity
            smartFace = env.settings.smartFace
            defaultCrop = env.settings.defaultCrop
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: - Âm thanh

struct SoundPane: View {
    @ObservedObject var env: AppEnvironment
    @State private var enabled = true
    @State private var volume = 50
    @State private var countdown = true
    @State private var shutter = true
    @State private var finish = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Âm thanh (§5.6)")
            SettingsRow(label: "Bật âm thanh") {
                Toggle("", isOn: $enabled).onChange(of: enabled) { env.settings.soundEnabled = $0 }
            }
            SettingsRow(label: "Âm lượng") {
                HStack {
                    Slider(value: Binding(get: { Double(volume) }, set: { volume = Int($0) }), in: 0...100)
                        .frame(width: 200)
                    Text("\(volume)%").monospacedDigit()
                }
            }
            .disabled(!enabled)
            .onChange(of: volume) { env.settings.soundVolume = $0 }
            SettingsRow(label: "Tiếng tick đếm ngược") {
                Toggle("", isOn: $countdown).onChange(of: countdown) { env.settings.soundCountdown = $0 }
            }
            .disabled(!enabled)
            SettingsRow(label: "Tiếng chụp (shutter)") {
                Toggle("", isOn: $shutter).onChange(of: shutter) { env.settings.soundShutter = $0 }
            }
            .disabled(!enabled)
            SettingsRow(label: "Tiếng hoàn thành") {
                Toggle("", isOn: $finish).onChange(of: finish) { env.settings.soundFinish = $0 }
            }
            .disabled(!enabled)
            Button("Nghe thử") {
                env.audio.handle(.preview("Glass"))
            }
            .disabled(!enabled)
        }
        .onAppear {
            enabled = env.settings.soundEnabled
            volume = env.settings.soundVolume
            countdown = env.settings.soundCountdown
            shutter = env.settings.soundShutter
            finish = env.settings.soundFinish
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: - Lưu trữ

struct StoragePane: View {
    @ObservedObject var env: AppEnvironment
    @State private var format = ExportImageFormat.jpeg
    @State private var quality = 95
    @State private var autoExport = false
    @State private var sizeText = ""
    @State private var bookmarkLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Lưu trữ & xuất (§15.2)")
            SettingsRow(label: "Định dạng xuất mặc định") {
                Picker("", selection: $format) {
                    Text("JPG").tag(ExportImageFormat.jpeg)
                    Text("PNG").tag(ExportImageFormat.png)
                }
                .frame(width: 140)
                .onChange(of: format) { env.settings.exportFormat = $0 }
            }
            SettingsRow(label: "Chất lượng JPG", description: "1–100") {
                Slider(value: Binding(get: { Double(quality) }, set: { quality = Int($0) }), in: 1...100)
                    .frame(width: 200)
                Text("\(quality)").monospacedDigit()
            }
            .disabled(format == .png)
            .onChange(of: quality) { env.settings.jpegQuality = $0 }
            SettingsRow(label: "Auto Export khi Hoàn thành",
                        description: "Mặc định Tắt. Lỗi export không ảnh hưởng phiên đã lưu (§10.1)") {
                Toggle("", isOn: $autoExport).onChange(of: autoExport) { env.settings.autoExport = $0 }
            }
            SettingsRow(label: "Thư mục xuất mặc định", description: "Security-scoped bookmark (§10.4)") {
                Text(bookmarkLabel.isEmpty ? bookmarkText() : bookmarkLabel).font(.caption).foregroundStyle(.secondary)
                Button("Chọn…") { chooseFolder() }
            }
            Divider()
            SettingsRow(label: "Dung lượng dữ liệu", description: "Thư viện nội bộ") {
                Text(env.storageMeasurement.formattedText).foregroundStyle(.secondary)
            }
            SettingsRow(label: "Ảnh nguồn", description: "Luôn được lưu trong thư viện để có thể chỉnh sửa và khôi phục") {
                Label("Luôn bật", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            Button(env.isCleaningCache ? "Đang dọn bộ nhớ đệm…" : "Dọn bộ nhớ đệm") {
                env.cleanCache()
            }
            .disabled(env.isCleaningCache)
            .help("Cache thumbnail/preview có thể tạo lại, không thuộc Trash 30 ngày (§10.5)")
            Button("Hiện thư mục dữ liệu") {
                env.shareService.revealInFinder(env.layout.rootURL)
            }
        }
        .onAppear {
            format = env.settings.exportFormat
            quality = env.settings.jpegQuality
            autoExport = env.settings.autoExport
            bookmarkLabel = bookmarkText()
            env.requestStorageMeasurement()
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func bookmarkText() -> String {
        guard let id = env.settings.exportFolderBookmarkID,
              let bm = try? env.trashRepo.bookmark(id: id),
              let path = bm.displayPath else { return "Chưa đặt (mỗi lần xuất sẽ hỏi)" }
        return path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try env.saveDefaultExportFolder(url)
                    bookmarkLabel = url.path
                } catch {
                    env.showToast("Không lưu được thư mục xuất mặc định. Hãy chọn lại.", kind: .warning)
                }
            }
        }
    }
}

// MARK: - Toàn màn hình

struct FullscreenPane: View {
    @ObservedObject var env: AppEnvironment
    @State private var defaultFrame = ""
    @State private var filter = "all"
    @State private var idleReturn = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Toàn màn hình")
            SettingsRow(label: "Khung mặc định", description: "Màn hình chờ") {
                Picker("", selection: $defaultFrame) {
                    Text("Khung hiện tại").tag("")
                    ForEach((try? env.frames.listReadyFrames()) ?? [], id: \.id) { f in
                        Text(f.name).tag(f.id)
                    }
                }
                .frame(width: 220)
                .onChange(of: defaultFrame) { env.settings.fullscreenDefaultFrame = $0 }
            }
            SettingsRow(label: "Lọc khung", description: "Tất cả hoặc danh mục") {
                Picker("", selection: $filter) {
                    Text("Tất cả").tag("all")
                    ForEach((try? env.frames.listCategories()) ?? [], id: \.id) { c in
                        Text(c.name).tag(c.id)
                    }
                }
                .frame(width: 220)
                .onChange(of: filter) { env.settings.fullscreenFrameFilter = $0 }
            }
            SettingsRow(label: "Tự quay về màn hình chờ", description: "Chỉ áp dụng ở màn hoàn thành") {
                Picker("", selection: $idleReturn) {
                    Text("Tắt").tag(0)
                    Text("15s").tag(15)
                    Text("30s").tag(30)
                    Text("60s").tag(60)
                    Text("120s").tag(120)
                }
                .frame(width: 140)
                .onChange(of: idleReturn) { env.settings.fullscreenIdleReturn = $0 }
            }
            // "Cho phép chụp lại/chia sẻ" đã ẩn: fullscreen chưa có nút retake/share —
            // toggle không có tác dụng, không hiển thị.
        }
        .onAppear {
            defaultFrame = env.settings.fullscreenDefaultFrame
            filter = env.settings.fullscreenFrameFilter
            idleReturn = env.settings.fullscreenIdleReturn
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: - Dữ liệu

struct DataPane: View {
    @ObservedObject var env: AppEnvironment
    @State private var trashSize = ""
    @State private var confirmReset = false
    @State private var confirmEmptyTrash = false
    @State private var pendingPurgeItems: [TrashItem] = []
    @State private var pendingPurgeBytes: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Dữ liệu (§15.2)")
            Button("Sao lưu thư viện khung (Frame Pack)") {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "photoframepack") ?? .data]
                panel.nameFieldStringValue = "Khung_backup.photoframepack"
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    Task { @MainActor in
                        let frames = (try? env.frames.listFrames().map(\.id)) ?? []
                        let packService = env.packService
                        let target = url
                        do {
                            let result = try await Task.detached(priority: .userInitiated) { () -> FramePackService.BuildPackResult in
                                let res = try packService.preparePack(name: "Khung backup", frameIDs: frames)
                                try res.data.write(to: target, options: .atomic)
                                return res
                            }.value
                            if result.skippedDraftCount > 0 {
                                env.showToast("Đã sao lưu \(result.packedFramesCount) khung (bỏ qua \(result.skippedDraftCount) bản nháp)")
                            } else {
                                env.showToast("Đã sao lưu \(result.packedFramesCount) khung")
                            }
                        } catch {
                            env.showToast("Sao lưu thất bại: \((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
                        }
                    }
                }
            }
            Button("Khôi phục từ Frame Pack…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "photoframepack") ?? .data]
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    Task { @MainActor in
                        env.pendingPackURL = url
                        env.showPackImport = true
                    }
                }
            }
            Button("Mở Thùng rác") { env.route = .trash }
            SettingsRow(label: "Dung lượng Thùng rác", description: "Ước tính") {
                Text(trashSize).foregroundStyle(.secondary)
            }
            Button(env.isManualPurging ? "Đang dọn Thùng rác…" : "Dọn sạch Thùng rác", role: .destructive) {
                let all = (try? env.trashRepo.list()) ?? []
                let eligible = all.filter { $0.status == .trashed || $0.status == .purgeFailed }
                guard !eligible.isEmpty else {
                    env.showToast("Thùng rác trống", kind: .info)
                    return
                }
                pendingPurgeItems = eligible
                pendingPurgeBytes = eligible.reduce(Int64(0)) { $0 + $1.estimatedBytes }
                confirmEmptyTrash = true
            }
            .disabled(env.isManualPurging)
            .confirmationDialog("Không thể khôi phục sau thao tác này", isPresented: $confirmEmptyTrash) {
                Button("Dọn sạch \(pendingPurgeItems.count) mục", role: .destructive) {
                    guard let taskID = env.beginManualPurge() else {
                        env.showToast("Đang có tác vụ dọn khác đang chạy", kind: .warning)
                        return
                    }

                    let freshAll = (try? env.trashRepo.list()) ?? []
                    let freshEligible = freshAll.filter { $0.status == .trashed || $0.status == .purgeFailed }
                    let freshBytes = freshEligible.reduce(Int64(0)) { $0 + $1.estimatedBytes }

                    if Set(freshEligible.map(\.id)) != Set(pendingPurgeItems.map(\.id)) || freshBytes != pendingPurgeBytes {
                        env.endManualPurge(taskID: taskID)
                        env.showToast("Danh sách mục hoặc dung lượng đã thay đổi. Vui lòng xác nhận lại.", kind: .warning)
                        let bytes = (try? env.trashRepo.totalBytes()) ?? 0
                        trashSize = FileLayout.formattedBytes(bytes)
                        return
                    }

                    let trashService = env.trashService
                    let trashRepo = env.trashRepo
                    let itemsToPurge = freshEligible

                    Task.detached(priority: .utility) {
                        let report = trashService.purgeAll(items: itemsToPurge)
                        await MainActor.run {
                            env.endManualPurge(taskID: taskID)
                            if report.failed > 0 {
                                env.showToast("Dọn sạch: \(report.success) thành công / \(report.failed) lỗi / \(report.skipped) bỏ qua", kind: .warning)
                            } else if report.skipped > 0 {
                                env.showToast("Đã dọn sạch \(report.success) mục (\(report.skipped) mục bỏ qua)")
                            } else {
                                env.showToast("Đã dọn sạch \(report.success) mục")
                            }
                            let bytes = (try? trashRepo.totalBytes()) ?? 0
                            trashSize = FileLayout.formattedBytes(bytes)
                        }
                    }
                }
                Button("Hủy", role: .cancel) {
                    pendingPurgeItems = []
                    pendingPurgeBytes = 0
                }
            } message: {
                Text("Dọn sạch toàn bộ \(pendingPurgeItems.count) mục trong Thùng rác (\(FileLayout.formattedBytes(pendingPurgeBytes)))?\nKhông thể khôi phục sau thao tác này.")
            }
            Divider()
            Button("Đặt lại cài đặt", role: .destructive) { confirmReset = true }
                .confirmationDialog("Đặt lại toàn bộ cài đặt (không xóa dữ liệu)?", isPresented: $confirmReset) {
                    Button("Đặt lại", role: .destructive) {
                        // Xóa bookmark row mồ côi trước khi reset key (P3-19)
                        if let bmID = env.settings.exportFolderBookmarkID {
                            try? env.trashRepo.deleteBookmark(id: bmID)
                        }
                        env.settings.resetAll()
                        env.showToast("Đã đặt lại cài đặt")
                    }
                    Button("Hủy", role: .cancel) {}
                }
            Divider()
            Text("Phiên bản: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0") — Offline, không backend, không thu thập dữ liệu.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            let bytes = (try? env.trashRepo.totalBytes()) ?? 0
            trashSize = FileLayout.formattedBytes(bytes)
        }
        .task {
            for await _ in EventBus.shared.stream {
                let bytes = (try? env.trashRepo.totalBytes()) ?? 0
                await MainActor.run {
                    trashSize = FileLayout.formattedBytes(bytes)
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}
