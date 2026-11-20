import Foundation
import CoreGraphics
import CoreImage

/// FrameThumbnailService: Đường dựng thumbnail dùng chung cho Khung ảnh, Chụp, Fullscreen và Review picker (§Bước 1).
/// - Cache PNG theo revision (`frame-<revisionID>`).
/// - Dựng aspect-fit kích thước tối đa 240×240 pixel, giữ kênh alpha.
/// - Gộp request in-flight theo key + cache generation.
/// - Hủy lưu nếu cache generation đã thay đổi do `clearAll()`.
public final class FrameThumbnailService: @unchecked Sendable {
    private let frames: FrameRepository
    private let assets: AssetStore
    private let thumbnails: ThumbnailStore
    private let settings: SettingsStore
    private let inFlightLock = NSLock()
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(frames: FrameRepository, assets: AssetStore, thumbnails: ThumbnailStore, settings: SettingsStore) {
        self.frames = frames
        self.assets = assets
        self.thumbnails = thumbnails
        self.settings = settings
    }

    /// Trả về cached thumbnail nếu có sẵn, hoặc nil nếu chưa dựng.
    public func cachedThumbnail(frameID: String, revisionID: String) -> Data? {
        thumbnails.cachedData(key: "frame-v2-r\(CompositeRenderer.renderCacheVersion)-\(revisionID)", validForGeneration: thumbnails.generation)
    }

    private func getInFlight(key: String) -> Task<Data?, Never>? {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlight[key]
    }

    private func setInFlight(key: String, task: Task<Data?, Never>) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        inFlight[key] = task
    }

    private func removeInFlight(key: String) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        inFlight.removeValue(forKey: key)
    }

    /// Yêu cầu thumbnail bất đồng bộ (coalesce theo key + generation, A3 đúng tỷ lệ).
    public func requestThumbnail(frameID: String, revisionID: String) async -> Data? {
        let gen = thumbnails.generation
        let key = "frame-v2-r\(CompositeRenderer.renderCacheVersion)-\(revisionID)"
        if let cached = thumbnails.cachedData(key: key, validForGeneration: gen) {
            return cached
        }

        let taskKey = "\(key):\(gen)"
        if let existing = getInFlight(key: taskKey) {
            return await existing.value
        }

        let defaults = await MainActor.run { [settings] in
            settings.sessionDefaultsSnapshot()
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] () -> Data? in
            guard let self else { return nil }
            guard let rev = try? self.frames.getRevision(id: revisionID),
                  let slots = try? self.frames.getSlots(revisionID: revisionID) else { return nil }

            var assetImages: [String: CGImage] = [:]
            if let bg = rev.backgroundAssetID, let img = try? self.assets.loadImage(assetID: bg) {
                assetImages[bg] = img
            }
            if let fg = rev.foregroundAssetID, let img = try? self.assets.loadImage(assetID: fg) {
                assetImages[fg] = img
            }

            let snapSlots = slots.map { SnapshotSlot(from: $0) }
            let snap = FrameSnapshot(sourceFrameID: frameID, sourceFrameRevisionID: revisionID,
                                     canvasWidth: rev.canvasWidth, canvasHeight: rev.canvasHeight,
                                     background: rev.backgroundAssetID.map { SnapshotLayer(assetID: $0, placement: rev.backgroundPlacement, imageOrientation: rev.backgroundImageOrientation) },
                                     foreground: rev.foregroundAssetID.map { SnapshotLayer(assetID: $0, placement: rev.foregroundPlacement, imageOrientation: rev.foregroundImageOrientation) },
                                     backgroundColorHex: rev.backgroundColorHex,
                                     slots: snapSlots, snapshotHash: "thumb-\(revisionID)")

            var sources: [Int: RenderSource] = [:]
            for idx in Set(slots.map(\.captureIndex)) {
                if let s = SampleImageFactory.shared.sample(index: idx, size: CGSize(width: 320, height: 320)) {
                    sources[idx] = RenderSource(image: s)
                }
            }

            // A3: Tính scale = min(1, 240 / max(width, height)) cho canvas hợp lệ
            let maxDim = Double(max(rev.canvasWidth, rev.canvasHeight))
            let scale = maxDim > 0 ? min(1.0, 240.0 / maxDim) : 1.0
            let targetWidth = max(1, Int((Double(rev.canvasWidth) * scale).rounded()))
            let targetHeight = max(1, Int((Double(rev.canvasHeight) * scale).rounded()))

            let model3d = CompositionModel(snapshot: snap, sources: sources, faces: [:],
                                           defaults: defaults,
                                           overrides: [:], placements: [:], cropModes: [:],
                                           assetImages: assetImages,
                                           options: RenderOptions(targetWidth: targetWidth, targetHeight: targetHeight))

            guard let img = try? CompositeRenderer.render(model: model3d),
                  let data = CIContextHolder.shared.context.pngRepresentation(
                    of: CIImage(cgImage: img), format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }

            let stored = self.thumbnails.store(data: data, key: key, expectedGeneration: gen)
            return stored ? data : nil
        }

        setInFlight(key: taskKey, task: task)
        let result = await task.value
        removeInFlight(key: taskKey)
        return result
    }
}
