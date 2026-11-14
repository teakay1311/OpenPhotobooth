import Foundation

/// TrashCleanupScheduler (§12.5): chỉ chạy trong tiến trình app, ưu tiên thấp, batch nhỏ.
public final class TrashCleanupScheduler: @unchecked Sendable {
    private let trashService: TrashService
    private let trashRepo: TrashRepository
    private let clockSanity: ClockSanityMonitor
    private let clock: AppClock
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var running = false

    public init(trashService: TrashService, trashRepo: TrashRepository,
                clockSanity: ClockSanityMonitor, clock: AppClock = SystemClock.shared) {
        self.trashService = trashService
        self.trashRepo = trashRepo
        self.clockSanity = clockSanity
        self.clock = clock
    }

    /// Chạy khi launch (sau DB recovery) và định kỳ ≤24h (dùng 6h).
    public func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vn.openphotobooth.trash.scheduler", qos: .utility))
        t.schedule(deadline: .now() + 15, repeating: 6 * 3600)
        t.setEventHandler { [weak self] in
            self?.runOnce(manual: false)
        }
        t.resume()
        timer = t
        // Lần đầu chạy nền (utility) — không block MainActor trong lúc boot (§12.5)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runOnce(manual: false)
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Kết quả tự dọn; nếu bị đóng băng do đồng hồ, trả về nil (caller hiển thị cảnh báo E-TRS-04).
    @discardableResult
    public func runOnce(manual: Bool) -> TrashService.PurgeReport? {
        lock.lock()
        if running { lock.unlock(); return nil }
        running = true
        lock.unlock()
        defer {
            lock.lock(); running = false; lock.unlock()
        }
        clockSanity.observe(clock: clock)
        if clockSanity.isAutoPurgeFrozen && !manual {
            Log.trash.warning("Tự động dọn rác bị đóng băng do đồng hồ bất thường (E-TRS-04)")
            return nil
        }
        let now = Time.nowMs(clock)
        guard let expired = try? trashRepo.expired(nowMs: now, limit: 20) else { return nil }
        guard !expired.isEmpty else { return TrashService.PurgeReport() }
        // Batch nhỏ + yield cho CameraService (§12.5)
        return trashService.purgeAll(items: expired)
    }
}
