import CoreImage
import Foundation
import CoreGraphics

/// Thumbnail/cache store — cache có thể tạo lại, KHÔNG thuộc vòng đời Trash 30 ngày (§1.3, §10.5).
public final class ThumbnailStore: @unchecked Sendable {
    private let layout: FileLayout
    private let memory = NSCache<NSString, NSData>()
    private let lock = NSLock()
    private let ioLock = NSLock()
    private var currentGeneration: Int = 0
    private var isCleaning: Bool = false

    // Hooks phục vụ bài thử concurrency/race condition (§5.1.4, T09)
    public var onBeforeStoreWriteHook: ((Int) -> Void)?
    public var onBeforeClearIOHook: (() -> Void)?
    public var onAfterClearMemoryHook: (() -> Void)?

    public enum ClearResult: Equatable {
        case success
        case partial(failedCount: Int, firstErrorDescription: String)
        case failure(description: String)
    }

    public init(layout: FileLayout) {
        self.layout = layout
        memory.countLimit = 400
    }

    public var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration
    }

    public func cachedData(key: String, validForGeneration gen: Int? = nil) -> Data? {
        lock.lock()
        if isCleaning {
            lock.unlock()
            return nil
        }
        if let gen, gen != currentGeneration {
            lock.unlock()
            return nil
        }
        lock.unlock()

        if let mem = memory.object(forKey: key as NSString) { return mem as Data }
        let url = layout.thumbnailsDir.appendingPathComponent(Self.safeFileName(key) + ".png")
        guard let data = try? Data(contentsOf: url) else { return nil }

        lock.lock()
        if isCleaning || (gen != nil && gen != currentGeneration) {
            lock.unlock()
            return nil
        }
        memory.setObject(data as NSData, forKey: key as NSString)
        lock.unlock()
        return data
    }

    @discardableResult
    public func store(data: Data, key: String, expectedGeneration: Int? = nil) -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }

        lock.lock()
        if isCleaning || (expectedGeneration != nil && expectedGeneration != currentGeneration) {
            lock.unlock()
            return false // Bỏ qua vì cache đang dọn hoặc generation đã đổi (§5.1.2)
        }
        lock.unlock()

        if let hook = onBeforeStoreWriteHook {
            let gen = generation
            hook(gen)
        }

        // Kiểm tra generation lần nữa trước khi ghi nguyên tử (§5.1.2)
        lock.lock()
        if isCleaning || (expectedGeneration != nil && expectedGeneration != currentGeneration) {
            lock.unlock()
            return false
        }
        lock.unlock()

        let url = layout.thumbnailsDir.appendingPathComponent(Self.safeFileName(key) + ".png")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // Ghi đĩa thất bại vẫn cho phép lưu bộ nhớ cache theo hành vi hiện có (§5.1.2)
        }

        lock.lock()
        if !isCleaning && (expectedGeneration == nil || expectedGeneration == currentGeneration) {
            memory.setObject(data as NSData, forKey: key as NSString)
        }
        lock.unlock()
        return true
    }

    public func cacheImage(key: String, size: CGSize, maker: () -> CGImage?) -> CGImage? {
        let currentGen = generation
        let data = cachedData(key: key, validForGeneration: currentGen)
        if let data, let img = CGImage.createFrom(data: data) { return img }
        guard let img = maker() else { return nil }
        let ctx = CIContextHolder.shared.context
        if let encoded = ctx.pngRepresentation(of: CIImage(cgImage: img), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
            store(data: encoded, key: key, expectedGeneration: currentGen)
        }
        return img
    }

    /// Dọn cache thumbnail/temp (§10.5, §5.1) — không đụng ảnh gốc, Recovery, Trash.
    @discardableResult
    public func clearAllWithResult() -> ClearResult {
        onBeforeClearIOHook?()
        ioLock.lock()
        defer { ioLock.unlock() }

        lock.lock()
        isCleaning = true
        currentGeneration += 1
        memory.removeAllObjects()
        lock.unlock()

        defer {
            lock.lock()
            isCleaning = false
            lock.unlock()
        }

        onAfterClearMemoryHook?()

        let fm = FileManager.default
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: layout.thumbnailsDir, includingPropertiesForKeys: nil)
        } catch {
            return .failure(description: error.localizedDescription)
        }

        var failedCount = 0
        var firstError: String? = nil

        for item in items {
            do {
                try fm.removeItem(at: item)
            } catch {
                // Tệp đã biến mất giữa chừng tính là đã sạch (§5)
                if fm.fileExists(atPath: item.path) {
                    failedCount += 1
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
        }

        if failedCount > 0 {
            return .partial(failedCount: failedCount, firstErrorDescription: firstError ?? "Lỗi xóa tệp cache")
        }
        return .success
    }

    public func clearAll() throws {
        let res = clearAllWithResult()
        switch res {
        case .success: break
        case .partial(let count, let err):
            throw AppError.ioFailure("Dọn cache một phần (\(count) mục lỗi): \(err)")
        case .failure(let err):
            throw AppError.ioFailure("Lỗi dọn cache: \(err)")
        }
    }

    /// Dọn file thumbnail cũ (> `days` ngày) — cache có thể tạo lại (§10.5).
    /// Chặn tăng trưởng đĩa vô hạn vì key có revisionNo bump liên tục.
    public func pruneOlderThan(days: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: layout.thumbnailsDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    static func safeFileName(_ key: String) -> String {
        Hashing.sha256Hex(Data(key.utf8))
    }
}

/// CIContext dùng chung cho mọi render/thumbnail (một pipeline §7.6).
public enum CIContextHolder {
    public static let shared = CIContextHolderBox()
}

public final class CIContextHolderBox: @unchecked Sendable {
    public let context: CIContext
    init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .cacheIntermediates: false
        ])
    }
}
