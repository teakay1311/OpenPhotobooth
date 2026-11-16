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

    public var onShotCommitted: ((Int, PhotoRevision, ShotKind) -> Void)?
    public var onSessionStatusChanged: ((SessionStatus) -> Void)?

    private let camera: CameraServing
    private let safetySave: SafetySaveService
    private let sessions: SessionRepository
    private let audio: AudioService
    private let coordinator: OperationCoordinator
    private var sessionLockToken: OperationCoordinator.OperationToken?
    private var cameraEventTask: Task<Void, Never>?
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
                sessions: SessionRepository, audio: AudioService,
                coordinator: OperationCoordinator = OperationCoordinator.shared) {
        self.camera = camera
        self.safetySave = safetySave
        self.sessions = sessions
        self.audio = audio
        self.coordinator = coordinator
        registerLifecycleObservers()
        listenCameraEvents()
    }

    deinit {
        for o in notificationObservers { NotificationCenter.default.removeObserver(o) }
        cameraEventTask?.cancel()
    }

    // MARK: - Điều kiện/bảng hành động (§5.2)

    public var canStart: Bool {
        guard session != nil, snapshot != nil else { return false }
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
        guard state == .idle || state == .completed else {
            throw AppError.invalidState("Đang có phiên hoạt động")
        }
        guard snapshot.requiredCaptureCount >= 1 else { throw AppError.frameUnconfigured }
        let record = try sessions.createSession(snapshot: snapshot, mode: mode,
                                                cameraID: cameraID, defaults: defaults,
                                                frameNameAtCapture: frameName,
                                                countdownSeconds: countdown,
                                                intermissionSeconds: interval)
        session = record
        self.snapshot = snapshot
        committedShots = [:]
        countdownSeconds = countdown
        intervalSeconds = interval
        state = .ready
        return record
    }

    public var canAdoptSession: Bool {
        !isCaptureBusy && !hasPhotoToSave && !isNavigationSafePointHold
    }

    /// Tiếp tục phiên đã có (recovery / "Tiếp tục phiên cũ" §10.3).
    @discardableResult
    public func adoptSession(record: CaptureSessionRecord, snapshot: FrameSnapshot,
                             committed: [Int: PhotoRevision], forReview: Bool = false) -> Bool {
        guard canAdoptSession else { return false }
        timerToken += 1
        if session?.id != record.id || self.snapshot?.id != snapshot.id {
            releaseSessionLock()
            lastShotContext = nil
            pendingRetakeKeepCrop = false
        }
        session = record
        self.snapshot = snapshot
        let validIndices = record.captureIndices(in: snapshot)
        committedShots = committed.filter { validIndices.contains($0.key) }
        state = forReview ? .reviewing : .ready
        countdownSeconds = record.countdownSeconds
        intervalSeconds = record.intermissionSeconds
        return true
    }

    public func resetToIdle() {
        guard !hasPhotoToSave else { return }
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

    private func acquireSessionLockIfNeeded(sessionID: String) {
        guard sessionLockToken == nil else { return }
        sessionLockToken = try? coordinator.acquire(key: "session:\(sessionID)", reason: "CaptureEngine: capturing")
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
        if case .ready = state {
            if session?.captureMode == .automatic, let next = nextPendingIndex {
                scheduleIntermission(nextIndex: next)
            }
        }
    }

    public func resumeFromNavigationHold(remainingSeconds: Int, captureIndex: Int, kind: ShotKind, isIntermission: Bool) {
        if case .paused = state {
            // L1: Pause do mất focus, sleep hoặc mất camera vẫn còn hiệu lực
            return
        }
        if isIntermission {
            scheduleIntermission(nextIndex: captureIndex)
        } else {
            scheduleCountdown(seconds: max(remainingSeconds, 1), index: captureIndex, kind: kind)
        }
    }

    public func pauseFromNavigationHold(nextIndex: Int, kind: ShotKind) {
        timerToken += 1
        state = .paused(reason: .user, nextIndex: nextIndex, kind: kind)
        if let session {
            try? sessions.setStatus(sessionID: session.id, status: .paused)
        }
        releaseSessionLock()
    }

    // MARK: - Start / Pause / Resume / Cancel

    public func startOrContinue() throws {
        guard canStart else { throw AppError.invalidState("Không thể bắt đầu ở trạng thái \(state)") }
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
        guard let index = nextPendingIndex else { enterReview(); return }
        pauseRequested = false
        pendingPauseReason = nil
        scheduleCountdown(seconds: countdownSeconds, index: index, kind: .normal)
    }

    /// Esc hủy đếm ngược — không ghi ảnh (CAP-04).
    public func cancelCountdown() {
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
        switch state {
        case .countdown(_, let index, let kind):
            timerToken += 1
            state = .paused(reason: reason, nextIndex: index, kind: kind)
            if let session { try? sessions.setStatus(sessionID: session.id, status: .paused) }
            releaseSessionLock()
        case .intermission(let index, _):
            timerToken += 1
            state = .paused(reason: reason, nextIndex: index, kind: .normal)
            if let session { try? sessions.setStatus(sessionID: session.id, status: .paused) }
            releaseSessionLock()
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
        pauseRequested = false
        switch kind {
        case .normal:
            guard let index = nextPendingIndex ?? nextPendingIndexForced(nextIndex) else {
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
        guard !hasPhotoToSave, !isCaptureBusy else { return }
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
        guard requiredIndices.contains(index) else { throw AppError.invalidState("Index không thuộc khung") }
        pendingRetakeKeepCrop = keepCrop
        scheduleCountdown(seconds: countdownSeconds, index: index, kind: .retake)
    }

    public func beginAdditionalShot(index: Int) throws {
        guard case .reviewing = state else { throw AppError.invalidState("Chỉ chụp bổ sung trong Review") }
        scheduleCountdown(seconds: countdownSeconds, index: index, kind: .additional)
    }

    public func enterReview() {
        timerToken += 1
        releaseSessionLock()
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
        guard !hasPhotoToSave else { return }
        guard case .recoverableError(_, let captureIndex) = state else { return }
        releaseSessionLock()
        if let ctx = lastShotContext, ctx.kind == .retake, ctx.captureIndex == captureIndex {
            pendingRetakeKeepCrop = ctx.keepCrop
            scheduleCountdown(seconds: countdownSeconds, index: captureIndex, kind: .retake)
        } else if let ctx = lastShotContext, ctx.kind == .additional, ctx.captureIndex == captureIndex {
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
        guard !hasPhotoToSave else { return }
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

    // MARK: - Timer (§5.3)

    private func scheduleCountdown(seconds: Int, index: Int, kind: ShotKind) {
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
        acquireSessionLockIfNeeded(sessionID: session.id)
        lastShotContext = ShotContext(sessionID: session.id, snapshotID: snap.id,
                                      captureIndex: index, kind: kind,
                                      keepCrop: pendingRetakeKeepCrop)
        timerToken += 1
        let token = timerToken
        state = .countdown(remainingSeconds: max(seconds, 1), captureIndex: index, kind: kind)
        Task { [weak self] in
            await self?.runTimer(seconds: seconds, token: token) { remaining in
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

    private func scheduleIntermission(nextIndex: Int) {
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
        acquireSessionLockIfNeeded(sessionID: session.id)
        timerToken += 1
        let token = timerToken
        let seconds = intervalSeconds
        state = .intermission(nextIndex: nextIndex, remainingSeconds: max(seconds, 1))
        Task { [weak self] in
            await self?.runTimer(seconds: seconds, token: token) { remaining in
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

    private func runTimer(seconds: Int, token: Int,
                          update: @escaping (Int) -> State,
                          tick: @escaping (Int) -> Void,
                          finish: @escaping () async -> Void) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(TimeInterval(max(seconds, 0)))
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
                try await clock.sleep(until: clock.now + .seconds(1), tolerance: .milliseconds(40))
            } catch {
                return
            }
        }
        guard token == timerToken else { return }
        await finish()
    }

    // MARK: - Capture + persist barrier (I-01, I-09, §5.3)

    public func retryPendingSave() async {
        guard let pendingPhoto, pendingPhoto.sessionID == session?.id,
              case .recoverableError = state, !captureInFlight else { return }
        acquireSessionLockIfNeeded(sessionID: pendingPhoto.sessionID)
        pauseRequested = true
        pendingPauseReason = .user
        await performCapture(index: pendingPhoto.index, kind: pendingPhoto.kind,
                             token: timerToken, retry: pendingPhoto)
    }

    private func performCapture(index: Int, kind: ShotKind, token: Int, retry: PendingPhoto? = nil, expectedSessionID: String? = nil, expectedSnapshotID: String? = nil) async {
        guard token == timerToken, !captureInFlight, !hasPhotoToSave || retry != nil else { return }
        guard let session, let snap = snapshot else {
            state = .recoverableError(message: "Không có phiên chụp", captureIndex: index)
            return
        }
        if let expectedSessionID, session.id != expectedSessionID { return }
        if let expectedSnapshotID, snap.id != expectedSnapshotID { return }
        captureInFlight = true
        defer { captureInFlight = false }
        do {
            let photo: PendingPhoto
            if let retry {
                photo = retry
            } else {
                state = .capturing(captureIndex: index, kind: kind)
                let request = UUID()
                let payload = try await camera.captureStill(requestID: request)
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
                                               manualOverride: false)
                }
                pendingRetakeKeepCrop = false
            }

            // Safe point thoát / tạm dừng (§Bước 2 / L1): kiểm tra trước khi lên lịch lượt kế
            let currentStatus = (try? sessions.getSession(id: session.id))?.status ?? session.status
            if pauseRequested {
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
                isNavigationSafePointHold = false
                let required = session.captureIndices(in: snap)
                if required.isSubset(of: Set(committedShots.keys)) {
                    if currentStatus != .completed {
                        try? sessions.setStatus(sessionID: session.id, status: .reviewable)
                        onSessionStatusChanged?(.reviewable)
                    }
                    state = .reviewing
                    audio.handle(.completed)
                    releaseSessionLock()
                } else if session.captureMode == .manual {
                    state = .ready
                    releaseSessionLock()
                } else {
                    // Đợi quyết định từ dialog điều hướng (NAV-02)
                    state = .ready
                }
                return
            }

            let required = session.captureIndices(in: snap)
            if required.isSubset(of: Set(committedShots.keys)) {
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
        } catch {
            timerToken += 1
            pauseRequested = false
            pendingPauseReason = nil
            isNavigationSafePointHold = false
            if !hasPhotoToSave { releaseSessionLock() }
            let failure = (error as? AppError) ?? .ioFailure(error.localizedDescription)
            lastError = failure
            state = .recoverableError(message: failure.message, captureIndex: index)
            if kind != .retake, (try? sessions.getSession(id: session.id)?.status) != .completed {
                try? sessions.setStatus(sessionID: session.id, status: .paused)
            }
            audio.handle(.warning)
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

    private func handleCameraEvent(_ event: CameraEvent) {
        switch event {
        case .deviceDisconnected, .interruptionStarted:
            switch state {
            case .countdown(_, let index, let kind):
                // CAM-05/CAP-06: hủy đếm, không tạo photo, giữ ảnh đã chụp
                timerToken += 1
                state = .paused(reason: .cameraDisconnected, nextIndex: index, kind: kind)
                audio.handle(.warning)
            case .intermission(let index, _):
                timerToken += 1
                state = .paused(reason: .cameraDisconnected, nextIndex: index, kind: .normal)
                audio.handle(.warning)
            case .capturing, .persisting:
                break // Capturing: đợi callback trong timeout; Saving: ưu tiên lưu an toàn
            default:
                break
            }
        case .fatalFailure(let message):
            switch state {
            case .capturing, .countdown, .intermission:
                timerToken += 1
                if case .capturing = state {
                    state = .recoverableError(message: message, captureIndex: nextPendingIndex ?? 1)
                } else {
                    state = .paused(reason: .cameraDisconnected, nextIndex: nextPendingIndex ?? 1, kind: .normal)
                }
                audio.handle(.warning)
            default:
                break
            }
        case .pressureWarning:
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

    private func nextPendingIndexForced(_ fallback: Int) -> Int? {
        nextPendingIndex ?? (requiredIndices.contains(fallback) ? fallback : nil)
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
