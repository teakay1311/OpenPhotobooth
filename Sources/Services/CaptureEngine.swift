import Foundation
import AppKit

/// CaptureEngine — state machine chuẩn §5.1.
/// Bất biến quan trọng:
///  - I-01: chỉ một capture operation đang thực thi (inFlight guard + từ chối duplicate).
///  - I-09: không chuyển lượt tiếp khi ảnh hiện tại chưa ghi an toàn (persist barrier).
///  - I-10: không tự tiếp tục chụp sau restart/sleep/wake/ngắt camera.
/// Timer có generationToken chống callback cũ (§5.3); countdown dùng ContinuousClock (monotonic).
@MainActor
public final class CaptureEngine: ObservableObject {
    public enum ShotKind: Equatable { case normal, retake, additional }

    public enum State: Equatable {
        case idle
        case ready
        case countdown(remainingSeconds: Int, captureIndex: Int, kind: ShotKind)
        case capturing(captureIndex: Int, kind: ShotKind)
        case persisting(captureIndex: Int, kind: ShotKind)
        case intermission(nextIndex: Int, remainingSeconds: Int)
        case paused(reason: PauseReason, nextIndex: Int, kind: ShotKind)
        case recoverableError(message: String, captureIndex: Int)
        case reviewing
        case exporting
        case completed
    }

    public enum PauseReason: Equatable {
        case user, cameraDisconnected, sleepWake, appInactive
    }

    // MARK: Published state
    @Published public private(set) var state: State = .idle
    @Published public private(set) var committedShots: [Int: PhotoRevision] = [:]
    @Published public private(set) var session: CaptureSessionRecord?
    @Published public private(set) var snapshot: FrameSnapshot?
    @Published public private(set) var lastError: AppError?

    public struct ShotContext: Equatable {
        public let sessionID: String
        public let snapshotID: String
        public let captureIndex: Int
        public let kind: ShotKind
        public let keepCrop: Bool

        public init(sessionID: String, snapshotID: String, captureIndex: Int, kind: ShotKind, keepCrop: Bool = false) {
            self.sessionID = sessionID
            self.snapshotID = snapshotID
            self.captureIndex = captureIndex
            self.kind = kind
            self.keepCrop = keepCrop
        }
    }
    public private(set) var lastShotContext: ShotContext?

    enum CancellationPhase: Equatable {
        case confirming
        case waitingForShot
        case saveFailed(message: String, index: Int)
        case confirmingDiscard(message: String, index: Int)
    }

    private struct Cancellation {
        let sessionID: String
        let snapshotID: String
        let remainingTime: Duration?
        let heldTimerState: State?
        var interruption: PauseReason?
        var savedShotKind: ShotKind?
    }

    @Published private(set) var cancellationPhase: CancellationPhase?
    private var cancellation: Cancellation?
    private var timerDeadline: ContinuousClock.Instant?
    var isCancellingSession: Bool { cancellationPhase != nil }

    var onSessionCancelled: ((String) -> Void)?
    var onCancellationError: ((AppError) -> Void)?
    public var onShotCommitted: ((Int, PhotoRevision, ShotKind) -> Void)?
    public var onSessionStatusChanged: ((SessionStatus) -> Void)?

    private let camera: CameraServing
    private let safetySave: SafetySaveService
    private let trashService: TrashService
    private let sessions: SessionRepository
    private let audio: AudioService
    private let coordinator: OperationCoordinator
    private var sessionLockToken: OperationCoordinator.OperationToken?
    private var cameraEventTask: Task<Void, Never>?
    private var sessionEventTask: Task<Void, Never>?
    private var timerToken = 0
    @Published public private(set) var pauseRequested = false
    private var pendingPauseReason: PauseReason?
    private var captureInFlight = false
    private struct PendingPhoto {
        let sessionID: String
        let index: Int
        let kind: ShotKind
        let requestID: String
        let payload: CapturedImagePayload
    }
    private var pendingPhoto: PendingPhoto?
    public var hasPhotoToSave: Bool { pendingPhoto != nil }
    private var isNavigationSafePointHold = false
    /// Giữ tùy chọn "giữ crop" của lệnh retake đang chạy (§3.3) — bền vững qua route vì nằm trong engine.
    private var pendingRetakeKeepCrop = false
    private var notificationObservers: [NSObjectProtocol] = []
    /// Cấu hình freeze khi tạo phiên (§8.3/§15.1)
    public private(set) var countdownSeconds: Int = 3
    public private(set) var intervalSeconds: Int = 2

    public init(camera: CameraServing, safetySave: SafetySaveService,
                sessions: SessionRepository, trashService: TrashService, audio: AudioService,
                coordinator: OperationCoordinator = OperationCoordinator.shared) {
        self.camera = camera
        self.safetySave = safetySave
        self.trashService = trashService
        self.sessions = sessions
        self.audio = audio
        self.coordinator = coordinator
        registerLifecycleObservers()
        listenCameraEvents()
        let sessionEvents = EventBus.shared.stream
        sessionEventTask = Task { [weak self] in
            for await event in sessionEvents {
                guard let self else { return }
                guard case .sessionChanged(let id, _) = event, self.session?.id == id,
                      self.canAdoptSession, self.sessionLockToken == nil else { continue }
                self.refreshSessionAfterChange(id)
            }
        }
    }

    deinit {
        for o in notificationObservers { NotificationCenter.default.removeObserver(o) }
        cameraEventTask?.cancel()
        sessionEventTask?.cancel()
    }

    // MARK: - Điều kiện/bảng hành động (§5.2)

    public var canStart: Bool {
        guard !isCancellingSession, session != nil, snapshot != nil else { return false }
        switch state {
        case .ready, .paused: return true
        default: return false
        }
    }

    public var canChangeFrame: Bool {
        switch state {
        case .reviewing, .completed: return true
        default: return false   // E-CAP-04: khóa đổi khung khi đã chụp (§3.2)
        }
    }

    public var canChangeCamera: Bool {
        guard !isCancellingSession else { return false }
        switch state {
        case .ready, .paused, .recoverableError, .idle, .reviewing: return true
        case .intermission, .countdown, .capturing, .persisting: return false // Intermission còn lượt là bận (§3.5 BUG-CAM-02)
        default: return false
        }
    }

    public var isCaptureBusy: Bool {
        switch state {
        case .countdown, .capturing, .persisting, .intermission, .exporting: return true
        default: return false
        }
    }

    public var requiredIndices: Set<Int> {
        guard let snapshot else { return [] }
        return session?.captureIndices(in: snapshot) ?? snapshot.requiredIndices
    }

    public var nextPendingIndex: Int? {
        requiredIndices.subtracting(Set(committedShots.keys)).sorted().first
    }

    public var allShotsCommitted: Bool {
        !requiredIndices.isEmpty && requiredIndices.isSubset(of: Set(committedShots.keys))
    }

    // MARK: - Bắt đầu phiên (CreateSession §17.3)

    public func beginSession(snapshot: FrameSnapshot, mode: CaptureMode, cameraID: String?,
                             defaults: SessionDefaultsSnapshot,
                             countdown: Int, interval: Int,
                             frameName: String? = nil) throws -> CaptureSessionRecord {
        guard !isCancellingSession, state == .idle || state == .completed else {
            throw AppError.invalidState("Đang có phiên hoạt động")
        }
        guard snapshot.requiredCaptureCount >= 1 || defaults.plannedCaptureCount != nil else {
            throw AppError.frameUnconfigured
        }
        let record = try sessions.createSession(snapshot: snapshot, mode: mode,
                                                cameraID: cameraID, defaults: defaults,
                                                frameNameAtCapture: frameName,
                                                countdownSeconds: countdown,
                                                intermissionSeconds: interval)
        session = record
        self.snapshot = snapshot
        committedShots = [:]
        lastShotContext = nil
        countdownSeconds = countdown
        intervalSeconds = interval
        state = .ready
        return record
    }

    public var canAdoptSession: Bool {
        !isCancellingSession && !isCaptureBusy && !hasPhotoToSave && !isNavigationSafePointHold
    }

    /// Tiếp tục phiên đã có (recovery / "Tiếp tục phiên cũ" §10.3).
    @discardableResult
    public func adoptSession(record: CaptureSessionRecord, snapshot: FrameSnapshot,
                             committed: [Int: PhotoRevision], forReview: Bool = false) -> Bool {
        guard canAdoptSession,
              let detail = try? sessions.activeCaptureDetail(sessionID: record.id),
              detail.snapshot.id == snapshot.id else { return false }
        timerToken += 1
        if session?.id != record.id || self.snapshot?.id != snapshot.id {
            releaseSessionLock()
            lastShotContext = nil
            pendingRetakeKeepCrop = false
        }
        updateCaptureDetail(detail, reverify: true)
        state = forReview ? .reviewing : .ready
        countdownSeconds = detail.session.countdownSeconds
        intervalSeconds = detail.session.intermissionSeconds
        return true
    }

    public func resetToIdle() {
        guard !isCancellingSession, !hasPhotoToSave, !isCaptureBusy, !captureInFlight else { return }
        isNavigationSafePointHold = false
        pendingRetakeKeepCrop = false
        pauseRequested = false
        pendingPauseReason = nil
        timerToken += 1
        releaseSessionLock()
        session = nil
        snapshot = nil
        committedShots = [:]
        lastShotContext = nil
        state = .idle
    }

    // MARK: - Lock & Navigation Hold Helpers (DATA-01, NAV-02)

    private func refreshSessionAfterChange(_ id: String) {
        do {
            guard let detail = try sessions.activeCaptureDetail(sessionID: id) else {
                resetToIdle()
                return
            }
            if snapshot?.id != detail.snapshot.id {
                lastShotContext = nil
                pendingRetakeKeepCrop = false
                state = .ready
            }
            updateCaptureDetail(detail)
        } catch {
            lastError = .ioFailure(error.localizedDescription)
        }
    }

    private func updateCaptureDetail(_ detail: SessionDetail, reverify: Bool = false) {
        session = detail.session
        snapshot = detail.snapshot
        let valid = detail.session.captureIndices(in: detail.snapshot)
        let current = detail.currentRevisions().filter { valid.contains($0.key) && $0.value.state == .available }
        if detail.session.defaults.plannedCaptureCount != nil {
            let known = committedShots
            committedShots = current.filter { index, revision in
                (!reverify && known[index]?.id == revision.id && FileManager.default.fileExists(atPath: (try? sessions.fileURL(for: revision).path) ?? "")) ||
                    (try? sessions.verifiedPhotoImage(revision)) != nil
            }
        } else {
            committedShots = current
        }
    }

    private func prepareCapture() throws {
        guard !isCancellingSession else { throw AppError.busy("Đang xử lý yêu cầu hủy phiên") }
        guard let id = session?.id else { throw AppError.invalidState("Không có phiên chụp") }
        if sessionLockToken == nil {
            sessionLockToken = try coordinator.acquire(key: "session:\(id)", reason: "CaptureEngine: capturing")
        }
        do {
            guard let detail = try sessions.activeCaptureDetail(sessionID: id) else {
                resetToIdle()
                throw AppError.invalidState("Phiên chụp không còn hoạt động")
            }
            guard snapshot?.id == detail.snapshot.id else {
                refreshSessionAfterChange(id)
                throw AppError.invalidState("Khung của phiên đã thay đổi. Hãy kiểm tra rồi thử lại.")
            }
            updateCaptureDetail(detail)
        } catch {
            if !hasPhotoToSave { releaseSessionLock() }
            throw error
        }
    }

    private func prepareCaptureOrReport() -> Bool {
        do {
            try prepareCapture()
            return true
        } catch {
            lastError = (error as? AppError) ?? .ioFailure(error.localizedDescription)
            return false
        }
    }

    private func releaseSessionLock() {
        sessionLockToken?.release()
        sessionLockToken = nil
    }

    public func holdCountdownTimer() {
        timerToken += 1
    }

    public func holdAtSafePoint() {
        isNavigationSafePointHold = true
    }

    public func releaseSafePointHold() {
        isNavigationSafePointHold = false
        if case .ready = state, sessionLockToken != nil {
            if session?.captureMode == .automatic, let next = nextPendingIndex {
                scheduleIntermission(nextIndex: next)
            } else {
                releaseSessionLock()
            }
        }
    }

    public func resumeFromNavigationHold(remainingSeconds: Int, captureIndex: Int, kind: ShotKind, isIntermission: Bool) {
        if case .paused = state {
            // L1: Pause do mất focus, sleep hoặc mất camera vẫn còn hiệu lực
            return
        }
        guard prepareCaptureOrReport() else { return }
        if isIntermission {
            scheduleIntermission(nextIndex: captureIndex)
        } else {
            scheduleCountdown(seconds: max(remainingSeconds, 1), index: captureIndex, kind: kind)
        }
    }

    public func pauseFromNavigationHold(nextIndex: Int, kind: ShotKind) {
        pauseAtIndex(nextIndex, kind: kind, reason: .user)
    }

    private func pauseAtIndex(_ index: Int, kind: ShotKind, reason: PauseReason) {
        timerToken += 1
        isNavigationSafePointHold = false
        state = .paused(reason: reason, nextIndex: index, kind: kind)
        if let session {
            do {
                if try sessions.getSession(id: session.id)?.status != .completed {
                    try sessions.setStatus(sessionID: session.id, status: .paused)
                }
            } catch {
                let failure = (error as? AppError) ?? .ioFailure(error.localizedDescription)
                lastError = failure
                state = .recoverableError(message: failure.message, captureIndex: index)
            }
        }
        releaseSessionLock()
    }

    // MARK: - Start / Pause / Resume / Cancel

    public func startOrContinue() throws {
        guard canStart else { throw AppError.invalidState("Không thể bắt đầu ở trạng thái \(state)") }
        try prepareCapture()
        guard let index = nextPendingIndex else {
            // Đủ ảnh → vào Review
            enterReview()
            return
        }
        pauseRequested = false
        pendingPauseReason = nil
        scheduleCountdown(seconds: countdownSeconds, index: index, kind: .normal)
    }

    /// Manual mode: nút "Chụp tiếp" (§5.4).
    public func captureNextManual() throws {
        guard let session, session.captureMode == .manual else {
            throw AppError.invalidState("Chế độ không phải thủ công")
        }
        guard case .ready = state else { throw AppError.invalidState("Chưa sẵn sàng") }
        try prepareCapture()
        guard let index = nextPendingIndex else { enterReview(); return }
        pauseRequested = false
        pendingPauseReason = nil
        scheduleCountdown(seconds: countdownSeconds, index: index, kind: .normal)
    }

    /// Esc hủy đếm ngược — không ghi ảnh (CAP-04).
    public func cancelCountdown() {
        guard !isCancellingSession else { return }
        switch state {
        case .countdown, .intermission:
            timerToken += 1
            state = .ready
            releaseSessionLock()
            lastShotContext = nil
        default:
            break
        }
    }

    public func pause(reason: PauseReason = .user) {
        if isCancellingSession {
            if reason != .user { cancellation?.interruption = reason }
            return
        }
        switch state {
        case .countdown(_, let index, let kind):
            pauseAtIndex(index, kind: kind, reason: reason)
        case .intermission(let index, _):
            pauseAtIndex(index, kind: .normal, reason: reason)
        case .ready where isNavigationSafePointHold:
            if let nextPendingIndex {
                pauseAtIndex(nextPendingIndex, kind: .normal, reason: reason)
            } else {
                isNavigationSafePointHold = false
                releaseSessionLock()
            }
        case .capturing, .persisting:
            // Đợi safe point (§5.2 / L1) — sau persist sẽ apply
            pauseRequested = true
            pendingPauseReason = reason
        default:
            break
        }
    }

    public func resume() throws {
        guard case .paused(_, let nextIndex, let kind) = state else {
            throw AppError.invalidState("Không ở trạng thái tạm dừng")
        }
        try prepareCapture()
        pauseRequested = false
        switch kind {
        case .normal:
            guard let index = nextPendingIndex else {
                enterReview(); return
            }
            scheduleCountdown(seconds: countdownSeconds, index: index, kind: .normal)
        case .retake, .additional:
            scheduleCountdown(seconds: countdownSeconds, index: nextIndex, kind: kind)
        }
    }

    /// "Giữ phiên và thoát" (§2.2 Paused) — session đã lưu paused trong DB, engine về idle.
    /// Phiên đã hoàn thành giữ nguyên trạng thái completed (không hạ xuống paused).
    public func keepSessionAndExit() {
        guard !isCancellingSession, !hasPhotoToSave, !isCaptureBusy else { return }
        if let session {
            if let current = try? sessions.getSession(id: session.id),
               current.status == .inProgress || current.status == .reviewable || current.status == .draft {
                try? sessions.setStatus(sessionID: session.id, status: .paused)
            }
        }
        timerToken += 1
        releaseSessionLock()
        state = .idle
        session = nil
        snapshot = nil
        committedShots = [:]
    }

    // MARK: - Retake / Additional (§5.5)

    public func beginRetake(index: Int, keepCrop: Bool = false) throws {
        guard case .reviewing = state else { throw AppError.invalidState("Chỉ retake trong Review") }
        try prepareCapture()
        guard requiredIndices.contains(index) else {
            releaseSessionLock()
            throw AppError.invalidState("Index không thuộc khung")
        }
        pendingRetakeKeepCrop = keepCrop
        scheduleCountdown(seconds: countdownSeconds, index: index, kind: .retake)
    }

    public func beginAdditionalShot(index: Int) throws {
        guard case .reviewing = state else { throw AppError.invalidState("Chỉ chụp bổ sung trong Review") }
        try prepareCapture()
        scheduleCountdown(seconds: countdownSeconds, index: index, kind: .additional)
    }

    public func enterReview() {
        guard prepareCaptureOrReport() else { return }
        defer { releaseSessionLock() }
        timerToken += 1
        state = .reviewing
        if let session {
            let currentStatus = (try? sessions.getSession(id: session.id))?.status ?? session.status
            if currentStatus != .completed {
                try? sessions.setStatus(sessionID: session.id, status: .reviewable)
                onSessionStatusChanged?(.reviewable)
            }
        }
    }

    /// Rời RecoverableError về Ready hoặc đếm ngược lại lượt retake/additional (CAP-01).
    public func retryFromError() {
        guard !isCancellingSession, !hasPhotoToSave else { return }
        guard case .recoverableError(_, let captureIndex) = state else { return }
        releaseSessionLock()
        if let ctx = lastShotContext, ctx.kind == .retake, ctx.captureIndex == captureIndex {
            guard prepareCaptureOrReport() else { return }
            pendingRetakeKeepCrop = ctx.keepCrop
            scheduleCountdown(seconds: countdownSeconds, index: captureIndex, kind: .retake)
        } else if let ctx = lastShotContext, ctx.kind == .additional, ctx.captureIndex == captureIndex {
            guard prepareCaptureOrReport() else { return }
            scheduleCountdown(seconds: countdownSeconds, index: captureIndex, kind: .additional)
        } else {
            state = .ready
        }
    }

    public func beginExport() {
        if case .reviewing = state { state = .exporting }
    }

    public func endExport(success: Bool) {
        if case .exporting = state { state = .reviewing }
    }

    public func complete() {
        guard !isCancellingSession, !hasPhotoToSave else { return }
        if let session {
            onSessionStatusChanged?(.completed)
        }
        audio.handle(.completed)
        // Reset về idle để có thể bắt đầu phiên mới ngay (P1-6) — phiên đã completed trong DB,
        // mở lại được từ Thư viện bất cứ lúc nào.
        timerToken += 1
        releaseSessionLock()
        state = .idle
        session = nil
        snapshot = nil
        committedShots = [:]
        lastShotContext = nil
    }

    // MARK: - Cancel capture session

    var canCancelSession: Bool {
        guard !isCancellingSession, let session, session.status != .completed,
              lastShotContext?.kind != .retake, lastShotContext?.kind != .additional,
              !isNavigationSafePointHold else { return false }
        switch state {
        case .ready:
            return !allShotsCommitted
        case .countdown, .capturing, .persisting, .intermission, .paused, .recoverableError:
            return true
        default:
            return false
        }
    }

    func requestSessionCancellation() throws {
        guard canCancelSession, let sessionID = session?.id, let snapshotID = snapshot?.id else {
            throw AppError.invalidState("Phiên hiện tại không thể hủy")
        }
        try prepareCapture()
        var heldState: State?
        var remaining: Duration?
        switch state {
        case .countdown, .intermission:
            heldState = state
            remaining = timerDeadline.map { max(.zero, ContinuousClock.now.duration(to: $0)) }
            holdCountdownTimer()
        default:
            break
        }
        cancellation = Cancellation(sessionID: sessionID, snapshotID: snapshotID,
                                    remainingTime: remaining, heldTimerState: heldState,
                                    interruption: pauseRequested ? pendingPauseReason : nil)
        cancellationPhase = .confirming
    }

    func returnFromSessionCancellation() {
        switch cancellationPhase {
        case .confirmingDiscard(let message, let index):
            cancellationPhase = .saveFailed(message: message, index: index)
            return
        case .confirming, .saveFailed:
            break
        default:
            return
        }
        guard let request = cancellation else { return }
        clearCancellation()

        if captureInFlight {
            if let reason = request.interruption { pause(reason: reason) }
            return
        }
        pauseRequested = false
        pendingPauseReason = nil
        if let reason = request.interruption, let next = nextPendingIndex, !hasPhotoToSave {
            if request.savedShotKind != nil || request.heldTimerState != nil || state == .ready {
                pauseAtIndex(next, kind: .normal, reason: reason)
                return
            }
        }
        if let shotKind = request.savedShotKind {
            continueAfterSavedShot(kind: shotKind)
            return
        }
        switch request.heldTimerState {
        case .countdown(let seconds, let index, let kind):
            scheduleCountdown(seconds: seconds, index: index, kind: kind, duration: request.remainingTime)
        case .intermission(let index, let seconds):
            scheduleIntermission(nextIndex: index, duration: request.remainingTime ?? .seconds(seconds))
        default:
            if !hasPhotoToSave { releaseSessionLock() }
        }
    }

    func confirmSessionCancellation() {
        guard cancellationPhase == .confirming else { return }
        cancellationPhase = .waitingForShot
        finishCancellationIfReady()
    }

    func retrySaveForSessionCancellation() async {
        guard case .saveFailed = cancellationPhase, let pendingPhoto, !captureInFlight else { return }
        cancellationPhase = .waitingForShot
        await performCapture(index: pendingPhoto.index, kind: pendingPhoto.kind,
                             token: timerToken, retry: pendingPhoto)
    }

    func requestDiscardForSessionCancellation() {
        guard case .saveFailed(let message, let index) = cancellationPhase else { return }
        cancellationPhase = .confirmingDiscard(message: message, index: index)
    }

    func discardForSessionCancellation() {
        guard case .confirmingDiscard = cancellationPhase, !captureInFlight else { return }
        moveCancelledSessionToTrash(discardPending: true)
    }

    private func clearCancellation() {
        cancellation = nil
        cancellationPhase = nil
    }

    private func showCancellationSaveFailure(message: String? = nil) {
        guard let pendingPhoto else { return }
        cancellationPhase = .saveFailed(message: message ?? lastError?.message ?? "Chưa lưu được ảnh",
                                        index: pendingPhoto.index)
    }

    private func finishCancellationIfReady() {
        guard cancellationPhase == .waitingForShot, !captureInFlight else { return }
        if hasPhotoToSave {
            showCancellationSaveFailure()
        } else {
            moveCancelledSessionToTrash(discardPending: false)
        }
    }

    private func moveCancelledSessionToTrash(discardPending: Bool) {
        guard let request = cancellation, request.sessionID == session?.id,
              request.snapshotID == snapshot?.id, let sessionLockToken else { return }
        let pending: TrashService.PendingCapture? = discardPending ? pendingPhoto.map {
            .init(index: $0.index, requestID: $0.requestID, sha256: Hashing.sha256Hex($0.payload.data))
        } : nil
        do {
            try trashService.cancelCaptureSession(sessionID: request.sessionID, snapshotID: request.snapshotID,
                                                  pending: pending, parentToken: sessionLockToken)
            pendingPhoto = nil
            lastError = nil
            state = .ready
            clearCancellation()
            resetToIdle()
            onSessionCancelled?(request.sessionID)
        } catch {
            let failure = (error as? AppError) ?? .ioFailure(error.localizedDescription)
            if hasPhotoToSave {
                showCancellationSaveFailure(message: failure.message)
            } else {
                clearCancellation()
                pauseAtIndex(nextPendingIndex ?? requiredIndices.max() ?? 1, kind: .normal,
                             reason: request.interruption ?? .user)
                onCancellationError?(failure)
            }
        }
    }

    // MARK: - Timer (§5.3)

    private func scheduleCountdown(seconds: Int, index: Int, kind: ShotKind, duration: Duration? = nil) {
        if pauseRequested {
            let reason = pendingPauseReason ?? .user
            pauseRequested = false
            pendingPauseReason = nil
            timerToken += 1
            state = .paused(reason: reason, nextIndex: index, kind: kind)
            if let session { try? sessions.setStatus(sessionID: session.id, status: .paused) }
            releaseSessionLock()
            return
        }
        guard let session, let snap = snapshot else { return }
        let sessionID = session.id
        let snapshotID = snap.id
        guard sessionLockToken != nil else { return }
        lastShotContext = ShotContext(sessionID: session.id, snapshotID: snap.id,
                                      captureIndex: index, kind: kind,
                                      keepCrop: pendingRetakeKeepCrop)
        timerToken += 1
        let token = timerToken
        let deadline = ContinuousClock.now + (duration ?? .seconds(max(seconds, 0)))
        timerDeadline = deadline
        state = .countdown(remainingSeconds: max(seconds, 1), captureIndex: index, kind: kind)
        Task { [weak self] in
            await self?.runTimer(until: deadline, token: token) { remaining in
                .countdown(remainingSeconds: remaining, captureIndex: index, kind: kind)
            } tick: { remaining in
                if remaining <= 3 { self?.audio.handle(.countdownTick(last: remaining == 1)) }
            } finish: { [weak self] in
                guard let self, self.timerToken == token,
                      self.session?.id == sessionID, self.snapshot?.id == snapshotID else { return }
                await self.performCapture(index: index, kind: kind, token: token, expectedSessionID: sessionID, expectedSnapshotID: snapshotID)
            }
        }
    }

    private func scheduleIntermission(nextIndex: Int, duration: Duration? = nil) {
        if pauseRequested {
            let reason = pendingPauseReason ?? .user
            pauseRequested = false
            pendingPauseReason = nil
            timerToken += 1
            state = .paused(reason: reason, nextIndex: nextIndex, kind: .normal)
            if let session { try? sessions.setStatus(sessionID: session.id, status: .paused) }
            releaseSessionLock()
            return
        }
        guard let session, let snap = snapshot else { return }
        let sessionID = session.id
        let snapshotID = snap.id
        guard sessionLockToken != nil else { return }
        timerToken += 1
        let token = timerToken
        let seconds = intervalSeconds
        let deadline = ContinuousClock.now + (duration ?? .seconds(max(seconds, 0)))
        timerDeadline = deadline
        let remaining = duration.map { max(1, Int($0.components.seconds) + ($0.components.attoseconds > 0 ? 1 : 0)) }
        state = .intermission(nextIndex: nextIndex, remainingSeconds: remaining ?? max(seconds, 1))
        Task { [weak self] in
            await self?.runTimer(until: deadline, token: token) { remaining in
                .intermission(nextIndex: nextIndex, remainingSeconds: remaining)
            } tick: { _ in
            } finish: { [weak self] in
                guard let self, self.timerToken == token,
                      self.session?.id == sessionID, self.snapshot?.id == snapshotID else { return }
                if self.pauseRequested {
                    let reason = self.pendingPauseReason ?? .user
                    self.pauseRequested = false
                    self.pendingPauseReason = nil
                    self.timerToken += 1
                    self.state = .paused(reason: reason, nextIndex: nextIndex, kind: .normal)
                    if let sess = self.session, sess.id == sessionID { try? self.sessions.setStatus(sessionID: sess.id, status: .paused) }
                    self.releaseSessionLock()
                    return
                }
                self.scheduleCountdown(seconds: self.countdownSeconds, index: nextIndex, kind: .normal)
            }
        }
    }

    private func runTimer(until deadline: ContinuousClock.Instant, token: Int,
                          update: @escaping (Int) -> State,
                          tick: @escaping (Int) -> Void,
                          finish: @escaping () async -> Void) async {
        let clock = ContinuousClock()
        while true {
            guard token == timerToken else { return }
            let now = clock.now
            if now >= deadline { break }
            let d = now.duration(to: deadline)
            var secs = Int(d.components.seconds)
            if d.components.attoseconds > 0 { secs += 1 }
            let shown = max(secs, 1)
            state = update(shown)
            tick(shown)
            do {
                try await clock.sleep(until: min(deadline, now + .seconds(1)), tolerance: .milliseconds(40))
            } catch {
                return
            }
        }
        guard token == timerToken else { return }
        await finish()
    }

    // MARK: - Capture + persist barrier (I-01, I-09, §5.3)

    public func retryPendingSave() async {
        guard !isCancellingSession, let pendingPhoto, pendingPhoto.sessionID == session?.id,
              case .recoverableError = state, !captureInFlight else { return }
        guard prepareCaptureOrReport() else { return }
        pauseRequested = true
        pendingPauseReason = .user
        await performCapture(index: pendingPhoto.index, kind: pendingPhoto.kind,
                             token: timerToken, retry: pendingPhoto)
    }

    private func performCapture(index: Int, kind: ShotKind, token: Int, retry: PendingPhoto? = nil, expectedSessionID: String? = nil, expectedSnapshotID: String? = nil) async {
        guard token == timerToken, sessionLockToken != nil, !captureInFlight,
              (!isCancellingSession && !hasPhotoToSave) || retry != nil else { return }
        guard let session, let snap = snapshot else {
            state = .recoverableError(message: "Không có phiên chụp", captureIndex: index)
            return
        }
        if let expectedSessionID, session.id != expectedSessionID { return }
        if let expectedSnapshotID, snap.id != expectedSnapshotID { return }
        captureInFlight = true
        defer {
            captureInFlight = false
            finishCancellationIfReady()
        }
        do {
            let photo: PendingPhoto
            if let retry {
                photo = retry
            } else {
                state = .capturing(captureIndex: index, kind: kind)
                let request = UUID()
                let payload = try await camera.captureStill(requestID: request)
                guard token == timerToken, self.session?.id == session.id, snapshot?.id == snap.id,
                      state == .capturing(captureIndex: index, kind: kind) else { return }
                guard payload.requestID == request.uuidString else {
                    throw AppError.ioFailure("Ảnh trả về không khớp lượt chụp")
                }
                photo = PendingPhoto(sessionID: session.id, index: index, kind: kind,
                                     requestID: request.uuidString, payload: payload)
                pendingPhoto = photo
                audio.handle(.shutter)
            }
            state = .persisting(captureIndex: index, kind: kind)
            let payload = photo.payload
            // Persist barrier: ghi file + verify + DB transaction (§5.3) — lỗi không tăng index
            let revision = try await safetySave.savePhoto(
                sessionID: session.id, captureIndex: index,
                payloadData: payload.data, requestID: photo.requestID,
                width: payload.actualWidth, height: payload.actualHeight,
                orientation: payload.orientation, codec: payload.codec,
                colorProfile: payload.colorProfile,
                parentToken: sessionLockToken)
            pendingPhoto = nil
            committedShots[index] = revision
            EventBus.shared.post(.shotCommitted(sessionID: session.id, captureIndex: index, photoRevisionID: revision.id))
            onShotCommitted?(index, revision, kind)
            // §3.3: ảnh retake mới → crop slot về Auto Face (trừ khi người dùng chọn giữ crop)
            if kind == .retake {
                for slot in snap.slots where slot.captureIndex == index && !pendingRetakeKeepCrop {
                    try? sessions.setPlacement(sessionID: session.id, snapshotSlotID: slot.id,
                                               placement: PhotoPlacement(), cropMode: .autoFace,
                                               manualOverride: false, expectedSnapshotID: snap.id,
                                               parentToken: sessionLockToken)
                }
                pendingRetakeKeepCrop = false
            }

            if isCancellingSession {
                cancellation?.savedShotKind = kind
                state = .ready
                return
            }

            // Safe point thoát / tạm dừng (§Bước 2 / L1): kiểm tra trước khi lên lịch lượt kế
            let currentStatus = (try? sessions.getSession(id: session.id))?.status ?? session.status
            if pauseRequested {
                isNavigationSafePointHold = false
                let reason = pendingPauseReason ?? .user
                pauseRequested = false
                pendingPauseReason = nil
                timerToken += 1
                let required = session.captureIndices(in: snap)
                if required.isSubset(of: Set(committedShots.keys)) {
                    if currentStatus != .completed {
                        try? sessions.setStatus(sessionID: session.id, status: .reviewable)
                        onSessionStatusChanged?(.reviewable)
                    }
                    state = .reviewing
                    audio.handle(.completed)
                    releaseSessionLock()
                } else {
                    let next = nextPendingIndex ?? index
                    state = .paused(reason: reason, nextIndex: next, kind: .normal)
                    try? sessions.setStatus(sessionID: session.id, status: .paused)
                    releaseSessionLock()
                }
                return
            }

            if isNavigationSafePointHold {
                let required = session.captureIndices(in: snap)
                if required.isSubset(of: Set(committedShots.keys)) {
                    if currentStatus != .completed {
                        try? sessions.setStatus(sessionID: session.id, status: .reviewable)
                        onSessionStatusChanged?(.reviewable)
                    }
                    state = .reviewing
                    audio.handle(.completed)
                    isNavigationSafePointHold = false
                    releaseSessionLock()
                } else {
                    state = .ready
                }
                return
            }

            continueAfterSavedShot(kind: kind)
        } catch {
            timerToken += 1
            pauseRequested = false
            pendingPauseReason = nil
            isNavigationSafePointHold = false
            let failure = (error as? AppError) ?? .ioFailure(error.localizedDescription)
            lastError = failure
            state = .recoverableError(message: failure.message, captureIndex: index)
            if kind != .retake, (try? sessions.getSession(id: session.id)?.status) != .completed {
                try? sessions.setStatus(sessionID: session.id, status: .paused)
            }
            if !isCancellingSession && !hasPhotoToSave { releaseSessionLock() }
            audio.handle(.warning)
        }
    }

    private func continueAfterSavedShot(kind: ShotKind) {
        guard let session else { return }
        let currentStatus = (try? sessions.getSession(id: session.id))?.status ?? session.status
        if allShotsCommitted {
            if currentStatus != .completed {
                try? sessions.setStatus(sessionID: session.id, status: .reviewable)
                onSessionStatusChanged?(.reviewable)
            }
            state = .reviewing
            audio.handle(.completed)
            releaseSessionLock()
        } else if kind != .normal {
            state = .reviewing
            releaseSessionLock()
        } else if session.captureMode == .manual {
            state = .ready   // CAP-10: chờ người dùng bấm Chụp tiếp
            releaseSessionLock()
        } else if let next = nextPendingIndex {
            scheduleIntermission(nextIndex: next)
        } else {
            state = .reviewing
            releaseSessionLock()
        }
    }

    // MARK: - Camera events (§4.5)

    private func listenCameraEvents() {
        cameraEventTask = Task { [weak self] in
            let stream = self?.camera.events
            guard let stream else { return }
            for await event in stream {
                guard let self else { return }
                await self.handleCameraEvent(event)
            }
        }
    }

    private func handleCameraEvent(_ event: CameraEvent) async {
        switch event {
        case .deviceDisconnected(let id):
            guard await camera.currentDevice?.uniqueID == id else { return }
            pauseForCameraInterruption()
        case .interruptionStarted, .fatalFailure:
            pauseForCameraInterruption()
        case .pressureWarning:
            audio.handle(.warning)
        default:
            break
        }
    }

    private func pauseForCameraInterruption() {
        if isCancellingSession {
            cancellation?.interruption = .cameraDisconnected
            return
        }
        guard !pauseRequested else { return }
        switch state {
        case .countdown, .intermission, .capturing, .persisting:
            pause(reason: .cameraDisconnected)
            audio.handle(.warning)
        default:
            break
        }
    }

    // MARK: - Sleep/wake + app inactive (E-CAP-03, §5.3)

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default
        notificationObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause(reason: .sleepWake) }
        })
        notificationObservers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                switch self.state {
                case .countdown, .intermission, .capturing, .persisting:
                    self.pause(reason: .appInactive)
                default:
                    break
                }
            }
        })
    }


}

#if DEBUG
extension CaptureEngine {
    public func setStateForTesting(_ newState: State) {
        self.state = newState
    }
    public var timerTokenForTesting: Int {
        timerToken
    }
    public var isNavigationSafePointHoldForTesting: Bool {
        isNavigationSafePointHold
    }
}
#endif
