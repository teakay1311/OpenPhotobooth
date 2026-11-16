import CoreText
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// FakeCamera cho test/dev (§17.5): sinh frame mẫu, giả lập ngắt kết nối.
public final class FakeCameraService: CameraServing, @unchecked Sendable {
    private let lock = NSLock()
    private var connected = true
    private var frameCounter = 0
    private var running = false
    private var previewTimer: DispatchSourceTimer?
    private var eventContinuations: [UUID: AsyncStream<CameraEvent>.Continuation] = [:]
    private var selectedDevice: CameraDescriptor?
    private let frameSize = CGSize(width: 1280, height: 720)

    public var devicesCatalog: [CameraDescriptor]

    public init(devicesCatalog: [CameraDescriptor]? = nil) {
        let caps = CameraCapabilities(supportsStillPhoto: true,
                                      resolutions: [CGSize(width: 1280, height: 720)],
                                      supportsFocus: false, supportsExposure: false,
                                      supportsWhiteBalance: false, supportsFrameRate: false,
                                      maxPhotoDimensions: CGSize(width: 1280, height: 720))
        self.devicesCatalog = devicesCatalog ?? [
            CameraDescriptor(uniqueID: "fake-built-in", localizedName: "Camera tích hợp (giả lập)",
                             kind: .builtIn, isConnected: true, isSystemPreferred: true, capabilities: caps),
            CameraDescriptor(uniqueID: "fake-usb", localizedName: "Camera USB (giả lập)",
                             kind: .usb, isConnected: true, isSystemPreferred: false, capabilities: caps)
        ]
    }

    public var events: AsyncStream<CameraEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock(); eventContinuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.eventContinuations[id] = nil; self.lock.unlock()
            }
        }
    }

    public var configuredPermissionState: CameraPermissionState = .authorized
    public var requestAccessCallCount = 0

    public func cameraPermissionState() async -> CameraPermissionState {
        lock.lock(); defer { lock.unlock() }
        return configuredPermissionState
    }

    public func requestAccessIfNeeded() async -> CameraPermissionState {
        lock.lock()
        requestAccessCallCount += 1
        let state = configuredPermissionState
        lock.unlock()
        return state
    }

    public func discoverDevices() async -> [CameraDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return devicesCatalog.filter { $0.isConnected }
    }

    public func selectDevice(_ id: CameraID) async throws -> CameraCapabilities {
        lock.lock(); defer { lock.unlock() }
        guard let d = devicesCatalog.first(where: { $0.uniqueID == id && $0.isConnected }) else {
            throw AppError.noCamera
        }
        selectedDevice = d
        return d.capabilities
    }

    public func selectAutoDevice() async throws -> CameraCapabilities {
        let devices = await discoverDevices()
        guard !devices.isEmpty else { throw AppError.noCamera }
        let builtIn = devices.filter { $0.kind == .builtIn }
            .sorted { (a, b) in
                if a.isSystemPreferred != b.isSystemPreferred { return a.isSystemPreferred }
                return a.uniqueID < b.uniqueID
            }
        let nonBuiltIn = devices.filter { $0.kind != .builtIn }
            .sorted { (a, b) in
                if a.isSystemPreferred != b.isSystemPreferred { return a.isSystemPreferred }
                return a.uniqueID < b.uniqueID
            }
        let candidates = builtIn + nonBuiltIn
        guard let first = candidates.first else { throw AppError.noCamera }
        return try await selectDevice(first.uniqueID)
    }

    public var isPreviewRunning: Bool { get async { lock.withLock { running && connected } } }

    public func startPreview() async throws {
        lock.lock()
        guard connected, selectedDevice != nil else { lock.unlock(); throw AppError.noCamera }
        running = true
        lock.unlock()
        // DispatchSourceTimer trên main queue — Timer.scheduledTimer trong ngữ cảnh async
        // nonisolated sẽ neo vào RunLoop của thread nền (không chạy) → frameCounter đứng yên.
        previewTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alive = self.running
            if alive { self.frameCounter += 1 }
            self.lock.unlock()
            if !alive {
                self.previewTimer?.cancel()
                self.previewTimer = nil
            }
        }
        t.schedule(deadline: .now(), repeating: 1.0 / 15.0)
        t.resume()
        previewTimer = t
    }

    public func stopPreview() async {
        lock.lock(); running = false; lock.unlock()
        previewTimer?.cancel()
        previewTimer = nil
    }

    deinit {
        previewTimer?.cancel()
    }

    public func captureStill(requestID: UUID) async throws -> CapturedImagePayload {
        try await Task.sleep(nanoseconds: 120_000_000) // mô phỏng latency chụp
        lock.lock()
        guard connected else { lock.unlock(); throw AppError.cameraBusy }
        let frameNo = frameCounter
        lock.unlock()
        guard let cg = Self.sampleImage(frameNo: frameNo, size: frameSize) else {
            throw AppError.ioFailure("Fake frame encode lỗi")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AppError.ioFailure("Fake encode lỗi")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest), let data = out as Data? else {
            throw AppError.ioFailure("Fake encode lỗi")
        }
        return CapturedImagePayload(data: data, actualWidth: Int(frameSize.width), actualHeight: Int(frameSize.height),
                                    orientation: 1, colorProfile: "sRGB", capturedAtMs: Time.nowMs(),
                                    requestID: requestID.uuidString, codec: "jpeg")
    }

    private var configuredResolution: String = "best"

    public func setResolution(_ resolution: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        configuredResolution = resolution
    }

    public func applyControls(_ controls: CameraControls) async throws -> AppliedControls {
        AppliedControls(focusLocked: controls.focusLocked ?? false,
                        exposureLocked: controls.exposureLocked ?? false,
                        whiteBalanceLocked: controls.whiteBalanceLocked ?? false,
                        frameRate: controls.frameRate)
    }

    public var currentDevice: CameraDescriptor? { get async {
        lock.lock(); defer { lock.unlock() }
        return selectedDevice
    }}

    public var isFallbackVideoStill: Bool { get async { false } }

    // MARK: - Test hooks

    public func simulateDisconnect() {
        lock.lock(); connected = false; lock.unlock()
        post(.deviceDisconnected(selectedDevice?.uniqueID ?? "fake-built-in"))
        post(.interruptionStarted(reason: "Giả lập ngắt kết nối"))
    }

    public func simulateReconnect() {
        lock.lock(); connected = true; lock.unlock()
        post(.interruptionEnded)
    }

    func post(_ event: CameraEvent) {
        lock.lock()
        let all = Array(eventContinuations.values)
        lock.unlock()
        for c in all { c.yield(event) }
    }

    /// Ảnh mẫu động: gradient + đồng hồ số để kiểm tra mirror/crop (CAM-07).
    static func sampleImage(frameNo: Int, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.35 + 0.2 * sin(Double(frameNo) / 20), green: 0.5, blue: 0.85, alpha: 1),
                      CGColor(red: 0.95, green: 0.75 + 0.1 * cos(Double(frameNo) / 30), blue: 0.55, alpha: 1)] as CFArray
        if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        // "Mặt" giả lập để Vision có thể bắt (ellipse da + mắt tối)
        ctx.setFillColor(CGColor(red: 0.92, green: 0.78, blue: 0.66, alpha: 1))
        let faceRect = CGRect(x: CGFloat(w) * 0.38, y: CGFloat(h) * 0.22, width: CGFloat(w) * 0.24, height: CGFloat(w) * 0.24)
        ctx.fillEllipse(in: faceRect)
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: faceRect.midX - faceRect.width * 0.18, y: faceRect.midY + faceRect.height * 0.05, width: faceRect.width * 0.12, height: faceRect.height * 0.12))
        ctx.fillEllipse(in: CGRect(x: faceRect.midX + faceRect.width * 0.06, y: faceRect.midY + faceRect.height * 0.05, width: faceRect.width * 0.12, height: faceRect.height * 0.12))
        // Số frame để thấy mirror
        let text = "F\(frameNo)"
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 48, nil),
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)
        ]
        if let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) {
            let line = CTLineCreateWithAttributedString(attrStr)
            ctx.textPosition = CGPoint(x: 24, y: CGFloat(h) - 60)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }
}
