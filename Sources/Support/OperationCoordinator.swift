import Foundation

/// OperationCoordinator (§3.2): Điều phối thao tác và khóa tài nguyên chống xung đột / race condition.
/// Hỗ trợ khóa theo `session ID`, `loại đối tượng + ID`, hoặc `frame -> session` theo thứ tự nhất quán.
public final class OperationCoordinator: @unchecked Sendable {
    public static let shared = OperationCoordinator()

    private let lock = NSLock()
    private var activeLocks: [String: LockEntry] = [:]

    private struct LockEntry {
        let tokenID: String
        let reason: String
        let acquiredAtMs: Int64
        var reentrancyCount: Int
    }

    public final class OperationToken: @unchecked Sendable {
        public let keys: [String]
        public let id: String
        public let reason: String
        private var released = false
        private unowned let coordinator: OperationCoordinator

        fileprivate init(keys: [String], id: String, reason: String, coordinator: OperationCoordinator) {
            self.keys = keys
            self.id = id
            self.reason = reason
            self.coordinator = coordinator
        }

        public func release() {
            guard !released else { return }
            released = true
            coordinator.release(tokenID: id, keys: keys)
        }

        deinit {
            release()
        }
    }

    public init() {}

    /// Kiểm tra tài nguyên có đang bận hay không
    public func isBusy(key: String) -> (busy: Bool, reason: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let entry = activeLocks[key] {
            return (true, entry.reason)
        }
        return (false, nil)
    }

    public func isSessionBusy(_ sessionID: String) -> (busy: Bool, reason: String?) {
        isBusy(key: "session:\(sessionID)")
    }

    /// Lấy quyền thao tác cho một khóa. Nếu đã bận bởi token khác, throw lỗi xung đột.
    public func acquire(key: String, reason: String, parentToken: OperationToken? = nil) throws -> OperationToken {
        try acquire(keys: [key], reason: reason, parentToken: parentToken)
    }

    /// Lấy quyền theo thứ tự cố định Frame -> Session (§3.2) để tránh deadlock.
    public func acquireFrameAndSession(frameID: String, sessionID: String, reason: String, parentToken: OperationToken? = nil) throws -> OperationToken {
        let keys = ["frame:\(frameID)", "session:\(sessionID)"]
        return try acquire(keys: keys, reason: reason, parentToken: parentToken)
    }

    public func acquire(keys: [String], reason: String, parentToken: OperationToken? = nil) throws -> OperationToken {
        lock.lock()
        defer { lock.unlock() }

        // Sắp xếp thứ tự khóa để tránh deadlock giữa các tác vụ đa khóa
        let sortedKeys = keys.sorted()

        // Kiểm tra xem tất cả các khóa có khả dụng hoặc thuộc parentToken không
        for key in sortedKeys {
            if let entry = activeLocks[key] {
                if let parent = parentToken, entry.tokenID == parent.id {
                    // Re-entrant: token cha đã giữ khóa này
                    continue
                }
                throw AppError.busy("Tài nguyên đang bận (\(entry.reason))")
            }
        }

        let tokenID = parentToken?.id ?? IDFactory.new()
        let now = Time.nowMs()

        for key in sortedKeys {
            if var entry = activeLocks[key], entry.tokenID == tokenID {
                entry.reentrancyCount += 1
                activeLocks[key] = entry
            } else {
                activeLocks[key] = LockEntry(
                    tokenID: tokenID,
                    reason: reason,
                    acquiredAtMs: now,
                    reentrancyCount: 1
                )
            }
        }

        return OperationToken(keys: sortedKeys, id: tokenID, reason: reason, coordinator: self)
    }

    fileprivate func release(tokenID: String, keys: [String]) {
        lock.lock()
        defer { lock.unlock() }

        for key in keys {
            if var entry = activeLocks[key], entry.tokenID == tokenID {
                entry.reentrancyCount -= 1
                if entry.reentrancyCount <= 0 {
                    activeLocks.removeValue(forKey: key)
                } else {
                    activeLocks[key] = entry
                }
            }
        }
    }
}
