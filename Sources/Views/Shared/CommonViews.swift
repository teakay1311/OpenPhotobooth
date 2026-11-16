import SwiftUI
import AppKit
import MetalKit
import CoreImage
import CoreVideo

// MARK: - PrimaryButton (§2.1)

public struct PrimaryButton: View {
    public var title: String
    public var systemImage: String?
    public var isDestructive = false
    public var disabledReason: String? = nil
    public let action: () -> Void

    public init(title: String, systemImage: String? = nil, isDestructive: Bool = false,
                disabledReason: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage
        self.isDestructive = isDestructive; self.disabledReason = disabledReason
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .frame(maxWidth: 220)
        }
        .buttonStyle(.borderedProminent)
        .tint(isDestructive ? .red : .accentColor)
        .disabled(disabledReason != nil)
        .help(disabledReason ?? title)
        .accessibilityLabel(title)
    }
}

// MARK: - EmptyState (§2.1)

public struct EmptyStateView: View {
    public var systemImage: String
    public var title: String
    public var message: String
    public var actionTitle: String?
    public var action: (() -> Void)?

    public init(systemImage: String, title: String, message: String,
                actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage; self.title = title; self.message = message
        self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Toast (§2.1)

public struct ToastOverlay: View {
    @ObservedObject var env: AppEnvironment

    public var body: some View {
        VStack {
            Spacer()
            if let toast = env.toast {
                HStack(spacing: 8) {
                    Image(systemName: icon(toast.kind))
                    Text(toast.text).lineLimit(3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(borderColor(toast.kind), lineWidth: 1))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // .id(toast): toast MỚI đè toast cũ phải bắt đầu lại bộ đếm 3.5s
                // (onAppear chỉ chạy lại khi identity đổi — nếu không toast mới không bao giờ tự ẩn)
                .id(toast)
                .onAppear {
                    Task {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        withAnimation { if env.toast == toast { env.toast = nil } }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: env.toast)
        .allowsHitTesting(false)
    }

    func icon(_ kind: ToastMessage.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    func borderColor(_ kind: ToastMessage.Kind) -> Color {
        switch kind {
        case .success: return .green
        case .info: return .blue
        case .warning: return .orange
        }
    }
}

// MARK: - Banner phiên chưa hoàn thành (§3.1.6)

public struct SessionBanner: View {
    @ObservedObject var env: AppEnvironment
    var onContinue: (String) -> Void
    var onView: (String) -> Void

    public init(env: AppEnvironment, onContinue: @escaping (String) -> Void, onView: @escaping (String) -> Void) {
        self.env = env
        self.onContinue = onContinue
        self.onView = onView
    }

    private var disabledReason: String? {
        if env.engine.hasPhotoToSave {
            return "Thử lưu lại ảnh của phiên đang mở trước"
        }
        if env.engine.isCaptureBusy {
            return "Chờ hoàn tất lượt chụp hoặc dừng an toàn trước khi tiếp tục phiên khác"
        }
        if env.showLeaveCaptureConfirmation {
            return "Hoàn tất thao tác điều hướng trước khi tiếp tục"
        }
        return nil
    }

    public var body: some View {
        if let bannerID = env.bannerSessionID {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Có phiên chưa hoàn thành")
                Spacer()
                Button("Tiếp tục") {
                    onContinue(bannerID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(env.isProcessingBannerAction || !env.engine.canAdoptSession || env.showLeaveCaptureConfirmation)
                .help(disabledReason ?? "Tiếp tục chụp phiên này")

                Button("Xem") {
                    onView(bannerID)
                }
                .controlSize(.small)
                .disabled(env.isProcessingBannerAction || env.engine.isCaptureBusy || env.engine.hasPhotoToSave || env.showLeaveCaptureConfirmation)
                .help(disabledReason ?? "Mở xem và chỉnh ảnh phiên này")

                Button {
                    env.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                }
                .controlSize(.small)
                .disabled(env.isProcessingBannerAction)
                .help("Để sau")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12))
        }
    }
}

// MARK: - CGImage/Data preview

public struct ImageDataView: View {
    public var data: Data?
    public var image: CGImage?
    public var contentMode: ContentMode = .fit
    @State private var decodedImage: NSImage?

    public init(data: Data? = nil, image: CGImage? = nil, contentMode: ContentMode = .fit) {
        self.data = data; self.image = image; self.contentMode = contentMode
    }

    public var body: some View {
        ZStack {
            if let img = effectiveImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(nsColor: .controlBackgroundColor))
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: data) {
            updateDecodedImage()
        }
    }

    private var effectiveImage: NSImage? {
        if let image {
            return image.asNSImage
        }
        if let decodedImage {
            return decodedImage
        }
        if let data {
            return NSImage(data: data)
        }
        return nil
    }

    private func updateDecodedImage() {
        guard let data else {
            decodedImage = nil
            return
        }
        decodedImage = NSImage(data: data)
    }
}

extension CGImage {
    var asNSImage: NSImage { NSImage(cgImage: self, size: NSSize(width: CGFloat(width), height: CGFloat(height))) }
}

/// Checkerboard cho PNG alpha (§2.9).
public struct CheckeredBackground: View {
    public init() {}
    public var body: some View {
        GeometryReader { geo in
            let side: CGFloat = 12
            let cols = Int(ceil(geo.size.width / side))
            let rows = Int(ceil(geo.size.height / side))
            Canvas { ctx, size in
                for r in 0...max(rows, 1) {
                    for c in 0...max(cols, 1) {
                        let rect = CGRect(x: CGFloat(c) * side, y: CGFloat(r) * side, width: side, height: side)
                        ctx.fill(Path(rect), with: .color((r + c) % 2 == 0 ? Color(white: 0.92) : Color(white: 0.82)))
                    }
                }
            }
        }
    }
}

// MARK: - AsyncThumbView: decode ảnh nhỏ ngoài body (P3-11b)
// Photo strip / thumbnail strip không decode NSImage full-res đồng bộ trong body mỗi lần render.
public struct AsyncThumbView: View {
    let url: URL?
    var width: CGFloat
    var height: CGFloat
    @State private var image: NSImage?

    public init(url: URL?, width: CGFloat, height: CGFloat) {
        self.url = url
        self.width = width
        self.height = height
    }

    static let cache = NSCache<NSString, NSImage>()

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color(nsColor: .controlBackgroundColor)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            guard let url else { image = nil; return }
            let key = url.absoluteString as NSString
            if let cached = AsyncThumbView.cache.object(forKey: key) { image = cached; return }
            let img = await Task.detached(priority: .utility, operation: { NSImage(contentsOf: url) }).value
            if let img {
                AsyncThumbView.cache.setObject(img, forKey: key)
                image = img
            }
        }
    }
}

// MARK: - ShareSheet: nút thật mở NSSharingServicePicker (P2-25)
// Neo picker vào NSView kích thước 0 thì popover không hiện; nút NSButton thật
// cho anchor hợp lệ và người dùng luôn có nút đóng của sheet bên ngoài.
public struct ShareSheet: NSViewRepresentable {
    public let items: [Any]

    public init(items: [Any]) { self.items = items }

    public func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Chia sẻ…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }

    public func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.items = items
    }

    public func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    public final class Coordinator: NSObject {
        var items: [Any]
        init(items: [Any]) { self.items = items }
        @objc func share(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}


// MARK: - Camera preview (Metal + CoreImage) §4, §8.1

/// Spec cho chế độ "Trong khung": composite tĩnh + slot rect cần chèn live video.
public struct InFrameSpec: Equatable {
    public var base: CGImage
    public var slotRects: [CGRect]   // normalized top-left
    public init(base: CGImage, slotRects: [CGRect]) {
        self.base = base; self.slotRects = slotRects
    }
}

public struct CIPreviewView: NSViewRepresentable {
    public var cameraService: CameraService?
    public var mirror: Bool
    public var inFrame: InFrameSpec?
    public var photoParameters: ResolvedPhotoParams?
    public var faceAnalysis: FaceAnalysisService?

    public init(cameraService: CameraService?, mirror: Bool, inFrame: InFrameSpec? = nil,
                photoParameters: ResolvedPhotoParams? = nil, faceAnalysis: FaceAnalysisService? = nil) {
        self.cameraService = cameraService; self.mirror = mirror; self.inFrame = inFrame
        self.photoParameters = photoParameters; self.faceAnalysis = faceAnalysis
    }

    public func makeNSView(context: Context) -> MetalPreviewNSView {
        let view = MetalPreviewNSView()
        view.cameraService = cameraService
        view.mirror = mirror
        view.inFrame = inFrame
        view.photoParameters = photoParameters
        view.faceAnalysis = faceAnalysis
        view.configure()
        return view
    }

    public func updateNSView(_ view: MetalPreviewNSView, context: Context) {
        view.mirror = mirror
        view.inFrame = inFrame
        view.photoParameters = photoParameters
        view.faceAnalysis = faceAnalysis
        if view.cameraService !== cameraService {
            view.cameraService = cameraService
        }
    }
}

public final class MetalPreviewNSView: NSView, MTKViewDelegate {
    var cameraService: CameraService?
    var mirror = true
    var inFrame: InFrameSpec?
    var photoParameters: ResolvedPhotoParams?
    var faceAnalysis: FaceAnalysisService?
    private var mtkView: MTKView?
    // CIContext phải cùng MTLDevice với MTKView để render qua CIRRenderDestination —
    // tạo lại trong configure() sau khi có device (P3-21a).
    private var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var commandQueue: MTLCommandQueue?

    public func configure() {
        wantsLayer = true
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        commandQueue = device.makeCommandQueue()
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let v = MTKView(frame: bounds, device: device)
        v.delegate = self
        v.enableSetNeedsDisplay = false
        v.isPaused = false
        v.preferredFramesPerSecond = 30
        // BUG-CAM-03: Bắt buộc đặt false để drawable.texture có MTLTextureUsageShaderWrite cho Core Image render
        v.framebufferOnly = false
        v.autoresizingMask = [.width, .height]
        v.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        addSubview(v)
        mtkView = v
    }

    public override func layout() {
        super.layout()
        mtkView?.frame = bounds
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, commandQueue != nil else { return }
        guard let service = cameraService, let frame = service.latestPreviewBuffer() else { return }
        let viewSize = view.drawableSize
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        var ci = CIImage(cvPixelBuffer: frame.buffer)
        guard ci.extent.width > 0, ci.extent.height > 0, !ci.extent.isInfinite else { return }

        // Chuẩn hóa extent về (0,0) trước khi tính toán
        if ci.extent.origin != .zero {
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        }

        if mirror {
            ci = ci.oriented(.upMirrored)
            if ci.extent.origin != .zero {
                ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
            }
        }

        if let params = photoParameters {
            ci = ImageNormalizer.rotated(ci, degrees: params.photoRotation)
            ci = ImageColorPipeline.applyColor(ci, resolved: params)
        }

        let target: CIImage
        if let spec = inFrame {
            target = Self.composeInFrame(video: ci, spec: spec, size: viewSize)
        } else {
            // Fit toàn khung camera (aspect-fit, không stretch §4.4, căn giữa BUG-CAM-03)
            let scale = min(viewSize.width / ci.extent.width, viewSize.height / ci.extent.height)
            let scaledW = ci.extent.width * scale
            let scaledH = ci.extent.height * scale
            let tx = (viewSize.width - scaledW) / 2.0
            let ty = (viewSize.height - scaledH) / 2.0

            let transformed = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: tx, y: ty))

            // Nền đục kích thước viewSize để xoá pixel cũ và tạo letterbox chuẩn
            let bg = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0))
                .cropped(to: CGRect(origin: .zero, size: viewSize))
            target = transformed.composited(over: bg).cropped(to: CGRect(origin: .zero, size: viewSize))
        }

        guard let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let destBounds = CGRect(origin: .zero, size: viewSize)
        ciContext.render(target, to: drawable.texture, commandBuffer: commandBuffer, bounds: destBounds, colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Ghép live video vào slot đang chụp, trên composite tĩnh của khung (§8.1).
    static func composeInFrame(video: CIImage, spec: InFrameSpec, size: CGSize) -> CIImage {
        let base = CIImage(cgImage: spec.base)
        guard base.extent.width > 0, base.extent.height > 0 else {
            return CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)).cropped(to: CGRect(origin: .zero, size: size))
        }
        var baseNorm = base
        if baseNorm.extent.origin != .zero {
            baseNorm = baseNorm.transformed(by: CGAffineTransform(translationX: -baseNorm.extent.origin.x, y: -baseNorm.extent.origin.y))
        }
        let scale = min(size.width / baseNorm.extent.width, size.height / baseNorm.extent.height)
        let tx = (size.width - baseNorm.extent.width * scale) / 2
        let ty = (size.height - baseNorm.extent.height * scale) / 2
        var output = baseNorm.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
        let canvasH = baseNorm.extent.height * scale
        let canvasTop = ty + canvasH // đỉnh canvas trong hệ CI
        for rectN in spec.slotRects {
            let w = rectN.width * baseNorm.extent.width * scale
            let h = rectN.height * baseNorm.extent.height * scale
            let x = tx + rectN.origin.x * baseNorm.extent.width * scale
            let y = canvasTop - (rectN.origin.y * baseNorm.extent.height * scale) - h
            let slotRect = CGRect(x: x, y: y, width: w, height: h)
            guard slotRect.width > 0, slotRect.height > 0, video.extent.width > 0, video.extent.height > 0 else { continue }
            // Fill video vào slot
            let vScale = max(w / video.extent.width, h / video.extent.height)
            let videoT = video.transformed(by: CGAffineTransform(scaleX: vScale, y: vScale))
                .transformed(by: CGAffineTransform(translationX: slotRect.midX - video.extent.width * vScale / 2,
                                                   y: slotRect.midY - video.extent.height * vScale / 2))
                .cropped(to: slotRect)
            // Mask chữ nhật slot (đủ cho preview nhanh)
            let mask = CIImage(color: CIColor.white).cropped(to: slotRect)
            let blended = CIFilter(name: "CIBlendWithMask")
            blended?.setValue(videoT, forKey: kCIInputImageKey)
            blended?.setValue(output.cropped(to: slotRect), forKey: kCIInputBackgroundImageKey)
            blended?.setValue(mask, forKey: kCIInputMaskImageKey)
            if let piece = blended?.outputImage {
                output = piece.composited(over: output)
            }
        }
        let bg = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)).cropped(to: CGRect(origin: .zero, size: size))
        return output.composited(over: bg).cropped(to: CGRect(origin: .zero, size: size))
    }
}
