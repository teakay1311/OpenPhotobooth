import Foundation

/// Domain event sau commit (§17.2). Events mang entityId để ViewModel bỏ qua event cũ.
public enum DomainEvent: Equatable, Sendable {
    case frameLibraryChanged(frameID: String?)
    case categoryChanged
    case presetChanged
    case sessionChanged(sessionID: String, revision: Int)
    case shotCommitted(sessionID: String, captureIndex: Int, photoRevisionID: String)
    case photoAdjusted(sessionID: String, photoRevisionID: String)
    case frameSnapshotChanged(sessionID: String)
    case trashChanged
    case exportFinished(sessionID: String, recordID: String, success: Bool)
    case settingsChanged(key: String)
    case cameraAvailabilityChanged
    case recoveryCompleted(issues: Int)
}

/// Bus phát event sau khi DB/file commit thành công (không phát trước commit).
public final class EventBus: @unchecked Sendable {
    public static let shared = EventBus()
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DomainEvent>.Continuation] = [:]

    public init() {}

    public var stream: AsyncStream<DomainEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    public func post(_ event: DomainEvent) {
        lock.lock()
        let all = Array(continuations.values)
        lock.unlock()
        for c in all { c.yield(event) }
    }
}
