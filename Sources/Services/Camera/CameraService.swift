import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// CameraService AVFoundation (§4.2–4.5).
/// - Chỉ MỘT AVCaptureSession do service này sở hữu (§4.2).
/// - Preview bằng AVCaptureVideoDataOutput (frame mới nhất) — dùng chung cho Camera mode
///   và Live Frame Preview, không mở thêm session thứ hai.
/// - Still ưu tiên AVCapturePhotoOutput + maxPhotoDimensions; nếu không hỗ trợ → fallback
///   video frame chất lượng cao nhất với thông báo (§4.4), không upscale coi là tăng chất lượng.
public final class CameraService: NSObject, CameraServing, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "vn.openphotobooth.camera.session")
    private let videoQueue = DispatchQueue(label: "vn.openphotobooth.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()

    private var currentInput: AVCaptureDeviceInput?
    private var selectedDevice: AVCaptureDevice?
    private var capabilities = CameraCapabilities()
    private var fallbackStill = false
    private var previewRunning = false
    private var latestBuffer: (buffer: CVPixelBuffer, atMs: Int64)?
    private let bufferLock = NSLock()
    private var pendingContinuations: [String: CheckedContinuation<CapturedImagePayload, Error>] = [:]
    /// Ánh xạ AVCapturePhotoSettings.uniqueID → key request — chống callback trễ (sau timeout)
    /// giao nhầm ảnh cho request chụp kế tiếp (P2-15).
    private var pendingBySettingsID: [Int64: String] = [:]
    private let pendingLock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<CameraEvent>.Continuation] = [:]
    private let eventLock = NSLock()
    private var observers: [NSObjectProtocol] = []
    private var isConfiguring = false

    public nonisolated var events: AsyncStream<CameraEvent> {
        AsyncStream { continuation in
            let id = UUID()
            eventLock.lock()
            eventContinuations[id] = continuation
            eventLock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.eventLock.lock()
                self.eventContinuations[id] = nil
                self.eventLock.unlock()
            }
        }
    }

    public override init() {
        super.init()
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoQueue)
        registerNotifications()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    public var currentDevice: CameraDescriptor? { get async {
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                cont.resume(returning: self.makeDescriptor(from: self.selectedDevice))
            }
        }
    }

    public var isFallbackVideoStill: Bool { get async {
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in cont.resume(returning: self?.fallbackStill ?? false) }
        }
    }}

    // MARK: - Permission (§4.3)

    public func requestAccessIfNeeded() async -> CameraPermissionState {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: return .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            post(.permissionChanged)
            return granted ? .authorized : .denied
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    // MARK: - Discovery (§4.2)

    public func discoverDevices() async -> [CameraDescriptor] {
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(returning: []); return }
                // macOS 14: externalUnknown bao gồm camera USB + Continuity (theo Apple sample)
                let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown, .continuityCamera]
                let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
                let preferred = AVCaptureDevice.systemPreferredCamera
                let devices = discovery.devices
                cont.resume(returning: devices.map { self.makeDescriptor(from: $0, systemPreferred: preferred) })
            }
        }
    }

    private func makeDescriptor(from device: AVCaptureDevice?, systemPreferred: AVCaptureDevice? = nil) -> CameraDescriptor? {
        guard let device else { return nil }
        let preferred = systemPreferred ?? AVCaptureDevice.systemPreferredCamera
        let kind: CameraKind
        switch device.deviceType {
        case .builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera, .builtInUltraWideCamera:
            kind = .builtIn
        case .continuityCamera: kind = .continuity
        case .externalUnknown: kind = device.localizedName.contains("iPhone") || device.localizedName.contains("iPad") ? .continuity : .usb
        default: kind = .other
        }
        let fmt = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let stillSupported = Self.supportsStill(device: device)
        var caps = CameraCapabilities(
            supportsStillPhoto: stillSupported,
            resolutions: [CGSize(width: Double(dims.width), height: Double(dims.height))],
            supportsFocus: device.isFocusModeSupported(.locked) && !device.isLockedForConfiguration,
            supportsExposure: device.isExposureModeSupported(.custom) || device.isExposureModeSupported(.locked),
            supportsWhiteBalance: device.isWhiteBalanceModeSupported(.locked),
            supportsFrameRate: fmt.videoSupportedFrameRateRanges.first.map { $0.maxFrameRate > 0 } ?? false,
            minFrameRate: fmt.videoSupportedFrameRateRanges.first?.minFrameRate ?? 15,
            maxFrameRate: fmt.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30,
            maxPhotoDimensions: CGSize(width: Double(dims.width), height: Double(dims.height)))
        if stillSupported {
            caps.maxPhotoDimensions = CGSize(width: Double(dims.width), height: Double(dims.height))
        }
        return CameraDescriptor(uniqueID: device.uniqueID, localizedName: device.localizedName,
                                kind: kind, isConnected: true,
                                isSystemPreferred: preferred?.uniqueID == device.uniqueID,
                                capabilities: caps)
    }

    private static func supportsStill(device: AVCaptureDevice) -> Bool {
        // Ảnh still hỗ trợ trên hầu hết thiết bị; Continuity/USB cũ có thể chỉ có video.
        device.activeFormat.videoMaxZoomFactor > 0
    }

    // MARK: - Select device (§4.2)

    public func selectDevice(_ id: CameraID) async throws -> CameraCapabilities {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CameraCapabilities, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(throwing: AppError.cameraBusy); return }
                do {
                    try self.configureDeviceLocked(uniqueID: id)
                    cont.resume(returning: self.capabilities)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Chọn camera theo mode: auto → systemPreferredCamera (§4.2).
    public func selectAutoDevice() async throws -> CameraCapabilities {
        let devices = await discoverDevices()
        guard !devices.isEmpty else { throw AppError.noCamera }
        let preferred = devices.first { $0.isSystemPreferred } ?? devices[0]
        return try await selectDevice(preferred.uniqueID)
    }

    private func configureDeviceLocked(uniqueID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else { throw AppError.noCamera }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let oldInput = currentInput {
            session.removeInput(oldInput)
            currentInput = nil
        }
        session.removeOutput(photoOutput)
        session.removeOutput(videoDataOutput)
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AppError.cameraConfigurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else { throw AppError.cameraConfigurationFailed("Không thêm được input") }
        try input.device.lockForConfiguration()
        device.unlockForConfiguration()
        session.addInput(input)
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // maxPhotoDimensions theo availability (§1.2 — API đời cũ deprecate)
            if photoOutput.maxPhotoDimensions.width == 0 {
                let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                photoOutput.maxPhotoDimensions = CMVideoDimensions(width: dims.width, height: dims.height)
            }
        }
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }
        let conn = photoOutput.connection(with: .video)
        conn?.isEnabled = true
        currentInput = input
        selectedDevice = device
        if let desc = makeDescriptor(from: device) {
            capabilities = desc.capabilities
            fallbackStill = !desc.capabilities.supportsStillPhoto
        }
        Log.camera.info("Đã chọn camera: \(device.localizedName, privacy: .public)")
    }

    // MARK: - Preview

    public func startPreview() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(throwing: AppError.cameraBusy); return }
                if self.currentInput == nil {
                    cont.resume(throwing: AppError.noCamera)
                    return
                }
                self.session.startRunning()
                self.previewRunning = true
                cont.resume()
            }
        }
    }

    public func stopPreview() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                if self.previewRunning {
                    self.session.stopRunning()
                    self.previewRunning = false
                }
                cont.resume()
            }
        }
    }

    public var isPreviewRunning: Bool { get async {
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in cont.resume(returning: self?.previewRunning ?? false) }
        }
    }}

    // MARK: - Still capture (§4.4, §4.5)

    public func captureStill(requestID: UUID) async throws -> CapturedImagePayload {
        let key = requestID.uuidString
        // E-CAP-01: từ chối request trùng khi đang chờ
        pendingLock.lock()
        if !pendingContinuations.isEmpty {
            pendingLock.unlock()
            throw AppError.duplicateShutterRequest
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CapturedImagePayload, Error>) in
            pendingLock.lock()
            pendingContinuations[key] = cont
            pendingLock.unlock()
            sessionQueue.async { [weak self] in
                guard let self else {
                    self?.failPending(key, error: AppError.cameraBusy)
                    return
                }
                if self.selectedDevice == nil {
                    self.failPending(key, error: AppError.noCamera)
                    return
                }
                if self.fallbackStill || !self.session.outputs.contains(self.photoOutput) {
                    // Fallback: lấy video frame chất lượng cao nhất khả dụng (§4.4)
                    self.captureFromVideoFrame(requestID: key)
                    return
                }
                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                let dims = self.photoOutput.maxPhotoDimensions
                if dims.width > 0, dims.height > 0 {
                    settings.maxPhotoDimensions = dims
                }
                // Ghi nhận uniqueID của settings → delegate dùng nó để định danh đúng request
                self.pendingLock.lock()
                self.pendingBySettingsID[settings.uniqueID] = key
                self.pendingLock.unlock()
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
            // Timeout có giới hạn (§4.5): 10s
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.failPending(key, error: AppError.captureTimeout)
            }
        }
    }

    private func captureFromVideoFrame(requestID: String) {
        bufferLock.lock()
        let frame = latestBuffer
        bufferLock.unlock()
        guard let frame else {
            failPending(requestID, error: AppError.captureTimeout)
            return
        }
        let ci = CIImage(cvPixelBuffer: frame.buffer)
        guard let cg = CIContextHolder.shared.context.createCGImage(ci, from: ci.extent) else {
            failPending(requestID, error: AppError.captureTimeout)
            return
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            failPending(requestID, error: AppError.ioFailure("Tạo JPEG fallback thất bại"))
            return
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95 as CFNumber])
        guard CGImageDestinationFinalize(dest), let data = out as Data? else {
            failPending(requestID, error: AppError.ioFailure("Encode JPEG fallback thất bại"))
            return
        }
        let payload = CapturedImagePayload(data: data, actualWidth: cg.width, actualHeight: cg.height,
                                           orientation: 1, colorProfile: "sRGB",
                                           capturedAtMs: Time.nowMs(), requestID: requestID,
                                           codec: "video-frame")
        succeedPending(requestID, payload: payload)
    }

    private func succeedPending(_ key: String, payload: CapturedImagePayload) {
        pendingLock.lock()
        let cont = pendingContinuations.removeValue(forKey: key)
        if cont != nil { pendingBySettingsID = pendingBySettingsID.filter { $0.value != key } }
        pendingLock.unlock()
        cont?.resume(returning: payload)
    }

    private func failPending(_ key: String, error: Error) {
        pendingLock.lock()
        let cont = pendingContinuations.removeValue(forKey: key)
        if cont != nil { pendingBySettingsID = pendingBySettingsID.filter { $0.value != key } }
        pendingLock.unlock()
        cont?.resume(throwing: error)
    }

    // MARK: - Controls (§4.4)

    public func applyControls(_ controls: CameraControls) async throws -> AppliedControls {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AppliedControls, Error>) in
            sessionQueue.async { [weak self] in
                guard let self, let device = self.selectedDevice else {
                    cont.resume(throwing: AppError.noCamera)
                    return
                }
                var applied = AppliedControls()
                do {
                    try device.lockForConfiguration()
                    if let focus = controls.focusLocked, device.isFocusModeSupported(focus ? .locked : .continuousAutoFocus) {
                        device.focusMode = focus ? .locked : .continuousAutoFocus
                        applied.focusLocked = focus
                    }
                    if let exposure = controls.exposureLocked {
                        if exposure && device.isExposureModeSupported(.custom) {
                            device.exposureMode = .custom
                            applied.exposureLocked = true
                        } else if !exposure && device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                            applied.exposureLocked = false
                        }
                    }
                    if let wb = controls.whiteBalanceLocked, device.isWhiteBalanceModeSupported(wb ? .locked : .continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = wb ? .locked : .continuousAutoWhiteBalance
                        applied.whiteBalanceLocked = wb
                    }
                    if let fps = controls.frameRate, device.activeFormat.videoSupportedFrameRateRanges.contains(where: { fps >= $0.minFrameRate && fps <= $0.maxFrameRate }) {
                        let duration = CMTime(seconds: 1.0 / fps, preferredTimescale: 600)
                        device.activeVideoMinFrameDuration = duration
                        device.activeVideoMaxFrameDuration = duration
                        applied.frameRate = fps
                    }
                    device.unlockForConfiguration()
                    cont.resume(returning: applied)
                } catch {
                    // Cấu hình thất bại phải revert hiển thị giá trị cũ (§4.4) — caller đọc lại controls
                    try? device.lockForConfiguration()
                    applied = AppliedControls(
                        focusLocked: device.focusMode == .locked,
                        exposureLocked: device.exposureMode == .custom,
                        whiteBalanceLocked: device.whiteBalanceMode == .locked)
                    device.unlockForConfiguration()
                    cont.resume(returning: applied)
                }
            }
        }
    }

    /// Frame mới nhất cho preview (CVPixelBuffer BGRA).
    public func latestPreviewBuffer() -> (buffer: CVPixelBuffer, atMs: Int64)? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return latestBuffer
    }

    // MARK: - Notifications / events (§4.5)

    private func registerNotifications() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            self?.post(.deviceConnected(device.uniqueID))
        })
        observers.append(nc.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            self?.post(.deviceDisconnected(device.uniqueID))
            if device.uniqueID == self?.selectedDevice?.uniqueID {
                self?.post(.interruptionStarted(reason: "Camera ngắt kết nối"))
            }
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.post(.fatalFailure(err?.localizedDescription ?? "Lỗi session camera"))
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            self?.post(.interruptionStarted(reason: Self.interruptionReasonText(reason)))
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            self?.post(.interruptionEnded)
        })
    }

    static func interruptionReasonText(_ raw: Int?) -> String {
        guard let raw else { return "Tạm gián đoạn" }
        switch AVCaptureSession.InterruptionReason(rawValue: raw) {
        case .videoDeviceNotAvailableInBackground: return "App không ở nền trước"
        case .videoDeviceInUseByAnotherClient: return "Camera đang được app khác dùng"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "Camera bị chiếm dụng"
        case .videoDeviceNotAvailable: return "Camera không khả dụng"
        default: return "Tạm gián đoạn"
        }
    }

    private func post(_ event: CameraEvent) {
        eventLock.lock()
        let all = Array(eventContinuations.values)
        eventLock.unlock()
        for c in all { c.yield(event) }
    }
}

// MARK: - Video frame delegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        latestBuffer = (buffer, Time.nowMs())
        bufferLock.unlock()
    }
}

// MARK: - Photo delegate

extension CameraService: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // Định danh request theo uniqueID của settings. KHÔNG fallback "pending đầu tiên":
        // callback trễ (sau timeout đã failPending) sẽ giao nhầm ảnh cho request kế tiếp.
        // Map entry đã bị dọn khi timeout → guard chặn late-callback rơi đúng.
        pendingLock.lock()
        let key = pendingBySettingsID.removeValue(forKey: photo.resolvedSettings.uniqueID)
        pendingLock.unlock()
        guard let key else { return }
        if let error {
            failPending(key, error: AppError.captureTimeout)
            Log.camera.error("Chụp ảnh lỗi: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            failPending(key, error: AppError.ioFailure("Không đọc được dữ liệu ảnh"))
            return
        }
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let profile = props?[kCGImagePropertyProfileName] as? String
        succeedPending(key, payload: CapturedImagePayload(
            data: data, actualWidth: w, actualHeight: h, orientation: orientation,
            colorProfile: profile, capturedAtMs: Time.nowMs(), requestID: key, codec: "jpeg"))
    }
}
