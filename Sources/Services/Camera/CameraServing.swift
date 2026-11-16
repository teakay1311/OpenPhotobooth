import Foundation
import CoreGraphics

/// Hợp đồng CameraService (§4.1): chỉ quản lý thiết bị, quyền, session, preview và still.
/// KHÔNG biết bảng phiên chụp, Thùng rác hay Frame Editor.
public typealias CameraID = String

public struct CameraDescriptor: Equatable, Sendable {
    public var uniqueID: CameraID
    public var localizedName: String
    public var kind: CameraKind
    public var isConnected: Bool
    public var isSystemPreferred: Bool
    public var capabilities: CameraCapabilities

    public init(uniqueID: CameraID, localizedName: String, kind: CameraKind,
                isConnected: Bool, isSystemPreferred: Bool, capabilities: CameraCapabilities) {
        self.uniqueID = uniqueID; self.localizedName = localizedName; self.kind = kind
        self.isConnected = isConnected; self.isSystemPreferred = isSystemPreferred
        self.capabilities = capabilities
    }
}

public struct CameraCapabilities: Equatable, Sendable {
    public var supportsStillPhoto: Bool
    public var resolutions: [CGSize]
    public var supportsFocus: Bool
    public var supportsExposure: Bool
    public var supportsWhiteBalance: Bool
    public var supportsFrameRate: Bool
    public var minFrameRate: Double
    public var maxFrameRate: Double
    public var maxPhotoDimensions: CGSize

    public init(supportsStillPhoto: Bool = true, resolutions: [CGSize] = [],
                supportsFocus: Bool = false, supportsExposure: Bool = false,
                supportsWhiteBalance: Bool = false, supportsFrameRate: Bool = false,
                minFrameRate: Double = 15, maxFrameRate: Double = 30,
                maxPhotoDimensions: CGSize = .zero) {
        self.supportsStillPhoto = supportsStillPhoto
        self.resolutions = resolutions
        self.supportsFocus = supportsFocus; self.supportsExposure = supportsExposure
        self.supportsWhiteBalance = supportsWhiteBalance; self.supportsFrameRate = supportsFrameRate
        self.minFrameRate = minFrameRate; self.maxFrameRate = maxFrameRate
        self.maxPhotoDimensions = maxPhotoDimensions
    }
}

public struct CameraControls: Equatable, Sendable {
    public var focusLocked: Bool?
    public var exposureLocked: Bool?
    public var whiteBalanceLocked: Bool?
    public var frameRate: Double?
    public var previewMirror: Bool?
    public var outputMirror: Bool?
    public var rotation: Int?

    public init(focusLocked: Bool? = nil, exposureLocked: Bool? = nil,
                whiteBalanceLocked: Bool? = nil, frameRate: Double? = nil,
                previewMirror: Bool? = nil, outputMirror: Bool? = nil, rotation: Int? = nil) {
        self.focusLocked = focusLocked; self.exposureLocked = exposureLocked
        self.whiteBalanceLocked = whiteBalanceLocked; self.frameRate = frameRate
        self.previewMirror = previewMirror; self.outputMirror = outputMirror; self.rotation = rotation
    }
}

public struct AppliedControls: Equatable, Sendable {
    public var focusLocked: Bool
    public var exposureLocked: Bool
    public var whiteBalanceLocked: Bool
    public var frameRate: Double?
    public var appliedAtMs: Int64

    public init(focusLocked: Bool = false, exposureLocked: Bool = false,
                whiteBalanceLocked: Bool = false, frameRate: Double? = nil) {
        self.focusLocked = focusLocked; self.exposureLocked = exposureLocked
        self.whiteBalanceLocked = whiteBalanceLocked; self.frameRate = frameRate
        self.appliedAtMs = Time.nowMs()
    }
}

public enum CameraEvent: Equatable, Sendable {
    case deviceConnected(CameraID)
    case deviceDisconnected(CameraID)
    case systemPreferredChanged(CameraID?)
    case interruptionStarted(reason: String)
    case interruptionEnded
    case pressureWarning
    case fatalFailure(String)
    case permissionChanged
}

public struct CapturedImagePayload: @unchecked Sendable {
    public var data: Data            // JPEG bytes + EXIF
    public var actualWidth: Int
    public var actualHeight: Int
    public var orientation: Int      // EXIF 1..8
    public var colorProfile: String?
    public var capturedAtMs: Int64
    public var requestID: String
    public var codec: String         // "jpeg" hoặc "video-frame" (fallback §4.4)

    public init(data: Data, actualWidth: Int, actualHeight: Int, orientation: Int,
                colorProfile: String?, capturedAtMs: Int64, requestID: String, codec: String) {
        self.data = data; self.actualWidth = actualWidth; self.actualHeight = actualHeight
        self.orientation = orientation; self.colorProfile = colorProfile
        self.capturedAtMs = capturedAtMs; self.requestID = requestID; self.codec = codec
    }
}

public protocol CameraServing: AnyObject {
    /// Đọc trạng thái quyền hiện tại của camera mà không khởi phát yêu cầu cấp quyền (§4.3, BUG-CAM-01).
    func cameraPermissionState() async -> CameraPermissionState
    /// Chỉ khởi phát prompt xin quyền khi trạng thái là notDetermined và được gọi từ thao tác chủ động của người dùng.
    func requestAccessIfNeeded() async -> CameraPermissionState
    func discoverDevices() async -> [CameraDescriptor]
    func selectDevice(_ id: CameraID) async throws -> CameraCapabilities
    /// Chọn camera theo mode auto (systemPreferredCamera hoặc device đầu tiên).
    func selectAutoDevice() async throws -> CameraCapabilities
    /// Trả thành công sau khi nhận frame đầu tiên của lần khởi động hiện tại.
    func startPreview() async throws
    var isPreviewRunning: Bool { get async }
    func stopPreview() async
    /// Fallback still từ video khi thiết bị không hỗ trợ still (codec = "video-frame").
    func captureStill(requestID: UUID) async throws -> CapturedImagePayload
    func applyControls(_ controls: CameraControls) async throws -> AppliedControls
    func setResolution(_ resolution: String) async throws
    var events: AsyncStream<CameraEvent> { get }
    var currentDevice: CameraDescriptor? { get async }
    var isFallbackVideoStill: Bool { get async }
}
