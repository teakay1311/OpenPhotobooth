import Foundation
import Vision
import CoreGraphics

/// Quan sát khuôn mặt chuẩn hóa theo gốc trên-trái (đã đổi từ hệ Vision gốc dưới-trái).
public struct FaceBox: Equatable, Codable, Sendable {
    public var x: Double      // normalized top-left
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double

    public init(x: Double, y: Double, width: Double, height: Double, confidence: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.confidence = confidence
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

/// FaceAnalysisService: Vision observations — KHÔNG nhận diện danh tính, không lưu vector (§17.1, §18.3).
public final class FaceAnalysisService: @unchecked Sendable {
    private let cacheLock = NSLock()
    private var cache: [String: [FaceBox]] = [:]  // key: photoRevisionID|assetHash

    public init() {}

    public func clearCache() {
        cacheLock.lock(); cache.removeAll(); cacheLock.unlock()
    }

    public func cachedFaces(key: String) -> [FaceBox]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[key]
    }

    /// Phát hiện mặt trên ảnh tĩnh (đã chuẩn hóa orientation). Kết quả cache theo key.
    public func detectFaces(cgImage: CGImage, cacheKey: String? = nil) async -> [FaceBox] {
        if let key = cacheKey, let hit = cachedFaces(key: key) { return hit }
        let boxes = await withCheckedContinuation { (cont: CheckedContinuation<[FaceBox], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectFaceRectanglesRequest()
                request.revision = VNDetectFaceRectanglesRequestRevision3
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    let faces = (request.results ?? []).map { obs -> FaceBox in
                        let bb = obs.boundingBox
                        return FaceBox(x: Double(bb.origin.x),
                                       y: Double(1.0 - bb.origin.y - bb.height),
                                       width: Double(bb.width),
                                       height: Double(bb.height),
                                       confidence: Double(obs.confidence))
                    }
                    cont.resume(returning: faces)
                } catch {
                    Log.render.error("Vision face detect lỗi: \(error.localizedDescription, privacy: .public)")
                    cont.resume(returning: [])
                }
            }
        }
        if let key = cacheKey {
            cacheLock.lock()
            cache[key] = boxes
            // Chặn tăng vô hạn — chỉ giữ kết quả gần nhất, có thể tính lại khi cần
            if cache.count > 400 { cache.removeAll(keepingCapacity: true) }
            cacheLock.unlock()
        }
        return boxes
    }
}
