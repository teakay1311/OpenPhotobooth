import Foundation

/// Coalescing: khi có nhiều update liên tiếp (slider), chỉ thực thi khối cuối cùng
/// sau khoảng dừng — tránh đảo kết quả khi callback chậm (§17.4).
public final class LatestValueRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var workItem: DispatchWorkItem?
    private var activeTask: Task<Void, Never>?
    private var generation = 0
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "vn.openphotobooth.coalesce", qos: .userInitiated)) {
        self.queue = queue
    }

    public func schedule(delay: DispatchTimeInterval = .milliseconds(24), _ block: @escaping @Sendable () -> Void) {
        lock.lock()
        workItem?.cancel()
        activeTask?.cancel()
        workItem = DispatchWorkItem(block: block)
        let item = workItem!
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Variant cho closure async — hủy Task cũ + generation token,
    /// đảm bảo chỉ khối cuối cùng thực sự chạy (kể cả khi khối trước đã bắt đầu await).
    public func scheduleAsync(delay: DispatchTimeInterval = .milliseconds(24),
                              _ block: @escaping @Sendable () async -> Void) {
        lock.lock()
        workItem?.cancel()
        activeTask?.cancel()
        generation += 1
        let gen = generation
        let ns = Self.toNanoseconds(delay)
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.lock.lock()
            let current = self.generation
            self.lock.unlock()
            guard current == gen else { return }
            await block()
        }
        activeTask = task
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        workItem?.cancel()
        workItem = nil
        activeTask?.cancel()
        activeTask = nil
        lock.unlock()
    }

    static func toNanoseconds(_ d: DispatchTimeInterval) -> UInt64 {
        switch d {
        case .seconds(let s): return UInt64(max(s, 0)) * 1_000_000_000
        case .milliseconds(let ms): return UInt64(max(ms, 0)) * 1_000_000
        case .microseconds(let us): return UInt64(max(us, 0)) * 1_000
        case .nanoseconds(let ns): return UInt64(max(ns, 0))
        @unknown default: return 0
        }
    }
}

/// Persist debounce 300–500ms (§9.3): gom nhiều thay đổi thành một lần ghi DB.
public final class Debouncer: @unchecked Sendable {
    private let lock = NSLock()
    private var workItem: DispatchWorkItem?
    private var activeTask: Task<Void, Never>?
    private var generation = 0
    private let queue: DispatchQueue
    private let delay: DispatchTimeInterval

    public init(delay: DispatchTimeInterval = .milliseconds(400), queue: DispatchQueue = DispatchQueue(label: "vn.openphotobooth.debounce", qos: .utility")) {
        self.delay = delay
        self.queue = queue
    }

    public func call(_ block: @escaping @Sendable () -> Void) {
        lock.lock()
        workItem?.cancel()
        activeTask?.cancel()
        workItem = DispatchWorkItem(block: block)
        let item = workItem!
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Variant cho closure async (persist DB + reload preview §9.3):
    /// hủy Task cũ + generation token — chỉ khối cuối cùng được ghi.
    public func callAsync(_ block: @escaping @Sendable () async -> Void) {
        lock.lock()
        workItem?.cancel()
        activeTask?.cancel()
        generation += 1
        let gen = generation
        let ns = LatestValueRunner.toNanoseconds(delay)
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.lock.lock()
            let current = self.generation
            self.lock.unlock()
            guard current == gen else { return }
            await block()
        }
        activeTask = task
        lock.unlock()
    }
}
