import Foundation

/// Đồng hồ có thể thay thế trong kiểm thử (§17.5 TestClock).
public protocol AppClock: Sendable {
    func now() -> Date
}

public struct SystemClock: AppClock {
    public static let shared = SystemClock()
    public init() {}
    public func now() -> Date { Date() }
}

public final class TestClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }
    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    public func advance(seconds: Double) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    public func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
}

/// Giám sát lệch đồng hồ khi app đang chạy (§12.5, E-TRS-04).
/// So wall-clock với monotonic elapsed; lệch bất thường > 24 giờ ⇒ đóng băng tự động dọn rác.
public final class ClockSanityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var wallAtStart: Date
    private var startUptime: Double
    private var frozen = false
    public static let anomalyThresholdSeconds: Double = 86_400

    public init(clock: AppClock = SystemClock.shared) {
        wallAtStart = clock.now()
        startUptime = ProcessInfo.processInfo.systemUptime
    }

    public func observe(clock: AppClock = SystemClock.shared) {
        lock.lock(); defer { lock.unlock() }
        let elapsedMonotonic = ProcessInfo.processInfo.systemUptime - startUptime
        let elapsedWall = clock.now().timeIntervalSince(wallAtStart)
        if abs(elapsedWall - elapsedMonotonic) > Self.anomalyThresholdSeconds {
            frozen = true
            Log.trash.warning("Đồng hồ hệ thống thay đổi bất thường — tạm dừng tự dọn rác (E-TRS-04)")
        } else {
            // Rebase định kỳ: systemUptime KHÔNG tính thời gian máy ngủ — nếu không rebase,
            // chênh lệch tích lũy theo tổng thời gian sleep sẽ vượt ngưỡng và đóng băng nhầm (E-TRS-04).
            wallAtStart = clock.now()
            startUptime = ProcessInfo.processInfo.systemUptime
            if frozen {
                frozen = false
                Log.trash.info("Đồng hồ trở lại bình thường — tiếp tục tự dọn rác")
            }
        }
    }

    public var isAutoPurgeFrozen: Bool {
        lock.lock(); defer { lock.unlock() }
        return frozen
    }
}
