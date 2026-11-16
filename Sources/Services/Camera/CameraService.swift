import CoreImage
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
    private var videoDataOutput: AVCaptureVideoDataOutput?

    private var currentInput: AVCaptureDeviceInput?
    private var selectedDevice: AVCaptureDevice?
    private var baselineFormat: AVCaptureDevice.Format?
    private var capabilities = CameraCapabilities()
    private var fallbackStill = false
    private var previewOutputID: ObjectIdentifier?
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
    }}

    public var activeResolution: String? { get async {
        await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                let dims = selectedDevice.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
                cont.resume(returning: dims.map { "\($0.width)x\($0.height)" })
            }
        }
    }}

    public var isFallbackVideoStill: Bool { get async {
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in cont.resume(returning: self?.fallbackStill ?? false) }
        }
    }}

    // MARK: - Permission (§4.3)

    public func cameraPermissionState() async -> CameraPermissionState {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

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
                cont.resume(returning: devices.compactMap { self.makeDescriptor(from: $0, systemPreferred: preferred) })
            }
        }
    }

    private func makeDescriptor(from device: AVCaptureDevice?, systemPreferred: AVCaptureDevice? = nil) -> CameraDescriptor? {
        guard let device else { return nil }
        let preferred = systemPreferred ?? AVCaptureDevice.systemPreferredCamera
        let kind: CameraKind
        switch device.deviceType {
        case .builtInWideAngleCamera:
            kind = .builtIn
        case .continuityCamera: kind = .continuity
        case .externalUnknown: kind = device.localizedName.contains("iPhone") || device.localizedName.contains("iPad") ? .continuity : .usb
        default: kind = .other
        }
        let fmt = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let stillSupported = device.uniqueID == selectedDevice?.uniqueID
            ? !fallbackStill : !fmt.supportedMaxPhotoDimensions.isEmpty
        var allResolutions: [CGSize] = []
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sz = CGSize(width: Double(d.width), height: Double(d.height))
            if !allResolutions.contains(sz) {
                allResolutions.append(sz)
            }
        }
        if allResolutions.isEmpty {
            allResolutions = [CGSize(width: Double(dims.width), height: Double(dims.height))]
        }
        allResolutions.sort { ($0.width * $0.height) > ($1.width * $1.height) }

        var caps = CameraCapabilities(
            supportsStillPhoto: stillSupported,
            resolutions: allResolutions,
            supportsFocus: device.isFocusModeSupported(.locked),
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

    private func updatePhotoOutput(for device: AVCaptureDevice) {
        let dims = device.activeFormat.supportedMaxPhotoDimensions.max {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        let connection = photoOutput.connection(with: .video)
        fallbackStill = !session.outputs.contains(photoOutput) || connection == nil || dims == nil
        if !fallbackStill, let dims {
            connection?.isEnabled = true
            photoOutput.maxPhotoDimensions = dims
        }
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

    /// Chọn camera theo mode: auto → ưu tiên camera tích hợp trước Continuity (§3.1, BUG-CAM-02).
    public func selectAutoDevice() async throws -> CameraCapabilities {
        let devices = await discoverDevices()
        guard !devices.isEmpty else { throw AppError.noCamera }
        let sorted = devices.sorted { (a: CameraDescriptor, b: CameraDescriptor) -> Bool in
            let scoreA = a.kind == .builtIn ? 3 : (a.kind == .usb ? 2 : 1)
            let scoreB = b.kind == .builtIn ? 3 : (b.kind == .usb ? 2 : 1)
            if scoreA != scoreB { return scoreA > scoreB }
            if a.isSystemPreferred != b.isSystemPreferred { return a.isSystemPreferred }
            return a.localizedName < b.localizedName
        }
        var lastError: Error?
        for dev in sorted {
            try Task.checkCancellation()
            do {
                return try await selectDevice(dev.uniqueID)
            } catch {
                lastError = error
                Log.camera.warning("Auto-select fallback: cannot configure \(dev.localizedName): \(error)")
            }
        }
        throw lastError ?? AppError.noCamera
    }

    private func configureDeviceLocked(uniqueID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else { throw AppError.noCamera }
        // Tạo input trước để lỗi tạo thiết bị mới không tháo thiết bị hiện tại.
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AppError.cameraConfigurationFailed(error.localizedDescription)
        }
        stopPreviewLocked()
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            if selectedDevice?.uniqueID == device.uniqueID {
                updatePhotoOutput(for: device)
                if let desc = makeDescriptor(from: device) { capabilities = desc.capabilities }
            }
        }
        if let oldInput = currentInput {
            session.removeInput(oldInput)
            currentInput = nil
        }
        session.removeOutput(photoOutput)
        selectedDevice = nil
        baselineFormat = nil
        guard session.canAddInput(input) else { throw AppError.cameraConfigurationFailed("Không thêm được input") }
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        currentInput = input
        selectedDevice = device
        baselineFormat = device.activeFormat
        Log.camera.info("Đã chọn camera: \(device.localizedName, privacy: .public)")
    }

    // MARK: - Preview

    public func startPreview() async throws {
        try Task.checkCancellation()
        let activeOutput = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AVCaptureVideoDataOutput, Error>) in
            sessionQueue.async { [self] in
                guard currentInput != nil else { cont.resume(throwing: AppError.noCamera); return }
                if let output = videoDataOutput, session.isRunning, hasFreshPreviewFrame() {
                    cont.resume(returning: output)
                    return
                }
                stopPreviewLocked()
                // Một output riêng cho mỗi lần khởi động để callback cũ không thể xác nhận preview mới.
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: videoQueue)
                session.beginConfiguration()
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    cont.resume(throwing: AppError.cameraConfigurationFailed("Không thêm được đầu ra preview"))
                    return
                }
                session.addOutput(output)
                session.commitConfiguration()
                videoDataOutput = output
                let id = ObjectIdentifier(output)
                bufferLock.withLock { previewOutputID = id }
                session.startRunning()
                guard session.isRunning else {
                    stopPreviewLocked()
                    cont.resume(throwing: AppError.cameraConfigurationFailed("Không khởi động được preview"))
                    return
                }
                cont.resume(returning: output)
            }
        }
        let outputID = ObjectIdentifier(activeOutput)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                let state = bufferLock.withLock { (previewOutputID == outputID, latestBuffer != nil) }
                guard state.0 else { throw CancellationError() }
                if state.1 { return }
                try await clock.sleep(for: .milliseconds(40))
            }
            throw AppError.cameraConfigurationFailed("Camera chưa gửi khung hình (đã chờ 5 giây)")
        } catch {
            await stopPreview(matching: activeOutput)
            throw error
        }
    }

    public func stopPreview() async { await stopPreview(matching: nil) }

    private func stopPreview(matching output: AVCaptureVideoDataOutput?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                if output == nil || videoDataOutput === output {
                    stopPreviewLocked()
                }
                cont.resume()
            }
        }
    }

    private func stopPreviewLocked() {
        bufferLock.withLock {
            previewOutputID = nil
            latestBuffer = nil
        }
        if session.isRunning { session.stopRunning() }
        if let output = videoDataOutput {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.beginConfiguration()
            session.removeOutput(output)
            session.commitConfiguration()
            videoDataOutput = nil
        }
    }

    public var isPreviewRunning: Bool { get async {
        await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                cont.resume(returning: session.isRunning && hasFreshPreviewFrame())
            }
        }
    }}

    private func hasFreshPreviewFrame() -> Bool {
        guard let frame = latestPreviewBuffer() else { return false }
        return Time.nowMs() - frame.atMs < 5_000
    }

    // MARK: - Still capture (§4.4, §4.5)

    public func captureStill(requestID: UUID) async throws -> CapturedImagePayload {
        let key = requestID.uuidString
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CapturedImagePayload, Error>) in
            // Kiểm tra và đăng ký lượt chụp trong cùng một lần khóa.
            let registered = pendingLock.withLock {
                guard pendingContinuations.isEmpty else { return false }
                pendingContinuations[key] = cont
                return true
            }
            guard registered else {
                cont.resume(throwing: AppError.duplicateShutterRequest)
                return
            }
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
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95 as CFNumber] as CFDictionary)
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

    static func withDeviceConfigurationLock<T>(lock: () throws -> Void, unlock: () -> Void,
                                               _ body: () -> T) throws -> T {
        try lock()
        defer { unlock() }
        return body()
    }

    public func applyControls(_ controls: CameraControls) async throws -> AppliedControls {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AppliedControls, Error>) in
            sessionQueue.async { [weak self] in
                guard let self, let device = self.selectedDevice else {
                    cont.resume(throwing: AppError.noCamera)
                    return
                }
                do {
                    let applied = try Self.withDeviceConfigurationLock(
                        lock: device.lockForConfiguration, unlock: device.unlockForConfiguration
                    ) {
                        var applied = AppliedControls()
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
                        return applied
                    }
                    cont.resume(returning: applied)
                } catch {
                    cont.resume(throwing: AppError.cameraConfigurationFailed(error.localizedDescription))
                }
            }
        }
    }

    public func setResolution(_ resolution: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                guard let device = selectedDevice else {
                    cont.resume()
                    return
                }
                guard let baselineFormat else {
                    cont.resume(throwing: AppError.noCamera)
                    return
                }
                let requested = device.formats.first {
                    let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                    return resolution == "\(dims.width)x\(dims.height)"
                }
                let format = requested ?? baselineFormat
                do {
                    try Self.withDeviceConfigurationLock(
                        lock: device.lockForConfiguration, unlock: device.unlockForConfiguration
                    ) {
                        device.activeFormat = format
                    }
                    updatePhotoOutput(for: device)
                    cont.resume()
                } catch {
                    cont.resume(throwing: AppError.cameraConfigurationFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Frame mới nhất cho preview (CVPixelBuffer BGRA).
    public func latestPreviewBuffer() -> (buffer: CVPixelBuffer, atMs: Int64)? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
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
            let id = device.uniqueID
            self?.sessionQueue.async { [weak self] in
                guard let self else { return }
                if id == selectedDevice?.uniqueID {
                    post(.interruptionStarted(reason: "Camera ngắt kết nối"))
                }
                post(.deviceDisconnected(id))
            }
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.post(.fatalFailure(err?.localizedDescription ?? "Lỗi session camera"))
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            self?.post(.interruptionStarted(reason: "Tạm gián đoạn camera"))
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            self?.post(.interruptionEnded)
        })
    }

    static func interruptionReasonText(_ raw: Int?) -> String {
        return "Tạm gián đoạn camera"
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
        bufferLock.withLock {
            guard previewOutputID == ObjectIdentifier(output) else { return }
            latestBuffer = (buffer, Time.nowMs())
        }
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
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            failPending(key, error: AppError.ioFailure("Không đọc được thuộc tính ảnh"))
            return
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let profile = props[kCGImagePropertyProfileName] as? String
        succeedPending(key, payload: CapturedImagePayload(
            data: data, actualWidth: w, actualHeight: h, orientation: orientation,
            colorProfile: profile, capturedAtMs: Time.nowMs(), requestID: key, codec: "jpeg"))
    }
}
