import CoreGraphics
import XCTest
@testable import OpenPhotobooth

@MainActor
final class CapturePhotoSelectionTests: XCTestCase {
    func testExistingLibraryReceivesOnlyNewTemplates() async throws {
        let env = AppEnvironment(inMemory: true)
        let original = try env.frames.createEmptyFrame(name: "Dải 3 ảnh", categoryID: nil)
        let custom = try env.frames.createEmptyFrame(name: "Cặp ảnh dọc", categoryID: nil)
        try env.db.run("INSERT INTO app_state(key, value, updated_at_ms) VALUES('seedVersion', '1', 0)")
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)

        XCTAssertEqual(try env.frames.getFrame(id: original.id)?.name, "Dải 3 ảnh")
        XCTAssertEqual(try env.frames.getFrame(id: custom.id)?.name, "Cặp ảnh dọc")
        let newFrames = try env.frames.listReadyFrames()
        XCTAssertEqual(newFrames.count, 5)
        for frame in newFrames {
            let revisionID = try XCTUnwrap(frame.currentRevisionID)
            let revision = try XCTUnwrap(env.frames.getRevision(id: revisionID))
            let slots = try env.frames.getSlots(revisionID: revisionID)
            XCTAssertTrue(FrameValidator.validate(revision: revision, slots: slots).isEmpty, frame.name)
            let thumbnail = await env.frameThumbnails.requestThumbnail(frameID: frame.id, revisionID: revisionID)
            XCTAssertNotNil(thumbnail, frame.name)
        }
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        XCTAssertEqual(try env.frames.listFrames().count, 7)
    }

    func testKioskManualSessionContinuesToReviewAndFinishes() async throws {
        let camera = FakeCameraService()
        let env = AppEnvironment(inMemory: true, camera: camera)
        await env.boot()
        let capture = CaptureViewModel(env: env)
        capture.mode = .manual
        capture.countdown = 0
        await capture.retryCamera()
        env.showFullscreen = true
        let vm = FullscreenViewModel(env: env, captureVM: capture)
        vm.enterFullscreen()
        vm.step = .captureSetup
        capture.plannedCaptureCount = 2
        await vm.beginShooting()

        XCTAssertEqual(vm.step, .live)
        let sessionID = try XCTUnwrap(env.engine.session?.id)
        for _ in 0..<100 {
            if env.engine.committedShots.count == 1 && env.engine.state == .ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(env.engine.committedShots.count, 1)
        XCTAssertEqual(env.engine.state, .ready)
        try env.engine.captureNextManual()
        for _ in 0..<100 {
            if env.engine.state == .reviewing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(env.engine.state, .reviewing)
        await vm.openReview()
        XCTAssertEqual(vm.step, .chooseFrame)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: sessionID))
        XCTAssertTrue(detail.session.awaitsFrame)
        XCTAssertNil(detail.snapshot.sourceFrameID)
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first(where: { $0.name == "Cặp ảnh ngang" }))
        try env.sessions.applyCaptureFrame(sessionID: sessionID, expectedRevision: detail.session.revisionNo,
                                           frameID: frame.id, frameRevisionID: XCTUnwrap(frame.currentRevisionID),
                                           orderedPhotoIDs: detail.currentRevisions().sorted { $0.key < $1.key }.map { $0.value.id },
                                           frames: env.frames, assets: env.assets)
        await vm.openReview()
        XCTAssertEqual(vm.step, .review)
        XCTAssertTrue(vm.reviewVM?.canExport == true)
        await vm.finish()
        XCTAssertEqual(vm.step, .finish)
        XCTAssertEqual(try env.sessions.getSession(id: sessionID)?.status, .completed)
        vm.exitFullscreenRequested()
        await camera.stopPreview()
    }

    func testPB16KioskWaitsForInFlightPhotoBeforeClosing() async throws {
        let camera = FakeCameraService()
        let env = AppEnvironment(inMemory: true, camera: camera)
        await env.boot()
        let capture = CaptureViewModel(env: env)
        capture.countdown = 0
        await capture.retryCamera()
        env.showFullscreen = true
        let vm = FullscreenViewModel(env: env, captureVM: capture)
        vm.enterFullscreen()
        vm.step = .captureSetup
        capture.plannedCaptureCount = 2
        await vm.beginShooting()
        let id = try XCTUnwrap(env.engine.session?.id)
        let deadline = ContinuousClock.now + .seconds(3)
        while env.engine.state != .capturing(captureIndex: 1, kind: .normal), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(env.engine.state, .capturing(captureIndex: 1, kind: .normal))

        vm.exitFullscreenRequested()
        vm.exitFullscreenRequested()
        XCTAssertTrue(env.showFullscreen)
        XCTAssertTrue(vm.exitRequested)
        while env.engine.isCaptureBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        vm.finishExitIfReady()
        XCTAssertFalse(env.showFullscreen)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        XCTAssertEqual(detail.currentRevisions().keys.sorted(), [1])
        XCTAssertEqual(detail.session.status, .paused)
        XCTAssertFalse(env.coordinator.isBusy(key: "session:\(id)").busy)
        await camera.stopPreview()
    }

    func testCaptureSettingsFollowSelectedFrameAndColor() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let vm = CaptureViewModel(env: env)
        let readyFrames = try env.frames.listReadyFrames()
        let strip = try XCTUnwrap(readyFrames.first { $0.name == "Dải 3 ảnh" })
        let grid = try XCTUnwrap(readyFrames.first { $0.name == "Lưới 4 ảnh" })
        vm.selectFrame(strip.id)
        XCTAssertEqual(vm.selectedFrameIndices, [1, 2, 3])
        vm.requestedSelectionCount = 3
        vm.selectFrame(grid.id)
        XCTAssertEqual(vm.selectedFrameIndices, [1, 2, 3, 4])
        XCTAssertEqual(vm.selectionCount, 4)
        vm.selectedPresetID = "blackwhite"
        XCTAssertEqual(vm.livePhotoParameters.presetParameters, .blackWhite)
    }

    func testBatchSelectionPersistsOrderAndProtectsOriginals() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let readyFrames = try env.frames.listReadyFrames()
        let frame = try XCTUnwrap(readyFrames.first { $0.name == "Dải 3 ảnh" })
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)
        var defaults = env.settings.sessionDefaultsSnapshot()
        defaults.selectionCaptureCount = 6
        let session = try env.sessions.createSession(snapshot: snapshot, mode: .automatic, cameraID: nil, defaults: defaults)
        let jpeg = try ExportService.encode(cg: .createBlank(), format: .jpeg, quality: 90)

        for index in 1...6 {
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: index,
                                                   payloadData: jpeg, requestID: UUID().uuidString,
                                                   width: 64, height: 64, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
            if index == 3 {
                XCTAssertThrowsError(try env.sessions.confirmPhotoSelection(sessionID: session.id, order: [1, 2, 3]))
            }
        }
        try env.sessions.setStatus(sessionID: session.id, status: .reviewable)
        let before = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertFalse(before.hasEnoughPhotos)
        XCTAssertEqual(before.committedCount, 6)
        XCTAssertEqual(try env.sessions.listSessions().first?.committedCount, 6)
        try env.trashService.trashSession(sessionID: session.id)
        let item = try XCTUnwrap(env.trashRepo.list().first(where: { $0.rootID == session.id }))
        try env.trashService.restore(item)
        let restored = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertTrue(restored.needsPhotoSelection)
        XCTAssertEqual(restored.session.status, .reviewable)
        XCTAssertThrowsError(try env.sessions.confirmPhotoSelection(sessionID: session.id, order: [5, 5, 2]))
        XCTAssertThrowsError(try env.sessions.confirmPhotoSelection(sessionID: session.id, order: [7, 2, 1]))
        do {
            _ = try await env.completeSession(sessionID: session.id)
            XCTFail("Phiên chưa xác nhận ảnh vẫn được hoàn thành")
        } catch {
            XCTAssertEqual(try env.sessions.getSession(id: session.id)?.status, .reviewable)
        }

        try env.sessions.confirmPhotoSelection(sessionID: session.id, order: [5, 2, 6])
        let confirmed = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertTrue(confirmed.hasEnoughPhotos)
        XCTAssertEqual(confirmed.session.defaults.selectedCaptureOrder, [5, 2, 6])
        XCTAssertEqual(confirmed.session.status, .reviewable)
        let slots = snapshot.slots.sorted { $0.captureIndex < $1.captureIndex }
        XCTAssertEqual(slots.compactMap { slot in
            confirmed.snapshot.slots.first { $0.id == slot.id }?.captureIndex
        }, [5, 2, 6])
        XCTAssertEqual(Set(confirmed.currentRevisions().keys), [5, 2, 6])
        XCTAssertEqual(confirmed.shots, before.shots)
        XCTAssertEqual(confirmed.photoRevisions, before.photoRevisions)
        XCTAssertEqual(try env.sessions.listSessions().first?.committedCount, 3)
        XCTAssertThrowsError(try env.sessions.confirmPhotoSelection(sessionID: session.id, order: [1, 2, 3]))
        let render = try await env.renderBuilder.buildModelStrict(detail: confirmed, targetWidth: 360, targetHeight: 480)
        XCTAssertEqual(Set(render.sources.keys), [5, 2, 6])

        let grid = try XCTUnwrap(readyFrames.first { $0.name == "Lưới 4 ảnh" })
        try env.sessions.changeFrame(sessionID: session.id, newSnapshot: env.frames.createSnapshot(frameID: grid.id, persist: false))
        let reopened = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertEqual(reopened.snapshot.requiredCaptureCount, 4)
        XCTAssertEqual(reopened.session.pendingSelectionCount, 6)
        XCTAssertFalse(reopened.hasEnoughPhotos)
        XCTAssertEqual(reopened.committedCount, 6)
        try env.sessions.confirmPhotoSelection(sessionID: session.id, order: [6, 5, 4, 1])
        let reselection = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertEqual(reselection.session.defaults.selectedCaptureOrder, [6, 5, 4, 1])
        XCTAssertEqual(reselection.shots, before.shots)
    }
}

private actor PreviewTrace {
    private(set) var calls: [String] = []
    private var pausedSelection: CheckedContinuation<Void, Never>?
    private var pauseNextSelection = true
    private var failNextPreview = false

    func selecting(_ id: String) async {
        calls.append("select:\(id)")
        if pauseNextSelection {
            pauseNextSelection = false
            await withCheckedContinuation { pausedSelection = $0 }
        }
    }

    func releaseSelection() {
        pausedSelection?.resume()
        pausedSelection = nil
    }

    func starting(_ id: String) throws {
        calls.append("preview:\(id)")
        if failNextPreview {
            failNextPreview = false
            throw AppError.cameraConfigurationFailed("Camera chưa gửi khung hình")
        }
    }

    func failPreviewOnce() { failNextPreview = true }
    var isSelectionPaused: Bool { pausedSelection != nil }
}

private final class TracedPreviewCamera: CameraServing {
    let base = FakeCameraService()
    let trace = PreviewTrace()

    var events: AsyncStream<CameraEvent> { base.events }
    var currentDevice: CameraDescriptor? { get async { await base.currentDevice } }
    var isFallbackVideoStill: Bool { get async { await base.isFallbackVideoStill } }
    var isPreviewRunning: Bool { get async { await base.isPreviewRunning } }
    func cameraPermissionState() async -> CameraPermissionState { await base.cameraPermissionState() }
    func requestAccessIfNeeded() async -> CameraPermissionState { await base.requestAccessIfNeeded() }
    func discoverDevices() async -> [CameraDescriptor] { await base.discoverDevices() }
    func selectAutoDevice() async throws -> CameraCapabilities { try await selectDevice("fake-built-in") }
    func selectDevice(_ id: CameraID) async throws -> CameraCapabilities {
        await trace.selecting(id)
        return try await base.selectDevice(id)
    }
    func startPreview() async throws {
        try await trace.starting(await base.currentDevice?.uniqueID ?? "none")
        try await base.startPreview()
    }
    func stopPreview() async { await base.stopPreview() }
    func captureStill(requestID: UUID) async throws -> CapturedImagePayload {
        try await base.captureStill(requestID: requestID)
    }
    func applyControls(_ controls: CameraControls) async throws -> AppliedControls {
        try await base.applyControls(controls)
    }
    func setResolution(_ resolution: String) async throws { try await base.setResolution(resolution) }
}

@MainActor
final class CameraStartupRegressionTests: XCTestCase {
    private func waitForSelection(_ trace: PreviewTrace) async throws {
        for _ in 0..<200 {
            if await trace.isSelectionPaused { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Camera fixture chưa vào bước chọn thiết bị")
    }

    func testConcurrentRefreshesShareOneSetupAndKeepRunningPreview() async throws {
        let camera = TracedPreviewCamera()
        let env = AppEnvironment(inMemory: true, camera: camera)
        let capture = CaptureViewModel(env: env)
        let kiosk = CaptureViewModel(env: env)
        let first = Task { await capture.refreshCameraState() }
        try await waitForSelection(camera.trace)
        let second = Task { await kiosk.refreshCameraState() }

        XCTAssertFalse(capture.isCameraReady)
        let duringSetup = await camera.trace.calls
        XCTAssertEqual(duringSetup, ["select:fake-built-in"])

        await camera.trace.releaseSelection()
        await first.value
        await second.value
        await capture.refreshCameraState()
        let calls = await camera.trace.calls
        XCTAssertEqual(calls, ["select:fake-built-in", "preview:fake-built-in"])
        XCTAssertTrue(capture.isCameraReady)
        XCTAssertTrue(kiosk.isCameraReady)
        await camera.stopPreview()
    }

    func testManualSwitchSupersedesAutomaticSetupAndCanRetryFailedPreview() async throws {
        let camera = TracedPreviewCamera()
        let env = AppEnvironment(inMemory: true, camera: camera)
        let vm = CaptureViewModel(env: env)
        let automatic = Task { await vm.refreshCameraState() }
        try await waitForSelection(camera.trace)
        await camera.trace.failPreviewOnce()
        let manual = Task { await vm.selectCamera("fake-usb") }
        while env.settings.cameraSelection != "fake-usb" { await Task.yield() }
        await camera.trace.releaseSelection()
        await automatic.value
        await manual.value

        let initialCalls = await camera.trace.calls
        XCTAssertEqual(initialCalls, ["select:fake-built-in", "select:fake-usb", "preview:fake-usb"])
        XCTAssertFalse(vm.isCameraReady)
        XCTAssertNotNil(vm.cameraPreviewError)
        await vm.retryCamera()
        XCTAssertTrue(vm.isCameraReady)
        XCTAssertNil(vm.cameraPreviewError)
        XCTAssertEqual(vm.selectedDeviceID, "fake-usb")
        await camera.stopPreview()
    }

    func testNativeStillCaptureWithoutInputReleasesRequestSlot() async {
        let camera = CameraService()
        for _ in 0..<2 {
            do {
                _ = try await camera.captureStill(requestID: UUID())
                XCTFail("Không có input mà vẫn trả ảnh")
            } catch {
                XCTAssertEqual(error as? AppError, .noCamera)
            }
        }
    }

    func testLaunchDoesNotRequestPermissionAndDeniedCannotStartPreview() async {
        let camera = TracedPreviewCamera()
        camera.base.configuredPermissionState = .notDetermined
        let env = AppEnvironment(inMemory: true, camera: camera)
        let vm = CaptureViewModel(env: env)
        await vm.refreshCameraState()
        XCTAssertEqual(camera.base.requestAccessCallCount, 0)
        XCTAssertEqual(vm.permissionState, .notDetermined)
        camera.base.configuredPermissionState = .denied
        await vm.enableCamera()
        XCTAssertEqual(vm.permissionState, .denied)
        XCTAssertFalse(vm.isCameraReady)
        let calls = await camera.trace.calls
        XCTAssertTrue(calls.isEmpty)
    }
}

@MainActor
final class CaptureLayoutRegressionTests: XCTestCase {
    func testSwitchFrameAfterCancelledCountdownKeepsOldSessionAndRejectsSavedPhotos() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        await env.boot()
        let frames = try env.frames.listReadyFrames()
        let strip = try XCTUnwrap(frames.first { $0.name == "Dải 3 ảnh" })
        let grid = try XCTUnwrap(frames.first { $0.name == "Lưới 4 ảnh" })
        let snapshot = try env.frames.createSnapshot(frameID: strip.id)
        let first = try env.engine.beginSession(snapshot: snapshot, mode: .automatic, cameraID: nil,
                                                defaults: env.settings.sessionDefaultsSnapshot(), countdown: 3, interval: 0)
        try env.engine.startOrContinue()
        XCTAssertNoThrow(try env.selectFrameForCapture(strip.id))
        XCTAssertThrowsError(try env.selectFrameForCapture(grid.id))
        env.engine.cancelCountdown()
        XCTAssertThrowsError(try env.selectFrameForCapture("missing"))
        XCTAssertEqual(env.engine.session?.id, first.id)
        let vm = CaptureViewModel(env: env)
        vm.selectFrame(grid.id)
        XCTAssertNil(env.engine.session)
        XCTAssertEqual(vm.selectedFrameIndices, [1, 2, 3, 4])
        XCTAssertEqual(try env.sessions.getSession(id: first.id)?.status, .paused)
        XCTAssertEqual(try env.sessions.getSession(id: first.id)?.activeFrameSnapshotID, snapshot.id)

        let second = try env.engine.beginSession(snapshot: snapshot, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot(), countdown: 3, interval: 0)
        let bytes = try ExportService.encode(cg: .createBlank(), format: .jpeg, quality: 90)
        _ = try await env.safetySave.savePhoto(sessionID: second.id, captureIndex: 1, payloadData: bytes,
                                               requestID: UUID().uuidString, width: 64, height: 64,
                                               orientation: 1, codec: "jpeg", colorProfile: nil)
        XCTAssertTrue(env.engine.committedShots.isEmpty)
        XCTAssertThrowsError(try env.selectFrameForCapture(grid.id))
        XCTAssertEqual(env.engine.session?.id, second.id)
    }

    func testPauseAndRetrySaveUsesPromotedFileWithoutAnotherShot() async throws {
        let camera = FakeCameraService()
        let env = AppEnvironment(inMemory: true, camera: camera)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.engine.beginSession(snapshot: snapshot, mode: .automatic, cameraID: nil,
                                             defaults: env.settings.sessionDefaultsSnapshot(), countdown: 0, interval: 0)
        try env.db.run("""
            CREATE TRIGGER fail_photo_commit BEFORE INSERT ON photo_revisions
            BEGIN SELECT RAISE(ABORT, 'fixture fail after file promotion'); END
            """)
        try env.engine.startOrContinue()
        for _ in 0..<300 {
            if case .capturing = env.engine.state { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard case .capturing = env.engine.state else { return XCTFail("Camera giả chưa bắt đầu chụp") }
        env.engine.pause()
        env.engine.pause()
        XCTAssertTrue(env.engine.pauseRequested)
        for _ in 0..<300 {
            if case .recoverableError = env.engine.state { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard env.engine.hasPhotoToSave else { return XCTFail("Ảnh nhận từ camera phải còn để lưu lại") }
        XCTAssertFalse(env.engine.pauseRequested)
        XCTAssertTrue(env.engine.committedShots.isEmpty)
        let intent = try XCTUnwrap(env.trashRepo.pendingIntents(opType: "savePhoto").first { $0.rootID == rec.id })
        let journal = try JSONDecoder().decode(SafetySaveService.SavePhotoIntentPayload.self, from: Data(intent.payloadJSON.utf8))
        env.engine.keepSessionAndExit()
        XCTAssertEqual(env.engine.session?.id, rec.id)

        try env.db.run("DROP TRIGGER fail_photo_commit")
        await env.engine.retryPendingSave()
        XCTAssertFalse(env.engine.hasPhotoToSave)
        XCTAssertEqual(env.engine.state, .paused(reason: .user, nextIndex: 2, kind: .normal))
        let revision = try XCTUnwrap(env.engine.committedShots[1])
        XCTAssertEqual(revision.captureRequestID, journal.requestID)
        XCTAssertEqual(revision.relativePath, journal.intendedRelativePath)
        XCTAssertEqual(revision.sha256, journal.sha256)
        XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM photo_revisions"), 1)
        XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM operation_intents WHERE op_type='savePhoto'"), 1)
    }

    func testSaveRetryReusesIntentBeforePromotionAndAfterCommit() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let bytes = try ExportService.encode(cg: .createBlank(), format: .jpeg, quality: 90)
        for phase in ["files_staged", "committed"] {
            let snapshot = try env.frames.createSnapshot(frameID: frame.id)
            let rec = try env.sessions.createSession(snapshot: snapshot, mode: .manual, cameraID: nil,
                                                     defaults: env.settings.sessionDefaultsSnapshot())
            let request = UUID().uuidString
            try env.db.run("""
                CREATE TRIGGER fail_intent_update BEFORE UPDATE ON operation_intents
                WHEN NEW.status = '\(phase)'
                BEGIN SELECT RAISE(ABORT, 'fixture failed intent update'); END
                """)
            do {
                _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1,
                    payloadData: bytes, requestID: request, width: 64, height: 64,
                    orientation: 1, codec: "jpeg", colorProfile: nil)
                XCTFail("Phải kích hoạt lỗi ở \(phase)")
            } catch {}
            try env.db.run("DROP TRIGGER fail_intent_update")
            let intent = try XCTUnwrap(env.trashRepo.pendingIntents(opType: "savePhoto").first { $0.rootID == rec.id })
            let journal = try JSONDecoder().decode(SafetySaveService.SavePhotoIntentPayload.self, from: Data(intent.payloadJSON.utf8))
            let saved = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1,
                payloadData: bytes, requestID: request, width: 64, height: 64,
                orientation: 1, codec: "jpeg", colorProfile: nil)
            XCTAssertEqual(saved.relativePath, journal.intendedRelativePath)
            let actualSHA = Hashing.sha256Hex(fileURL: try env.sessions.fileURL(for: saved))
            XCTAssertEqual(actualSHA, journal.sha256)
            XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM operation_intents WHERE root_id=?", [.text(rec.id)]), 1)
            XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM photo_revisions WHERE capture_request_id=?", [.text(request)]), 1)
        }
    }

    func testMirrorDefaultChangesOnlyNewSessionsAndLeavesOriginalBytes() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Một ảnh lớn" })
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 64, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 64))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 40, y: 0, width: 40, height: 64))
        let bytes = try ExportService.encode(cg: XCTUnwrap(context.makeImage()), format: .jpeg, quality: 100)
        var sessions: [String] = []
        for flipped in [false, true] {
            env.settings.outputMirror = flipped
            let snapshot = try env.frames.createSnapshot(frameID: frame.id)
            let rec = try env.sessions.createSession(snapshot: snapshot, mode: .manual, cameraID: nil,
                                                     defaults: env.settings.sessionDefaultsSnapshot())
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1,
                payloadData: bytes, requestID: UUID().uuidString, width: 80, height: 64,
                orientation: 1, codec: "jpeg", colorProfile: nil)
            sessions.append(rec.id)
        }
        env.settings.previewMirror = false
        env.settings.outputMirror = false
        for (index, id) in sessions.enumerated() {
            let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
            XCTAssertEqual(detail.session.defaults.outputMirror, index == 1)
            let revision = try XCTUnwrap(detail.currentRevisions()[1])
            XCTAssertEqual(try Data(contentsOf: env.sessions.fileURL(for: revision)), bytes)
            let strict = try await env.renderBuilder.buildModelStrict(detail: detail, targetWidth: 80, targetHeight: 64)
            let preview = await env.renderBuilder.buildModel(detail: detail, targetWidth: 80, targetHeight: 64)
            for model in [strict, preview] {
                let image = try XCTUnwrap(model.sources[1]?.image)
                let sample = try XCTUnwrap(CGContext(data: nil, width: 80, height: 64, bitsPerComponent: 8,
                    bytesPerRow: 320, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                sample.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 64))
                let pixel = try XCTUnwrap(sample.data).assumingMemoryBound(to: UInt8.self) + (32 * 320 + 20 * 4)
                XCTAssertEqual(pixel[0] > pixel[2], index == 0)
            }
        }
    }

    func testBuiltinTitleUpgradeKeepsPreviousSnapshotAndCanRetry() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frames = try env.frames.listReadyFrames()
        let strip = try XCTUnwrap(frames.first { $0.name == "Dải 3 ảnh" })
        let grid = try XCTUnwrap(frames.first { $0.name == "Lưới 4 ảnh" })
        let stripRevisionID = try XCTUnwrap(strip.currentRevisionID)
        let gridRevisionID = try XCTUnwrap(grid.currentRevisionID)
        let legacyPNG = FrameSeeder.renderBackground(width: 1200, height: 1800)
        let legacy = try env.assets.store(data: legacyPNG, mediaType: "image/png", purpose: "foreground",
                                          ownerType: "frame_revision", ownerID: stripRevisionID)
        try env.db.run("UPDATE frame_revisions SET foreground_asset_id=? WHERE id=?", [.text(legacy.id), .text(stripRevisionID)])
        try env.frames.setFavorite(id: strip.id, true)
        let oldSnapshot = try env.frames.createSnapshot(frameID: strip.id)
        let old = try env.sessions.createSession(snapshot: oldSnapshot, mode: .manual, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        try env.db.run("UPDATE app_state SET value='2' WHERE key='seedVersion'")
        try env.db.run("""
            CREATE TRIGGER fail_title_revision BEFORE UPDATE OF current_revision_id ON frames
            BEGIN SELECT RAISE(ABORT, 'fixture fail before pointer swap'); END
            """)
        XCTAssertThrowsError(try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames,
                                                          presetRepo: env.presets, assets: env.assets))
        XCTAssertEqual(try env.frames.getFrame(id: strip.id)?.currentRevisionID, stripRevisionID)
        try env.db.run("DROP TRIGGER fail_title_revision")
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        let newStrip = try XCTUnwrap(env.frames.getFrame(id: strip.id))
        XCTAssertNotEqual(newStrip.currentRevisionID, stripRevisionID)
        XCTAssertTrue(newStrip.isFavorite)
        XCTAssertEqual(try env.frames.getFrame(id: grid.id)?.currentRevisionID, gridRevisionID)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: old.id)?.snapshot, oldSnapshot)
        XCTAssertEqual(try env.assets.loadData(assetID: legacy.id), legacyPNG)
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        XCTAssertEqual(try env.frames.getFrame(id: strip.id)?.currentRevisionID, newStrip.currentRevisionID)
    }
}

extension CapturePhotoSelectionTests {
    func testCaptureFirstKeepsAllOriginalsAcrossApplyExportAndReapply() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let session = try makeUnframedSession(env, count: 6)
        let photos = try await saveCaptureFirstPhotos(env, sessionID: session.id, count: 6)
        let unframed = try XCTUnwrap(env.sessions.verifiedCaptureDetail(sessionID: session.id))
        XCTAssertTrue(unframed.session.awaitsFrame)
        XCTAssertTrue(unframed.missingIndices.isEmpty)
        XCTAssertFalse(unframed.hasEnoughPhotos)
        XCTAssertEqual(try env.sessions.listSessions().first?.committedCount, 6)
        XCTAssertThrowsError(try env.renderBuilder.verifyCompletion(unframed))

        let readyFrames = try env.frames.listReadyFrames()
        let grid = try XCTUnwrap(readyFrames.first { $0.name == "Lưới 4 ảnh" })
        let six = try XCTUnwrap(readyFrames.first { $0.name == "Lưới 6 ảnh" })
        let nine = try XCTUnwrap(readyFrames.first { $0.name == "Lưới 9 ảnh" })
        let order = [6, 2, 4, 1]
        let photoIDs = order.map { photos[$0 - 1].id }
        XCTAssertThrowsError(try applyCaptureFirstFrame(env, detail: unframed, frame: nine,
                                                        photoIDs: photos.map(\.id)))
        try env.db.run("""
            CREATE TRIGGER cancel_mapping BEFORE INSERT ON slot_placements
            BEGIN SELECT RAISE(ABORT, 'QA interrupted placement'); END
            """)
        XCTAssertThrowsError(try applyCaptureFirstFrame(env, detail: unframed, frame: grid, photoIDs: photoIDs))
        XCTAssertEqual(try env.sessions.getDetail(sessionID: session.id), unframed)
        try env.db.run("DROP TRIGGER cancel_mapping")

        try applyCaptureFirstFrame(env, detail: unframed, frame: grid, photoIDs: photoIDs)
        let framed = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertEqual(framed.session.defaults.selectedCaptureOrder, order)
        XCTAssertEqual(framed.session.defaults.plannedCaptureCount, 6)
        XCTAssertEqual(framed.session.defaults.appliedFrameName, grid.name)
        XCTAssertEqual(framed.snapshot.slots.sorted { $0.zOrder < $1.zOrder }.map(\.captureIndex), order)
        XCTAssertEqual(framed.originalChecksums, unframed.originalChecksums)
        try applyCaptureFirstFrame(env, detail: unframed, frame: grid, photoIDs: photoIDs)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: session.id)?.snapshot.id, framed.snapshot.id)
        XCTAssertEqual(try env.sessions.listSessions().first?.totalCapturedCount, 6)

        let request = ExportService.ExportRequest(sessionID: session.id, format: .png, quality: 95,
            width: 400, height: 400, filenameBase: "capture-first", destinationFolder: env.layout.rootURL)
        let (_, url) = try await env.exportService.export(detail: framed, request: request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try env.sessions.listExportRecords(sessionID: session.id).count, 1)

        try applyCaptureFirstFrame(env, detail: framed, frame: six, photoIDs: photos.map(\.id))
        let changed = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertEqual(changed.snapshot.requiredCaptureCount, 6)
        XCTAssertEqual(changed.currentRevisions().count, 6)
        XCTAssertEqual(changed.originalChecksums, unframed.originalChecksums)
        for photo in photos {
            XCTAssertEqual(Hashing.sha256Hex(fileURL: try env.sessions.fileURL(for: photo)), photo.sha256)
        }
        let repair = try env.sessions.repairLegacyFrameAssignments(using: env.frames)
        XCTAssertEqual(repair.updated, 0)
        XCTAssertTrue(repair.unresolved.isEmpty)
    }

    func testCaptureFirstCompletionValidatesSelectedBytesAndIgnoresMissingReserve() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let session = try makeUnframedSession(env, count: 2)
        let photos = try await saveCaptureFirstPhotos(env, sessionID: session.id, count: 2)
        let before = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Một ảnh lớn" })
        try applyCaptureFirstFrame(env, detail: before, frame: frame, photoIDs: [photos[0].id])
        let framed = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        let primary = try env.sessions.fileURL(for: photos[0])
        let reserve = try env.sessions.fileURL(for: photos[1])
        let original = try Data(contentsOf: primary)
        let substitute = try ExportService.encode(cg: alphaFixture(size: 64, openings: []), format: .jpeg, quality: 85)
        XCTAssertNotNil(ImageNormalizer.uprightImage(data: substitute))
        XCTAssertNotEqual(Hashing.sha256Hex(substitute), photos[0].sha256)

        for corrupt in [nil, Data([0]), substitute] {
            if let corrupt { try corrupt.write(to: primary) }
            else { try FileManager.default.removeItem(at: primary) }
            do {
                _ = try await env.completeSession(sessionID: session.id)
                XCTFail("Hoàn thành phiên khi tệp nguồn không hợp lệ")
            } catch {
                XCTAssertEqual(try env.sessions.getSession(id: session.id), framed.session)
                XCTAssertTrue(try env.sessions.listExportRecords(sessionID: session.id).isEmpty)
            }
        }
        try original.write(to: primary)
        try FileManager.default.removeItem(at: reserve)
        XCTAssertEqual(try env.sessions.verifiedCaptureDetail(sessionID: session.id)?.missingIndices, [])
        let completed = try await env.completeSession(sessionID: session.id)
        XCTAssertTrue(completed)
    }

    func testCaptureFirstRecoveryValidatesBothCommittedAndUncommittedFiles() async throws {
        for scenario in ["partial", "promoted", "committed", "changedBytes"] {
            let env = AppEnvironment(inMemory: true)
            let session = try makeUnframedSession(env, count: 1)
            let image = CGImage.createBlank()
            let data = try ExportService.encode(cg: image, format: .jpeg, quality: 93)
            let id = UUID().uuidString
            let path = "Sessions/\(session.id)/Originals/fixture.jpg"
            let payload = SafetySaveService.SavePhotoIntentPayload(sessionID: session.id, captureIndex: 1,
                requestID: id, intendedRelativePath: path, tempRelativePath: path + ".partial", sha256: Hashing.sha256Hex(data))
            let intent = try env.trashRepo.createIntent(opType: "savePhoto", rootID: session.id,
                payloadJSON: String(decoding: JSONEncoder().encode(payload), as: UTF8.self))
            let file = try env.layout.absoluteURL(forRelativePath: scenario == "partial" ? path + ".partial" : path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            if scenario == "committed" || scenario == "changedBytes" {
                _ = try env.sessions.commitPhoto(sessionID: session.id, captureIndex: 1, requestID: id,
                    relativePath: path, sha256: payload.sha256, width: image.width, height: image.height,
                    orientation: 1, codec: "jpeg", colorProfile: nil)
            }
            if scenario == "changedBytes" {
                let other = try ExportService.encode(cg: alphaFixture(size: 64, openings: []), format: .jpeg, quality: 90)
                try other.write(to: file)
            }
            let recovery = RecoveryService(db: env.db, layout: env.layout, sessions: env.sessions,
                                           trashRepo: env.trashRepo, trashService: env.trashService)
            _ = await recovery.runOnLaunch()
            _ = await recovery.runOnLaunch()
            let usable = scenario == "promoted" || scenario == "committed"
            let detail = try XCTUnwrap(env.sessions.verifiedCaptureDetail(sessionID: session.id))
            XCTAssertEqual(detail.committedCount, usable ? 1 : 0, scenario)
            XCTAssertEqual(try env.trashRepo.getIntent(id: intent.id)?.status, usable ? .committed : .failed, scenario)
            XCTAssertEqual(detail.photoRevisions.values.flatMap { $0 }.count,
                           scenario == "partial" ? 0 : 1, scenario)
        }
    }

    func testPNGOpeningsUseOriginalPixelsAndDeterministicRowOrder() throws {
        let grid = [
            CGRect(x: 100, y: 100, width: 350, height: 350),
            CGRect(x: 550, y: 100, width: 350, height: 350),
            CGRect(x: 100, y: 550, width: 350, height: 350),
            CGRect(x: 550, y: 550, width: 350, height: 350),
        ]
        let detected = PNGAutoAlignmentService.detectOpenings(try alphaFixture(size: 1000, openings: grid))
        XCTAssertTrue(detected.isAutoAligned)
        XCTAssertEqual(detected.slots, grid.map {
            SlotRect(x: $0.minX / 1000, y: $0.minY / 1000, width: $0.width / 1000, height: $0.height / 1000)
        })
        let opening = CGRect(x: 300, y: 500, width: 900, height: 800)
        let closed = PNGAutoAlignmentService.detectOpenings(try alphaFixture(size: 2048, openings: [opening]))
        XCTAssertEqual(closed.slots.count, 1)
        let gap = CGRect(x: 0, y: 729, width: 301, height: 1)
        let open = PNGAutoAlignmentService.detectOpenings(try alphaFixture(size: 2048, openings: [opening, gap]))
        XCTAssertTrue(open.requiresInspection)
        XCTAssertTrue(open.slots.isEmpty)
    }

    func testPNGOpeningsIncludeTheTranslucentBorderAndIgnoreSeparateOutside() throws {
        let frame = CGRect(x: 40, y: 40, width: 920, height: 920)
        let windows = [
            CGRect(x: 140, y: 200, width: 280, height: 380),
            CGRect(x: 560, y: 200, width: 280, height: 380),
        ]
        let decoration = CGRect(x: 460, y: 690, width: 40, height: 40)
        let result = PNGAutoAlignmentService.detectOpenings(
            try alphaFixture(size: 1000, openings: windows + [decoration], frame: frame, border: 7))
        XCTAssertTrue(result.isAutoAligned)
        XCTAssertEqual(result.slots, windows.map {
            let expanded = $0.insetBy(dx: -7, dy: -7)
            return SlotRect(x: expanded.minX / 1000, y: expanded.minY / 1000,
                            width: expanded.width / 1000, height: expanded.height / 1000)
        })
    }

    func testPNGAdaptiveOpeningsPreserveGeometryForOneThroughTwelveSlots() throws {
        let size = 512
        for count in 1...12 {
            let boxes = adaptiveGrid(count: count)
            let expected = boxes.map { normalized($0, size: size) }
            for background in [255, 250] {
                let windows = boxes.enumerated().map {
                    ($0.element, background == 255 ? 0 : [12, 55, 120][$0.offset % 3])
                }
                let image = try adaptiveFixture(size: size, background: background, regions: windows)
                let result = PNGAutoAlignmentService.detectOpenings(image)
                XCTAssertEqual(result.pngStatus, .ready, "\(count) slots, alpha \(background): \(result.inspectionReason ?? "")")
                XCTAssertEqual(result.slots, expected, "\(count) slots, alpha \(background)")
            }
        }
    }

    func testPNGAdaptiveOpeningsTreatNestedCoresAsTheSameWindows() throws {
        let size = 512
        let boxes = adaptiveGrid(count: 4)
        let walls = boxes.map { ($0, 120) }
        let cores = boxes.map { ($0.insetBy(dx: 12, dy: 9), 16) }
        let image = try adaptiveFixture(size: size, background: 250, regions: walls + cores)
        let result = PNGAutoAlignmentService.detectOpenings(image)
        XCTAssertEqual(result.pngStatus, .ready)
        XCTAssertEqual(result.slots, boxes.map { normalized($0, size: size) })
    }

    func testPNGAdaptiveOpeningsAskForReviewWhenAFourthSlotAppearsLate() throws {
        let size = 512
        let boxes = adaptiveGrid(count: 4)
        let connector = CGRect(x: boxes[3].maxX, y: floor(boxes[3].midY), width: CGFloat(size) - boxes[3].maxX, height: 1)
        let regions = boxes.enumerated().map { ($0.element, $0.offset == 3 ? 235 : 12) } + [(connector, 242)]
        let image = try adaptiveFixture(size: size, background: 250, regions: regions)
        let result = PNGAutoAlignmentService.detectOpenings(image)
        XCTAssertEqual(result.pngStatus, .review)
        XCTAssertEqual(result.slots, boxes.map { normalized($0, size: size) })
    }

    func testPNGAdaptiveOpeningsAskForReviewWhenStableLayoutsMerge() throws {
        let boxes = [CGRect(x: 60, y: 90, width: 150, height: 200),
                     CGRect(x: 235, y: 90, width: 150, height: 200)]
        let bridge = CGRect(x: 210, y: 170, width: 25, height: 20)
        let image = try adaptiveFixture(size: 512, background: 250,
                                        regions: boxes.map { ($0, 0) } + [(bridge, 128)])
        let result = PNGAutoAlignmentService.detectOpenings(image)
        XCTAssertEqual(result.pngStatus, .review)
        XCTAssertNotNil(result.inspectionReason)
    }

    func testPNGAdaptiveOpeningsDoNotHideAnOpenSlotWhenClosedSlotsExist() throws {
        let size = 512
        let boxes = adaptiveGrid(count: 4)
        let gap = CGRect(x: 0, y: floor(boxes[0].midY), width: boxes[0].minX, height: 1)
        for gapAlpha in [0, 120] {
            let windows = boxes.enumerated().map { ($0.element, $0.offset == 0 ? gapAlpha : 0) }
            let image = try adaptiveFixture(size: size, background: 255, regions: windows + [(gap, gapAlpha)])
            let result = PNGAutoAlignmentService.detectOpenings(image)
            XCTAssertEqual(result.pngStatus, .review)
            XCTAssertEqual(result.slots, boxes.dropFirst().map { normalized($0, size: size) })
            XCTAssertEqual(result.inspectionReason, "Có thể có ô ảnh thông ra mép khung")
        }
    }

    func testPNGAdaptiveOpeningsKeepManualRoutesForTooManyOpaqueAndBlankFrames() throws {
        let overflow = try adaptiveFixture(size: 512, background: 250, regions: adaptiveGrid(count: 13).map { ($0, 32) })
        let result = PNGAutoAlignmentService.detectOpenings(overflow)
        XCTAssertEqual(result.pngStatus, .tooManyRegions)
        XCTAssertTrue(result.slots.isEmpty)
        let opaque = try adaptiveFixture(size: 512, background: 255, regions: [])
        XCTAssertEqual(PNGAutoAlignmentService.detectOpenings(opaque).pngStatus, .opaque)
        let transparent = try adaptiveFixture(size: 512, background: 0, regions: [])
        XCTAssertEqual(PNGAutoAlignmentService.detectOpenings(transparent).pngStatus, .undetermined)
    }

    private func adaptiveGrid(count: Int) -> [CGRect] {
        (0..<count).map { index in
            let (row, column) = index.quotientAndRemainder(dividingBy: 4)
            return CGRect(x: 22 + column * 120, y: 24 + row * 120 - column % 2,
                          width: [96, 78, 48][index % 3], height: [91, 72, 45][index % 3])
        }
    }

    private func normalized(_ box: CGRect, size: Int) -> SlotRect {
        SlotRect(x: box.minX / CGFloat(size), y: box.minY / CGFloat(size),
                 width: box.width / CGFloat(size), height: box.height / CGFloat(size))
    }

    private func adaptiveFixture(size: Int, background: Int, regions: [(CGRect, Int)]) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        context.setBlendMode(.copy)
        context.setFillColor(red: 0.7, green: 0.4, blue: 0.1, alpha: CGFloat(background) / 255)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for (box, alpha) in regions {
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: CGFloat(alpha) / 255)
            context.fill(box)
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testCaptureFirstReopensAtMissingMiddleShotWithTwelveShotLimit() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        XCTAssertThrowsError(try makeUnframedSession(env, count: 0))
        XCTAssertThrowsError(try makeUnframedSession(env, count: 13))
        let session = try makeUnframedSession(env, count: 12)
        let photos = try await saveCaptureFirstPhotos(env, sessionID: session.id, count: 3)
        try FileManager.default.removeItem(at: env.sessions.fileURL(for: photos[1]))
        let detail = try XCTUnwrap(env.sessions.verifiedCaptureDetail(sessionID: session.id))
        XCTAssertEqual(detail.shots.count, 12)
        XCTAssertEqual(detail.committedCount, 2)
        XCTAssertEqual(detail.nextPendingIndex, 2)
        XCTAssertTrue(env.engine.adoptSession(record: detail.session, snapshot: detail.snapshot,
                                              committed: detail.currentRevisions()))
        XCTAssertEqual(env.engine.committedShots.keys.sorted(), [1, 3])
        XCTAssertEqual(env.engine.nextPendingIndex, 2)
        XCTAssertEqual(env.engine.session?.captureCount, 12)
    }

    func testImportedPNGCanBeAppliedAndExportsExpectedAlpha() async throws {
        let env = AppEnvironment(inMemory: true)
        let session = try makeUnframedSession(env, count: 1)
        let photos = try await saveCaptureFirstPhotos(env, sessionID: session.id, count: 1)
        let photo = try XCTUnwrap(photos.first)
        let opening = CGRect(x: 150, y: 140, width: 212, height: 232)
        let image = try alphaFixture(size: 512, openings: [opening],
                                     frame: CGRect(x: 30, y: 30, width: 452, height: 452), border: 5)
        let bytes = try ExportService.encode(cg: image, format: .png, quality: 100)
        let decoded = try AssetStore.validatedFrameImage(bytes, minimumDimension: ResourceLimits.canvasMin).image
        let slots = PNGAutoAlignmentService.detectOpenings(decoded).slots.enumerated().map { index, rect in
            FrameSlot(captureIndex: index + 1, x: rect.x, y: rect.y, width: rect.width,
                      height: rect.height, zOrder: index, maskType: .rectangle,
                      cornerRadius: 0, defaultCropMode: .autoFace)
        }
        XCTAssertEqual(slots.count, 1)
        let frame = try env.frames.createConfiguredFrame(name: "PNG QA", imageData: bytes, mediaType: "image/png",
                                                        role: .frameForeground, categoryID: nil, slots: slots)
        XCTAssertEqual(frame.validationStatus, .ready)
        let before = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        try applyCaptureFirstFrame(env, detail: before, frame: frame, photoIDs: [photo.id])
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        for format in [ExportImageFormat.png, .jpeg] {
            let request = ExportService.ExportRequest(sessionID: session.id, format: format, quality: 100,
                width: 512, height: 512, filenameBase: "imported-alpha", destinationFolder: env.layout.rootURL)
            let (_, url) = try await env.exportService.export(detail: detail, request: request)
            let output = try XCTUnwrap(CGImage.createFrom(data: Data(contentsOf: url)))
            let corner = try rgbaPixel(output, x: 3, y: 3)
            XCTAssertEqual(corner[3], format == .png ? 0 : 255)
            if format == .jpeg { XCTAssertTrue(corner.prefix(3).allSatisfy { $0 >= 248 }) }
            XCTAssertEqual(try rgbaPixel(output, x: 256, y: 256)[3], 255)
        }
        var white = detail
        white.snapshot.explicitWhite = true
        let model = try await env.renderBuilder.buildModelStrict(detail: white, targetWidth: 512, targetHeight: 512,
                                                                  transparentBackground: true)
        XCTAssertEqual(try rgbaPixel(CompositeRenderer.render(model: model), x: 3, y: 3)[3], 255)
    }

    func testChooserRendersOnlySelectedAndIncludesPreviouslyUnassignedPhoto() async throws {
        let env = AppEnvironment(inMemory: true)
        let session = try makeUnframedSession(env, count: 4)
        let photos = try await saveCaptureFirstPhotos(env, sessionID: session.id, count: 4)
        let initial = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        let slots = (0..<3).map { n in
            FrameSlot(captureIndex: n + 1, x: 0.1 + Double(n) * 0.3, y: 0.25,
                      width: 0.2, height: 0.5, zOrder: n, defaultCropMode: .fill)
        }
        let frame = try env.frames.createConfiguredFrame(
            name: "Preview QA", imageData: clarityFixture(alpha: 0), mediaType: "image/png",
            role: .frameForeground, categoryID: nil, slots: slots)
        try applyCaptureFirstFrame(env, detail: initial, frame: frame, photoIDs: photos.prefix(3).map(\.id))
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        let snapshot = try env.frames.createSnapshot(frameID: frame.id, persist: false)
        XCTAssertNil(detail.currentRevisions()[4])
        XCTAssertThrowsError(try snapshot.assigningPhotos(in: [4]))
        let image = try await env.renderBuilder.renderChooserPreview(detail: detail, snapshot: snapshot,
                                                                     order: [4], width: 512, height: 512)
        XCTAssertEqual(try rgbaPixel(image, x: 102, y: 256)[3], 255)
        XCTAssertEqual(try rgbaPixel(image, x: 256, y: 256)[3], 0)
        XCTAssertEqual(try rgbaPixel(image, x: 410, y: 256)[3], 0)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: session.id), detail)

        let order = [4, 2, 1]
        try applyCaptureFirstFrame(env, detail: detail, frame: frame, photoIDs: order.map { photos[$0 - 1].id })
        let previewDefault = try await env.renderBuilder.renderChooserPreview(detail: detail, snapshot: snapshot,
                                                                               order: order, width: 512, height: 512)
        let snapshotSlot = try XCTUnwrap(snapshot.slots.first)
        try env.sessions.setPlacement(sessionID: session.id, snapshotSlotID: snapshotSlot.id,
                                      placement: PhotoPlacement(scale: 0.75, offsetX: 0.1),
                                      cropMode: .fit, manualOverride: true)
        let updated = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        let previewCropped = try await env.renderBuilder.renderChooserPreview(detail: updated, snapshot: snapshot,
                                                                               order: order, width: 512, height: 512)
        let strict = try await env.renderBuilder.buildModelStrict(detail: updated, targetWidth: 512, targetHeight: 512,
                                                                  transparentBackground: true)
        XCTAssertEqual(previewCropped.dataProvider?.data as Data?,
                       try CompositeRenderer.render(model: strict).dataProvider?.data as Data?)
        XCTAssertNotEqual(previewCropped.dataProvider?.data as Data?, previewDefault.dataProvider?.data as Data?)
        let changedOrder = [2, 4, 1]
        let changed = try await env.renderBuilder.renderChooserPreview(detail: updated, snapshot: snapshot,
                                                                      order: changedOrder, width: 512, height: 512)
        // The fixture photos are identical, so swapping uncropped sources produces the original pixels.
        XCTAssertEqual(changed.dataProvider?.data as Data?, previewDefault.dataProvider?.data as Data?)

        try FileManager.default.removeItem(at: env.sessions.fileURL(for: photos[3]))
        do {
            _ = try await env.renderBuilder.renderChooserPreview(detail: detail, snapshot: snapshot,
                                                                  order: [4], width: 512, height: 512)
            XCTFail("Missing selected photo must fail preview")
        } catch let error as AppError {
            guard case .ioFailure = error else { return XCTFail(error.message) }
        }
    }

    func testClarityCopyPreservesPixelsAndFrameLinksAcrossRetry() async throws {
        let env = AppEnvironment(inMemory: true)
        let slot = FrameSlot(captureIndex: 1, x: 0.1, y: 0.25, width: 0.8, height: 0.5, zOrder: 0)
        let original = try clarityFixture(alpha: 112, decoration: true)
        let frame = try env.frames.createConfiguredFrame(name: "Haze", imageData: original, mediaType: "image/png",
                                                        role: .frameForeground, categoryID: nil, slots: [slot])
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)
        let sourceID = try XCTUnwrap(snapshot.foreground?.assetID)
        let revisionID = try XCTUnwrap(frame.currentRevisionID)
        let oldSession = try makeUnframedSession(env, count: 1)
        let oldPhoto = try await saveCaptureFirstPhotos(env, sessionID: oldSession.id, count: 1).first
        let oldUnframed = try XCTUnwrap(env.sessions.getDetail(sessionID: oldSession.id))
        try applyCaptureFirstFrame(env, detail: oldUnframed, frame: frame, photoIDs: [XCTUnwrap(oldPhoto).id])
        let oldDetail = try XCTUnwrap(env.sessions.getDetail(sessionID: oldSession.id))
        let persistentCounts = try env.db.query("""
            SELECT (SELECT COUNT(*) FROM frames) AS frames,
                   (SELECT COUNT(*) FROM frame_revisions) AS revisions,
                   (SELECT COUNT(*) FROM asset_references) AS refs
            """)
        let prepared = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
        XCTAssertEqual(try env.db.query("""
            SELECT (SELECT COUNT(*) FROM frames) AS frames,
                   (SELECT COUNT(*) FROM frame_revisions) AS revisions,
                   (SELECT COUNT(*) FROM asset_references) AS refs
            """), persistentCounts, "Preparing or cancelling a preview must not persist a copy")
        XCTAssertEqual(prepared.slots.map(\.status), [.cleared])
        XCTAssertTrue(prepared.canSave)
        XCTAssertEqual(try PNGSlotClarity.prepare(data: prepared.data, snapshot: snapshot).slots.map(\.status), [.alreadyClear])
        let before = try XCTUnwrap(CGImage.createFrom(data: original))
        let after = try XCTUnwrap(CGImage.createFrom(data: prepared.data))
        XCTAssertEqual(try rgbaPixel(after, x: 256, y: 256)[3], 0)
        XCTAssertEqual(try rgbaPixel(after, x: 85, y: 176), try rgbaPixel(before, x: 85, y: 176))
        let copyID = IDFactory.new()
        try env.db.run("""
            CREATE TRIGGER fail_clarity BEFORE INSERT ON frame_revisions
            BEGIN SELECT RAISE(ABORT, 'Interrupted clarity copy'); END
            """)
        XCTAssertThrowsError(try env.frames.saveClearSlotCopy(sourceID: frame.id, revisionID: revisionID,
                                                               copyID: copyID, png: prepared.data))
        XCTAssertNil(try env.frames.getFrame(id: copyID))
        XCTAssertEqual(try env.db.query("""
            SELECT (SELECT COUNT(*) FROM frames) AS frames,
                   (SELECT COUNT(*) FROM frame_revisions) AS revisions,
                   (SELECT COUNT(*) FROM asset_references) AS refs
            """), persistentCounts)
        XCTAssertTrue(try env.db.query("SELECT 1 FROM asset_references WHERE owner_id=?",
                                       [.text("draft-\(copyID)")]).isEmpty)
        try env.db.run("DROP TRIGGER fail_clarity")
        let saved = try env.frames.saveClearSlotCopy(sourceID: frame.id, revisionID: revisionID,
                                                      copyID: copyID, png: prepared.data)
        let retry = try env.frames.saveClearSlotCopy(sourceID: frame.id, revisionID: revisionID,
                                                      copyID: copyID, png: prepared.data)
        XCTAssertEqual(saved, retry)
        XCTAssertEqual(try env.frames.getFrame(id: frame.id)?.currentRevisionID, revisionID)
        XCTAssertEqual(try env.assets.loadData(assetID: sourceID), original)
        let copy = try env.frames.createSnapshot(frameID: saved.id)
        XCTAssertNotEqual(copy.sourceFrameID, snapshot.sourceFrameID)
        XCTAssertNotEqual(copy.sourceFrameRevisionID, snapshot.sourceFrameRevisionID)
        XCTAssertNotEqual(copy.foreground?.assetID, snapshot.foreground?.assetID)
        XCTAssertEqual(copy.canvasWidth, snapshot.canvasWidth)
        XCTAssertEqual(copy.canvasHeight, snapshot.canvasHeight)
        XCTAssertEqual(copy.background, snapshot.background)
        XCTAssertEqual(copy.backgroundColorHex, snapshot.backgroundColorHex)
        XCTAssertEqual(copy.geometryVersion, snapshot.geometryVersion)
        var copiedSlots = copy.slots
        XCTAssertEqual(copiedSlots.count, snapshot.slots.count)
        for index in copiedSlots.indices { copiedSlots[index].id = snapshot.slots[index].id }
        XCTAssertEqual(copiedSlots, snapshot.slots)
        XCTAssertEqual(try env.assets.loadData(assetID: XCTUnwrap(copy.foreground?.assetID)), prepared.data)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: oldSession.id), oldDetail)

        let freshSession = try makeUnframedSession(env, count: 1)
        let freshPhoto = try await saveCaptureFirstPhotos(env, sessionID: freshSession.id, count: 1).first
        let freshUnframed = try XCTUnwrap(env.sessions.getDetail(sessionID: freshSession.id))
        let preview = try await env.renderBuilder.renderChooserPreview(detail: freshUnframed, snapshot: copy,
                                                                       order: [1], width: 512, height: 512)
        try applyCaptureFirstFrame(env, detail: freshUnframed, frame: saved, photoIDs: [XCTUnwrap(freshPhoto).id])
        let freshDetail = try XCTUnwrap(env.sessions.getDetail(sessionID: freshSession.id))
        let request = ExportService.ExportRequest(sessionID: freshSession.id, format: .png, quality: 100,
                                                  width: 512, height: 512, filenameBase: "clarity-preview",
                                                  destinationFolder: env.layout.rootURL)
        let (_, url) = try await env.exportService.export(detail: freshDetail, request: request)
        let exported = try XCTUnwrap(CGImage.createFrom(data: Data(contentsOf: url)))
        for (x, y) in [(256, 256), (85, 176), (16, 16)] {
            XCTAssertEqual(try rgbaPixel(preview, x: x, y: y), try rgbaPixel(exported, x: x, y: y))
        }
        let pack = try env.packService.buildPack(name: "Clarity QA", frameIDs: [saved.id])
        let validated = try FramePackService.validate(data: pack)
        XCTAssertEqual(validated.manifest.frames.first?.assets.foreground, "sha256:\(Hashing.sha256Hex(prepared.data))")
        let restore = AppEnvironment(inMemory: true)
        let choice = FramePackService.ImportChoice(packFrameID: saved.id, policy: .copy, selected: true)
        let imported = try restore.packService.applyImportDetailed(result: validated, choices: [choice], data: pack)
        guard case .imported(let importedID) = imported[saved.id] else { return XCTFail("Pack import failed") }
        let restored = try restore.frames.createSnapshot(frameID: importedID, persist: false)
        XCTAssertEqual(restored.slots.first?.rect, copy.slots.first?.rect)
        XCTAssertEqual(try restore.assets.loadData(assetID: XCTUnwrap(restored.foreground?.assetID)), prepared.data)

        let sourceRevision = try XCTUnwrap(env.frames.getRevision(id: revisionID))
        _ = try env.frames.commitRevision(frameID: frame.id, draft: sourceRevision, slots: [slot])
        let staleCopyID = IDFactory.new()
        XCTAssertThrowsError(try env.frames.saveClearSlotCopy(sourceID: frame.id, revisionID: revisionID,
                                                               copyID: staleCopyID, png: prepared.data))
        XCTAssertNil(try env.frames.getFrame(id: staleCopyID))
        XCTAssertEqual(try env.assets.loadData(assetID: sourceID), original)
    }

    func testClarityChecksEverySlotAndRevisitsNarrowEdge() throws {
        let slots = [
            FrameSlot(captureIndex: 1, x: 0, y: 0.125, width: 0.25, height: 0.75, zOrder: 0),
            FrameSlot(captureIndex: 2, x: 0.25, y: 0.125, width: 0.25, height: 0.75, zOrder: 1),
            FrameSlot(captureIndex: 3, x: 0.5, y: 0.125, width: 0.25, height: 0.75, zOrder: 2),
            FrameSlot(captureIndex: 4, x: 0.75, y: 0.125, width: 0.25, height: 0.75, zOrder: 3)
        ]
        let snapshot = claritySnapshot(slots)
        let original = try clarityFixture(alpha: 0) { x, y in
            guard (64..<448).contains(y) else { return (20, 40, 60, 0) }
            switch x {
            case 145..<168: return (250, 251, 252, 115) // 18% of slot 2
            case 260..<261 where (110..<402).contains(y): return (250, 251, 252, 115) // d=3.5% in slot 3
            case 396..<500 where (100..<412).contains(y): return (220, 20, 90, 115)
            default: return (20, 40, 60, 0)
            }
        }
        let automatic = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
        XCTAssertEqual(automatic.slots.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(automatic.slots.map(\.status), [.alreadyClear, .needsReview, .needsReview, .needsReview])
        XCTAssertFalse(automatic.canSave)
        let overlay = try XCTUnwrap(CGImage.createFrom(data: automatic.data))
        XCTAssertEqual(try rgbaPixel(overlay, x: 154, y: 256)[3], 115)
        XCTAssertEqual(try rgbaPixel(overlay, x: 260, y: 256)[3], 115)
        let clears = automatic.slots[1...2].flatMap { slot in
            slot.issues.map { PNGSlotClarity.Edit(slotID: slot.id, bounds: $0.bounds, action: .clear, pixels: $0.pixels) }
        }
        let fourth = try XCTUnwrap(automatic.slots.last)
        let proposedArea = try XCTUnwrap(fourth.issues.first?.bounds)
        let keep = PNGSlotClarity.Edit(slotID: fourth.id, bounds: proposedArea, action: .keep)
        let approved = try PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: automatic, edits: clears + [keep])
        XCTAssertEqual(approved.slots.map(\.status), [.alreadyClear, .cleared, .cleared, .detailKept])
        XCTAssertTrue(approved.canSave)
        let cleaned = try XCTUnwrap(CGImage.createFrom(data: approved.data))
        XCTAssertLessThanOrEqual(try rgbaPixel(cleaned, x: 154, y: 256)[3], 8)
        XCTAssertLessThanOrEqual(try rgbaPixel(cleaned, x: 260, y: 256)[3], 8)
    }

    func testClarityUsesSlotShapeAndRechecksSharedPixelsAfterEachEdit() throws {
        let round = FrameSlot(captureIndex: 1, x: 0.08, y: 0.11, width: 0.36, height: 0.36, zOrder: 0,
                              maskType: .roundedRectangle, cornerRadius: 0.10)
        let ellipse = FrameSlot(captureIndex: 2, x: 0.54, y: 0.11, width: 0.30, height: 0.46,
                                rotationDegrees: 23, zOrder: 1, maskType: .ellipse)
        let original = try clarityFixture(alpha: 112)
        let shaped = try PNGSlotClarity.prepare(data: original, snapshot: claritySnapshot([round, ellipse]))
        XCTAssertEqual(shaped.slots.map(\.status), [.cleared, .cleared])
        let layer = try XCTUnwrap(CGImage.createFrom(data: shaped.data))
        XCTAssertEqual(try rgbaPixel(layer, x: 43, y: 58)[3], 112)
        XCTAssertEqual(try rgbaPixel(layer, x: 278, y: 59)[3], 112)
        XCTAssertEqual(try rgbaPixel(layer, x: 133, y: 148)[3], 0)
        XCTAssertEqual(try rgbaPixel(layer, x: 353, y: 174)[3], 0)

        let left = FrameSlot(captureIndex: 1, x: 0.1, y: 0.2, width: 0.5, height: 0.6, zOrder: 0)
        let right = FrameSlot(captureIndex: 2, x: 0.4, y: 0.2, width: 0.5, height: 0.6, zOrder: 1)
        let overlap = claritySnapshot([left, right])
        let automatic = try PNGSlotClarity.prepare(data: original, snapshot: overlap)
        XCTAssertEqual(automatic.slots.map(\.status), [.needsReview, .needsReview])
        let region = CGRect(x: 204, y: 101, width: 105, height: 310)
        let remove = PNGSlotClarity.Edit(slotID: left.id, bounds: region, action: .clear)
        let protect = PNGSlotClarity.Edit(slotID: right.id, bounds: region, action: .keep)
        let cleared = try PNGSlotClarity.refine(data: original, snapshot: overlap, automatic: automatic, edits: [remove])
        let kept = try PNGSlotClarity.refine(data: original, snapshot: overlap, automatic: automatic, edits: [protect, remove])
        XCTAssertEqual(cleared.slots.map(\.id), [left.id, right.id])
        XCTAssertEqual(try rgbaPixel(XCTUnwrap(CGImage.createFrom(data: cleared.data)), x: 256, y: 256)[3], 0)
        XCTAssertEqual(try rgbaPixel(XCTUnwrap(CGImage.createFrom(data: kept.data)), x: 256, y: 256)[3], 112)
        XCTAssertEqual(try PNGSlotClarity.refine(data: original, snapshot: overlap, automatic: automatic, edits: []).data,
                       automatic.data)
    }

    func testClarityDetectsWhiteFilmAtTwoToThreePercent() throws {
        let snapshot = claritySnapshot([FrameSlot(captureIndex: 1, x: 0, y: 0, width: 1, height: 1, zOrder: 0)])
        let original = try clarityFixture(alpha: 0) { x, y in
            (11..<15).contains(x) && (80..<432).contains(y) ? (250, 251, 252, 115) : (0, 0, 0, 0)
        }
        let result = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
        let image = try XCTUnwrap(CGImage.createFrom(data: result.data))
        XCTAssertTrue(try rgbaPixel(image, x: 12, y: 256)[3] < 26 || result.slots[0].status == .needsReview,
                      "A visible film at depth 2.4% must be cleared or sent for review")
    }

    func testPreviewApprovalCoversAllWarningsPerSlotWithoutChangingBytes() throws {
        let a = FrameSlot(captureIndex: 1, x: 0, y: 0, width: 0.5, height: 1, zOrder: 0)
        let b = FrameSlot(captureIndex: 2, x: 0.5, y: 0, width: 0.5, height: 1, zOrder: 1)
        let snapshot = claritySnapshot([a, b])
        let data = try clarityFixture(alpha: 0) { x, y in
            let local = x % 256
            return (local == 2 || local == 253) && (100..<400).contains(y)
                ? (250, 250, 250, 130) : (0, 0, 0, 0)
        }
        let initial = try PNGSlotClarity.prepare(data: data, snapshot: snapshot)
        let before = Hashing.sha256Hex(initial.data)
        XCTAssertEqual(initial.slots.map { $0.issues.count }, [2, 2])
        let one = initial.approving([:], slotID: a.id)
        XCTAssertEqual(initial.pending(one).map(\.id), [b.id])
        XCTAssertEqual(initial.displayedSlots(one).map(\.status), [.previewApproved, .needsReview])
        let all = initial.approving(one)
        XCTAssertTrue(initial.pending(all).isEmpty)
        XCTAssertEqual(initial.pending(one).map(\.id), [b.id], "Undo restores the previous approval value")
        XCTAssertEqual(Hashing.sha256Hex(initial.data), before)

        let edit = PNGSlotClarity.Edit(slotID: a.id, bounds: CGRect(x: 0, y: 85, width: 25, height: 330), action: .clear)
        let changed = try PNGSlotClarity.refine(data: data, snapshot: snapshot, automatic: initial, edits: [edit])
        XCTAssertEqual(Set(changed.retained(all).keys), [b.id])
        XCTAssertEqual(changed.pending(all).map(\.id), [a.id])
        var reordered = snapshot
        reordered.slots.swapAt(0, 1)
        reordered.slots[0].zOrder = 0
        reordered.slots[1].zOrder = 1
        let afterReorder = try PNGSlotClarity.prepare(data: data, snapshot: reordered)
        XCTAssertEqual(afterReorder.retained(all), all)

        let sharedA = FrameSlot(captureIndex: 1, x: 0.125, y: 0, width: 0.5, height: 1, zOrder: 0)
        let sharedB = FrameSlot(captureIndex: 2, x: 0.375, y: 0, width: 0.5, height: 1, zOrder: 1)
        let overlap = claritySnapshot([sharedA, sharedB])
        let colored = try clarityFixture(alpha: 0) { x, y in
            (216..<296).contains(x) && (100..<400).contains(y) ? (180, 30, 90, 130) : (0, 0, 0, 0)
        }
        let original = try PNGSlotClarity.prepare(data: colored, snapshot: overlap)
        let approvedBoth = original.approving([:])
        XCTAssertEqual(approvedBoth.count, 2)
        let clearShared = PNGSlotClarity.Edit(slotID: sharedA.id,
            bounds: CGRect(x: 240, y: 200, width: 30, height: 125), action: .clear)
        let afterSharedEdit = try PNGSlotClarity.refine(data: colored, snapshot: overlap, automatic: original, edits: [clearShared])
        XCTAssertEqual(afterSharedEdit.pending(approvedBoth).map(\.id), [sharedA.id, sharedB.id])
    }

    func testOpaqueArtworkInsideAnEllipseCannotBeSavedAsReady() throws {
        let env = AppEnvironment(inMemory: true)
        let ellipse = FrameSlot(captureIndex: 1, x: 0.25, y: 0.25, width: 0.5, height: 0.5,
                                maskType: .ellipse)
        let bytes = try clarityFixture(alpha: 255) { x, y in
            let outsideEllipse = (130..<145).contains(x) && (130..<145).contains(y)
            return (12, 25, 48, outsideEllipse ? 0 : 255)
        }
        let before = try env.frames.listFrames().count
        XCTAssertThrowsError(try env.frames.createConfiguredFrame(name: "Covered ellipse", imageData: bytes,
            mediaType: "image/png", role: .frameForeground, categoryID: nil, slots: [ellipse])) { error in
            XCTAssertTrue((error as? AppError)?.message.contains("che kín ô 1") == true)
        }
        XCTAssertEqual(try env.frames.listFrames().count, before)
    }

    func testNativeSlotCoverageAcrossTileEdgesAndPlacementModes() throws {
        let size = 2048
        let slot = FrameSlot(captureIndex: 1, x: 0, y: 0.25, width: 0.5, height: 0.5)
        let thinOpening = try adaptiveFixture(size: size, background: 255, regions: [
            (CGRect(x: 511, y: 987, width: 2, height: 1), 0)
        ])
        let solid = try adaptiveFixture(size: size, background: 255, regions: [])
        for placement in [PlacementKind.stretchToCanvas, .aspectFill, .aspectFit] {
            let draft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: size, canvasHeight: size,
                                      foregroundPlacement: placement)
            XCTAssertEqual(try PNGAutoAlignmentService.blockedSlots(overlay: solid, draft: draft, slots: [slot]), [1])
            XCTAssertEqual(try PNGAutoAlignmentService.blockedSlots(overlay: thinOpening, draft: draft, slots: [slot]), [])
        }
        let rounded = FrameSlot(captureIndex: 1, x: 0.25, y: 0.25, width: 0.5, height: 0.5,
                                 maskType: .roundedRectangle, cornerRadius: 0.25)
        let rotated = FrameSlot(captureIndex: 1, x: 0.25, y: 0.25, width: 0.5, height: 0.5,
                                 rotationDegrees: 45)
        let corner = try adaptiveFixture(size: 512, background: 255, regions: [
            (CGRect(x: 133, y: 133, width: 4, height: 4), 0)
        ])
        let draft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: 512, canvasHeight: 512,
                                  foregroundPlacement: .stretchToCanvas)
        for slot in [rounded, rotated] {
            XCTAssertEqual(try PNGAutoAlignmentService.blockedSlots(overlay: corner, draft: draft, slots: [slot]), [1])
        }
        // At native size the same opening lets the underlying photo reach the rendered pixels.
        let snapshot = FrameSnapshot(sourceFrameID: nil, sourceFrameRevisionID: nil,
            canvasWidth: size, canvasHeight: size, background: nil,
            foreground: SnapshotLayer(assetID: "test-overlay", placement: .stretchToCanvas),
            backgroundColorHex: "#FFFFFFFF", slots: [SnapshotSlot(from: slot)], snapshotHash: "")
        let photo = try adaptiveFixture(size: 256, background: 255, regions: [])
        let model = CompositionModel(snapshot: snapshot, sources: [1: RenderSource(image: photo)],
            defaults: AppEnvironment(inMemory: true).settings.sessionDefaultsSnapshot(), overrides: [:],
            placements: [:], cropModes: [:], assetImages: ["test-overlay": thinOpening],
            options: RenderOptions(targetWidth: size, targetHeight: size, transparentBackground: true))
        XCTAssertEqual(try rgbaPixel(thinOpening, x: 512, y: 987)[3], 0)
        XCTAssertEqual(try rgbaPixel(CompositeRenderer.render(model: model), x: 512, y: 987)[3], 255)
    }

    func testFrameChooserPassesOriginalSourceOnlyForTheCurrentSession() async throws {
        let env = AppEnvironment(inMemory: true)
        let slot = FrameSlot(captureIndex: 1, x: 0, y: 0, width: 1, height: 1)
        let frame = try env.frames.createConfiguredFrame(name: "Routing", imageData: clarityFixture(alpha: 0),
            mediaType: "image/png", role: .frameForeground, categoryID: nil, slots: [slot])
        for source in [ScreenRoute.FrameChooserSource.capture, .library] {
            let session = try makeUnframedSession(env, count: 1)
            let photos = try await saveCaptureFirstPhotos(env, sessionID: session.id, count: 1)
            env.route = source.reviewRoute
            env.openReview(sessionID: session.id, source: source.reviewRoute)
            let chooser: ScreenRoute = .chooseFrame(sessionID: session.id, source: source)
            for _ in 0..<100 where env.route != chooser {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(env.route, chooser)
            env.finishFrameChoice(sessionID: "other", source: source)
            XCTAssertEqual(env.route, chooser)
            let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
            try applyCaptureFirstFrame(env, detail: detail, frame: frame, photoIDs: photos.map(\.id))
            env.finishFrameChoice(sessionID: session.id, source: source)
            XCTAssertEqual(env.reviewContext?.sourceRoute, source.reviewRoute)
            XCTAssertEqual(env.route, .review(sessionID: session.id))
            let vm = ReviewViewModel(env: env)
            let loaded = await vm.load(sessionID: session.id)
            XCTAssertTrue(loaded)
            XCTAssertEqual(vm.previewMode, source == .capture ? .inFrame : .singlePhoto)
            XCTAssertEqual(vm.detail?.snapshot.sourceFrameID, frame.id)
            XCTAssertEqual(vm.detail?.session.defaults.selectedCaptureOrder, [1])
        }
    }

    func testApprovedFrameSaveRetryRecoversSameIDAndRejectsAnotherPreview() throws {
        let env = AppEnvironment(inMemory: true)
        let slot = FrameSlot(captureIndex: 1, x: 0, y: 0, width: 1, height: 1, zOrder: 0)
        let data = try clarityFixture(alpha: 0)
        let id = IDFactory.new()
        let before = try env.frames.listFrames().count
        func save(_ bytes: Data) throws -> Frame {
            try env.frames.createConfiguredFrame(name: "Approved preview", imageData: bytes,
                mediaType: "image/png", role: .frameForeground, categoryID: nil, slots: [slot], retryID: id)
        }
        try env.db.run("""
            CREATE TRIGGER fail_approved_import BEFORE INSERT ON frame_revisions
            BEGIN SELECT RAISE(ABORT, 'Interrupted approval'); END
            """)
        XCTAssertThrowsError(try save(data))
        XCTAssertNil(try env.frames.getFrame(id: id))
        try env.db.run("DROP TRIGGER fail_approved_import")
        XCTAssertThrowsError(try {
            _ = try save(data)
            throw AppError.ioFailure("QA lost response after commit")
        }())
        let frame = try XCTUnwrap(env.frames.getFrame(id: id))
        XCTAssertEqual(try save(data), frame, "Retry after a successful commit returns the existing frame")
        XCTAssertThrowsError(try save(clarityFixture(alpha: 30)))
        XCTAssertEqual(try env.frames.listFrames().count, before + 1)
        let snapshot = try env.frames.createSnapshot(frameID: id, persist: false)
        let layer = try env.assets.loadData(assetID: XCTUnwrap(snapshot.foreground?.assetID))
        XCTAssertEqual(Hashing.sha256Hex(layer), Hashing.sha256Hex(data))
    }

    func testClarityProtectsIsolatedAndTouchingPaleArtwork() throws {
        let slot = FrameSlot(captureIndex: 1, x: 0.08, y: 0.08, width: 0.84, height: 0.84, zOrder: 0)
        let snapshot = claritySnapshot([slot])
        for underlay in [UInt8(0), 70] {
            let original = try clarityFixture(alpha: 0) { x, y in
                let circle = hypot(Double(x - 256), Double(y - 256)) <= 75
                return circle ? (250, 250, 250, 125) : (250, 250, 250, underlay)
            }
            let result = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
            XCTAssertEqual(result.slots.first?.status, .needsReview)
            let image = try XCTUnwrap(CGImage.createFrom(data: result.data))
            let before = try XCTUnwrap(CGImage.createFrom(data: original))
            XCTAssertEqual(try rgbaPixel(image, x: 256, y: 256), try rgbaPixel(before, x: 256, y: 256))
            XCTAssertEqual(try rgbaPixel(image, x: 256, y: 256)[3], 125)
            if underlay > 0 { XCTAssertEqual(try rgbaPixel(image, x: 140, y: 256)[3], 0) }
        }
    }

    func testClarityFindsSinglePixelFilmInsideProtectedBorderAndEditsOnlyIssuePixels() throws {
        let slot = FrameSlot(captureIndex: 1, x: 0, y: 0, width: 1, height: 1, zOrder: 0)
        let snapshot = claritySnapshot([slot])
        for side in 0..<4 {
            let original = try clarityFixture(alpha: 0) { x, y in
                let depth = side == 0 ? x : side == 1 ? 511 - x : side == 2 ? y : 511 - y
                let position = side < 2 ? y : x
                return depth == 5 && (70..<440).contains(position) ? (250, 250, 250, 130) : (0, 0, 0, 0)
            }
            let result = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
            XCTAssertEqual(result.data, original)
            XCTAssertEqual(result.slots.first?.status, .needsReview)
            let issue = try XCTUnwrap(result.slots.first?.issues.first)
            XCTAssertEqual(issue.pixels.reduce(0) { $0 + $1.count }, 370)
            let clear = PNGSlotClarity.Edit(slotID: slot.id, bounds: issue.bounds, action: .clear, pixels: issue.pixels)
            let cleaned = try PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: result, edits: [clear])
            XCTAssertTrue(cleaned.complete)
            let before = try XCTUnwrap(CGImage.createFrom(data: original)?.dataProvider?.data as Data?)
            let after = try XCTUnwrap(CGImage.createFrom(data: cleaned.data)?.dataProvider?.data as Data?)
            var expected = before
            for run in issue.pixels { for n in run { expected[n * 4 + 3] = 0 } }
            XCTAssertEqual(after, expected)
        }
    }

    func testClarityKeepsOriginalBytesForAlreadyClearGrayscalePNG() throws {
        let slot = FrameSlot(captureIndex: 1, x: 0.125, y: 0.125, width: 0.75, height: 0.75, zOrder: 0)
        let snapshot = claritySnapshot([slot])
        func grayPNG(alpha: UInt8) throws -> Data {
            var bytes = Data(repeating: 255, count: 512 * 512 * 2)
            for y in 64..<448 { for x in 64..<448 { bytes[(y * 512 + x) * 2 + 1] = alpha } }
            let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
            let image = try XCTUnwrap(CGImage(width: 512, height: 512, bitsPerComponent: 8, bitsPerPixel: 16,
                bytesPerRow: 1024, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            return try ExportService.encode(cg: image, format: .png, quality: 100)
        }
        let bytes = try grayPNG(alpha: 0)
        XCTAssertEqual(try AssetStore.validatedFrameImage(bytes).image.bitsPerPixel, 16)
        let clear = try PNGSlotClarity.prepare(data: bytes, snapshot: snapshot)
        XCTAssertTrue(clear.complete)
        XCTAssertEqual(clear.data, bytes)
        let hazy = try grayPNG(alpha: 130)
        XCTAssertThrowsError(try PNGSlotClarity.prepare(data: hazy, snapshot: snapshot)) { error in
            XCTAssertTrue((error as? AppError)?.message.contains("Ô 1") == true)
        }
    }

    func testClarityEditorKeepsOtherSlotApprovalAndUndoDoesNotResurrectExpiredApproval() throws {
        let a = FrameSlot(captureIndex: 1, x: 0.1, y: 0.1, width: 0.3, height: 0.3, zOrder: 0)
        let b = FrameSlot(captureIndex: 2, x: 0.6, y: 0.6, width: 0.3, height: 0.3, zOrder: 1)
        let bytes = try clarityFixture(alpha: 0)
        let edits = [a.id, b.id].map { PNGSlotClarity.Edit(slotID: $0, bounds: CGRect(x: 60, y: 60, width: 18, height: 18), action: .keep) }
        let draft = FrameEditorImportDraft(name: "QA", categoryID: nil, data: bytes, mediaType: "image/png",
            role: .frameForeground, width: 512, height: 512, slots: [a, b],
            claritySHA256: Hashing.sha256Hex(bytes), clarityEdits: edits)
        let vm = FrameEditorViewModel(env: AppEnvironment(inMemory: true))
        vm.load(imported: draft)
        XCTAssertEqual(try vm.importedClarityInput()?.edits.map(\.slotID), [a.id, b.id])
        vm.moveZOrder(b.id, up: false)
        XCTAssertEqual(try vm.importedClarityInput()?.edits.map(\.slotID), [a.id, b.id])
        var moved = try XCTUnwrap(vm.slots.first { $0.id == a.id })
        moved.x += 0.02
        vm.updateSlotFromInspector(moved)
        XCTAssertEqual(try vm.importedClarityInput()?.edits.map(\.slotID), [b.id])
        vm.undo()
        XCTAssertEqual(try vm.importedClarityInput()?.edits.map(\.slotID), [b.id])
        moved.x = 0.65; moved.y = 0.65
        vm.updateSlotFromInspector(moved)
        XCTAssertEqual(try vm.importedClarityInput()?.edits.count, 0)
        vm.discardImportedFrame()
        let reopened = FrameEditorViewModel(env: AppEnvironment(inMemory: true))
        reopened.load(imported: draft)
        XCTAssertEqual(try reopened.importedClarityInput()?.edits.map(\.slotID), [a.id, b.id])
        reopened.setPlacement(kind: .aspectFit, isBackground: false)
        XCTAssertEqual(try reopened.importedClarityInput()?.edits.count, 0)
    }

    func testClarityDetectsColoredEdgeWithoutErasingIt() throws {
        let snapshot = claritySnapshot([FrameSlot(captureIndex: 1, x: 0, y: 0, width: 1, height: 1, zOrder: 0)])
        let original = try clarityFixture(alpha: 0) { x, y in
            (11..<20).contains(x) && (60..<452).contains(y) ? (220, 20, 90, 115) : (0, 0, 0, 0)
        }
        let result = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
        XCTAssertEqual(result.slots.map(\.status), [.needsReview])
        XCTAssertFalse(result.canSave)
        XCTAssertEqual(result.data, original)
        XCTAssertFalse(result.slots[0].issues.isEmpty)
        XCTAssertTrue(result.slots[0].issues.allSatisfy { !$0.canRetry })
    }

    func testClarityChecksBothEdgeBandsOnEverySideAndHonorsAlphaThreshold() throws {
        let snapshot = claritySnapshot([FrameSlot(captureIndex: 1, x: 0, y: 0, width: 1, height: 1, zOrder: 0)])
        for side in 0..<4 {
            for band in [11..<15, 16..<20] {
                for alpha in [UInt8(25), 26, 208, 209] {
                    let original = try clarityFixture(alpha: 0) { x, y in
                        let depth = side == 0 ? x : side == 1 ? 511 - x : side == 2 ? y : 511 - y
                        let position = side < 2 ? y : x
                        return band.contains(depth) && (80..<432).contains(position)
                            ? (220, 20, 90, alpha) : (0, 0, 0, 0)
                    }
                    let result = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
                    XCTAssertEqual(result.slots[0].status, alpha < 26 ? .alreadyClear : .needsReview,
                                   "side=\(side), band=\(band), alpha=\(alpha)")
                    XCTAssertEqual(result.data, original, "Colored edge pixels must remain unchanged")
                    XCTAssertFalse(result.canSave)
                    XCTAssertTrue(result.slots[0].issues.allSatisfy { !$0.canRetry })
                }
            }
        }
    }

    func testClarityEdgeCoverageIsLocalToEachBandAndRequiresAnEdgeSpan() throws {
        // A 400px-wide slot gives each 1% band exactly four pixel columns.
        let snapshot = claritySnapshot([FrameSlot(captureIndex: 1, x: 0, y: 0,
                                                  width: 400.0 / 512, height: 1, zOrder: 0)])
        for start in [8, 12] {
            for width in [1, 2] {
                for height in [30, 320] {
                    let original = try clarityFixture(alpha: 0) { x, y in
                        (start..<(start + width)).contains(x) && (96..<(96 + height)).contains(y)
                            ? (220, 20, 90, 115) : (0, 0, 0, 0)
                    }
                    let result = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
                    let expected: PNGSlotClarity.Status = width == 2 && height == 320 ? .needsReview : .alreadyClear
                    XCTAssertEqual(result.slots[0].status, expected,
                                   "start=\(start), coverage=\(width)/4, height=\(height)")
                    XCTAssertEqual(result.data, original)
                    if expected == .needsReview {
                        let issue = try XCTUnwrap(result.slots[0].issues.first)
                        XCTAssertEqual(issue.bounds.minX, Double(start))
                        XCTAssertEqual(issue.bounds.width, Double(width))
                        XCTAssertGreaterThanOrEqual(issue.bounds.minY, 96)
                        XCTAssertLessThanOrEqual(issue.bounds.maxY, Double(96 + height))
                        XCTAssertGreaterThan(issue.bounds.height, 100)
                        XCTAssertFalse(issue.canRetry)
                    }
                }
            }
        }
    }

    func testClarityMixedEdgeDoesNotAuthorizeColoredPixelsForRetry() throws {
        let snapshot = claritySnapshot([FrameSlot(captureIndex: 1, x: 0, y: 0, width: 1, height: 1, zOrder: 0)])
        let original = try clarityFixture(alpha: 0) { x, y in
            guard (11..<15).contains(x), (80..<432).contains(y) else { return (0, 0, 0, 0) }
            return y < 256 ? (250, 251, 252, 115) : (220, 20, 90, 115)
        }
        let result = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
        XCTAssertEqual(result.slots[0].status, .needsReview)
        let before = try XCTUnwrap(CGImage.createFrom(data: original))
        let after = try XCTUnwrap(CGImage.createFrom(data: result.data))
        XCTAssertEqual(try rgbaPixel(after, x: 12, y: 320), try rgbaPixel(before, x: 12, y: 320))
        XCTAssertEqual(try rgbaPixel(after, x: 13, y: 180)[3], 115)
        let pale = try XCTUnwrap(result.slots[0].issues.first { $0.canRetry })
        let clear = PNGSlotClarity.Edit(slotID: snapshot.slots[0].id, bounds: pale.bounds,
                                       action: .clear, pixels: pale.pixels)
        let refined = try PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: result, edits: [clear])
        let layer = try XCTUnwrap(CGImage.createFrom(data: refined.data))
        XCTAssertLessThanOrEqual(try rgbaPixel(layer, x: 13, y: 180)[3], 8)
        XCTAssertEqual(try rgbaPixel(layer, x: 12, y: 320), try rgbaPixel(before, x: 12, y: 320))
        XCTAssertEqual(refined.slots[0].status, .needsReview)
    }

    func testClarityMapsFitLayerAndManualReviewToCanvasCoordinates() throws {
        let slot = FrameSlot(captureIndex: 1, x: 0.25, y: 0, width: 0.5, height: 1, zOrder: 0)
        var snapshot = claritySnapshot([slot])
        snapshot.canvasWidth = 1024
        snapshot.foreground = SnapshotLayer(assetID: "overlay", placement: .aspectFit)
        let original = try clarityFixture(alpha: 0) { x, y in
            (110..<400).contains(x) && (120..<390).contains(y) ? (220, 20, 90, 115) : (0, 0, 0, 0)
        }
        let automatic = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
        let issue = try XCTUnwrap(automatic.slots.first?.issues.first)
        XCTAssertEqual(issue.bounds.minX, 366, accuracy: 1)
        let edit = PNGSlotClarity.Edit(slotID: slot.id, bounds: issue.bounds, action: .clear)
        let reviewed = try PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: automatic, edits: [edit])
        let image = try XCTUnwrap(CGImage.createFrom(data: reviewed.data))
        XCTAssertLessThanOrEqual(try rgbaPixel(image, x: 260, y: 256)[3], 8)
        XCTAssertTrue(reviewed.complete)
    }

    func testClarityPreservesRGBOutsidePixelsAndProtectedBorder() throws {
        let slot = FrameSlot(captureIndex: 1, x: 0.125, y: 0.125, width: 0.75, height: 0.75, zOrder: 0)
        let snapshot = claritySnapshot([slot])
        let original = try clarityFixture(alpha: 115)
        let result = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
        XCTAssertEqual(result.slots[0].status, .cleared)
        let before = try XCTUnwrap(CGImage.createFrom(data: original))
        let after = try XCTUnwrap(CGImage.createFrom(data: result.data))
        let old = try XCTUnwrap(before.dataProvider?.data as Data?)
        let new = try XCTUnwrap(after.dataProvider?.data as Data?)
        XCTAssertEqual(old.count, new.count)
        for y in 0..<512 {
            for x in 0..<512 {
                let p = (y * 512 + x) * 4
                XCTAssertEqual(Array(old[p..<(p + 3)]), Array(new[p..<(p + 3)]))
                XCTAssertLessThanOrEqual(new[p + 3], old[p + 3])
                // Slot bounds are 64...448; its protected 2% is 7.68px wide.
                if x < 72 || x >= 440 || y < 72 || y >= 440 {
                    XCTAssertEqual(new[p + 3], old[p + 3])
                }
            }
        }
        let reopened = try PNGSlotClarity.prepare(data: result.data, snapshot: snapshot)
        XCTAssertEqual(reopened.slots[0].status, .alreadyClear)
        XCTAssertEqual(reopened.data, result.data)
        XCTAssertFalse(reopened.canSave)
    }

    func testClarityVisitsEverySlotEvenWhenCaptureIndicesAreReused() throws {
        let original = try clarityFixture(alpha: 115)
        for count in [1, 2, 3, 4, 5, 6, 8, 9] {
            let slots = (0..<count).map { index in
                FrameSlot(captureIndex: 1, x: 0.05 + 0.9 * Double(index) / Double(count), y: 0.05,
                          width: 0.9 / Double(count), height: 0.9, zOrder: index)
            }
            let result = try PNGSlotClarity.prepare(data: original, snapshot: claritySnapshot(slots))
            XCTAssertEqual(result.slots.map(\.id), slots.map(\.id))
            XCTAssertEqual(result.slots.map(\.number), Array(1...count))
            XCTAssertEqual(result.slots.map(\.status), Array(repeating: .cleared, count: count), "count=\(count)")
            XCTAssertTrue(result.canSave)
        }
    }

    func testClarityManualReviewRechecksAllSlotsAndUndoReturnsAutomaticBytes() throws {
        let slots = [FrameSlot(captureIndex: 1, x: 0.05, y: 0.05, width: 0.4, height: 0.9, zOrder: 0),
                     FrameSlot(captureIndex: 2, x: 0.5, y: 0, width: 0.5, height: 1, zOrder: 1)]
        let snapshot = claritySnapshot(slots)
        let original = try clarityFixture(alpha: 0) { x, y in
            if x < 256 { return (250, 251, 252, 115) }
            return (262..<264).contains(x) && (80..<432).contains(y) ? (220, 20, 90, 115) : (0, 0, 0, 0)
        }
        let automatic = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
        XCTAssertEqual(automatic.slots.map(\.status), [.cleared, .needsReview])
        XCTAssertFalse(automatic.canSave)
        let clear = PNGSlotClarity.Edit(slotID: slots[1].id, bounds: CGRect(x: 256, y: 0, width: 256, height: 512), action: .clear)
        let keep = PNGSlotClarity.Edit(slotID: slots[1].id, bounds: clear.bounds, action: .keep)
        let cleared = try PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: automatic, edits: [clear])
        XCTAssertEqual(cleared.slots.map(\.status), [.cleared, .cleared])
        XCTAssertTrue(cleared.canSave)
        let kept = try PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: automatic, edits: [keep, clear])
        XCTAssertEqual(kept.slots.map(\.status), [.cleared, .detailKept])
        XCTAssertEqual(kept.data, automatic.data)
        XCTAssertTrue(kept.canSave)
        let reopened = try PNGSlotClarity.prepare(data: kept.data, snapshot: snapshot)
        XCTAssertEqual(reopened.slots.map(\.status), [.alreadyClear, .needsReview],
                       "A previous keep confirmation must never authorize automatic erasure on reopening")
        let undone = try PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: automatic, edits: [])
        XCTAssertEqual(undone.data, automatic.data)
        XCTAssertEqual(undone.slots.map(\.status), automatic.slots.map(\.status))
        XCTAssertFalse(undone.canSave)
    }

    func testClarityOuterEdgeConfirmationDoesNotCreateAnUnnecessaryCopy() throws {
        let slot = FrameSlot(captureIndex: 1, x: 0, y: 0, width: 1, height: 1, zOrder: 0)
        let snapshot = claritySnapshot([slot])
        let original = try clarityFixture(alpha: 0) { x, y in
            (4..<8).contains(x) && (80..<432).contains(y) ? (220, 20, 90, 115) : (0, 0, 0, 0)
        }
        let automatic = try PNGSlotClarity.prepare(data: original, snapshot: snapshot)
        XCTAssertEqual(automatic.slots[0].status, .needsReview)
        XCTAssertFalse(automatic.canSave)
        let bounds = CGRect(x: 0, y: 0, width: 512, height: 512)
        let keep = PNGSlotClarity.Edit(slotID: slot.id, bounds: bounds, action: .keep)
        let kept = try PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: automatic, edits: [keep])
        XCTAssertEqual(kept.slots[0].status, .detailKept)
        XCTAssertEqual(kept.data, original)
        XCTAssertFalse(kept.canSave)
        let clear = PNGSlotClarity.Edit(slotID: slot.id, bounds: bounds, action: .clear)
        let edited = try PNGSlotClarity.refine(data: original, snapshot: snapshot, automatic: automatic, edits: [clear])
        XCTAssertEqual(edited.slots[0].status, .cleared)
        XCTAssertTrue(edited.canSave)
        XCTAssertEqual(try rgbaPixel(XCTUnwrap(CGImage.createFrom(data: edited.data)), x: 5, y: 256)[3], 0)
    }

    func testClarityPartialPreviewForThreeAndFiveSlotsKeepsFourCaptureSessionUnchanged() async throws {
        let env = AppEnvironment(inMemory: true)
        let session = try makeUnframedSession(env, count: 4)
        _ = try await saveCaptureFirstPhotos(env, sessionID: session.id, count: 4)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        for count in [3, 5] {
            let slots = (0..<count).map { index in
                FrameSlot(captureIndex: index + 1, x: 0.05 + Double(index) * 0.18, y: 0.25,
                          width: 0.15, height: 0.5, zOrder: index)
            }
            let frame = try env.frames.createConfiguredFrame(name: "Partial \(count)", imageData: clarityFixture(alpha: 0),
                mediaType: "image/png", role: .frameForeground, categoryID: nil, slots: slots)
            let snapshot = try env.frames.createSnapshot(frameID: frame.id, persist: false)
            let image = try await env.renderBuilder.renderChooserPreview(detail: detail, snapshot: snapshot,
                                                                         order: [4], width: 512, height: 512)
            for index in 0..<count {
                let x = Int((0.125 + Double(index) * 0.18) * 512)
                XCTAssertEqual(try rgbaPixel(image, x: x, y: 256)[3], index == 0 ? 255 : 0)
            }
            XCTAssertEqual(try env.sessions.getDetail(sessionID: session.id), detail)
        }
    }

    private func claritySnapshot(_ slots: [FrameSlot]) -> FrameSnapshot {
        FrameSnapshot(sourceFrameID: nil, sourceFrameRevisionID: nil, canvasWidth: 512, canvasHeight: 512,
                      background: nil, foreground: SnapshotLayer(assetID: "test", placement: .stretchToCanvas),
                      backgroundColorHex: "#FFFFFFFF", slots: slots.map(SnapshotSlot.init(from:)), snapshotHash: "")
    }

    private func clarityFixture(alpha: UInt8, decoration: Bool = false,
                                custom: ((Int, Int) -> (UInt8, UInt8, UInt8, UInt8))? = nil) throws -> Data {
        let size = 512
        var bytes = Data(repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                if let pixel = custom?(x, y) {
                    (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = pixel
                } else if decoration && (80..<92).contains(x) && (169..<182).contains(y) {
                    bytes[i] = 232
                    bytes[i + 1] = 20
                    bytes[i + 2] = 60
                    bytes[i + 3] = 175
                } else {
                    bytes[i] = 255
                    bytes[i + 1] = 252
                    bytes[i + 2] = 250
                    bytes[i + 3] = alpha
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: size * 4, space: space,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent))
        return try ExportService.encode(cg: image, format: .png, quality: 100)
    }

    private func rgbaPixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: 4))
    }

    private func makeUnframedSession(_ env: AppEnvironment, count: Int) throws -> CaptureSessionRecord {
        var defaults = env.settings.sessionDefaultsSnapshot()
        defaults.plannedCaptureCount = count
        return try env.sessions.createSession(snapshot: .awaitingFrame(), mode: .manual, cameraID: nil, defaults: defaults)
    }

    private func saveCaptureFirstPhotos(_ env: AppEnvironment, sessionID: String, count: Int) async throws -> [PhotoRevision] {
        let image = CGImage.createBlank()
        let data = try ExportService.encode(cg: image, format: .jpeg, quality: 93)
        var revisions: [PhotoRevision] = []
        for index in 1...count {
            revisions.append(try await env.safetySave.savePhoto(
                sessionID: sessionID, captureIndex: index, payloadData: data, requestID: UUID().uuidString,
                width: image.width, height: image.height, orientation: 1, codec: "jpeg", colorProfile: nil))
        }
        return revisions
    }

    private func applyCaptureFirstFrame(_ env: AppEnvironment, detail: SessionDetail, frame: Frame, photoIDs: [String]) throws {
        try env.sessions.applyCaptureFrame(sessionID: detail.session.id, expectedRevision: detail.session.revisionNo,
                                           frameID: frame.id, frameRevisionID: XCTUnwrap(frame.currentRevisionID),
                                           orderedPhotoIDs: photoIDs, frames: env.frames, assets: env.assets)
    }

    private func alphaFixture(size: Int, openings: [CGRect], frame: CGRect? = nil, border: CGFloat = 0) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(red: 0.7, green: 0.4, blue: 0.1, alpha: 1)
        context.fill(frame ?? CGRect(x: 0, y: 0, width: size, height: size))
        for rect in openings {
            if border > 0 {
                context.setBlendMode(.copy)
                context.setFillColor(red: 0.7, green: 0.4, blue: 0.1, alpha: 0.65)
                context.fill(rect.insetBy(dx: -border, dy: -border))
            }
            context.clear(rect)
        }
        return try XCTUnwrap(context.makeImage())
    }
}

private extension SessionDetail {
    var originalChecksums: [String: String] {
        Dictionary(uniqueKeysWithValues: currentRevisions(includeUnassigned: true).values.map { ($0.id, $0.sha256) })
    }
}

extension CapturePhotoSelectionTests {
    func testPackDuplicateDetectionRoundTripsAssetContent() async throws {
        let env = AppEnvironment(inMemory: true)
        let bytes = try clarityFixture(alpha: 255)
        let frame = try env.frames.createConfiguredFrame(name: "Roundtrip", imageData: bytes,
            mediaType: "image/png", role: .frameBackground, categoryID: nil,
            slots: [FrameSlot(captureIndex: 1, x: 0.1, y: 0.1, width: 0.8, height: 0.8)])
        let data = try env.packService.buildPack(name: "QA", frameIDs: [frame.id])
        let entry = try XCTUnwrap(env.packService.loadPack(data: data).entries.first)
        XCTAssertTrue(entry.isDuplicate)
        let vm = FramePackImportViewModel(env: env)
        let url = env.layout.rootURL.appendingPathComponent("roundtrip.photoframepack")
        try data.write(to: url)
        await vm.loadAndValidate(url: url)
        XCTAssertEqual(vm.choices[frame.id]?.policy, .skip)
    }

    func testPackHashIncludesCropCornerAndPlacement() throws {
        let env = AppEnvironment(inMemory: true)
        let frame = try env.frames.createConfiguredFrame(name: "Hash", imageData: clarityFixture(alpha: 255),
            mediaType: "image/png", role: .frameBackground, categoryID: nil,
            slots: [FrameSlot(captureIndex: 1, x: 0.1, y: 0.1, width: 0.8, height: 0.8, maskType: .roundedRectangle)])
        let pack = try env.packService.buildPack(name: "QA", frameIDs: [frame.id])
        let original = try XCTUnwrap(FramePackService.validate(data: pack).manifest.frames.first)
        let hash = FramePackService.packContentHash(packFrame: original)
        var crop = original; crop.slots[0].cropMode = "fit"
        var corner = original; corner.slots[0].cornerRadius = 0.2
        var placement = original; placement.backgroundPlacement = "stretch"
        XCTAssertNotEqual(hash, FramePackService.packContentHash(packFrame: crop))
        XCTAssertNotEqual(hash, FramePackService.packContentHash(packFrame: corner))
        XCTAssertNotEqual(hash, FramePackService.packContentHash(packFrame: placement))
        var metadata = original
        metadata.frameId = "another-id"; metadata.name = "Renamed"; metadata.category = "Another category"
        metadata.slots[0].id = "another-slot"; metadata.slots[0].zOrder = 123
        metadata.assets.background = original.assets.background.map { String($0.dropFirst(7)).uppercased() }
        metadata.backgroundColor = "#FFFFFF"; metadata.backgroundPlacement = nil
        metadata.slots[0].rotationDegrees = nil; metadata.slots[0].cornerRadius = nil
        metadata.slots[0].cropMode = nil
        XCTAssertEqual(hash, FramePackService.packContentHash(packFrame: metadata))
        var white = original; white.explicitWhite = true
        XCTAssertNotEqual(hash, FramePackService.packContentHash(packFrame: white))
    }

    func testCoveredPackFailsBeforeWriteAndEditorCannotMarkReady() async throws {
        let env = AppEnvironment(inMemory: true)
        let bytes = try clarityFixture(alpha: 255) { x, y in
            (20..<30).contains(x) && (20..<30).contains(y) ? (0,0,0,0) : (20,30,40,255)
        }
        let frame = try env.frames.createFrame(name: "Covered", imageData: bytes, mediaType: "image/png",
            role: .frameForeground, categoryID: nil)
        let old = try XCTUnwrap(frame.currentRevisionID ?? env.frames.getFrame(id: frame.id)?.currentRevisionID)
        let draft = try XCTUnwrap(env.frames.getRevision(id: old))
        let slot = FrameSlot(captureIndex: 1, x: 0.25, y: 0.25, width: 0.5, height: 0.5, maskType: .ellipse)
        _ = try env.frames.commitRevision(frameID: frame.id, draft: draft, slots: [slot])
        try env.frames.setValidationStatus(frameID: frame.id, status: .ready)
        let data = try env.packService.buildPack(name: "QA", frameIDs: [frame.id])
        let validation = try FramePackService.validate(data: data)
        let count = try env.frames.listFrames().count
        for policy in [PackDuplicatePolicy.copy, .replace] {
            let results = try env.packService.applyImportDetailed(result: validation,
                choices: [.init(packFrameID: frame.id, policy: policy, selected: true)], data: data)
            if case .failedBeforeWrite(let message) = results[frame.id] {
                XCTAssertTrue(message.contains("che kín ô 1"))
            } else { XCTFail("Covered frame must fail before write: \(results)") }
        }
        XCTAssertEqual(try env.frames.listFrames().count, count)
        let vm = FrameEditorViewModel(env: env)
        vm.load(frameID: frame.id)
        var changed = try XCTUnwrap(vm.slots.first); changed.x += 0.01
        vm.updateSlotFromInspector(changed)
        while vm.isValidating { await Task.yield() }
        let saved = await vm.save()
        XCTAssertFalse(saved)
    }
}

extension CapturePhotoSelectionTests {
    private func faceSession(_ env: AppEnvironment) async throws -> SessionDetail {
        let slot = FrameSlot(captureIndex: 1, x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let frame = try env.frames.createConfiguredFrame(name: "Face", imageData: clarityFixture(alpha: 255),
            mediaType: "image/png", role: .frameBackground, categoryID: nil, slots: [slot])
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)
        let session = try env.sessions.createSession(snapshot: snapshot, mode: .manual, cameraID: nil,
            defaults: env.settings.sessionDefaultsSnapshot())
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
            bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 400,height: 200))
        let png = try ExportService.encode(cg: XCTUnwrap(context.makeImage()), format: .png, quality: 100)
        _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: 1, payloadData: png,
            requestID: UUID().uuidString, width: 400, height: 200, orientation: 1, codec: "png", colorProfile: nil)
        return try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
    }

    func testAutoFaceResolvedInBothBuildersAndPreservesLegacyManualAndOff() async throws {
        let env = AppEnvironment(inMemory: true)
        var detail = try await faceSession(env)
        let slot = try XCTUnwrap(detail.snapshot.slots.first)
        let faces = FaceAnalysisService(detector: { _ in [FaceBox(x: 0.8,y: 0.25,width: 0.1,height: 0.3,confidence: 1)] })
        let builder = SessionRenderBuilder(sessions: env.sessions, assets: env.assets, layout: env.layout, faceAnalysis: faces)
        let strict = try await builder.buildModelStrict(detail: detail, targetWidth: 512, targetHeight: 512)
        let preview = await builder.buildModel(detail: detail, targetWidth: 256, targetHeight: 256)
        XCTAssertEqual(strict.placements, preview.placements)
        XCTAssertEqual(strict.cropModes, preview.cropModes)
        XCTAssertEqual(try XCTUnwrap(strict.placements[slot.id]).offsetX, -0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(strict.placements[slot.id]).offsetY, 0, accuracy: 1e-9)
        XCTAssertEqual(strict.cropModes[slot.id], .fill)
        let before = try env.sessions.getSession(id: detail.session.id)?.revisionNo
        for version in [nil, 99] as [Int?] {
            detail.session.defaults.autoFacePlacementVersion = version
            let legacy = try await builder.buildModelStrict(detail: detail, targetWidth: 512, targetHeight: 512)
            XCTAssertEqual(legacy.placements[slot.id], PhotoPlacement())
            let decoded = try JSONDecoder().decode(SessionDefaultsSnapshot.self, from: JSONEncoder().encode(detail.session.defaults))
            XCTAssertEqual(decoded.autoFacePlacementVersion, version)
        }
        detail.session.defaults.autoFacePlacementVersion = 1
        detail.session.defaults.smartFace = false
        let off = await builder.buildModel(detail: detail, targetWidth: 512, targetHeight: 512)
        XCTAssertEqual(off.placements[slot.id], PhotoPlacement())
        detail.session.defaults.smartFace = true
        detail.placements[slot.id]?.manualOverride = true
        detail.placements[slot.id]?.offsetX = 0.1
        let manual = try await builder.buildModelStrict(detail: detail, targetWidth: 512, targetHeight: 512)
        XCTAssertEqual(manual.placements[slot.id]?.offsetX, 0.1)
        XCTAssertEqual(try env.sessions.getSession(id: detail.session.id)?.revisionNo, before, "Rendering is read-only")
    }

    func testOldDefaultsDoNotUpgradeUntilDifferentFrameIsApplied() async throws {
        let env = AppEnvironment(inMemory: true)
        let detail = try await faceSession(env)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail.session.defaults)) as? [String: Any])
        json.removeValue(forKey: "autoFacePlacementVersion")
        let old = try JSONDecoder().decode(SessionDefaultsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.autoFacePlacementVersion)
        try env.db.run("UPDATE sessions SET session_defaults_json=? WHERE id=?",
            [.text(String(decoding: JSONEncoder().encode(old), as: UTF8.self)), .text(detail.session.id)])
        let untouched = try env.sessions.createSession(snapshot: detail.snapshot, mode: .manual, cameraID: nil, defaults: old)
        let reopened = try XCTUnwrap(env.sessions.getDetail(sessionID: detail.session.id))
        let builder = env.renderBuilder
        _ = try await builder.buildModelStrict(detail: reopened, targetWidth: 512, targetHeight: 512)
        XCTAssertNil(try env.sessions.getSession(id: detail.session.id)?.defaults.autoFacePlacementVersion)
        let next = try env.frames.createEmptyFrame(name: "Next", categoryID: nil)
        let draft = FrameRevision(frameID: next.id, revisionNo: 1, canvasWidth: 512, canvasHeight: 512)
        _ = try env.frames.commitRevision(frameID: next.id, draft: draft,
            slots: [FrameSlot(captureIndex: 1,x: 0.1,y: 0.1,width: 0.8,height: 0.8)])
        try env.frames.setValidationStatus(frameID: next.id, status: .ready)
        let snapshot = try env.frames.createSnapshot(frameID: next.id, persist: false)
        try env.sessions.changeFrame(sessionID: detail.session.id, newSnapshot: snapshot, frames: env.frames)
        XCTAssertEqual(try env.sessions.getSession(id: detail.session.id)?.defaults.autoFacePlacementVersion, 1)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: untouched.id)?.snapshot.slots, detail.snapshot.slots)
    }

    func testConfiguredSaveRollsBackEveryWriteStageAndRetainsReferences() throws {
        let env = AppEnvironment(inMemory: true)
        let bytes = try clarityFixture(alpha: 255)
        let frame = try env.frames.createConfiguredFrame(name: "Atomic", imageData: bytes,
            mediaType: "image/png", role: .frameBackground, categoryID: nil,
            slots: [FrameSlot(captureIndex: 1,x: 0.1,y: 0.1,width: 0.8,height: 0.8)])
        let revisionID = try XCTUnwrap(frame.currentRevisionID)
        let draft = try XCTUnwrap(env.frames.getRevision(id: revisionID))
        let slots = try env.frames.getSlots(revisionID: revisionID)
        let owner = "qa-staging"
        _ = try env.assets.store(data: bytes, mediaType: "image/png", purpose: "background",
            ownerType: "frame_revision", ownerID: owner)
        for (table, event) in [("frame_revisions", "INSERT"), ("frame_slots", "INSERT"),
                               ("asset_references", "DELETE"), ("app_state", "INSERT"), ("frames", "UPDATE")] {
            try env.db.run("CREATE TEMP TRIGGER qa_fail BEFORE \(event) ON \(table) BEGIN SELECT RAISE(ABORT,'QA fault'); END")
            XCTAssertThrowsError(try env.frames.saveConfiguredRevision(frameID: frame.id, expectedRevisionID: revisionID,
                name: "Changed", draft: draft, slots: slots, stagedOwnerID: owner, explicitWhite: true))
            try env.db.run("DROP TRIGGER qa_fail")
            XCTAssertEqual(try env.frames.getFrame(id: frame.id)?.currentRevisionID, revisionID)
            XCTAssertEqual(try env.frames.getFrame(id: frame.id)?.name, "Atomic")
            XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM frame_revisions WHERE frame_id=?", [.text(frame.id)]), 1)
            XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM asset_references WHERE owner_id=?", [.text(owner)]), 1)
            XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
        }
        _ = try env.frames.saveConfiguredRevision(frameID: frame.id, expectedRevisionID: revisionID, name: "Changed",
            draft: draft, slots: slots, stagedOwnerID: owner, explicitWhite: true)
        XCTAssertNotEqual(try env.frames.getFrame(id: frame.id)?.currentRevisionID, revisionID)
        XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM asset_references WHERE owner_id=?", [.text(owner)]), 0)
        XCTAssertThrowsError(try env.frames.saveConfiguredRevision(frameID: frame.id, expectedRevisionID: revisionID,
            name: "Stale", draft: draft, slots: slots, stagedOwnerID: owner, explicitWhite: false))
    }
}

extension CapturePhotoSelectionTests {
    func testRealPNGFixturesKeepBytesAcrossValidationAndPackRoundTrip() throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: CapturePhotoSelectionTests.self)
        #endif
        let folder = try XCTUnwrap(bundle.resourceURL).appendingPathComponent("Fixtures/Frames")
        let checks = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: folder.appendingPathComponent("SHA256.json")))
        XCTAssertEqual(checks.count, 5)
        let env = AppEnvironment(inMemory: true)
        for (name, sha) in checks.sorted(by: { $0.key < $1.key }) {
            let bytes = try Data(contentsOf: folder.appendingPathComponent(name))
            XCTAssertEqual(Hashing.sha256Hex(bytes), sha)
            let image = try AssetStore.validatedFrameImage(bytes).image
            let found = PNGAutoAlignmentService.detectOpenings(image)
            XCTAssertFalse(found.slots.isEmpty, name)
            let slots = found.slots.enumerated().map { index, s in
                FrameSlot(captureIndex: index+1,x: s.x,y: s.y,width: s.width,height: s.height,zOrder: index)
            }
            let draft = FrameRevision(frameID: "",revisionNo: 1,canvasWidth: image.width,canvasHeight: image.height,
                foregroundAssetID: "qa",foregroundPlacement: .stretchToCanvas)
            XCTAssertTrue(try FrameRepository.configuredIssues(draft: draft, slots: slots, foreground: image).isEmpty, name)
            let frame = try env.frames.createConfiguredFrame(name: name, imageData: bytes, mediaType: "image/png",
                role: .frameForeground, categoryID: nil, slots: slots)
            let snapshot = try env.frames.validatedSnapshotForUse(frameID: frame.id)
            XCTAssertEqual(snapshot.requiredCaptureCount, slots.count)
            let pack = try env.packService.buildPack(name: "Fixture", frameIDs: [frame.id])
            XCTAssertEqual(try env.packService.loadPack(data: pack).entries.first?.isDuplicate, true)
            let assetID = try XCTUnwrap(snapshot.foreground?.assetID)
            XCTAssertEqual(try env.assets.loadData(assetID: assetID), bytes)
            XCTAssertEqual(Hashing.sha256Hex(try Data(contentsOf: folder.appendingPathComponent(name))), sha)
        }
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }

    func testAutoFaceGestureStartsFromVisiblePlacementAndUndoRestoresAuto() async throws {
        let faces = FaceAnalysisService(detector: { _ in [FaceBox(x: 0.8,y: 0.25,width: 0.1,height: 0.3,confidence: 1)] })
        let env = AppEnvironment(inMemory: true, faceAnalysis: faces)
        let detail = try await faceSession(env)
        let slot = try XCTUnwrap(detail.snapshot.slots.first)
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: detail.session.id)
        let deadline = ContinuousClock.now + .seconds(5)
        while !vm.canEditPlacement, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(vm.canEditPlacement)
        XCTAssertEqual(vm.draftPlacement?.offsetX ?? 99, -0.5, accuracy: 1e-9)
        vm.updatePlacement(scale: 1.1, isFinal: true)
        let manual = try XCTUnwrap(env.sessions.getDetail(sessionID: detail.session.id))
        XCTAssertEqual(manual.placements[slot.id]?.offsetX, -0.5)
        XCTAssertEqual(manual.placements[slot.id]?.scale, 1.1)
        XCTAssertEqual(manual.placements[slot.id]?.manualOverride, true)
        vm.undo()
        let undone = try XCTUnwrap(env.sessions.getDetail(sessionID: detail.session.id))
        XCTAssertEqual(undone.placements[slot.id]?.manualOverride, false)
        let model = try await env.renderBuilder.buildModelStrict(detail: undone, targetWidth: 512, targetHeight: 512)
        XCTAssertEqual(model.placements[slot.id]?.offsetX, -0.5)
        vm.redo()
        XCTAssertEqual(try env.sessions.getDetail(sessionID: detail.session.id)?.placements[slot.id]?.scale, 1.1)
    }

    func testReadyButCoveredFrameCannotBeAppliedAndRemainsRepairable() async throws {
        let env = AppEnvironment(inMemory: true)
        let detail = try await faceSession(env)
        let frame = try env.frames.createFrame(name: "Old covered", imageData: clarityFixture(alpha: 255),
            mediaType: "image/png", role: .frameForeground, categoryID: nil)
        let record = try XCTUnwrap(env.frames.getFrame(id: frame.id))
        let revision = try XCTUnwrap(env.frames.getRevision(id: XCTUnwrap(record.currentRevisionID)))
        _ = try env.frames.commitRevision(frameID: frame.id, draft: revision,
            slots: [FrameSlot(captureIndex: 1,x: 0.1,y: 0.1,width: 0.8,height: 0.8)])
        try env.frames.setValidationStatus(frameID: frame.id, status: .ready)
        let oldSnapshot = try env.frames.createSnapshot(frameID: frame.id, persist: false)
        XCTAssertThrowsError(try env.frames.validatedSnapshotForUse(frameID: frame.id))
        XCTAssertThrowsError(try env.sessions.changeFrame(sessionID: detail.session.id, newSnapshot: oldSnapshot, frames: env.frames))
        XCTAssertEqual(try env.sessions.getDetail(sessionID: detail.session.id)?.snapshot, detail.snapshot)
        XCTAssertEqual(try env.frames.getFrame(id: frame.id)?.validationStatus, .ready, "Read checks do not migrate old records")
        XCTAssertNoThrow(try env.frames.createSnapshot(frameID: frame.id, persist: false), "Repair tools still read the original")
        let editor = FrameEditorViewModel(env: env)
        editor.load(frameID: frame.id)
        while editor.isValidating { await Task.yield() }
        XCTAssertFalse(editor.validationIssues.isEmpty)
        XCTAssertEqual(editor.slots.count, 1)
    }
}

extension CapturePhotoSelectionTests {
    func testRetakeAllUsesVerifiedPersistedFrameAndLeavesOldSessionUnchanged() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let detail = try await faceSession(env)
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: detail.session.id)
        await vm.retakeAll()
        let session = try XCTUnwrap(env.engine.session)
        XCTAssertNotEqual(session.id, detail.session.id)
        XCTAssertEqual(session.defaults.autoFacePlacementVersion, 1)
        let persisted = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertEqual(persisted.snapshot.sourceFrameID, detail.snapshot.sourceFrameID)
        XCTAssertNotEqual(persisted.snapshot.id, detail.snapshot.id)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: detail.session.id), detail)
        env.engine.cancelCountdown()
        env.engine.resetToIdle()
    }
}
