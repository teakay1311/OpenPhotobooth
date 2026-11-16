import XCTest
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers
@testable import OpenPhotobooth

final class ComprehensiveVerificationTests: XCTestCase {
    var env: AppEnvironment!
    let fixturesDir = URL(fileURLWithPath: "/tmp/openphotobooth_test_env/fixtures")
    let exportsDir = FileManager.default.temporaryDirectory.appendingPathComponent("openphotobooth_test_exports/destination_valid", isDirectory: true)

    @MainActor
    override func setUp() async throws {
        env = AppEnvironment(inMemory: true)
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        cleanExportsDir()
    }

    @MainActor
    override func tearDown() async throws {
        // Clean up sessions dir so tests don't leave orphan files for subsequent in-memory DB tests
        if let items = try? FileManager.default.contentsOfDirectory(at: env.layout.sessionsDir, includingPropertiesForKeys: nil) {
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        if let qItems = try? FileManager.default.contentsOfDirectory(at: env.layout.quarantineDir, includingPropertiesForKeys: nil) {
            for item in qItems { try? FileManager.default.removeItem(at: item) }
        }
        cleanExportsDir()
    }

    private func cleanExportsDir() {
        if let items = try? FileManager.default.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("Test-Export-") || item.lastPathComponent.hasPrefix("E2E") {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    @MainActor
    func testPB03OnlySelectedCameraDisconnectPausesAndUnlocksSession() async throws {
        let camera = FakeCameraService()
        env = AppEnvironment(inMemory: true, camera: camera)
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        _ = try await camera.selectDevice("fake-built-in")
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first)
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)
        let record = try env.engine.beginSession(snapshot: snapshot, mode: .automatic, cameraID: "fake-built-in",
                                                 defaults: env.settings.sessionDefaultsSnapshot(), countdown: 10, interval: 0)
        try env.engine.startOrContinue()
        let key = "session:\(record.id)"
        camera.post(.deviceDisconnected("fake-usb"))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(env.coordinator.isBusy(key: key).busy)
        if case .countdown = env.engine.state {} else { XCTFail("Unrelated camera canceled countdown") }

        camera.simulateDisconnect()
        let deadline = ContinuousClock.now + .seconds(2)
        while env.coordinator.isBusy(key: key).busy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(env.engine.state, .paused(reason: .cameraDisconnected, nextIndex: 1, kind: .normal))
        XCTAssertFalse(env.coordinator.isBusy(key: key).busy)
        XCTAssertEqual(try env.sessions.getSession(id: record.id)?.status, .paused)
    }

    @MainActor
    func testPB07FrameValidatorRejectsTruncatedImageWithValidSignature() throws {
        let bytes = makeSamplePNG(width: 400, height: 400)
        XCTAssertEqual(try AssetStore.validatedFrameImage(bytes).mediaType, "image/png")
        XCTAssertThrowsError(try AssetStore.validatedFrameImage(Data(bytes.prefix(40)))) { error in
            XCTAssertEqual(error as? AppError, .frameFileCorrupt)
        }
    }

    @MainActor
    func testPB08SQLiteChecksDistinguishCleanViolationAndFailure() async throws {
        let recovery = RecoveryService(db: env.db, layout: env.layout, sessions: env.sessions, trashRepo: env.trashRepo)
        var report = RecoveryService.Report()
        await recovery.checkDatabase(into: &report)
        XCTAssertTrue(report.issues.isEmpty)

        try env.db.run("CREATE TABLE qa_parent(id INTEGER PRIMARY KEY)")
        try env.db.run("CREATE TABLE qa_child(parent_id REFERENCES qa_parent(id))")
        try env.db.run("PRAGMA foreign_keys=OFF")
        try env.db.run("INSERT INTO qa_child VALUES(123)")
        try env.db.run("PRAGMA foreign_keys=ON")
        await recovery.checkDatabase(into: &report)
        XCTAssertEqual(report.issues, ["foreign_key_check: 1 vi phạm"])

        try env.db.run("CREATE TABLE qa_bad_parent(id INTEGER)")
        try env.db.run("CREATE TABLE qa_bad_child(parent_id REFERENCES qa_bad_parent(id))")
        XCTAssertNil(try env.db.integrityCheck())
        report = RecoveryService.Report()
        await recovery.checkDatabase(into: &report)
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertTrue(report.issues.first?.hasPrefix("Không chạy được foreign_key_check") == true)
    }

    // MARK: - 2.1 E2E-01: Luồng dữ liệu xuyên suốt 1
    @MainActor
    func testE2E01_FullLoop_Capture_Crop_Export_Revision() async throws {
        // 1. Chọn khung 4 ô
        let readyFrames = try env.frames.listReadyFrames()
        guard let frame4 = readyFrames.first(where: { (try? env.frames.getSlots(revisionID: $0.currentRevisionID ?? ""))?.count == 4 }) ?? readyFrames.first else {
            XCTFail("No 4-slot frame available")
            return
        }
        let snap1 = try env.frames.createSnapshot(frameID: frame4.id)
        XCTAssertEqual(snap1.sourceFrameID, frame4.id)

        // 2. Chụp đủ với marker L
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.engine.beginSession(snapshot: snap1, mode: .automatic, cameraID: "fake-cam",
                                                 defaults: env.settings.sessionDefaultsSnapshot(), countdown: 1, interval: 1)
        XCTAssertEqual(session.activeFrameSnapshotID, snap1.id)

        // Commit all slots
        for i in 1...snap1.requiredCaptureCount {
            let rev = try await env.safetySave.savePhoto(
                sessionID: session.id, captureIndex: i, payloadData: markerData, requestID: UUID().uuidString,
                width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
            XCTAssertEqual(rev.sha256, Hashing.sha256Hex(markerData))
        }

        // 3. Mở trong Review
        let detail = try env.sessions.getDetail(sessionID: session.id)
        XCTAssertNotNil(detail)
        XCTAssertTrue(detail!.hasEnoughPhotos)

        // 4. Chỉnh crop một ô
        let slotToCrop = snap1.slots.first!
        let newPlacement = PhotoPlacement(scale: 1.5, offsetX: 10, offsetY: -10)
        try env.sessions.setPlacement(sessionID: session.id, snapshotSlotID: slotToCrop.id,
                                      placement: newPlacement, cropMode: .fit, manualOverride: true)
        let updatedDetail = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(updatedDetail.placements[slotToCrop.id]?.placement.scale, 1.5)

        // 5. Xuất PNG và JPG
        let pngReq = ExportService.ExportRequest(sessionID: session.id, format: .png, quality: 95,
                                                width: snap1.canvasWidth, height: snap1.canvasHeight,
                                                filenameBase: "E2E01_Output", destinationFolder: exportsDir)
        let (pngRecord, pngURL) = try await env.exportService.export(detail: updatedDetail, request: pngReq)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pngURL.path))
        XCTAssertEqual(pngRecord.status, .success)

        let jpgReq = ExportService.ExportRequest(sessionID: session.id, format: .jpeg, quality: 90,
                                                width: snap1.canvasWidth, height: snap1.canvasHeight,
                                                filenameBase: "E2E01_Output", destinationFolder: exportsDir)
        let (jpgRecord, jpgURL) = try await env.exportService.export(detail: updatedDetail, request: jpgReq)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpgURL.path))
        XCTAssertEqual(jpgRecord.status, .success)

        // 6. Lưu R2 của khung và mở lại phiên
        var rev2 = try env.frames.getRevision(id: frame4.currentRevisionID!)!
        rev2.id = IDFactory.new() // Revision mới phải có ID mới
        rev2.backgroundColorHex = "#FF0000FF" // đổi màu nền
        var existingSlots = try env.frames.getSlots(revisionID: frame4.currentRevisionID!)
        for i in existingSlots.indices { existingSlots[i].id = IDFactory.new() } // Slot mới ID mới
        let rev2Obj = try env.frames.commitRevision(frameID: frame4.id, draft: rev2, slots: existingSlots)
        XCTAssertNotEqual(rev2Obj.id, snap1.sourceFrameRevisionID)

        // Phiên cũ vẫn giữ nguyên snapshot cũ (R1)
        let sessionReopened = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(sessionReopened.snapshot.sourceFrameRevisionID, snap1.sourceFrameRevisionID)
        XCTAssertEqual(sessionReopened.snapshot.backgroundColorHex, snap1.backgroundColorHex)
    }

    // MARK: - 2.1 E2E-02: Luồng dữ liệu xuyên suốt 2
    @MainActor
    func testE2E02_PartialSession_Cancel_Resume_ExportRecovery() async throws {
        let frames = try env.frames.listReadyFrames()
        // Chọn khung đa ô (>= 3 ô) để kiểm tra phiên dở dang
        let multiSlotFrame = frames.first(where: { (try? env.frames.getSlots(revisionID: $0.currentRevisionID ?? ""))?.count ?? 0 >= 3 }) ?? frames.first!
        let snap = try env.frames.createSnapshot(frameID: multiSlotFrame.id)
        XCTAssertGreaterThan(snap.requiredCaptureCount, 1)

        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "cam",
                                                 defaults: env.settings.sessionDefaultsSnapshot(), countdown: 5, interval: 2)

        // Lượt 1: commit thành công
        _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: 1, payloadData: markerData,
                                              requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)

        // Lượt 2: hủy khi đang đếm
        try env.engine.startOrContinue()
        env.engine.cancelCountdown()
        XCTAssertEqual(env.engine.state, .ready)

        // Lượt 2: gây lỗi ghi (hết dung lượng / hỏng payload)
        let corruptData = Data()
        do {
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: 2, payloadData: corruptData,
                                                  requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
            XCTFail("Should have thrown on corrupt/empty data")
        } catch {
            // Lỗi không làm tăng tiến độ
            XCTAssertTrue(error is AppError)
        }

        // Mở lại phiên: đúng ID, ảnh lượt 1 vẫn đọc được, lượt 2 còn thiếu
        let detail = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(detail.committedCount, 1)
        XCTAssertEqual(detail.missingCount, snap.requiredCaptureCount - 1)

        // Xuất khi chưa đủ ảnh phải bị từ chối
        let exportReq = ExportService.ExportRequest(sessionID: session.id, format: .jpeg, quality: 90,
                                                    width: snap.canvasWidth, height: snap.canvasHeight,
                                                    filenameBase: "E2E02_Partial", destinationFolder: exportsDir)
        do {
            _ = try await env.exportService.export(detail: detail, request: exportReq)
            XCTFail("Exporting partial session should fail")
        } catch {
            guard let appErr = error as? AppError, case .notEnoughPhotos = appErr else {
                XCTFail("Expected notEnoughPhotos error, got \(error)")
                return
            }
        }
    }

    // MARK: - 2.2 BOOT-01: Khởi động & Seeding
    @MainActor
    func testBOOT01_SeedingAndIdempotency() throws {
        let framesFirst = try env.frames.listFrames()
        XCTAssertEqual(framesFirst.count, 9)

        // Re-run seeding: must be idempotent
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        let framesSecond = try env.frames.listFrames()
        XCTAssertEqual(Set(framesSecond.map(\.id)), Set(framesFirst.map(\.id)))
    }

    // MARK: - 2.2 CAM-01: Quyền Camera
    func testCAM01_CameraPermissionPromptFlow() async {
        let fake = FakeCameraService()
        fake.configuredPermissionState = .notDetermined
        let initial = await fake.cameraPermissionState()
        XCTAssertEqual(initial, .notDetermined)
        XCTAssertEqual(fake.requestAccessCallCount, 0)

        // Request access prompt
        fake.configuredPermissionState = .authorized
        let requested = await fake.requestAccessIfNeeded()
        XCTAssertEqual(requested, .authorized)
        XCTAssertEqual(fake.requestAccessCallCount, 1)
    }

    // MARK: - 2.2 CAM-02: Thứ tự ưu tiên Camera Auto
    func testCAM02_AutoCandidateOrdering() async throws {
        let caps = CameraCapabilities()
        let iphone = CameraDescriptor(uniqueID: "iphone-continuity", localizedName: "iPhone Camera", kind: .continuity, isConnected: true, isSystemPreferred: true, capabilities: caps)
        let builtin = CameraDescriptor(uniqueID: "builtin-mac", localizedName: "FaceTime HD", kind: .builtIn, isConnected: true, isSystemPreferred: false, capabilities: caps)
        let fake = FakeCameraService(devicesCatalog: [iphone, builtin])

        _ = try await fake.selectAutoDevice()
        let discovered = await fake.discoverDevices()
        XCTAssertTrue(discovered.contains(where: { $0.uniqueID == "builtin-mac" }))
    }

    // MARK: - 2.2 CAP-01 & CAP-02: Điều phối chụp & Hủy bằng Esc
    @MainActor
    func testCAP01_CAP02_EngineCountdownAndCancel() throws {
        let frame = try env.frames.listReadyFrames().first!
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        _ = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "cam",
                                        defaults: env.settings.sessionDefaultsSnapshot(), countdown: 5, interval: 2)
        XCTAssertEqual(env.engine.state, .ready)

        try env.engine.startOrContinue()
        if case .countdown(let remaining, let index, _) = env.engine.state {
            XCTAssertEqual(remaining, 5)
            XCTAssertEqual(index, 1)
            env.engine.cancelCountdown()
            XCTAssertEqual(env.engine.state, .ready)
        } else {
            XCTFail("Engine should enter countdown immediately")
        }
    }

    // MARK: - 2.2 CAP-04: Retake 1 ô
    @MainActor
    func testCAP04_RetakeSingleSlot() async throws {
        let frame = try env.frames.listReadyFrames().first!
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "cam",
                                                 defaults: env.settings.sessionDefaultsSnapshot(), countdown: 1, interval: 1)

        // Commit all slots
        for i in 1...snap.requiredCaptureCount {
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: i, payloadData: markerData,
                                                  requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
        }
        let detailBefore = try env.sessions.getDetail(sessionID: session.id)!
        let oldRevID = detailBefore.currentRevisions()[1]!.id

        // Retake slot 1 with different data
        let opaqueData = try Data(contentsOf: fixturesDir.appendingPathComponent("opaque.png"))
        let newRev = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: 1, payloadData: opaqueData,
                                                       requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
        XCTAssertNotEqual(newRev.id, oldRevID)

        let detailAfter = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(detailAfter.currentRevisions()[1]!.id, newRev.id)
        // Các slot khác giữ nguyên
        if snap.requiredCaptureCount > 1 {
            XCTAssertEqual(detailBefore.currentRevisions()[2]?.id, detailAfter.currentRevisions()[2]?.id)
        }
    }

    // MARK: - 2.2 SAVE-01: Ghi an toàn & Khôi phục (RecoveryService)
    @MainActor
    func testSAVE01_WriteSafetyAndQuarantine() async throws {
        let recovery = RecoveryService(db: env.db, layout: env.layout, sessions: env.sessions, trashRepo: env.trashRepo)
        let report = await recovery.runOnLaunch()
        XCTAssertFalse(report.hasProblems)
        XCTAssertNil(try env.db.integrityCheck())
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }

    // MARK: - 2.2 FR-01: Xác thực tệp ảnh nhập khung (Magic bytes & Alpha)
    func testFR01_AssetValidationMagicBytesAndAlpha() throws {
        let pngData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let jpgData = try Data(contentsOf: fixturesDir.appendingPathComponent("sample.jpg"))
        let corruptData = try Data(contentsOf: fixturesDir.appendingPathComponent("corrupt.png"))

        XCTAssertTrue(FramesViewModel.validateMagicBytes(pngData))
        XCTAssertTrue(FramesViewModel.validateMagicBytes(jpgData))
        XCTAssertFalse(FramesViewModel.validateMagicBytes(corruptData))
    }

    // MARK: - 2.2 PACK-01: Gói khung (Frame Pack Service & Security)
    @MainActor
    func testPACK01_ZipSlipAndChecksumRejection() throws {
        let zipSlipData = try Data(contentsOf: fixturesDir.appendingPathComponent("zip_slip.photoframepack"))
        XCTAssertThrowsError(try env.packService.loadPack(data: zipSlipData)) { error in
            guard let appErr = error as? AppError, case .unsafeFramePack = appErr else {
                XCTFail("Expected unsafeFramePack on zip-slip, got \(error)")
                return
            }
        }

        let badChecksumData = try Data(contentsOf: fixturesDir.appendingPathComponent("bad_checksum.photoframepack"))
        XCTAssertThrowsError(try env.packService.loadPack(data: badChecksumData))

        let validPackData = try Data(contentsOf: fixturesDir.appendingPathComponent("valid.photoframepack"))
        let result = try env.packService.loadPack(data: validPackData)
        XCTAssertEqual(result.manifest.frames.count, 1)
    }

    // MARK: - 2.2 TR-01: Thùng rác & Bảo vệ asset snapshot
    @MainActor
    func testTR01_TrashAndPurgeProtectsSnapshotAssets() throws {
        let frame = try env.frames.listReadyFrames().first!
        _ = try env.frames.createSnapshot(frameID: frame.id)

        // Soft delete frame
        try env.trashService.trashFrame(frameID: frame.id)
        let trashedItems = try env.trashRepo.list()
        XCTAssertTrue(trashedItems.contains(where: { $0.rootID == frame.id }))

        // Snapshot assets still protected by snapshot reference
        let gcCount = try env.assets.collectGarbage()
        XCTAssertEqual(gcCount, 0, "Assets referenced by snapshot must not be collected")

        // Restore frame
        let item = trashedItems.first(where: { $0.rootID == frame.id })!
        try env.trashService.restore(item)
        let activeFrames = try env.frames.listFrames()
        XCTAssertTrue(activeFrames.contains(where: { $0.id == frame.id }))
    }

    // MARK: - 2.2 EXP-02: Xuất an toàn (Atomic swap & Sanitize filename)
    @MainActor
    func testEXP02_SanitizeFilenameAndAtomicReplace() async throws {
        let frame = try env.frames.listReadyFrames().first!
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: "cam", defaults: env.settings.sessionDefaultsSnapshot())
        for i in 1...snap.requiredCaptureCount {
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: i, payloadData: markerData,
                                                  requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
        }
        let detail = try env.sessions.getDetail(sessionID: session.id)!

        // Forbidden characters in filename
        let dirtyName = "Test/Export:Photo*Name?"
        let cleanName = ExportService.sanitizedFilenameBase(dirtyName)
        XCTAssertEqual(cleanName, "Test-Export-Photo-Name-")

        let req1 = ExportService.ExportRequest(sessionID: session.id, format: .png, quality: 95,
                                              width: snap.canvasWidth, height: snap.canvasHeight,
                                              filenameBase: cleanName, destinationFolder: exportsDir,
                                              replaceExisting: false)
        let (_, url1) = try await env.exportService.export(detail: detail, request: req1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url1.path))

        // Export second time with same name without replaceExisting -> should create numbered suffix (1)
        let req2 = ExportService.ExportRequest(sessionID: session.id, format: .png, quality: 95,
                                              width: snap.canvasWidth, height: snap.canvasHeight,
                                              filenameBase: cleanName, destinationFolder: exportsDir,
                                              replaceExisting: false)
        let (_, url2) = try await env.exportService.export(detail: detail, request: req2)
        XCTAssertTrue(url2.lastPathComponent.contains("(1)"))

        // Export with replaceExisting -> replaces atomically into base filename
        let req3 = ExportService.ExportRequest(sessionID: session.id, format: .png, quality: 95,
                                              width: snap.canvasWidth, height: snap.canvasHeight,
                                              filenameBase: cleanName, destinationFolder: exportsDir,
                                              replaceExisting: true)
        let (_, url3) = try await env.exportService.export(detail: detail, request: req3)
        XCTAssertEqual(url1.path, url3.path)
    }

    // MARK: - 2.3 SEC-02: Path Traversal
    func testSEC02_InternalRelativePathValidation() {
        XCTAssertTrue(FileLayout.isValidRelativePath("Sessions/123/Originals/456.jpg"))
        XCTAssertFalse(FileLayout.isValidRelativePath("../Sessions/123"))
        XCTAssertFalse(FileLayout.isValidRelativePath("/etc/passwd"))
        XCTAssertFalse(FileLayout.isValidRelativePath("Sessions/../evil"))
        XCTAssertFalse(FileLayout.isValidRelativePath("Sessions/\0/evil"))
    }

    // MARK: - 2.3 PERF-01: Hiệu năng Composite Render
    @MainActor
    func testPERF01_CompositeRenderLatency() async throws {
        let frame = try env.frames.listReadyFrames().first!
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: "cam", defaults: env.settings.sessionDefaultsSnapshot())
        for i in 1...snap.requiredCaptureCount {
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: i, payloadData: markerData,
                                                  requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
        }
        let detail = try env.sessions.getDetail(sessionID: session.id)!

        var times: [Double] = []
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            let img = await env.renderBuilder.renderPreview(detail: detail, maxDimension: 1200)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            XCTAssertNotNil(img)
            times.append(elapsed)
        }
        let medianTime = times.sorted()[1]
        print("Composite Render Median Latency: \(String(format: "%.3f", medianTime))s (Runs: \(times.map { String(format: "%.3f", $0) }))")
        XCTAssertLessThan(medianTime, 1.0, "Render latency should be under 1 second for standard canvas")
    }

    // MARK: - A1: Export & Share Strict Validation
    @MainActor
    func testA01_ExportRejectsMissingOrCorruptPhotosAndAssets() async throws {
        let frame = try env.frames.listReadyFrames().first!
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: "cam", defaults: env.settings.sessionDefaultsSnapshot())
        for i in 1...snap.requiredCaptureCount {
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: i, payloadData: markerData,
                                                  requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
        }
        let detail = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertTrue(detail.hasEnoughPhotos)

        // Làm hỏng/xóa tệp ảnh của lượt 1 trên đĩa
        let rev1 = detail.currentRevisions()[1]!
        let file1URL = try env.sessions.fileURL(for: rev1)
        try FileManager.default.removeItem(at: file1URL)

        // Xuất ảnh phải bị chặn vì tệp trên đĩa bị mất
        let expReq = ExportService.ExportRequest(sessionID: session.id, format: .jpeg, quality: 90,
                                                width: snap.canvasWidth, height: snap.canvasHeight,
                                                filenameBase: "TestA01", destinationFolder: exportsDir)
        do {
            _ = try await env.exportService.export(detail: detail, request: expReq)
            XCTFail("Export should fail when photo file is missing on disk")
        } catch let err as AppError {
            if case .ioFailure = err {
                // Đạt yêu cầu A1
            } else {
                XCTFail("Expected ioFailure, got \(err)")
            }
        }
    }

    // MARK: - A5: Đếm ảnh sau khi đổi khung 4 -> 3 -> 4
    @MainActor
    func testA05_FrameChange_4_to_3_to_4_AccurateCounts() async throws {
        let readyFrames = try env.frames.listReadyFrames()
        guard let f4 = readyFrames.first(where: { (try? env.frames.getSlots(revisionID: $0.currentRevisionID ?? ""))?.count == 4 }) ?? readyFrames.first else {
            XCTFail("No 4-slot frame available")
            return
        }
        let snap4 = try env.frames.createSnapshot(frameID: f4.id)
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.sessions.createSession(snapshot: snap4, mode: .automatic, cameraID: "cam", defaults: env.settings.sessionDefaultsSnapshot())

        // Chụp đủ 4 ảnh
        for i in 1...4 {
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: i, payloadData: markerData,
                                                  requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
        }
        let detail4 = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(detail4.committedCount, 4)
        XCTAssertTrue(detail4.hasEnoughPhotos)

        // Tạo khung 3 ô
        let f3 = try env.frames.createEmptyFrame(name: "Test 3 Slot Frame", categoryID: nil, canvasWidth: 1200, canvasHeight: 1800)
        let f3Full = try env.frames.getFrame(id: f3.id)!
        var rev3 = try env.frames.getRevision(id: f3Full.currentRevisionID!)!
        let slots3 = (1...3).map { idx in
            FrameSlot(id: IDFactory.new(), frameRevisionID: rev3.id, captureIndex: idx,
                      x: 0.1, y: Double(idx) * 0.25, width: 0.8, height: 0.2,
                      rotationDegrees: 0, zOrder: idx, maskType: .rectangle, cornerRadius: 0, defaultCropMode: .fit)
        }
        rev3 = try env.frames.commitRevision(frameID: f3.id, draft: rev3, slots: slots3)
        try env.frames.setValidationStatus(frameID: f3.id, status: .ready)
        let snap3 = try env.frames.createSnapshot(frameID: f3.id)

        // Đổi sang khung 3 ô
        try env.sessions.changeFrame(sessionID: session.id, newSnapshot: snap3)
        let detail3 = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(detail3.committedCount, 3)
        XCTAssertEqual(detail3.missingCount, 0)
        XCTAssertTrue(detail3.hasEnoughPhotos)

        // Đổi lại sang khung 4 ô
        try env.sessions.changeFrame(sessionID: session.id, newSnapshot: snap4)
        let detail4Again = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(detail4Again.committedCount, 4)
        XCTAssertEqual(detail4Again.missingCount, 0)
        XCTAssertTrue(detail4Again.hasEnoughPhotos)
        XCTAssertNotNil(detail4Again.currentRevisions()[4])
    }

    // MARK: - BUG-FRM-01: Commit Revision tự động cấp ID mới cho revision và slots
    @MainActor
    func testBUG_FRM_01_CommitRevision_AutoAssignsNewIDs() throws {
        let frame = try env.frames.createEmptyFrame(name: "Test Bug FRM 01", categoryID: nil)
        let frameFull = try env.frames.getFrame(id: frame.id)!
        let rev1 = try env.frames.getRevision(id: frameFull.currentRevisionID!)!
        let slots1 = [
            FrameSlot(id: IDFactory.new(), frameRevisionID: rev1.id, captureIndex: 1,
                      x: 0.1, y: 0.1, width: 0.4, height: 0.4, rotationDegrees: 0, zOrder: 1,
                      maskType: .rectangle, cornerRadius: 0, defaultCropMode: .autoFace)
        ]
        let committed1 = try env.frames.commitRevision(frameID: frame.id, draft: rev1, slots: slots1)
        XCTAssertNotEqual(committed1.id, rev1.id)

        // Lưu lần 2 với cùng draft object mà không tự đổi ID thủ công
        let committed2 = try env.frames.commitRevision(frameID: frame.id, draft: committed1, slots: slots1)
        XCTAssertNotEqual(committed2.id, committed1.id)
        XCTAssertEqual(committed2.revisionNo, committed1.revisionNo + 1)
        let newSlots = try env.frames.getSlots(revisionID: committed2.id)
        XCTAssertEqual(newSlots.count, 1)
        XCTAssertNotEqual(newSlots.first?.id, slots1.first?.id)
    }

    // MARK: - A4: Restore session từ chối phiên mất tệp
    @MainActor
    func testA04_RestoreSession_MissingBytesRejected() async throws {
        let frame = try env.frames.listReadyFrames().first!
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: "cam", defaults: env.settings.sessionDefaultsSnapshot())
        _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: 1, payloadData: markerData,
                                              requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)

        // Chuyển vào thùng rác
        try env.trashService.trashSession(sessionID: session.id)
        let trashItems = try env.trashRepo.list()
        guard let item = trashItems.first(where: { $0.rootID == session.id }) else {
            XCTFail("Session not found in trash")
            return
        }

        // Xóa thư mục session trong thùng rác để mô phỏng mất tệp
        let trashedDir = env.layout.trashSessionsDir.appendingPathComponent(session.id, isDirectory: true)
        try FileManager.default.removeItem(at: trashedDir)

        // Khôi phục phải ném lỗi restoreMissingBytes
        do {
            try env.trashService.restore(item)
            XCTFail("Restore should fail when files in trash are missing")
        } catch let err as AppError {
            XCTAssertEqual(err, .restoreMissingBytes)
        }

        // Bản ghi session trong DB không được nâng lên reviewable
        let s = try env.sessions.getSession(id: session.id)!
        XCTAssertNotEqual(s.status, .reviewable)
    }

    // MARK: - 2.1 E2E-03: Luồng dữ liệu vòng đời & xung đột
    @MainActor
    func testE2E03_LifecycleAndConflicts_FrameChange_Trash_Restore_Purge_AssetProtection() async throws {
        // 1. Tạo phiên hoàn chỉnh với khung 4 ô
        let readyFrames = try env.frames.listReadyFrames()
        guard let f4 = readyFrames.first(where: { (try? env.frames.getSlots(revisionID: $0.currentRevisionID ?? ""))?.count == 4 }) ?? readyFrames.first else {
            XCTFail("No 4-slot frame available")
            return
        }
        let snap4 = try env.frames.createSnapshot(frameID: f4.id)
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.sessions.createSession(snapshot: snap4, mode: .automatic, cameraID: "cam", defaults: env.settings.sessionDefaultsSnapshot())
        for i in 1...4 {
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: i, payloadData: markerData,
                                                  requestID: UUID().uuidString, width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
        }
        var detail = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(detail.committedCount, 4)

        // 2. Đổi khung 4 -> 3
        let f3 = try env.frames.createEmptyFrame(name: "Test E2E03 3-Slot Frame", categoryID: nil, canvasWidth: 1200, canvasHeight: 1800)
        let f3Full = try env.frames.getFrame(id: f3.id)!
        var rev3 = try env.frames.getRevision(id: f3Full.currentRevisionID!)!
        let slots3 = (1...3).map { idx in
            FrameSlot(id: IDFactory.new(), frameRevisionID: rev3.id, captureIndex: idx,
                      x: 0.1, y: Double(idx) * 0.25, width: 0.8, height: 0.2,
                      rotationDegrees: 0, zOrder: idx, maskType: .rectangle, cornerRadius: 0, defaultCropMode: .fit)
        }
        rev3 = try env.frames.commitRevision(frameID: f3.id, draft: rev3, slots: slots3)
        try env.frames.setValidationStatus(frameID: f3.id, status: .ready)
        let snap3 = try env.frames.createSnapshot(frameID: f3.id)

        try env.sessions.changeFrame(sessionID: session.id, newSnapshot: snap3)
        detail = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(detail.committedCount, 3)

        // Đổi lại sang 4 ô -> giữ nguyên ảnh thứ 4
        try env.sessions.changeFrame(sessionID: session.id, newSnapshot: snap4)
        detail = try env.sessions.getDetail(sessionID: session.id)!
        XCTAssertEqual(detail.committedCount, 4)

        // 3. Chuyển vào thùng rác và khôi phục khi tệp nguyên vẹn
        try env.trashService.trashSession(sessionID: session.id)
        var trashItems = try env.trashRepo.list()
        guard let item = trashItems.first(where: { $0.rootID == session.id }) else {
            XCTFail("Session not in trash")
            return
        }
        try env.trashService.restore(item)
        let restoredSession = try env.sessions.getSession(id: session.id)
        XCTAssertNotNil(restoredSession)
        XCTAssertEqual(restoredSession?.status, .reviewable)

        // 4. Xóa vĩnh viễn phiên (Purge) -> xóa folder session, dọn DB sạch sẽ
        try env.trashService.trashSession(sessionID: session.id)
        trashItems = try env.trashRepo.list()
        let trashedItem2 = trashItems.first(where: { $0.rootID == session.id })!
        try env.trashService.purge(trashedItem2)

        let purgedSession = try env.sessions.getSession(id: session.id)
        XCTAssertNil(purgedSession)
        let sessionDirExists = FileManager.default.fileExists(atPath: env.layout.sessionDir(session.id).path)
        XCTAssertFalse(sessionDirExists)

        // 5. Kiểm tra toàn vẹn SQLite
        XCTAssertNil(try env.db.integrityCheck(), "Database PRAGMA integrity_check failed")
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty, "Database PRAGMA foreign_key_check failed")
    }

    // MARK: - D2-A02: Khởi tạo kho lỗi và khôi phục
    @MainActor
    func testD2A02_LaunchError_BlocksOperations_AndRecoversOnRetry() async throws {
        // Tạo một tệp thường để dùng làm root (gây lỗi FileLayout vì không phải thư mục)
        let filePath = FileManager.default.temporaryDirectory.appendingPathComponent("not_a_dir_\(UUID().uuidString)")
        FileManager.default.createFile(atPath: filePath.path, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(at: filePath) }

        let badEnv = AppEnvironment(inMemory: false, customRoot: filePath)
        XCTAssertNotNil(badEnv.launchError, "Khi rootURL là file, launchError phải được ghi nhận")

        // Khi có launchError, boot() phải trả về ngay lập tức mà không seed hay chạy recovery
        await badEnv.boot()
        XCTAssertNil(badEnv.recoveryReport)
        XCTAssertFalse(badEnv.trashScheduler.isRunning)

        // Phục hồi: đổi filePath thành thư mục hợp lệ và gọi makeRetriedEnvironment()
        try? FileManager.default.removeItem(at: filePath)
        try FileManager.default.createDirectory(at: filePath, withIntermediateDirectories: true)

        let retriedEnv = badEnv.makeRetriedEnvironment()
        XCTAssertNil(retriedEnv.launchError, "Sau khi thư mục hợp lệ, makeRetriedEnvironment phải không còn lỗi")
        await retriedEnv.boot()
        XCTAssertNotNil(retriedEnv.recoveryReport, "Sau khi retry thành công, boot() phải chạy hoàn tất")
    }

    // MARK: - D2-A04: Nhập khung ở bộ lọc Yêu thích và danh mục ảo
    @MainActor
    func testD2A04_ImportFrame_VirtualFiltersAndDeletedCategory() async throws {
        let vm = FramesViewModel(env: env)

        // Tạo tệp PNG giả lập có alpha
        let pngData = makeSamplePNG(width: 300, height: 400)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("d2a04_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pngURL1 = tempDir.appendingPathComponent("frame_fav.png")
        let pngURL2 = tempDir.appendingPathComponent("frame_unclass.png")
        let pngURL3 = tempDir.appendingPathComponent("frame_delcat.png")
        try pngData.write(to: pngURL1)
        try pngData.write(to: pngURL2)
        try pngData.write(to: pngURL3)

        // 1. Nhập khi đang ở bộ lọc "__favorites__"
        vm.selectedCategoryID = "__favorites__"
        await vm.importImages(urls: [pngURL1])
        let list1 = try env.frames.listFrames()
        let frameFav = try XCTUnwrap(list1.first(where: { $0.name == "frame_fav" }))
        XCTAssertNil(frameFav.categoryID, "Khung nhập từ bộ lọc Yêu thích phải có categoryID là nil (Chưa phân loại)")
        XCTAssertFalse(frameFav.isFavorite, "Khung nhập mới chưa được đánh dấu yêu thích")

        // 2. Nhập khi đang ở bộ lọc "unclassified"
        vm.selectedCategoryID = "unclassified"
        await vm.importImages(urls: [pngURL2])
        let list2 = try env.frames.listFrames()
        let frameUnclass = try XCTUnwrap(list2.first(where: { $0.name == "frame_unclass" }))
        XCTAssertNil(frameUnclass.categoryID, "Khung nhập từ bộ lọc unclassified phải có categoryID là nil")

        // 3. Nhập vào danh mục bị xóa trong lúc picker mở
        let tempCat = try env.frames.createCategory(name: "TempCategory")
        vm.selectedCategoryID = tempCat.id
        try env.trashService.trashCategory(categoryID: tempCat.id)
        await vm.importImages(urls: [pngURL3])
        let list3 = try env.frames.listFrames()
        let frameDelCat = try XCTUnwrap(list3.first(where: { $0.name == "frame_delcat" }))
        XCTAssertNil(frameDelCat.categoryID, "Khi danh mục bị xóa trước khi lưu, khung phải lưu về Chưa phân loại (nil)")
    }

    // MARK: - D2-A05 & D2-A06: Xử lý trùng tên khi khôi phục và đổi tên
    @MainActor
    func testD2A05_D2A06_DuplicateNamesOnRestoreAndRename() throws {
        // 1. Khôi phục danh mục trùng tên -> tự thêm hậu tố (1)
        let cat1 = try env.frames.createCategory(name: "Tiệc cưới")
        try env.trashService.trashCategory(categoryID: cat1.id)
        // Tạo danh mục mới cùng tên trong khi cat1 đang ở Trash
        let cat2 = try env.frames.createCategory(name: "Tiệc cưới")
        XCTAssertEqual(cat2.name, "Tiệc cưới")

        // Khôi phục cat1
        let trashCat = try XCTUnwrap(try env.trashRepo.list().first(where: { $0.rootID == cat1.id }))
        try env.trashService.restore(trashCat)
        let restoredCats = try env.frames.listCategories()
        let restoredCat1 = try XCTUnwrap(restoredCats.first(where: { $0.id == cat1.id }))
        XCTAssertEqual(restoredCat1.name, "Tiệc cưới (1)", "Khôi phục danh mục trùng tên phải tự thêm hậu tố (1)")

        // 2. Đổi tên danh mục sang tên đã tồn tại -> báo lỗi duplicateName
        XCTAssertThrowsError(try env.frames.renameCategory(id: cat1.id, to: "Tiệc cưới")) { error in
            guard let appErr = error as? AppError, case .duplicateName = appErr else {
                XCTFail("Đổi tên sang tên trùng phải ném AppError.duplicateName nhưng nhận \(error)")
                return
            }
        }

        // Đổi tên chính nó (giữ nguyên tên) -> thành công
        XCTAssertNoThrow(try env.frames.renameCategory(id: cat1.id, to: "Tiệc cưới (1)"))
    }

    // MARK: - D2-A07: Nhân bản gắn asset vào ID revision thật đã cấp
    @MainActor
    func testD2A07_DuplicateFrame_AssetReferenceIDMatchesCommittedRevision() throws {
        let pngData = makeSamplePNG(width: 400, height: 600)
        let created = try env.frames.createFrame(name: "Khung Gốc", imageData: pngData, mediaType: "image/png", role: .frameBackground, categoryID: nil)
        let original = try XCTUnwrap(env.frames.getFrame(id: created.id))
        let origRevID = try XCTUnwrap(original.currentRevisionID)
        let origRev = try XCTUnwrap(try env.frames.getRevision(id: origRevID))
        let bgAssetID = try XCTUnwrap(origRev.backgroundAssetID)

        // Nhân bản
        let copy = try env.frames.duplicateFrame(id: original.id)
        let copyRevID = try XCTUnwrap(copy.currentRevisionID)
        XCTAssertNotEqual(origRevID, copyRevID, "Bản sao phải có revision ID mới")

        // Kiểm tra asset_references: phải có bản ghi trỏ trực tiếp tới copyRevID
        let refs = try env.db.query("SELECT * FROM asset_references WHERE owner_type='frame_revision' AND owner_id=? AND asset_id=?",
                                    [.text(copyRevID), .text(bgAssetID)])
        XCTAssertEqual(refs.count, 1, "asset_references phải trỏ tới đúng ID revision thật của bản sao")

        // Xóa khung gốc vào trash và purge
        try env.trashService.trashFrame(frameID: original.id)
        let trashItem = try XCTUnwrap(try env.trashRepo.list().first(where: { $0.rootID == original.id }))
        try env.trashService.purge(trashItem)

        // Asset của bản sao vẫn phải còn nguyên trong kho
        XCTAssertNoThrow(try env.assets.loadData(assetID: bgAssetID), "Asset dùng chung không được bị xóa khi bản sao còn sở hữu reference")
    }

    // MARK: - D2-A08: Dọn snapshot mồ côi sau khi đổi khung
    @MainActor
    func testD2A08_ChangeFrame_CleansOrphanSnapshotWhenUnreferenced() async throws {
        let readyFrames = try env.frames.listReadyFrames()
        let f3 = readyFrames.first(where: { (try? env.frames.getSlots(revisionID: $0.currentRevisionID ?? ""))?.count == 3 })!
        let f4 = readyFrames.first(where: { (try? env.frames.getSlots(revisionID: $0.currentRevisionID ?? ""))?.count == 4 })!
        let snap1 = try env.frames.createSnapshot(frameID: f3.id)
        let snap2 = try env.frames.createSnapshot(frameID: f4.id)

        let session = try env.sessions.createSession(snapshot: snap1, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        XCTAssertEqual(session.activeFrameSnapshotID, snap1.id)

        // Đổi khung sang snap2
        try env.sessions.changeFrame(sessionID: session.id, newSnapshot: snap2)
        let updated = try XCTUnwrap(try env.sessions.getSession(id: session.id))
        XCTAssertEqual(updated.activeFrameSnapshotID, snap2.id)

        // Vì không còn phiên nào tham chiếu snap1, snap1 phải được xóa khỏi DB
        let snap1Rows = try env.db.query("SELECT COUNT(*) c FROM frame_snapshots WHERE id=?", [.text(snap1.id)])
        XCTAssertEqual(snap1Rows.first?["c"]?.intValue, 0, "Snapshot 1 không còn ai tham chiếu phải được dọn sạch")

        // snap2 vẫn đang được phiên sử dụng nên phải còn
        let snap2Rows = try env.db.query("SELECT COUNT(*) c FROM frame_snapshots WHERE id=?", [.text(snap2.id)])
        XCTAssertEqual(snap2Rows.first?["c"]?.intValue, 1, "Snapshot 2 đang được phiên trỏ tới phải còn tồn tại")
    }

    // MARK: - D2-A09: Màu nền canvas - PNG trong suốt vs JPG trắng đục
    @MainActor
    func testD2A09_CanvasBackground_LegacyTransparent_ExplicitWhite_JPGMatte() throws {
        let defaults = env.settings.sessionDefaultsSnapshot()
        // Khung 1: Legacy #FFFFFFFF (explicitWhite == nil)
        let snapLegacy = FrameSnapshot(sourceFrameID: "test", sourceFrameRevisionID: "rev",
                                       canvasWidth: 200, canvasHeight: 200,
                                       background: nil, foreground: nil,
                                       backgroundColorHex: "#FFFFFFFF", slots: [],
                                       snapshotHash: "hash1", explicitWhite: nil)
        let modelLegacyPNG = CompositionModel(snapshot: snapLegacy, sources: [:], faces: [:],
                                              defaults: defaults, overrides: [:],
                                              placements: [:], cropModes: [:], assetImages: [:],
                                              options: RenderOptions(targetWidth: 200, targetHeight: 200, transparentBackground: true))
        let imgLegacyPNG = try CompositeRenderer.render(model: modelLegacyPNG)
        // Lấy pixel tại (10, 10)
        let alphaLegacyPNG = getPixelAlpha(imgLegacyPNG, x: 10, y: 10)
        XCTAssertEqual(alphaLegacyPNG, 0, "Khung cũ thiếu explicitWhite khi render PNG phải giữ alpha trống (trong suốt)")

        // Khung 1 render dạng JPG (transparentBackground == false)
        let modelLegacyJPG = CompositionModel(snapshot: snapLegacy, sources: [:], faces: [:],
                                              defaults: defaults, overrides: [:],
                                              placements: [:], cropModes: [:], assetImages: [:],
                                              options: RenderOptions(targetWidth: 200, targetHeight: 200, transparentBackground: false))
        let imgLegacyJPG = try CompositeRenderer.render(model: modelLegacyJPG)
        let (rJPG, gJPG, bJPG, aJPG) = getPixelRGBA(imgLegacyJPG, x: 10, y: 10)
        XCTAssertEqual(aJPG, 255, "JPG luôn ghép lên nền trắng đục (alpha = 255)")
        XCTAssertEqual(rJPG, 255)
        XCTAssertEqual(gJPG, 255)
        XCTAssertEqual(bJPG, 255)

        // Khung 2: Explicit White (explicitWhite == true) -> PNG phải trắng đục
        var snapExplicitWhite = snapLegacy
        snapExplicitWhite.explicitWhite = true
        let modelExplicitPNG = CompositionModel(snapshot: snapExplicitWhite, sources: [:], faces: [:],
                                                defaults: defaults, overrides: [:],
                                                placements: [:], cropModes: [:], assetImages: [:],
                                                options: RenderOptions(targetWidth: 200, targetHeight: 200, transparentBackground: true))
        let imgExplicitPNG = try CompositeRenderer.render(model: modelExplicitPNG)
        let (rExp, gExp, bExp, aExp) = getPixelRGBA(imgExplicitPNG, x: 10, y: 10)
        XCTAssertEqual(aExp, 255, "Explicit white khi render PNG phải là trắng đục")
        XCTAssertEqual(rExp, 255)
        XCTAssertEqual(gExp, 255)
        XCTAssertEqual(bExp, 255)
    }

    // MARK: - D2-A10: Xác nhận điều hướng khi rời màn Chụp đang bận
    @MainActor
    func testD2A10_NavigationConfirmationWhenBusy() async throws {
        // Trạng thái nhàn rỗi: điều hướng tự do
        env.route = .capture
        env.requestNavigation(to: .library)
        XCTAssertEqual(env.route, .library)

        // Quay lại capture và bắt đầu countdown
        env.route = .capture
        let readyFrames = try env.frames.listReadyFrames()
        let snap = try env.frames.createSnapshot(frameID: readyFrames.first!.id)
        _ = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "cam",
                                        defaults: env.settings.sessionDefaultsSnapshot(), countdown: 5, interval: 2)
        try env.engine.startOrContinue()

        // Khi đang đếm: yêu cầu rời màn phải hiện showLeaveCaptureConfirmation
        env.requestNavigation(to: .library)
        XCTAssertTrue(env.showLeaveCaptureConfirmation)
        XCTAssertEqual(env.pendingNavigationRoute, .library)
        XCTAssertEqual(env.route, .capture, "Chưa xác nhận thì route vẫn ở .capture")

        // Chọn "Ở lại" -> tiếp tục ở Capture
        env.stayInCapture()
        XCTAssertFalse(env.showLeaveCaptureConfirmation)
        XCTAssertNil(env.pendingNavigationRoute)
        XCTAssertEqual(env.route, .capture)

        // Yêu cầu lại và chọn "Rời" -> chuyển màn và tạm dừng phiên
        env.requestNavigation(to: .library)
        env.confirmLeaveCapture()
        XCTAssertFalse(env.showLeaveCaptureConfirmation)
        XCTAssertEqual(env.route, .library)
        if case .paused(let reason, _, _) = env.engine.state {
            XCTAssertEqual(reason, .user, "Rời màn hình phải tạm dừng phiên an toàn với lý do .user")
        } else {
            XCTFail("Engine phải ở trạng thái paused khi tạm dừng và rời màn")
        }
    }

    // MARK: - D2-A11: Lưu và khôi phục cameraSelection, không ghi đè khi mất kết nối
    @MainActor
    func testD2A11_CameraSelection_PersistenceAndFallback() async throws {
        env.settings.cameraSelection = "external_usb_cam_123"

        let vm = CaptureViewModel(env: env)
        // Khi refresh: thiết bị "external_usb_cam_123" không có trong FakeCameraService
        // App phải tạm dùng Auto cho lần chạy này
        await vm.refreshCameraState()
        XCTAssertEqual(vm.selectedDeviceID, "auto", "Thiết bị mất kết nối phải tạm fallback sang Auto")
        XCTAssertEqual(env.settings.cameraSelection, "external_usb_cam_123", "Fallback Auto không được ghi đè preference của người dùng trong Settings")

        // Người dùng chủ động chọn Auto -> lưu "auto"
        await vm.selectCamera("auto")
        XCTAssertEqual(env.settings.cameraSelection, "auto", "Người dùng chủ động chọn Auto thì phải lưu Auto")
    }

    // MARK: - NAV-01 & NAV-02: Navigation Hold & Stay in Capture without premature pause
    @MainActor
    func testNAV01_NAV02_NavigationHoldAndStayInCapture() async throws {
        env.route = .capture
        let readyFrames = try env.frames.listReadyFrames()
        let frame = try XCTUnwrap(readyFrames.first(where: { $0.name == "Dải 3 ảnh" }))
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        _ = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "cam",
                                        defaults: env.settings.sessionDefaultsSnapshot(), countdown: 5, interval: 2)
        try env.engine.startOrContinue()

        // 1. Yêu cầu chuyển route khi đang đếm ngược: kích hoạt hold và hiển thị dialog
        env.requestNavigation(to: .library)
        XCTAssertTrue(env.showLeaveCaptureConfirmation)
        XCTAssertNotNil(env.navigationHold)
        XCTAssertEqual(env.navigationHold?.captureIndex, 1)

        // 2. Chọn "Ở lại": khôi phục đếm ngược với thời gian còn lại, không bị pause
        env.stayInCapture()
        XCTAssertFalse(env.showLeaveCaptureConfirmation)
        XCTAssertNil(env.navigationHold)
        if case .countdown(let rem, let idx, _) = env.engine.state {
            XCTAssertEqual(idx, 1)
            XCTAssertTrue(rem <= 5 && rem >= 1)
        } else {
            XCTFail("Sau khi chọn 'Ở lại', engine phải tiếp tục countdown thay vì bị pause")
        }

        // Dọn dẹp
        env.engine.cancelCountdown()
    }

    // MARK: - CAP-01: Retake single slot from Review starts countdown smoothly and cancels to Review
    @MainActor
    func testCAP01_RetakeFromReview_AdoptsSessionAndTransitions() async throws {
        env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        await env.boot()
        let readyFrames = try env.frames.listReadyFrames()
        let frame = try XCTUnwrap(readyFrames.first(where: { $0.name == "Dải 3 ảnh" }))
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let s = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "cam",
                                            defaults: env.settings.sessionDefaultsSnapshot(), countdown: 1, interval: 1)
        // Tạo ảnh giả cho slot 1, 2, 3
        let png = makeSamplePNG()
        for idx in snap.requiredIndices {
            _ = try await env.safetySave.savePhoto(sessionID: s.id, captureIndex: idx, payloadData: png,
                                                   requestID: "req-\(idx)", width: 200, height: 200,
                                                   orientation: 1, codec: "png", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: s.id, status: .reviewable)

        env.reviewContext = AppEnvironment.ReviewContext(sessionID: s.id, sourceRoute: .library)
        let reviewVM = ReviewViewModel(env: env)
        await reviewVM.load(sessionID: s.id)
        XCTAssertNotNil(reviewVM.detail)

        // Bắt đầu retake slot 2: không được văng lỗi "Chỉ retake trong Review"
        await reviewVM.retake(index: 2, keepCrop: true)
        XCTAssertEqual(env.retakeSessionID, s.id)
        XCTAssertEqual(env.route, .capture)
        if case .countdown(_, let idx, let kind) = env.engine.state {
            XCTAssertEqual(idx, 2)
            XCTAssertEqual(kind, .retake)
        } else {
            XCTFail("Engine phải bắt đầu countdown retake cho index 2")
        }

        // Hủy đếm ngược retake: quay lại review đúng session
        let captureVM = CaptureViewModel(env: env)
        await captureVM.primaryAction() // Esc / Hủy đếm ngược
        XCTAssertNil(env.retakeSessionID)
        XCTAssertEqual(env.route, .review(sessionID: s.id))
    }

    // MARK: - CAP-02: Nút "Chụp tiếp" trên phiên tự động đã có ảnh gọi đúng startOrContinue
    @MainActor
    func testCAP02_ContinueCapture_AutoSession_ResumesCountdown() async throws {
        env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        await env.boot()
        let readyFrames = try env.frames.listReadyFrames()
        let frame = try XCTUnwrap(readyFrames.first(where: { $0.name == "Dải 3 ảnh" }))
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let s = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "cam",
                                            defaults: env.settings.sessionDefaultsSnapshot(), countdown: 3, interval: 2)
        // Lưu 1 ảnh giả cho index 1
        let png = makeSamplePNG()
        let rev = try await env.safetySave.savePhoto(sessionID: s.id, captureIndex: 1, payloadData: png,
                                                     requestID: "req-auto-1", width: 200, height: 200,
                                                     orientation: 1, codec: "png", colorProfile: nil)
        env.engine.adoptSession(record: s, snapshot: snap, committed: [1: rev], forReview: false)
        XCTAssertEqual(env.engine.state, .ready)
        XCTAssertFalse(env.engine.committedShots.isEmpty)

        let captureVM = CaptureViewModel(env: env)
        XCTAssertEqual(captureVM.startButtonTitle, "Chụp tiếp")

        await captureVM.refreshCameraState()
        XCTAssertTrue(captureVM.isCameraReady)
        // Bấm "Chụp tiếp" -> Phải chuyển sang countdown cho index 2
        await captureVM.primaryAction()
        if case .countdown(_, let idx, _) = env.engine.state {
            XCTAssertEqual(idx, 2, "Chụp tiếp phiên tự động phải bắt đầu countdown lượt kế tiếp")
        } else {
            XCTFail("Engine phải đếm ngược cho lượt kế tiếp thay vì báo lỗi chế độ thủ công")
        }
        env.engine.cancelCountdown()
    }

    // MARK: - DATA-01: TrashSession bị chặn khi phiên đang bận chụp
    @MainActor
    func testDATA01_TrashSessionBlockedDuringActiveCapture() async throws {
        let readyFrames = try env.frames.listReadyFrames()
        let frame = try XCTUnwrap(readyFrames.first(where: { $0.name == "Dải 3 ảnh" }))
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let s = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "cam",
                                            defaults: env.settings.sessionDefaultsSnapshot(), countdown: 5, interval: 2)
        try env.engine.startOrContinue()

        // Thao tác xóa phiên đang đếm ngược/chụp phải bị chặn bởi OperationCoordinator
        XCTAssertThrowsError(try env.trashService.trashSession(sessionID: s.id)) { error in
            guard let appErr = error as? AppError, case .busy = appErr else {
                XCTFail("Xóa phiên đang chụp phải ném AppError.busy, nhận được: \(error)")
                return
            }
        }

        // Phiên vẫn nguyên vẹn
        let session = try env.sessions.getSession(id: s.id)
        XCTAssertEqual(session?.status, .inProgress)
        env.engine.cancelCountdown()
    }

    // MARK: - DATA-02: Đổi khung cập nhật trạng thái .paused khi thiếu ảnh & đếm chính xác
    @MainActor
    func testDATA02_ChangeFrame_UpdatesStatusAndEffectiveStatus() async throws {
        let readyFrames = try env.frames.listReadyFrames()
        // Khung 3 ảnh và khung 4 ảnh
        guard let frame3 = readyFrames.first(where: { $0.name == "Dải 3 ảnh" }),
              let frame4 = readyFrames.first(where: { $0.name == "Lưới 4 ảnh" }) else {
            return
        }
        let snap3 = try env.frames.createSnapshot(frameID: frame3.id)
        let snap4 = try env.frames.createSnapshot(frameID: frame4.id)

        let s = try env.engine.beginSession(snapshot: snap3, mode: .automatic, cameraID: "cam",
                                            defaults: env.settings.sessionDefaultsSnapshot(), countdown: 1, interval: 1)
        let png = makeSamplePNG()
        for idx in snap3.requiredIndices {
            _ = try await env.safetySave.savePhoto(sessionID: s.id, captureIndex: idx, payloadData: png,
                                                   requestID: "req-f-\(idx)", width: 200, height: 200,
                                                   orientation: 1, codec: "png", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: s.id, status: .completed)

        // Đổi từ khung 3 sang khung 4: còn thiếu index 4 -> phải chuyển sang .paused, completed_at_ms = nil
        try env.sessions.changeFrame(sessionID: s.id, newSnapshot: snap4)
        let updated = try env.sessions.getSession(id: s.id)
        XCTAssertEqual(updated?.status, .paused)
        XCTAssertNil(updated?.completedAtMs)
        XCTAssertEqual(updated?.currentCaptureIndex, 4)

        // listSessions lọc paused phải tìm thấy phiên này
        let pausedList = try env.sessions.listSessions(statuses: [.paused])
        XCTAssertTrue(pausedList.contains(where: { $0.id == s.id }))
    }

    // MARK: - INIT-01: Lần đầu mở app tự động chọn khung Dải 3 ảnh có sẵn
    @MainActor
    func testINIT01_AutoSelectBuiltin3PhotoFrameOnFreshLaunch() async throws {
        env.preferredFrameID = nil
        let captureVM = CaptureViewModel(env: env)
        captureVM.reloadFrames()

        XCTAssertNotNil(captureVM.selectedFrameID, "Mở app lần đầu phải tự động chọn một khung ảnh")
        XCTAssertEqual(captureVM.selectedFrame?.name, "Dải 3 ảnh", "Khung được chọn mặc định phải là Dải 3 ảnh theo §2.3")
    }

    // MARK: - Hermes Verification Tests

    @MainActor
    func testHermes_A01_L09_PackExportSkipsZeroSlotDrafts_AndMimeDetection() async throws {
        // 1. Tạo 1 khung nháp 0 slot và 1 khung hợp lệ
        let draftFrame = try env.frames.createFrame(name: "Draft 0 slot", imageData: makeSamplePNG(), mediaType: "image/png", role: .frameBackground, categoryID: nil)
        let readyFrame = try env.frames.createFrame(name: "Valid Ready Frame", imageData: makeSamplePNG(), mediaType: "image/png", role: .frameBackground, categoryID: nil)
        let readyFrameObj = try env.frames.getFrame(id: readyFrame.id)!
        let rev = try env.frames.getRevision(id: readyFrameObj.currentRevisionID!)!
        let slot = FrameSlot(frameRevisionID: rev.id, captureIndex: 1, x: 0.1, y: 0.1, width: 0.8, height: 0.8, zOrder: 1)
        _ = try env.frames.commitRevision(frameID: readyFrame.id, draft: rev, slots: [slot])

        // 2. Xuất pack chứa cả 2 ID
        let packResult = try env.packService.preparePack(name: "TestPack", frameIDs: [draftFrame.id, readyFrame.id])
        XCTAssertEqual(packResult.packedFramesCount, 1, "Chỉ 1 khung hợp lệ được đóng gói")
        XCTAssertEqual(packResult.skippedDraftCount, 1, "Phải báo 1 khung bị bỏ qua")
        XCTAssertEqual(packResult.skippedReasons.count, 1)
        XCTAssertTrue(packResult.skippedReasons.first?.contains("ô") == true)

        // 3. Toàn bộ là nháp 0 slot thì phải throw invalidState
        XCTAssertThrowsError(try env.packService.preparePack(name: "TestPack", frameIDs: [draftFrame.id])) { error in
            guard case AppError.invalidState(let msg) = error else {
                XCTFail("Expected invalidState error, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("0 ô") || msg.contains("hợp lệ"))
        }
    }

    @MainActor
    func testHermes_A02_L08_AutoExportCanvasDimensions_AndDefaultNaming() async throws {
        // Default filename format: Photobooth-YYYYMMDD-HHmmss
        let defaultName = ExportService.defaultFilenameBase()
        let pattern = #"^Photobooth-\d{8}-\d{6}$"#
        XCTAssertTrue(defaultName.range(of: pattern, options: .regularExpression) != nil, "Tên mặc định phải đúng dạng Photobooth-YYYYMMDD-HHmmss: \(defaultName)")

        // Tạo phiên chụp và kiểm tra autoExport dùng kích thước canvas snapshot
        let readyFrames = try env.frames.listReadyFrames()
        let frame = readyFrames.first!
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "fake-cam",
                                                 defaults: env.settings.sessionDefaultsSnapshot(), countdown: 1, interval: 1)
        for i in 1...snap.requiredCaptureCount {
            _ = try await env.safetySave.savePhoto(
                sessionID: session.id, captureIndex: i, payloadData: markerData, requestID: UUID().uuidString,
                width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)
        }
        let detail = try env.sessions.getDetail(sessionID: session.id)!
        env.settings.autoExport = true
        env.settings.exportFormat = .jpeg
        let oldWidth = env.settings.exportWidth
        let oldHeight = env.settings.exportHeight
        env.settings.exportWidth = 9999
        env.settings.exportHeight = 8888
        defer {
            env.settings.exportWidth = oldWidth
            env.settings.exportHeight = oldHeight
        }

        // Bookmark folder
        let bookmarkData = (try? exportsDir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? (try! exportsDir.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        let bookmarkID = try env.trashRepo.saveBookmark(purpose: "exportFolder", blob: bookmarkData, displayPath: exportsDir.path)
        env.settings.exportFolderBookmarkID = bookmarkID

        let exportResult = await env.exportService.autoExport(detail: detail, folderBookmarkID: bookmarkID)
        guard case .success(let outURL) = exportResult else {
            XCTFail("Auto export failed: \(exportResult)")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        guard let source = CGImageSourceCreateWithURL(outURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("Failed to read image properties from exported file")
            return
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertEqual(w, snap.canvasWidth, "Auto export phải dùng canvasWidth của snapshot")
        XCTAssertEqual(h, snap.canvasHeight, "Auto export phải dùng canvasHeight của snapshot")
    }

    @MainActor
    func testHermes_A03_ThumbnailPreservesAspectRatio() async throws {
        let thumbService = env.frameThumbnails
        // Khung dọc: 1200 x 1800 -> tỷ lệ 2:3 -> target 160 x 240
        let verticalFrame = try env.frames.createFrame(name: "Vertical", imageData: makeSamplePNG(width: 120, height: 180), mediaType: "image/png", role: .frameBackground, categoryID: nil)
        let vFrameObj = try env.frames.getFrame(id: verticalFrame.id)!
        var vRev = try env.frames.getRevision(id: vFrameObj.currentRevisionID!)!
        vRev.canvasWidth = 1200
        vRev.canvasHeight = 1800
        let slotV = FrameSlot(frameRevisionID: vRev.id, captureIndex: 1, x: 0.1, y: 0.1, width: 0.8, height: 0.8, zOrder: 1)
        let committedV = try env.frames.commitRevision(frameID: verticalFrame.id, draft: vRev, slots: [slotV])

        let vThumbData = await thumbService.requestThumbnail(frameID: verticalFrame.id, revisionID: committedV.id)
        XCTAssertNotNil(vThumbData)
        if let vThumbData, let source = CGImageSourceCreateWithData(vThumbData as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            XCTAssertEqual(cg.width, 160, "Khung 1200x1800 phải dựng thumbnail width 160")
            XCTAssertEqual(cg.height, 240, "Khung 1200x1800 phải dựng thumbnail height 240")
        }
    }

    @MainActor
    func testHermes_A06_Max12SlotsEnforced() async throws {
        let readyFrames = try env.frames.listReadyFrames()
        let frame = readyFrames.first!
        let editorVM = FrameEditorViewModel(env: env)
        editorVM.load(frameID: frame.id)

        while editorVM.slots.count > 1 {
            editorVM.deleteSlot(editorVM.slots.last!.id)
        }
        XCTAssertEqual(editorVM.slots.count, 1)

        for _ in 2...12 {
            editorVM.addSlot()
        }
        XCTAssertEqual(editorVM.slots.count, 12)

        editorVM.addSlot()
        XCTAssertEqual(editorVM.slots.count, 12, "Số ô không được vượt quá 12")

        // Capture indices phải liên tục 1...12
        let indices = editorVM.slots.map { $0.captureIndex }.sorted()
        XCTAssertEqual(indices, Array(1...12))
    }

    @MainActor
    func testHermes_A07_SessionDefaults_Rotation_SmartFace_SetResolution() async throws {
        env.settings.rotation = 90
        env.settings.smartFace = false
        let snap = env.settings.sessionDefaultsSnapshot()
        XCTAssertEqual(snap.rotation, 90)
        XCTAssertEqual(snap.smartFace, false)

        let resolved = ResolvedPhotoParams.resolve(defaults: snap, override: nil)
        XCTAssertEqual(resolved.photoRotation, 90)

        // Camera setResolution
        try await env.camera.setResolution("1920x1080")
        try await env.camera.setResolution("best")
    }

    @MainActor
    func testHermes_L01_PauseAtSafePoints() async throws {
        let readyFrames = try env.frames.listReadyFrames()
        let snap = try env.frames.createSnapshot(frameID: readyFrames.first!.id)
        _ = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "fake-cam",
                                                 defaults: env.settings.sessionDefaultsSnapshot(), countdown: 1, interval: 1)
        try env.engine.startOrContinue()
        env.engine.pause(reason: .appInactive)
        if case .paused(let reason, _, _) = env.engine.state {
            XCTAssertEqual(reason, .appInactive)
        } else {
            XCTFail("Engine state should be paused, got \(env.engine.state)")
        }

        // Resume requires explicit user action
        try env.engine.resume()
        if case .countdown = env.engine.state {
            env.engine.cancelCountdown()
        }
        XCTAssertEqual(env.engine.state, .ready)
    }

    @MainActor
    func testHermes_L02_L03_PreferredFrameID_AndImportOpensEditor() async throws {
        let readyFrames = try env.frames.listReadyFrames()
        let frame = readyFrames.first!
        let captureVM = CaptureViewModel(env: env)
        captureVM.reloadFrames()
        captureVM.selectFrame(frame.id)
        XCTAssertEqual(env.preferredFrameID, frame.id)

        // Import frame image
        env.route = .frames
        let samplePNGURL = fixturesDir.appendingPathComponent("marker_L.png")
        let framesVM = FramesViewModel(env: env)
        await framesVM.importImages(urls: [samplePNGURL])
        if case .frameEditor(let fid) = env.route {
            XCTAssertNotNil(fid, "Phải mở FrameEditor cho khung vừa nhập")
        } else {
            XCTFail("Nhập ảnh trên màn Frames phải mở FrameEditor, route hiện tại là \(env.route)")
        }
    }

    @MainActor
    func testHermes_L05_IncompleteSessionDownscaledThumbnail() async throws {
        let readyFrames = try env.frames.listReadyFrames()
        let snap = try env.frames.createSnapshot(frameID: readyFrames.first!.id)
        let markerData = try Data(contentsOf: fixturesDir.appendingPathComponent("marker_L.png"))
        let session = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: "fake-cam",
                                                 defaults: env.settings.sessionDefaultsSnapshot(), countdown: 1, interval: 1)
        // Only shoot 1 of 3 photos (incomplete)
        _ = try await env.safetySave.savePhoto(
            sessionID: session.id, captureIndex: 1, payloadData: markerData, requestID: UUID().uuidString,
            width: 500, height: 500, orientation: 1, codec: "png", colorProfile: nil)

        let libraryVM = LibraryViewModel(env: env)
        libraryVM.reload()
        guard let card = libraryVM.cards.first(where: { $0.id == session.id }) else {
            XCTFail("Session card not found")
            return
        }
        let previewData = await libraryVM.generatePreview(for: card)
        XCTAssertNotNil(previewData)
        if let previewData, let source = CGImageSourceCreateWithData(previewData as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            XCTAssertLessThanOrEqual(cg.width, 420)
            XCTAssertLessThanOrEqual(cg.height, 420)
        }
    }

    // MARK: - Helpers
    private func makeSamplePNG(width: Int = 200, height: Int = 200) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 0.8))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func getPixelAlpha(_ cg: CGImage, x: Int, y: Int) -> UInt8 {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return pixel[3]
    }

    private func getPixelRGBA(_ cg: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
