import Foundation
import CoreGraphics

/// Memory-only, bounded cache. A cancelled row cannot publish an image to a new row.
actor TrashPreviewLoader {
    private final class ImageBox: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private let service: TrashService
    private let cache = NSCache<NSString, ImageBox>()
    private struct Work {
        let task: Task<CGImage, Error>
        var waiters: Set<UUID>
    }
    private var pending: [String: Work] = [:]
    private var thumbnailTail: Task<Void, Never>?
    private var previewTail: Task<Void, Never>?

    private func release(_ key: String, waiter: UUID) {
        guard var work = pending[key] else { return }
        work.waiters.remove(waiter)
        if work.waiters.isEmpty {
            work.task.cancel()
            pending.removeValue(forKey: key)
        } else { pending[key] = work }
    }

    init(service: TrashService) {
        self.service = service
        cache.countLimit = 80
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func photos(item: TrashItem) async throws -> [TrashService.PreviewPhoto] {
        let service = service
        return try await Self.readPhotoListWithRetry(read: { try service.previewPhotos(item) })
    }

    /// Three bounded retries. Lists stay uncached so each attempt validates the current Trash item.
    static func readPhotoListWithRetry(
        read: @escaping @Sendable () throws -> [TrashService.PreviewPhoto],
        wait: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> [TrashService.PreviewPhoto] {
        var delays = [UInt64(100_000_000), 200_000_000, 400_000_000].makeIterator()
        while true {
            try Task.checkCancellation()
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try read()
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                guard case AppError.busy = error, let delay = delays.next() else { throw error }
                try await wait(delay)
            }
        }
    }

    func image(item: TrashItem, photoID: String? = nil, maxPixel: Int) async throws -> CGImage {
        let service = service
        try await Task.detached { try service.validatePreview(item) }.value
        try Task.checkCancellation()
        let key = "\(item.id):\(item.deletedAtMs):\(photoID ?? "cover"):\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached.image }
        let waiter = UUID()
        let task: Task<CGImage, Error>
        if var work = pending[key] {
            work.waiters.insert(waiter)
            pending[key] = work
            task = work.task
        } else {
            // At most one thumbnail and one large preview decode concurrently.
            let previous = maxPixel <= 120 ? thumbnailTail : previewTail
            task = Task.detached(priority: maxPixel <= 120 ? .utility : .userInitiated) {
                await previous?.value
                try Task.checkCancellation()
                for delay in [0, 100, 200, 400] {
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                    do { return try service.previewImage(item, photoID: photoID, maxPixel: maxPixel) }
                    catch AppError.busy where delay != 400 { continue }
                }
                throw AppError.invalidState("Không thể đọc ảnh xem trước")
            }
            let finished = Task { _ = await task.result }
            if maxPixel <= 120 { thumbnailTail = finished } else { previewTail = finished }
            pending[key] = Work(task: task, waiters: [waiter])
        }
        defer { release(key, waiter: waiter) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            cache.setObject(ImageBox(result), forKey: key as NSString, cost: result.bytesPerRow * result.height)
            return result
        } onCancel: {
            Task { await self.release(key, waiter: waiter) }
        }
    }
}
