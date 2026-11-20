import Foundation
import XCTest
@testable import OpenPhotobooth

@MainActor
final class SessionCancellationTests: XCTestCase {
    private func setup(frame name: String = "Lưới 9 ảnh", mode: CaptureMode = .manual,
                       countdown: Int = 0, interval: Int = 0) async throws
        -> (AppEnvironment, FakeCameraService, CaptureSessionRecord, FrameSnapshot) {
        let camera = FakeCameraService()
        let env = AppEnvironment(inMemory: true, camera: camera)
        await env.boot()
        _ = try await camera.selectAutoDevice()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == name })
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)
        let session = try env.engine.beginSession(snapshot: snapshot, mode: mode, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot(),
                                                 countdown: countdown, interval: interval, frameName: name)
        return (env, camera, session, snapshot)
    }

    private func waitFor(_ description: String, seconds: Int = 3,
                         condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(8))
        }
        _ = try XCTUnwrap(condition() ? true : nil, description, file: file, line: line)
    }

    func testCancelThreeOfNineStartFreshAndRestoreOriginals() async throws {
        let (env, _, session, snapshot) = try await setup()
        let engine = env.engine
        for index in 1...3 {
            try engine.captureNextManual()
            try await waitFor("Phiên lưu đúng lượt \(index)") { engine.committedShots.count == index && engine.state == .ready }
        }
        let originals = engine.committedShots
        env.bannerSessionID = session.id

        try engine.requestSessionCancellation()
        XCTAssertThrowsError(try engine.requestSessionCancellation())
        XCTAssertThrowsError(try engine.captureNextManual())
        env.requestNavigation(to: .library)
        XCTAssertEqual(env.route, .capture)
        engine.confirmSessionCancellation()
        engine.confirmSessionCancellation()
        XCTAssertNil(engine.cancellationPhase)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNil(env.bannerSessionID)
        XCTAssertEqual(env.lastCancelledCaptureID, session.id)
        let trash = try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: session.id))
        XCTAssertEqual(try env.trashRepo.list().count, 1)
        XCTAssertEqual(try env.sessions.getSession(id: session.id)?.status, .trashed)
        XCTAssertFalse(try env.sessions.listSessions().contains { $0.session.id == session.id })
        let trashedOriginals = env.layout.trashSessionsDir.appendingPathComponent(session.id).appendingPathComponent("Originals")
        for photo in originals.values {
            let filename = URL(fileURLWithPath: photo.relativePath).lastPathComponent
            XCTAssertEqual(Hashing.sha256Hex(fileURL: trashedOriginals.appendingPathComponent(filename)), photo.sha256)
        }

        let fresh = try engine.beginSession(snapshot: snapshot, mode: .manual, cameraID: nil,
                                            defaults: env.settings.sessionDefaultsSnapshot(), countdown: 0, interval: 0)
        XCTAssertNotEqual(fresh.id, session.id)
        XCTAssertEqual(engine.nextPendingIndex, 1)
        XCTAssertTrue(engine.committedShots.isEmpty)
        try env.trashService.restore(trash)
        let restored = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertEqual(restored.snapshot.id, snapshot.id)
        XCTAssertEqual(restored.currentRevisions().mapValues(\.id), originals.mapValues(\.id))
        XCTAssertEqual(restored.session.status, .paused)
        XCTAssertEqual(restored.missingIndices.min(), 4)
        XCTAssertEqual(engine.session?.id, fresh.id)
        XCTAssertTrue(try env.trashRepo.list().isEmpty)
    }

    func testCountdownHoldReturnsToRemainingTimeAndCanCancelWithoutPhotos() async throws {
        let (env, _, session, _) = try await setup(mode: .automatic, countdown: 2)
        let engine = env.engine
        try engine.startOrContinue()
        try await waitFor("Một giây còn lại") {
            engine.state == .countdown(remainingSeconds: 1, captureIndex: 1, kind: .normal)
        }
        try engine.requestSessionCancellation()
        let token = engine.timerTokenForTesting
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(engine.timerTokenForTesting, token)
        XCTAssertTrue(engine.committedShots.isEmpty)
        XCTAssertEqual(engine.state, .countdown(remainingSeconds: 1, captureIndex: 1, kind: .normal))
        engine.returnFromSessionCancellation()
        XCTAssertEqual(engine.state, .countdown(remainingSeconds: 1, captureIndex: 1, kind: .normal))
        try engine.requestSessionCancellation()
        engine.confirmSessionCancellation()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNotNil(try env.trashRepo.find(rootType: .session, rootID: session.id))
        XCTAssertTrue(try env.sessions.getDetail(sessionID: session.id)?.currentRevisions().isEmpty == true)
    }

    func testIntermissionHoldAndCameraDisconnectReturnPaused() async throws {
        let (env, camera, session, _) = try await setup(mode: .automatic, interval: 2)
        let engine = env.engine
        try engine.startOrContinue()
        try await waitFor("Còn một giây nghỉ trước lượt 2") { engine.state == .intermission(nextIndex: 2, remainingSeconds: 1) }
        try engine.requestSessionCancellation()
        try await Task.sleep(for: .milliseconds(1150))
        engine.returnFromSessionCancellation()
        XCTAssertEqual(engine.state, .intermission(nextIndex: 2, remainingSeconds: 1))
        try engine.requestSessionCancellation()
        camera.simulateDisconnect()
        try await Task.sleep(for: .milliseconds(80))
        engine.returnFromSessionCancellation()
        XCTAssertEqual(engine.state, .paused(reason: .cameraDisconnected, nextIndex: 2, kind: .normal))
        try engine.requestSessionCancellation()
        engine.returnFromSessionCancellation()
        XCTAssertEqual(engine.state, .paused(reason: .cameraDisconnected, nextIndex: 2, kind: .normal))
        XCTAssertEqual(try env.sessions.getSession(id: session.id)?.status, .paused)
    }

    func testLastInFlightShotWaitsForDecisionBeforeReviewOrTrash() async throws {
        for shouldCancel in [false, true] {
            let (env, _, session, _) = try await setup(frame: "Một ảnh lớn", mode: .automatic)
            let engine = env.engine
            try engine.startOrContinue()
            try await waitFor("Camera bắt đầu lượt cuối") { engine.state == .capturing(captureIndex: 1, kind: .normal) }
            try engine.requestSessionCancellation()
            if shouldCancel {
                engine.confirmSessionCancellation()
                XCTAssertEqual(engine.cancellationPhase, .waitingForShot)
                try await waitFor("Hoàn tất hủy") { engine.state == .idle }
                XCTAssertEqual(try env.sessions.getSession(id: session.id)?.status, .trashed)
            } else {
                try await waitFor("Đã lưu nhưng vẫn đang xác nhận") {
                    engine.committedShots.count == 1 && engine.state == .ready
                }
                XCTAssertEqual(engine.cancellationPhase, .confirming)
                XCTAssertFalse(engine.canAdoptSession)
                engine.returnFromSessionCancellation()
                XCTAssertEqual(engine.state, .reviewing)
                XCTAssertFalse(engine.canCancelSession)
                XCTAssertNil(try env.trashRepo.find(rootType: .session, rootID: session.id))
            }
            XCTAssertEqual(try env.sessions.getDetail(sessionID: session.id)?.currentRevisions().count, 1)
            XCTAssertFalse(env.coordinator.isSessionBusy(session.id).busy)
        }
    }

    func testTwoFailuresOfferDiscardAndRollbackPreservesPendingFile() async throws {
        let (env, _, session, _) = try await setup()
        let engine = env.engine
        try engine.captureNextManual()
        try await waitFor("Lưu ảnh đầu") { engine.state == .ready && engine.committedShots.count == 1 }
        let first = try XCTUnwrap(engine.committedShots[1])
        try env.db.run("""
            CREATE TRIGGER reject_capture_commit BEFORE INSERT ON photo_revisions
            BEGIN SELECT RAISE(ABORT, 'lỗi thử nghiệm lưu ảnh'); END
            """)
        try engine.captureNextManual()
        try await waitFor("Ảnh thứ hai chờ lưu") {
            if case .recoverableError = engine.state { return engine.hasPhotoToSave }
            return false
        }
        let intent = try XCTUnwrap(env.trashRepo.pendingIntents(opType: "savePhoto").first)
        let image = try JSONDecoder().decode(SafetySaveService.SavePhotoIntentPayload.self, from: Data(intent.payloadJSON.utf8))
        let source = try env.layout.absoluteURL(forRelativePath: image.intendedRelativePath)
        try engine.requestSessionCancellation()
        engine.confirmSessionCancellation()
        for _ in 0..<2 {
            await engine.retrySaveForSessionCancellation()
            guard case .saveFailed(_, 2) = engine.cancellationPhase else {
                return XCTFail("Phải hiện lại các lựa chọn sau lần lưu lỗi")
            }
        }

        engine.requestDiscardForSessionCancellation()
        guard case .confirmingDiscard(_, 2) = engine.cancellationPhase else {
            return XCTFail("Phải xác nhận riêng trước khi bỏ ảnh")
        }
        engine.returnFromSessionCancellation()
        guard case .saveFailed(_, 2) = engine.cancellationPhase else {
            return XCTFail("Quay lại từ xác nhận bỏ ảnh phải giữ các lựa chọn xử lý")
        }

        try env.db.run("""
            CREATE TRIGGER reject_capture_trash BEFORE INSERT ON trash_items
            BEGIN SELECT RAISE(ABORT, 'lỗi thử nghiệm chuyển phiên'); END
            """)
        engine.requestDiscardForSessionCancellation()
        engine.discardForSessionCancellation()
        guard case .saveFailed(_, 2) = engine.cancellationPhase else {
            return XCTFail("Chuyển phiên lỗi phải cho xử lý lại ảnh đang chờ")
        }
        XCTAssertEqual(Hashing.sha256Hex(fileURL: source), image.sha256)
        XCTAssertEqual(try env.trashRepo.getIntent(id: intent.id)?.status, .rollbackRequired)
        XCTAssertNil(try env.trashRepo.find(rootType: .session, rootID: session.id))
        XCTAssertTrue(engine.hasPhotoToSave)
        engine.returnFromSessionCancellation()
        XCTAssertNil(engine.cancellationPhase)
        XCTAssertTrue(engine.hasPhotoToSave)

        try env.db.run("DROP TRIGGER reject_capture_trash")
        try engine.requestSessionCancellation()
        engine.confirmSessionCancellation()
        engine.requestDiscardForSessionCancellation()
        engine.discardForSessionCancellation()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertFalse(engine.hasPhotoToSave)
        XCTAssertEqual(try env.trashRepo.getIntent(id: intent.id)?.status, .failed)
        let trash = try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: session.id))
        try env.trashService.restore(trash)
        let recovery = RecoveryService(db: env.db, layout: env.layout, sessions: env.sessions,
                                       trashRepo: env.trashRepo, trashService: env.trashService)
        let report = await recovery.runOnLaunch()
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.quarantinedFiles, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        XCTAssertEqual(detail.currentRevisions().mapValues(\.id), [1: first.id])
        XCTAssertEqual(Hashing.sha256Hex(fileURL: try env.sessions.fileURL(for: first)), first.sha256)
    }

    func testAlreadyCommittedPhotoSurvivesDiscardAndRetryCanFinishCancellation() async throws {
        for useRetry in [false, true] {
            let (env, _, session, _) = try await setup()
            let engine = env.engine
            try env.db.run("""
                CREATE TRIGGER reject_save_ack BEFORE UPDATE ON operation_intents
                WHEN NEW.op_type='savePhoto' AND NEW.status='committed'
                BEGIN SELECT RAISE(ABORT, 'lỗi thử nghiệm sau khi lưu bản ghi'); END
                """)
            try engine.captureNextManual()
            try await waitFor("Lỗi sau khi đã commit ảnh") {
                if case .recoverableError = engine.state { return engine.hasPhotoToSave }
                return false
            }
            let before = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id)?.currentRevisions()[1])
            try engine.requestSessionCancellation()
            engine.confirmSessionCancellation()
            try env.db.run("DROP TRIGGER reject_save_ack")
            if useRetry {
                await engine.retrySaveForSessionCancellation()
            } else {
                engine.requestDiscardForSessionCancellation()
                engine.discardForSessionCancellation()
            }
            XCTAssertEqual(engine.state, .idle)
            XCTAssertEqual(try env.sessions.getSession(id: session.id)?.status, .trashed)
            let after = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id)?.currentRevisions()[1])
            XCTAssertEqual(after.id, before.id)
            XCTAssertEqual(after.sha256, before.sha256)
            XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM photo_revisions"), 1)
            XCTAssertTrue(try env.trashRepo.pendingIntents(opType: "savePhoto").isEmpty)
        }
    }

    func testDiscardPhotoInMemoryWhenSaveJournalCouldNotBeCreated() async throws {
        let (env, _, session, _) = try await setup()
        let engine = env.engine
        try engine.captureNextManual()
        try await waitFor("Đã lưu ảnh 1") { engine.state == .ready && engine.committedShots.count == 1 }
        let first = try XCTUnwrap(engine.committedShots[1])

        try env.db.run("""
            CREATE TRIGGER reject_save_journal BEFORE INSERT ON operation_intents
            WHEN NEW.op_type='savePhoto'
            BEGIN SELECT RAISE(ABORT, 'lỗi thử nghiệm trước khi tạo nhật ký'); END
            """)
        try engine.captureNextManual()
        try await waitFor("Ảnh 2 chỉ còn trong bộ nhớ") {
            if case .recoverableError = engine.state { return engine.hasPhotoToSave }
            return false
        }
        XCTAssertTrue(try env.trashRepo.pendingIntents(opType: "savePhoto").isEmpty)
        try engine.requestSessionCancellation()
        engine.confirmSessionCancellation()
        engine.requestDiscardForSessionCancellation()
        engine.discardForSessionCancellation()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertFalse(engine.hasPhotoToSave)
        let item = try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: session.id))
        try env.trashService.restore(item)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: session.id)?.currentRevisions().mapValues(\.id),
                       [1: first.id])
        XCTAssertEqual(Hashing.sha256Hex(fileURL: try env.sessions.fileURL(for: first)), first.sha256)
    }

    func testStartupRollsBackBeforeCommitAndClearsOnlyCommittedDiscard() async throws {
        for phase in ["partial", "promoted", "committed"] {
            let (env, _, session, _) = try await setup()
            try env.layout.ensureSessionDirs(session.id)
            let request = UUID().uuidString
            let bytes = try ExportService.encode(cg: .createBlank(), format: .jpeg, quality: 90)
            let sourcePath = "Sessions/\(session.id)/Originals/\(request).jpg"
            let payload = SafetySaveService.SavePhotoIntentPayload(
                sessionID: session.id, captureIndex: 1, requestID: request,
                intendedRelativePath: sourcePath, tempRelativePath: sourcePath + ".partial",
                sha256: Hashing.sha256Hex(bytes))
            let save = try env.trashRepo.createIntent(opType: "savePhoto", rootID: session.id,
                payloadJSON: String(decoding: JSONEncoder().encode(payload), as: UTF8.self))
            let itemID = UUID().uuidString
            let trashIntent = try env.trashRepo.createIntent(opType: "trash", rootID: session.id, payloadJSON: """
                {"itemID":"\(itemID)","rootType":"session","captureCancellation":true,"discardedCapture":{"originalPaths":["\(sourcePath)","\(sourcePath).partial"]}}
                """)
            let stage = env.layout.trashStagingDir.appendingPathComponent("capture-discard-\(trashIntent.id)")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            let suffix = phase == "partial" ? ".partial" : ""
            let stagedFile = stage.appendingPathComponent(request + ".jpg" + suffix)
            try bytes.write(to: stagedFile)

            if phase == "committed" {
                // The user already restored the session before shutdown. Cleanup must still finish.
                try env.trashRepo.updateIntent(id: trashIntent.id, status: .committed)
                try env.trashRepo.updateIntent(id: save.id, status: .failed)
            } else {
                try FileManager.default.moveItem(at: env.layout.sessionDir(session.id),
                    to: env.layout.trashSessionsDir.appendingPathComponent(session.id))
                do {
                    _ = try await env.safetySave.savePhoto(
                        sessionID: session.id, captureIndex: 1, payloadData: bytes, requestID: request,
                        width: 64, height: 64, orientation: 1, codec: "jpeg", colorProfile: nil)
                    XCTFail("Phiên phải phục hồi vị trí tệp trước khi ghi tiếp")
                } catch {}
                XCTAssertFalse(FileManager.default.fileExists(atPath: env.layout.sessionDir(session.id).path))
                XCTAssertNil(try env.sessions.latestRecoverableSession())
                XCTAssertThrowsError(try env.trashService.trashSession(sessionID: session.id))
            }
            let recovery = RecoveryService(db: env.db, layout: env.layout, sessions: env.sessions,
                                           trashRepo: env.trashRepo, trashService: env.trashService)
            let report = await recovery.runOnLaunch()
            XCTAssertTrue(report.issues.isEmpty, "\(phase) \(report.issues)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
            XCTAssertNil(try env.trashRepo.find(rootType: .session, rootID: session.id))
            let restored = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
            XCTAssertEqual(restored.session.status, .paused)
            if phase == "promoted" {
                let photo = try XCTUnwrap(restored.currentRevisions()[1])
                XCTAssertEqual(photo.captureRequestID, request)
                XCTAssertEqual(Hashing.sha256Hex(fileURL: try env.sessions.fileURL(for: photo)), payload.sha256)
            } else {
                XCTAssertTrue(restored.currentRevisions().isEmpty)
                XCTAssertEqual(report.quarantinedFiles, phase == "partial" ? 1 : 0)
            }
            XCTAssertEqual(try env.trashRepo.getIntent(id: trashIntent.id)?.status,
                           phase == "committed" ? .committed : .failed)
        }
    }

    func testKioskCancellationBlocksExitAndReturnsToCaptureSetup() async throws {
        let (env, _, session, _) = try await setup()
        env.showFullscreen = true
        let captureVM = CaptureViewModel(env: env)
        let kiosk = FullscreenViewModel(env: env, captureVM: captureVM)
        kiosk.step = .live
        captureVM.plannedCaptureCount = 9
        try env.engine.requestSessionCancellation()
        kiosk.exitFullscreenRequested()
        XCTAssertFalse(kiosk.exitRequested)
        XCTAssertTrue(env.showFullscreen)
        env.engine.confirmSessionCancellation()
        XCTAssertEqual(env.lastCancelledCaptureID, session.id)
        kiosk.returnToCaptureSetupAfterCancellation()
        XCTAssertEqual(kiosk.step, .captureSetup)
        XCTAssertEqual(captureVM.plannedCaptureCount, 9)
        XCTAssertTrue(env.showFullscreen)
        kiosk.exitFullscreenRequested()
        XCTAssertFalse(env.showFullscreen)
    }

}
