import Foundation
import AppKit

/// SettingsStore (§15.1): bảng giá trị mặc định đầy đủ; thay đổi đơn giản auto-persist.
/// safetySave không có control (Always On); trashRetention chỉ đọc.
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    public static let defaultsDictionary: [String: Any] = [
        "appearance": AppearanceMode.system.rawValue,
        "startupScreen": "capture",
        "rememberWindow": true,
        "cameraSelection": "auto",
        "cameraResolution": "best",
        "previewMirror": true,
        "outputMirror": false,
        "rotation": 0,
        "captureMode": CaptureMode.automatic.rawValue,
        "countdown": 3,
        "interval": 2,
        "liveFramePreview": false,
        "soundEnabled": true,
        "soundVolume": 50,
        "soundCountdown": true,
        "soundShutter": true,
        "soundFinish": true,
        "defaultPreset": "natural",
        "presetIntensity": 100,
        "defaultSkinSmooth": 25,
        "smartFace": true,
        "defaultCrop": CropMode.autoFace.rawValue,
        "previewQuality": "auto",
        "exportFormat": ExportImageFormat.jpeg.rawValue,
        "jpegQuality": 95,
        "autoExport": false,
        "fullscreenDefaultFrame": "",
        "fullscreenFrameFilter": "all",
        "fullscreenIdleReturn": 30,
        "fullscreenAllowRetake": true,
        "fullscreenAllowShare": true,
        "exportWidth": 1200,
        "exportHeight": 1800
    ]

    private func registerDefaults() {
        defaults.register(defaults: Self.defaultsDictionary)
    }

    // MARK: - Chung

    public var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "system") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appearance")
            applyAppearance(newValue)
            EventBus.shared.post(.settingsChanged(key: "appearance"))
        }
    }

    public func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    public var startupScreen: String {
        get { defaults.string(forKey: "startupScreen") ?? "capture" }
        set { defaults.set(newValue, forKey: "startupScreen") }
    }

    public var rememberWindow: Bool {
        get { defaults.bool(forKey: "rememberWindow") }
        set { defaults.set(newValue, forKey: "rememberWindow") }
    }

    // MARK: - Camera

    public var cameraSelection: String {   // "auto" hoặc device uniqueID
        get { defaults.string(forKey: "cameraSelection") ?? "auto" }
        set { defaults.set(newValue, forKey: "cameraSelection") }
    }
    public var cameraResolution: String {
        get { defaults.string(forKey: "cameraResolution") ?? "best" }
        set { defaults.set(newValue, forKey: "cameraResolution") }
    }
    public var previewMirror: Bool {
        get { defaults.bool(forKey: "previewMirror") }
        set { defaults.set(newValue, forKey: "previewMirror") }
    }
    public var outputMirror: Bool {
        get { defaults.bool(forKey: "outputMirror") }
        set { defaults.set(newValue, forKey: "outputMirror") }
    }
    public var rotation: Int {
        get { defaults.integer(forKey: "rotation") }
        set { defaults.set(newValue, forKey: "rotation") }
    }

    // MARK: - Chụp

    public var captureMode: CaptureMode {
        get { CaptureMode(rawValue: defaults.string(forKey: "captureMode") ?? "automatic") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "captureMode") }
    }
    public var countdown: Int {
        get { min(max(defaults.integer(forKey: "countdown"), 0), 30) }
        set { defaults.set(min(max(newValue, 0), 30), forKey: "countdown") }
    }
    public var interval: Int {
        get { min(max(defaults.integer(forKey: "interval"), 0), 15) }
        set { defaults.set(min(max(newValue, 0), 15), forKey: "interval") }
    }
    public var liveFramePreview: Bool {
        get { defaults.bool(forKey: "liveFramePreview") }
        set { defaults.set(newValue, forKey: "liveFramePreview") }
    }

    // MARK: - Âm thanh

    public var soundEnabled: Bool {
        get { defaults.bool(forKey: "soundEnabled") }
        set { defaults.set(newValue, forKey: "soundEnabled") }
    }
    public var soundVolume: Int {
        get { defaults.integer(forKey: "soundVolume") }
        set { defaults.set(newValue, forKey: "soundVolume") }
    }
    public var soundCountdown: Bool {
        get { defaults.bool(forKey: "soundCountdown") }
        set { defaults.set(newValue, forKey: "soundCountdown") }
    }
    public var soundShutter: Bool {
        get { defaults.bool(forKey: "soundShutter") }
        set { defaults.set(newValue, forKey: "soundShutter") }
    }
    public var soundFinish: Bool {
        get { defaults.bool(forKey: "soundFinish") }
        set { defaults.set(newValue, forKey: "soundFinish") }
    }

    // MARK: - Màu & làm đẹp

    public var defaultPreset: String {
        get { defaults.string(forKey: "defaultPreset") ?? "natural" }
        set { defaults.set(newValue, forKey: "defaultPreset") }
    }
    public var presetIntensity: Int {   // 0..100 UI; nội bộ /100
        get { defaults.integer(forKey: "presetIntensity") }
        set { defaults.set(newValue, forKey: "presetIntensity") }
    }
    public var defaultSkinSmooth: Int { // 0..100
        get { defaults.integer(forKey: "defaultSkinSmooth") }
        set { defaults.set(newValue, forKey: "defaultSkinSmooth") }
    }
    public var smartFace: Bool {
        get { defaults.bool(forKey: "smartFace") }
        set { defaults.set(newValue, forKey: "smartFace") }
    }
    public var defaultCrop: CropMode {
        get { CropMode(rawValue: defaults.string(forKey: "defaultCrop") ?? "auto_face") ?? .autoFace }
        set { defaults.set(newValue.rawValue, forKey: "defaultCrop") }
    }
    public var previewQuality: String {
        get { defaults.string(forKey: "previewQuality") ?? "auto" }
        set { defaults.set(newValue, forKey: "previewQuality") }
    }

    // MARK: - Lưu trữ / Export

    public var exportFormat: ExportImageFormat {
        get { ExportImageFormat(rawValue: defaults.string(forKey: "exportFormat") ?? "jpeg") ?? .jpeg }
        set { defaults.set(newValue.rawValue, forKey: "exportFormat") }
    }
    public var jpegQuality: Int {
        get { min(max(defaults.integer(forKey: "jpegQuality"), 1), 100) }
        set { defaults.set(min(max(newValue, 1), 100), forKey: "jpegQuality") }
    }
    public var exportFolderBookmarkID: String? {
        get { defaults.string(forKey: "exportFolderBookmarkID") }
        set { defaults.set(newValue, forKey: "exportFolderBookmarkID") }
    }
    public var autoExport: Bool {
        get { defaults.bool(forKey: "autoExport") }
        set { defaults.set(newValue, forKey: "autoExport") }
    }
    public var exportWidth: Int {
        get { defaults.integer(forKey: "exportWidth") }
        set { defaults.set(newValue, forKey: "exportWidth") }
    }
    public var exportHeight: Int {
        get { defaults.integer(forKey: "exportHeight") }
        set { defaults.set(newValue, forKey: "exportHeight") }
    }

    // MARK: - Toàn màn hình (§14, §15.1)

    public var fullscreenDefaultFrame: String {
        get { defaults.string(forKey: "fullscreenDefaultFrame") ?? "" }
        set { defaults.set(newValue, forKey: "fullscreenDefaultFrame") }
    }
    public var fullscreenFrameFilter: String {  // "all" hoặc categoryID
        get { defaults.string(forKey: "fullscreenFrameFilter") ?? "all" }
        set { defaults.set(newValue, forKey: "fullscreenFrameFilter") }
    }
    public var fullscreenIdleReturn: Int {  // 0/15/30/60/120
        get { defaults.integer(forKey: "fullscreenIdleReturn") }
        set { defaults.set(newValue, forKey: "fullscreenIdleReturn") }
    }
    public var fullscreenAllowRetake: Bool {
        get { defaults.bool(forKey: "fullscreenAllowRetake") }
        set { defaults.set(newValue, forKey: "fullscreenAllowRetake") }
    }
    public var fullscreenAllowShare: Bool {
        get { defaults.bool(forKey: "fullscreenAllowShare") }
        set { defaults.set(newValue, forKey: "fullscreenAllowShare") }
    }

    // MARK: - Snapshot cho phiên mới (§8.3)

    public func sessionDefaultsSnapshot() -> SessionDefaultsSnapshot {
        let presetID = defaultPreset
        let preset = BuiltinPreset.byID(presetID)
        let params = preset?.parameters ?? .natural
        return SessionDefaultsSnapshot(
            parameterVersion: ColorMappingVersion.current,
            presetID: presetID,
            presetName: preset?.nameVN ?? "Tự nhiên",
            presetResolvedParameters: params,
            presetIntensity: Double(presetIntensity) / 100.0,
            color: .neutral,
            skinSmooth: Double(defaultSkinSmooth) / 100.0,
            outputMirror: outputMirror)
    }

    /// Đặt lại toàn bộ cài đặt (không xóa dữ liệu §15.2 Dữ liệu).
    public func resetAll() {
        for (key, value) in Self.defaultsDictionary {
            defaults.set(value, forKey: key)
        }
        defaults.removeObject(forKey: "exportFolderBookmarkID")
        applyAppearance(.system)
        objectWillChange.send()
        EventBus.shared.post(.settingsChanged(key: "all"))
    }
}
