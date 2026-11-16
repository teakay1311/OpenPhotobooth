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
        vm.step = .selectFrame
        vm.selectedFrameID = try XCTUnwrap(vm.readyFrames.first(where: { $0.frame.name == "Cặp ảnh ngang" })?.id)
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
        XCTAssertEqual(vm.step, .review)
        XCTAssertTrue(vm.reviewVM?.canExport == true)
        await vm.finish()
        XCTAssertEqual(vm.step, .finish)
        XCTAssertEqual(try env.sessions.getSession(id: sessionID)?.status, .completed)
        vm.exitFullscreenRequested()
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
