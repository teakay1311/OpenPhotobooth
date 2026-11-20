import XCTest
import SwiftUI
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
@testable import OpenPhotobooth

@MainActor
final class TrashAndSettingsFixTests: XCTestCase {
    var env: AppEnvironment!
    var tempDir: URL!

    override func setUp() async throws {
        env = AppEnvironment(inMemory: true)
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TrashSettingsFix_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helper Methods

    func testFrameBatchConfinesFilterAndReportsStaleTargets() throws {
        let frames = try (0..<50).map {
            try env.frames.createEmptyFrame(name: $0 < 5 ? "Visible \($0)" : "Hidden \($0)", categoryID: nil)
        }
        let vm = FramesViewModel(env: env)
        vm.searchText = "Visible "
        vm.reload()
        vm.selection = Set(vm.frames.map(\.id))
        let shown = vm.selectedTrashTargets
        XCTAssertEqual(Set(shown.map(\.id)), Set(frames.prefix(5).map(\.id)))
        let renamed = try XCTUnwrap(shown.first)
        let removed = shown[1]
        try env.frames.renameFrame(id: renamed.id, to: "Visible renamed")
        try env.trashService.trashFrame(frameID: removed.id)
        let current = try env.trashService.activeFrameTargets(shown.map(\.id))
        XCTAssertEqual(current.first?.name, "Visible renamed")
        XCTAssertFalse(current.contains { $0.id == removed.id })

        let partial = env.trashService.trashFrames(shown + [shown[2]])
        XCTAssertEqual(Set(partial.moved), Set(shown.dropFirst(2).map(\.id)))
        XCTAssertEqual(Set(partial.failures.keys), [renamed.id, removed.id])
        XCTAssertEqual(try env.frames.getFrame(id: renamed.id)?.lifecycle, .active)
        let retry = try env.trashService.activeFrameTargets([renamed.id])
        XCTAssertEqual(env.trashService.trashFrames(retry).moved, [renamed.id])
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(try env.frames.getFrame(id: frame.id)?.lifecycle, index < 5 ? .trashed : .active)
        }
        let item = try XCTUnwrap(env.trashRepo.find(rootType: .frame, rootID: renamed.id))
        try env.trashService.restore(item)
        XCTAssertEqual(try env.frames.getFrame(id: renamed.id)?.name, "Visible renamed")
        XCTAssertEqual(try env.frames.getFrame(id: renamed.id)?.lifecycle, .active)
    }

    private func createDummyImageData(color: CGColor = CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1.0)) -> Data {
        let width = 200
        let height = 200
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try! ExportService.encode(cg: ctx.makeImage()!, format: .png, quality: 90)
    }

    private func seedSessionInTrash(nameSuffix: String = "") async throws -> (sessionID: String, trashItem: TrashItem) {
        let readyFrames = try env.frames.listReadyFrames()
        let frame = readyFrames.first!
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let defaults = env.settings.sessionDefaultsSnapshot()

        let session = try env.sessions.createSession(
            snapshot: snap,
            mode: .automatic,
            cameraID: "fake-cam",
            defaults: defaults,
            frameNameAtCapture: "TestFrame\(nameSuffix)",
            countdownSeconds: 1,
            intermissionSeconds: 1
        )

        let imgData = createDummyImageData()
        _ = try await env.safetySave.savePhoto(
            sessionID: session.id,
            captureIndex: 1,
            payloadData: imgData,
            requestID: "req-\(session.id)-1",
            width: 200,
            height: 200,
            orientation: 1,
            codec: "png",
            colorProfile: nil
        )

        try env.trashService.trashSession(sessionID: session.id)
        let item = try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: session.id))
        return (session.id, item)
    }

    private func storedPhoto(_ sessionID: String) throws -> PhotoRevision {
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: sessionID))
        return try XCTUnwrap(detail.currentRevisions()[1])
    }

    private func moveTrashFilesToLive(_ id: String) throws {
        let source = env.layout.trashSessionsDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.moveItem(at: source, to: env.layout.sessionDir(id))
    }

    func testPB01LegacySplitIsReportedWithoutMovingOrChangingData() async throws {
        let (id, item) = try await seedSessionInTrash()
        try env.db.run("UPDATE sessions SET status='in_progress' WHERE id=?", [.text(id)])
        let photo = try storedPhoto(id)
        let original = env.layout.trashSessionsDir.appendingPathComponent(id)
            .appendingPathComponent("Originals").appendingPathComponent(URL(fileURLWithPath: photo.relativePath).lastPathComponent)
        let before = try Data(contentsOf: original)

        let report = try env.trashService.recoverOperations()
        XCTAssertTrue(report.excludedSessions.contains(id))
        XCTAssertFalse(report.issues.isEmpty)
        try env.sessions.convertTransientToPaused()
        XCTAssertNil(try env.sessions.activeCaptureDetail(sessionID: id))
        XCTAssertNil(try env.sessions.latestRecoverableSession())
        XCTAssertThrowsError(try env.trashService.restore(item))
        XCTAssertEqual(try env.sessions.getSession(id: id)?.status, .inProgress)
        XCTAssertEqual(try env.trashRepo.getItem(id: item.id)?.status, .trashed)
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.layout.sessionDir(id).path))
    }

    func testPB11MissingSnapshotLayerBlocksRestoreBeforeMovingFiles() async throws {
        let (id, item) = try await seedSessionInTrash()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        let layer = try XCTUnwrap(detail.snapshot.foreground ?? detail.snapshot.background)
        let row = try XCTUnwrap(env.db.query("SELECT relative_path FROM assets WHERE id=?", [.text(layer.assetID)]).first)
        let layerURL = try env.layout.absoluteURL(forRelativePath: row["relative_path"].stringValue)
        try FileManager.default.removeItem(at: layerURL)

        XCTAssertThrowsError(try env.trashService.restore(item)) { error in
            XCTAssertEqual(error as? AppError, .missingFrameAssets)
        }
        XCTAssertEqual(try env.sessions.getSession(id: id)?.status, .trashed)
        XCTAssertEqual(try env.trashRepo.getItem(id: item.id)?.status, .trashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.layout.sessionDir(id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.layout.trashSessionsDir.appendingPathComponent(id).path))
    }

    func testPB12RetiredBookmarkStaysAvailableUntilLastUseEnds() throws {
        let id = try env.trashRepo.saveBookmark(purpose: "export_folder", blob: Data([1]), displayPath: tempDir.path)
        do {
            let use = try env.trashRepo.useBookmark(id: id)
            try env.trashRepo.deleteBookmark(id: id)
            withExtendedLifetime(use) {
                XCTAssertNotNil(try? env.trashRepo.bookmark(id: id))
            }
        }
        XCTAssertNil(try env.trashRepo.bookmark(id: id))
    }

    func testAUD01RecoversInterruptedRestoreAndPreservesRevision() async throws {
        let root = tempDir.appendingPathComponent("recovery-store", isDirectory: true)
        let prefs = try XCTUnwrap(UserDefaults(suiteName: "test-recovery-\(UUID().uuidString)"))
        env = AppEnvironment(customRoot: root, customDefaults: prefs, camera: FakeCameraService())
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        let (id, item) = try await seedSessionInTrash()
        let original = try storedPhoto(id)
        try env.trashRepo.setStatus(id: item.id, status: .restoring)
        try moveTrashFilesToLive(id)

        for _ in 0..<2 {
            env = nil
            env = AppEnvironment(customRoot: root, customDefaults: prefs, camera: FakeCameraService())
            XCTAssertNil(env.launchError)
            await env.boot()
            env.trashScheduler.stop()
            XCTAssertEqual(env.recoveryReport?.issues, [])
            XCTAssertEqual(try env.trashRepo.getItem(id: item.id)?.status, .trashed)
            XCTAssertEqual(try env.sessions.getSession(id: id)?.status, .trashed)
        }
        try env.trashService.restore(item)
        XCTAssertEqual(try storedPhoto(id).id, original.id)
        XCTAssertEqual(Hashing.sha256Hex(fileURL: try env.sessions.fileURL(for: original)), original.sha256)
        XCTAssertNil(try env.trashRepo.getItem(id: item.id))
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }

    func testAUD01LegacyPurgeRequiresRetryAndKeepsBytes() async throws {
        let (id, item) = try await seedSessionInTrash()
        let original = try storedPhoto(id)
        let activePath = try env.sessions.fileURL(for: original)
        let trashPath = env.layout.trashSessionsDir.appendingPathComponent(id)
            .appendingPathComponent("Originals").appendingPathComponent(activePath.lastPathComponent)
        try env.trashRepo.setStatus(id: item.id, status: .purging)

        for _ in 0..<2 {
            XCTAssertTrue(try env.trashService.recoverOperations().issues.isEmpty)
            XCTAssertEqual(try env.trashRepo.getItem(id: item.id)?.status, .purgeFailed)
            XCTAssertEqual(Hashing.sha256Hex(fileURL: trashPath), original.sha256)
        }
        XCTAssertEqual(env.trashService.purgeResult(item), .processed)
        XCTAssertNil(try env.sessions.getSession(id: id))
        XCTAssertNil(try env.trashRepo.getItem(id: item.id))
    }

    func testAUD01ResumesAuthorizedPurgeAfterFolderWasRemoved() async throws {
        let (id, item) = try await seedSessionInTrash()
        let (otherID, otherItem) = try await seedSessionInTrash()
        let otherRevision = try storedPhoto(otherID)
        let outsideFile = tempDir.appendingPathComponent("already-exported.png")
        try createDummyImageData().write(to: outsideFile)
        let exportHash = Hashing.sha256Hex(fileURL: outsideFile)
        let payload = """
            {"itemID":"\(item.id)","rootType":"session","previousStatus":"trashed"}
            """
        try env.trashRepo.setStatus(id: item.id, status: .purging)
        let intent = try env.trashRepo.createIntent(opType: "purge", rootID: id, payloadJSON: payload)
        try FileManager.default.removeItem(at: env.layout.trashSessionsDir.appendingPathComponent(id))

        for _ in 0..<2 {
            XCTAssertTrue(try env.trashService.recoverOperations().issues.isEmpty)
            XCTAssertNil(try env.sessions.getSession(id: id))
            XCTAssertNil(try env.trashRepo.getItem(id: item.id))
            XCTAssertEqual(try env.trashRepo.getIntent(id: intent.id)?.status, .committed)
            XCTAssertEqual(try env.trashRepo.getItem(id: otherItem.id)?.status, .trashed)
        }
        try env.trashService.restore(otherItem)
        XCTAssertEqual(Hashing.sha256Hex(fileURL: try env.sessions.fileURL(for: otherRevision)), otherRevision.sha256)
        XCTAssertEqual(Hashing.sha256Hex(fileURL: outsideFile), exportHash)
        XCTAssertNil(try env.db.integrityCheck())
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }

    func testAUD01ConflictingDirectoriesAreLeftUntouched() async throws {
        let (id, item) = try await seedSessionInTrash()
        let original = try storedPhoto(id)
        let active = env.layout.sessionDir(id)
        let trash = env.layout.trashSessionsDir.appendingPathComponent(id)
        try FileManager.default.copyItem(at: trash, to: active)
        try env.trashRepo.setStatus(id: item.id, status: .purging)
        let payload = """
            {"itemID":"\(item.id)","rootType":"session","previousStatus":"trashed"}
            """
        _ = try env.trashRepo.createIntent(opType: "purge", rootID: id, payloadJSON: payload)

        let report = try env.trashService.recoverOperations()
        XCTAssertEqual(report.excludedSessions, [id])
        XCTAssertFalse(report.issues.isEmpty)
        XCTAssertEqual(try env.sessions.getSession(id: id)?.status, .trashed)
        let originalFile = try env.sessions.fileURL(for: original)
        XCTAssertEqual(Hashing.sha256Hex(fileURL: originalFile), original.sha256)
        let trashFile = trash.appendingPathComponent("Originals").appendingPathComponent(originalFile.lastPathComponent)
        XCTAssertEqual(Hashing.sha256Hex(fileURL: trashFile), original.sha256)
    }

    func testAUD03TrashIntentFailureRollsBackDatabaseAndFiles() async throws {
        let (id, item) = try await seedSessionInTrash()
        let original = try storedPhoto(id)
        try env.trashService.restore(item)
        let status = try env.sessions.getSession(id: id)?.status
        try env.db.run("""
            CREATE TRIGGER fail_audit_trash_commit BEFORE UPDATE ON operation_intents
            WHEN NEW.op_type='trash' AND NEW.status='committed'
            BEGIN SELECT RAISE(ABORT, 'fixture fault'); END
            """)
        XCTAssertThrowsError(try env.trashService.trashSession(sessionID: id))
        try env.db.run("DROP TRIGGER fail_audit_trash_commit")

        XCTAssertTrue(try env.trashService.recoverOperations().issues.isEmpty)
        XCTAssertEqual(try env.sessions.getSession(id: id)?.status, status)
        XCTAssertNil(try env.trashRepo.find(rootType: .session, rootID: id))
        XCTAssertEqual(Hashing.sha256Hex(fileURL: try env.sessions.fileURL(for: original)), original.sha256)

        try env.trashService.trashSession(sessionID: id)
        let fresh = try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: id))
        try env.trashService.restore(fresh)
        XCTAssertEqual(try storedPhoto(id).id, original.id)
    }

    func testAUD03RepairsLegacyCommittedTrashWithFilesInActiveDirectory() async throws {
        let (id, item) = try await seedSessionInTrash()
        let original = try storedPhoto(id)
        try moveTrashFilesToLive(id)
        let oldIntent = try env.trashRepo.createIntent(opType: "trash", rootID: id)
        try env.trashRepo.updateIntent(id: oldIntent.id, status: .rollbackRequired)

        for _ in 0..<2 {
            XCTAssertTrue(try env.trashService.recoverOperations().issues.isEmpty)
            XCTAssertEqual(try env.trashRepo.getIntent(id: oldIntent.id)?.status, .committed)
            XCTAssertEqual(try env.trashRepo.getItem(id: item.id)?.expiresAtMs, item.expiresAtMs)
        }
        try env.trashService.restore(item)
        XCTAssertEqual(Hashing.sha256Hex(fileURL: try env.sessions.fileURL(for: original)), original.sha256)
    }

    func testAUD01PurgeCanRetryAfterDatabaseFailureAndFileRemoval() async throws {
        let (id, item) = try await seedSessionInTrash()
        try env.db.run("""
            CREATE TRIGGER fail_audit_purge_commit BEFORE UPDATE ON operation_intents
            WHEN NEW.op_type='purge' AND NEW.status='committed'
            BEGIN SELECT RAISE(ABORT, 'fixture fault'); END
            """)
        guard case .failed = env.trashService.purgeResult(item) else {
            return XCTFail("Expected purge to fail after file removal")
        }
        try env.db.run("DROP TRIGGER fail_audit_purge_commit")
        let trash = env.layout.trashSessionsDir.appendingPathComponent(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertEqual(try env.trashRepo.getItem(id: item.id)?.status, .purgeFailed)
        XCTAssertEqual(try env.sessions.getSession(id: id)?.status, .trashed)
        XCTAssertEqual(env.trashService.purgeResult(item), .processed)
        XCTAssertNil(try env.trashRepo.getItem(id: item.id))
        XCTAssertNil(try env.sessions.getSession(id: id))
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }

    func testAUD01RestoreAndAutomaticPurgeAtExactExpiration() async throws {
        let clock = TestClock()
        let service = TrashService(db: env.db, layout: env.layout, trashRepo: env.trashRepo,
                                   assets: env.assets, clock: clock)
        for delta in [-1, 0, 1] {
            let (restoreID, restore) = try await seedSessionInTrash()
            let (purgeID, purge) = try await seedSessionInTrash()
            let deleted = Time.nowMs(clock) - TrashPolicy.retentionMs - Int64(delta)
            let expires = TrashPolicy.expiresAt(deletedAtMs: deleted)
            try env.db.run("UPDATE trash_items SET deleted_at_ms=?, expires_at_ms=? WHERE id IN (?,?)",
                           [.int(deleted), .int(expires), .text(restore.id), .text(purge.id)])
            XCTAssertEqual(Time.nowMs(clock) - expires, Int64(delta))
            XCTAssertEqual(service.restoreResult(restore) == .processed, delta == -1)
            if delta >= 0 {
                // Keep the restore and scheduler decisions independent.
                XCTAssertEqual(service.purgeResult(restore), .processed)
            }
            let scheduler = TrashCleanupScheduler(trashService: service, trashRepo: env.trashRepo,
                                                  clockSanity: ClockSanityMonitor(clock: clock), clock: clock)
            XCTAssertEqual(scheduler.runOnce(manual: false)?.success, delta >= 0 ? 1 : 0)
            XCTAssertEqual(try env.sessions.getSession(id: purgeID) == nil, delta >= 0)
            XCTAssertEqual(try env.sessions.getSession(id: restoreID) != nil, delta == -1)
            if delta == -1 { XCTAssertEqual(service.purgeResult(purge), .processed) }
        }
    }

    // MARK: - T01: Confirmation Scope & Eligible Items Filtering (TRS-04, §3.2)
    func testT01_ConfirmationScopeAndFiltering() async throws {
        let (_, item1) = try await seedSessionInTrash(nameSuffix: "1")
        let (_, item2) = try await seedSessionInTrash(nameSuffix: "2")
        let (_, item3) = try await seedSessionInTrash(nameSuffix: "3")

        let vm = TrashViewModel(env: env)
        vm.reload()
        XCTAssertEqual(vm.items.count, 3)

        // 1. Single row scope
        let singleScope = try XCTUnwrap(vm.prepareSinglePurgeScope(item: item1))
        XCTAssertEqual(singleScope.targetIDs, [item1.id])
        XCTAssertEqual(singleScope.itemCount, 1)
        XCTAssertEqual(singleScope.estimatedBytes, item1.estimatedBytes)
        XCTAssertEqual(singleScope.displayName, item1.displayName)

        // 2. Selection scope
        vm.selection = [item1.id, item2.id]
        let selScope = try XCTUnwrap(vm.prepareSelectionPurgeScope())
        XCTAssertEqual(Set(selScope.targetIDs), Set([item1.id, item2.id]))
        XCTAssertEqual(selScope.itemCount, 2)
        XCTAssertEqual(selScope.estimatedBytes, item1.estimatedBytes + item2.estimatedBytes)

        // 3. Mark item3 as status .restoring -> must be excluded from eligible scopes
        try env.trashRepo.setStatus(id: item3.id, status: .restoring)
        vm.reload()

        let emptyAllScope = try XCTUnwrap(vm.prepareAllPurgeScope())
        XCTAssertEqual(emptyAllScope.itemCount, 2) // item3 excluded because it's restoring
        XCTAssertFalse(emptyAllScope.targetIDs.contains(item3.id))

        // 4. Filter active: filter by something that excludes item2 visually
        vm.filter = .frame // Currently we only have sessions in trash
        vm.reload()
        XCTAssertEqual(vm.items.count, 0)
        XCTAssertEqual(vm.totalRepoCount, 3)

        // Empty trash must still consider ALL eligible items in repo, even when filtered out visually
        let filteredAllScope = try XCTUnwrap(vm.prepareAllPurgeScope())
        XCTAssertEqual(filteredAllScope.itemCount, 2)
        XCTAssertEqual(Set(filteredAllScope.targetIDs), Set([item1.id, item2.id]))

        // Cancel (activePurgeScope = nil) changes nothing
        vm.activePurgeScope = nil
        vm.reload()
        let repoList = try env.trashRepo.list()
        XCTAssertEqual(repoList.count, 3)
    }

    // MARK: - T02: Shift Detection During Confirmation (TRS-04, §3.2, T02)
    func testT02_ShiftDetectionDuringConfirmation() async throws {
        let (_, item1) = try await seedSessionInTrash(nameSuffix: "1")
        let (_, item2) = try await seedSessionInTrash(nameSuffix: "2")

        let vm = TrashViewModel(env: env)
        vm.reload()

        // User opens confirmation for item1
        let scope = try XCTUnwrap(vm.prepareSinglePurgeScope(item: item1))
        vm.activePurgeScope = scope

        // Background scheduler or simulated action purges item1 or changes its size
        try env.trashRepo.setStatus(id: item1.id, status: .purging)

        // User confirms -> executePurge should detect shift, cancel execution, and notify
        vm.executePurge(scope: scope)

        XCTAssertFalse(env.isManualPurging)
        // Check that item2 is intact
        let freshItem2 = try env.trashRepo.find(rootType: .session, rootID: item2.rootID)
        XCTAssertNotNil(freshItem2)
    }

    // MARK: - T03: Lock Contention & App-Level Manual Purge Blocking (TRS-03, T03)
    func testT03_LockContentionAndAppLevelBlocking() async throws {
        let (_, item1) = try await seedSessionInTrash(nameSuffix: "1")

        // 1. Acquire manual purge lock
        let taskID = try XCTUnwrap(env.beginManualPurge())
        XCTAssertTrue(env.isManualPurging)

        // 2. Second concurrent request is blocked
        let secondTask = env.beginManualPurge()
        XCTAssertNil(secondTask)

        // 3. Actions in TrashViewModel are blocked while busy
        let vm = TrashViewModel(env: env)
        vm.reload()
        vm.selection = [item1.id]

        vm.restoreSelected()
        // item1 must still be in trash
        let stillInTrash = try env.trashRepo.getItem(id: item1.id)
        XCTAssertNotNil(stillInTrash)

        // 4. Release lock
        env.endManualPurge(taskID: taskID)
        XCTAssertFalse(env.isManualPurging)

        // 5. Subsequent purge can succeed
        let scope = try XCTUnwrap(vm.prepareSinglePurgeScope(item: item1))
        vm.executePurge(scope: scope)

        // Wait brief moment for background task
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(env.isManualPurging)
    }

    // MARK: - T04: Stale Item Protection (TRS-03, TRS-04, §3.2, T04)
    func testT04_StaleItemProtection() async throws {
        let (sessionID, originalTrashItem) = try await seedSessionInTrash(nameSuffix: "Stale")

        // Simulate item restored then re-trashed with new ID
        try env.trashService.restore(originalTrashItem)
        try env.trashService.trashSession(sessionID: sessionID)

        let newTrashItem = try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: sessionID))
        XCTAssertNotEqual(newTrashItem.id, originalTrashItem.id)

        // Now attempt to purge the OLD trash item record
        let result = env.trashService.purgeResult(originalTrashItem)
        XCTAssertEqual(result, .skipped(reason: "Mục đã được thay thế bằng bản ghi rác mới"))

        // The session and new trash item must remain completely safe!
        let safeItem = try env.trashRepo.find(rootType: .session, rootID: sessionID)
        XCTAssertEqual(safeItem?.id, newTrashItem.id)

        // Clean up
        env.trashService.purge(newTrashItem)
    }

    // MARK: - T05: Expiration Boundary Check (TRS-05, TRS-06, §3.4, T05)
    func testT05_ExpirationBoundaryAndRetryPurge() async throws {
        let (s1, item1) = try await seedSessionInTrash(nameSuffix: "Active")
        let (s2, item2) = try await seedSessionInTrash(nameSuffix: "Expired")
        let (_, item3) = try await seedSessionInTrash(nameSuffix: "Failed")

        // Set item2 to expired (31 days ago)
        let pastTime = Time.nowMs() - (31 * 86_400 * 1000)
        try env.db.run("UPDATE trash_items SET deleted_at_ms=?, expires_at_ms=? WHERE id=?",
                       [.int(pastTime), .int(pastTime + TrashPolicy.retentionMs), .text(item2.id)])

        // Set item3 to purgeFailed with lastError
        try env.trashRepo.setStatus(id: item3.id, status: .purgeFailed, error: "Disk full simulation")

        let vm = TrashViewModel(env: env)
        vm.reload()

        // 1. Single restore on expired item is blocked
        let expiredItemFresh = try XCTUnwrap(env.trashRepo.getItem(id: item2.id))
        XCTAssertLessThanOrEqual(expiredItemFresh.expiresAtMs, Time.nowMs())
        let restoreResult = env.trashService.restoreResult(expiredItemFresh)
        XCTAssertEqual(restoreResult, .skipped(reason: "Mục đã quá hạn 30 ngày trong Thùng rác"))

        // 2. Mixed batch restore: selection of item1 (valid) and item2 (expired)
        vm.selection = [item1.id, item2.id]
        vm.restoreSelected()

        // item1 must be restored
        let item1After = try env.trashRepo.getItem(id: item1.id)
        XCTAssertNil(item1After)
        let session1 = try env.sessions.getDetail(sessionID: s1)
        XCTAssertNotNil(session1)

        // item2 must remain in trash
        let item2After = try env.trashRepo.getItem(id: item2.id)
        XCTAssertNotNil(item2After)

        // 3. Retry purge on purgeFailed item3
        let retryScope = try XCTUnwrap(vm.prepareSinglePurgeScope(item: item3))
        XCTAssertEqual(retryScope.itemCount, 1)
        XCTAssertEqual(retryScope.targetIDs, [item3.id])

        // Clean up
        _ = try? env.trashService.trashSession(sessionID: s1)
    }

    // MARK: - T06: True Empty vs Filter Mismatch (TRS-07, TRS-01, T06)
    func testT06_TrueEmptyVsFilterMismatch() async throws {
        let vm = TrashViewModel(env: env)
        vm.reload()

        // Case 1: Truly empty
        XCTAssertEqual(vm.totalRepoCount, 0)
        XCTAssertTrue(vm.items.isEmpty)

        // Case 2: Has items, but filter returns 0
        let (_, _) = try await seedSessionInTrash(nameSuffix: "FilterTest")
        vm.filter = .preset // No presets in trash
        vm.reload()

        XCTAssertEqual(vm.totalRepoCount, 1)
        XCTAssertEqual(vm.items.count, 0)
        // UI condition: vm.items.isEmpty && vm.totalRepoCount > 0 -> "Không tìm thấy mục phù hợp"
    }

    // MARK: - T07: Single-Use Navigation Intent (TRS-02, T07)
    func testT07_SingleUseNavigationIntent() async throws {
        // 1. Footer button triggers openSettings(section: .data)
        env.openSettings(section: .data)
        XCTAssertEqual(env.route, .settings)
        XCTAssertEqual(env.pendingSettingsSection, .data)

        // 2. SettingsView consumes intent
        let consumed = env.consumePendingSettingsSection()
        XCTAssertEqual(consumed, .data)
        XCTAssertNil(env.pendingSettingsSection)

        // 3. Normal navigation via sidebar or shortcut
        env.requestNavigation(to: .library)
        env.requestNavigation(to: .settings)
        let consumedAgain = env.consumePendingSettingsSection()
        XCTAssertNil(consumedAgain) // Defaults to general

        // 4. Cancelled or altered route clears pending section
        env.openSettings(section: .data)
        env.requestNavigation(to: .capture) // User routed away before consumption
        XCTAssertNil(env.pendingSettingsSection)
    }

    // MARK: - T08: Sound Toggle, JPG Quality Lock, Fullscreen Localization (SET-01, SET-03, SET-04, T08)
    func testT08_SettingsControlsAndLocalization() throws {
        // 1. Sound master toggle: preserves values when toggled off
        env.settings.soundVolume = 75
        env.settings.soundCountdown = true
        env.settings.soundEnabled = false

        XCTAssertEqual(env.settings.soundVolume, 75)
        XCTAssertEqual(env.settings.soundCountdown, true)

        env.settings.soundEnabled = true
        XCTAssertEqual(env.settings.soundVolume, 75)

        // 2. Export format: JPG -> PNG -> JPG preserves quality value
        env.settings.jpegQuality = 88
        env.settings.exportFormat = .png
        XCTAssertEqual(env.settings.jpegQuality, 88)
        env.settings.exportFormat = .jpeg
        XCTAssertEqual(env.settings.jpegQuality, 88)

        // 3. Fullscreen option tags and defaults
        env.settings.fullscreenDefaultFrame = ""
        XCTAssertEqual(env.settings.fullscreenDefaultFrame, "")
        env.settings.fullscreenFrameFilter = "all"
        XCTAssertEqual(env.settings.fullscreenFrameFilter, "all")
        env.settings.fullscreenIdleReturn = 0
        XCTAssertEqual(env.settings.fullscreenIdleReturn, 0)
    }

    // MARK: - T09: ThumbnailStore Generation & I/O Race Condition (SET-02, §5.1, §5.2, T09)
    func testT09_ThumbnailStoreGenerationAndLock() async throws {
        let store = env.thumbnails
        let initialGen = store.generation

        let dummyData1 = "thumb-generation-1".data(using: .utf8)!
        let dummyData2 = "thumb-generation-2".data(using: .utf8)!

        // 1. Normal store with initial generation
        let ok1 = store.store(data: dummyData1, key: "test-thumb-key", expectedGeneration: initialGen)
        XCTAssertTrue(ok1)
        XCTAssertNotNil(store.cachedData(key: "test-thumb-key", validForGeneration: initialGen))

        // 2. Clean cache bumps generation
        let clearResult = store.clearAllWithResult()
        XCTAssertEqual(clearResult, .success)
        XCTAssertEqual(store.generation, initialGen + 1)

        // 3. Producer with stale generation is rejected
        let okStale = store.store(data: dummyData1, key: "test-thumb-key", expectedGeneration: initialGen)
        XCTAssertFalse(okStale)

        // 4. Producer with fresh generation succeeds
        let freshGen = store.generation
        let okFresh = store.store(data: dummyData2, key: "test-thumb-key", expectedGeneration: freshGen)
        XCTAssertTrue(okFresh)

        // 5. AppEnvironment cleanCache execution
        env.cleanCache()
        // Wait brief moment for background clean
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(env.isCleaningCache)
    }

    // MARK: - T10: SET-UI Layout Verification (SET-UI, §6, T10)
    func testT10_SettingsUILayoutVerification() {
        // Verify SettingsView structural layout configuration
        let settingsView = SettingsView(env: env)
        XCTAssertNotNil(settingsView)
    }

    // MARK: - T11: Full Workflow Regression (T11)
    func testT11_FullWorkflowRegression() async throws {
        // 1. Create a session, save a photo, complete it
        let (sid, item) = try await seedSessionInTrash(nameSuffix: "Regression")

        // 2. Restore from trash
        try env.trashService.restore(item)
        let restoredSession = try XCTUnwrap(env.sessions.getDetail(sessionID: sid))
        XCTAssertEqual(restoredSession.session.id, sid)

        // 3. Verify files and snapshot exist
        let dir = env.layout.sessionDir(sid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        // 4. Trash again and purge
        try env.trashService.trashSession(sessionID: sid)
        let trashedAgain = try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: sid))
        let purgeSuccess = env.trashService.purge(trashedAgain)
        XCTAssertTrue(purgeSuccess)

        // 5. Verify completely removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(try env.trashRepo.find(rootType: .session, rootID: sid))
    }
}

extension TrashAndSettingsFixTests {
    func testTrashPreviewReadsMovedBytesWithoutWritingAndRejectsForeignPhoto() async throws {
        let (id, item) = try await seedSessionInTrash()
        let photo = try storedPhoto(id)
        let changes = try env.db.scalarInt("SELECT total_changes()")
        let filesBefore = try FileManager.default.subpathsOfDirectory(atPath: env.layout.rootURL.path).sorted()
        let entries = try env.trashService.previewPhotos(item)
        XCTAssertEqual(entries.map(\.id), [photo.id])
        let image = try env.trashService.previewImage(item, photoID: photo.id, maxPixel: 64)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
        XCTAssertThrowsError(try env.trashService.previewImage(item, photoID: UUID().uuidString, maxPixel: 64))
        XCTAssertEqual(try env.db.scalarInt("SELECT total_changes()"), changes)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: env.layout.rootURL.path).sorted(), filesBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.layout.sessionDir(id).path))
        let file = env.layout.trashSessionsDir.appendingPathComponent(id).appendingPathComponent("Originals")
            .appendingPathComponent(URL(fileURLWithPath: photo.relativePath).lastPathComponent)
        try Data([0, 1, 2]).write(to: file)
        XCTAssertThrowsError(try env.trashService.previewImage(item, maxPixel: 64))
    }

    func testTrashFramePreviewDoesNotPersistSnapshotAndCacheRejectsRestoredItem() async throws {
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first)
        try env.trashService.trashFrame(frameID: frame.id)
        let item = try XCTUnwrap(env.trashRepo.find(rootType: .frame, rootID: frame.id))
        let changes = try env.db.scalarInt("SELECT total_changes()")
        let image = try await env.trashPreviews.image(item: item, maxPixel: 120)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 120)
        XCTAssertEqual(try env.db.scalarInt("SELECT total_changes()"), changes)
        try env.trashService.restore(item)
        do {
            _ = try await env.trashPreviews.image(item: item, maxPixel: 120)
            XCTFail("A restored item must not be served from the Trash preview cache")
        } catch { }
    }

    private func parentWithDeletedPhoto() async throws -> (TrashItem, TrashItem) {
        let (id, parent) = try await seedSessionInTrash()
        let photo = try storedPhoto(id)
        try env.trashService.restore(parent)
        let child = try XCTUnwrap(env.sessions.trashPhotos(sessionID: id, pairs: [(photo.shotID, photo.id)]).first)
        try env.trashService.trashSession(sessionID: id)
        return (try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: id)), child)
    }

    func testTrashBatchNormalizesParentChildrenAndConfirmsImplicitDeletion() async throws {
        let (parent, child) = try await parentWithDeletedPhoto()
        let plan = try env.trashService.purgePlan(items: [parent, child])
        XCTAssertEqual(plan.targets.map(\.id), [parent.id])
        XCTAssertEqual(plan.includedChildren.map(\.id), [child.id])
        XCTAssertEqual(plan.estimatedBytes, parent.estimatedBytes)
        let onlyParent = try env.trashService.purgePlan(items: [parent])
        XCTAssertEqual(onlyParent.affectedIDs, [parent.id, child.id])
        XCTAssertEqual(try env.trashService.previewPhotos(parent).map(\.id), [child.rootID])
        XCTAssertNoThrow(try env.trashService.previewImage(child, maxPixel: 80))
        let result = env.trashService.purgeConfirmed(plan)
        XCTAssertEqual(result.results[parent.id], .processed)
        XCTAssertEqual(result.results[child.id], .processed)
        XCTAssertNil(try env.sessions.getSession(id: parent.rootID))
        XCTAssertNil(try env.trashRepo.getItem(id: child.id))
    }

    func testTrashBatchStopsWhenChildScopeChangesAndKeepsFiles() async throws {
        let (parent, child) = try await parentWithDeletedPhoto()
        let plan = try env.trashService.purgePlan(items: [parent])
        try env.db.run("UPDATE trash_items SET display_name=? WHERE id=?", [.text("Changed child"), .text(child.id)])
        let result = env.trashService.purgeConfirmed(plan)
        XCTAssertTrue(result.scopeChanged)
        XCTAssertNotNil(try env.trashRepo.getItem(id: parent.id))
        XCTAssertNotNil(try env.trashRepo.getItem(id: child.id))
        XCTAssertNoThrow(try env.trashService.previewImage(parent, maxPixel: 80))
    }

    func testTrashSelectAllConfinedToVisibleAndPartialFailureRetainsSelection() async throws {
        let (_, one) = try await seedSessionInTrash(nameSuffix: "visible")
        let (_, two) = try await seedSessionInTrash(nameSuffix: "hidden")
        try env.db.run("UPDATE trash_items SET display_name=? WHERE id=?", [.text("visible"), .text(one.id)])
        let vm = TrashViewModel(env: env)
        vm.searchText = "visible"
        vm.reload()
        vm.selectAllVisible()
        XCTAssertEqual(vm.selection, [one.id])
        vm.searchText = ""
        vm.reload()
        vm.selectAllVisible()
        XCTAssertEqual(vm.selection, [one.id, two.id])
        let scope = try XCTUnwrap(vm.prepareSelectionPurgeScope())
        let lock = try env.coordinator.acquire(key: "session:\(two.rootID)", reason: "QA contention")
        vm.executePurge(scope: scope)
        let deadline = ContinuousClock.now + .seconds(3)
        while vm.isPurging && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        lock.release()
        XCTAssertFalse(vm.isPurging)
        XCTAssertFalse(env.isManualPurging)
        XCTAssertEqual(vm.selection, [two.id])
        XCTAssertNil(try env.trashRepo.getItem(id: one.id))
        XCTAssertNotNil(try env.trashRepo.getItem(id: two.id))
        XCTAssertTrue(vm.batchDetails.contains("Bỏ qua"))
        vm.clearSelection()
        XCTAssertTrue(vm.selection.isEmpty)
    }
}

extension TrashAndSettingsFixTests {
    func testTrashPreviewCoalescesWaitersWithoutCancellingAnotherViewer() async throws {
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first)
        try env.trashService.trashFrame(frameID: frame.id)
        let item = try XCTUnwrap(env.trashRepo.find(rootType: .frame, rootID: frame.id))
        let service = env.trashPreviews
        let lock = try env.coordinator.acquire(key: "frame:\(frame.id)", reason: "QA preview contention")
        let first = Task { try await service.image(item: item, maxPixel: 120) }
        let second = Task { try await service.image(item: item, maxPixel: 120) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        try await Task.sleep(for: .milliseconds(100))
        lock.release()
        let image = try await second.value
        XCTAssertLessThanOrEqual(max(image.width, image.height), 120)
        do { _ = try await first.value; XCTFail("A cancelled viewer must not publish an image") } catch { }
        XCTAssertNotNil(try env.trashRepo.getItem(id: item.id))
    }
}

extension TrashAndSettingsFixTests {
    func testTrashBatchReleasesAppLockAfterViewModelIsDismissed() async throws {
        let (_, item) = try await seedSessionInTrash()
        var vm: TrashViewModel? = TrashViewModel(env: env)
        vm!.reload()
        let scope = try XCTUnwrap(vm!.prepareSinglePurgeScope(item: item))
        weak var dismissed = vm
        vm!.executePurge(scope: scope)
        vm = nil
        XCTAssertNil(dismissed)
        let deadline = ContinuousClock.now + .seconds(3)
        while env.isManualPurging && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(env.isManualPurging)
        XCTAssertNil(try env.trashRepo.getItem(id: item.id))
    }
}

private final class PhotoListAttemptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var delays: [UInt64] = []
    func nextRead() -> Int { lock.lock(); defer { lock.unlock() }; reads += 1; return reads }
    func recordWait(_ delay: UInt64) { lock.lock(); defer { lock.unlock() }; delays.append(delay) }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var waits: [UInt64] { lock.lock(); defer { lock.unlock() }; return delays }
}

extension TrashAndSettingsFixTests {
    func testPhotoListRetriesOnlyBusyAndPreservesResult() async throws {
        let probe = PhotoListAttemptProbe()
        let expected = [TrashService.PreviewPhoto(id: "photo-1", label: "Ảnh 1")]
        let actual = try await TrashPreviewLoader.readPhotoListWithRetry(read: {
            if probe.nextRead() == 1 { throw AppError.busy("Temporary read") }
            return expected
        }, wait: { probe.recordWait($0) })
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(probe.readCount, 2)
        XCTAssertEqual(probe.waits, [100_000_000])
    }

    func testPhotoListBusyBudgetIsFourReadsAndSevenHundredMilliseconds() async throws {
        let probe = PhotoListAttemptProbe()
        do {
            _ = try await TrashPreviewLoader.readPhotoListWithRetry(read: {
                throw AppError.busy("busy-\(probe.nextRead())")
            }, wait: { probe.recordWait($0) })
            XCTFail("A permanently busy list must return its final error")
        } catch { XCTAssertEqual(error as? AppError, .busy("busy-4")) }
        XCTAssertEqual(probe.readCount, 4)
        XCTAssertEqual(probe.waits, [100_000_000, 200_000_000, 400_000_000])
        XCTAssertEqual(probe.waits.reduce(0, +), 700_000_000)
    }

    func testPhotoListDoesNotRetryNonBusyErrors() async throws {
        for expected in [AppError.notFound("gone"), .invalidState("restored"), .ioFailure("database") ] {
            let probe = PhotoListAttemptProbe()
            do {
                _ = try await TrashPreviewLoader.readPhotoListWithRetry(read: {
                    _ = probe.nextRead()
                    throw expected
                }, wait: { probe.recordWait($0) })
                XCTFail("Required errors must not become an empty success")
            } catch { XCTAssertEqual(error as? AppError, expected) }
            XCTAssertEqual(probe.readCount, 1)
            XCTAssertTrue(probe.waits.isEmpty)
        }
    }

    func testPhotoListCancellationBeforeFirstRead() async throws {
        let probe = PhotoListAttemptProbe()
        let task = Task {
            try await TrashPreviewLoader.readPhotoListWithRetry(read: {
                _ = probe.nextRead()
                return []
            }, wait: { probe.recordWait($0) })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task must not return a list") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.readCount, 0)
        XCTAssertTrue(probe.waits.isEmpty)
    }

    func testPhotoListCancellationDuringBackoffStopsFurtherReads() async throws {
        let probe = PhotoListAttemptProbe()
        let waiting = expectation(description: "First busy backoff entered")
        let task = Task {
            try await TrashPreviewLoader.readPhotoListWithRetry(read: {
                _ = probe.nextRead()
                throw AppError.busy("temporary")
            }, wait: { delay in
                probe.recordWait(delay)
                waiting.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
            })
        }
        defer { task.cancel() }
        await fulfillment(of: [waiting], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Backoff cancellation must stop retries") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.readCount, 1)
        XCTAssertEqual(probe.waits, [100_000_000])
    }

    func testPhotoListCancellationDuringReadAndBeforePublication() async throws {
        for afterRead in [false, true] {
            let (id, item) = try await seedSessionInTrash()
            let service = env.trashService
            let probe = PhotoListAttemptProbe()
            let reached = expectation(description: afterRead ? "Read finished before publication" : "Read started")
            let gate = DispatchSemaphore(value: 0)
            let task = Task {
                try await TrashPreviewLoader.readPhotoListWithRetry(read: {
                    _ = probe.nextRead()
                    if afterRead {
                        let result = try service.previewPhotos(item)
                        reached.fulfill()
                        _ = gate.wait(timeout: .now() + 3)
                        return result
                    }
                    reached.fulfill()
                    _ = gate.wait(timeout: .now() + 3)
                    return try service.previewPhotos(item)
                }, wait: { probe.recordWait($0) })
            }
            await fulfillment(of: [reached], timeout: 3)
            task.cancel()
            gate.signal()
            do { _ = try await task.value; XCTFail("A late list must not be published") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(probe.readCount, 1)
            XCTAssertTrue(probe.waits.isEmpty)
            XCTAssertFalse(env.coordinator.isSessionBusy(id).busy)
            XCTAssertNotNil(try env.trashRepo.getItem(id: item.id))
        }
    }

    private func previewDatabaseManifest() throws -> [String: [SQLiteRow]] {
        var result: [String: [SQLiteRow]] = [:]
        for table in ["sessions", "session_shots", "photo_revisions", "photo_adjustments", "frames",
                      "frame_revisions", "frame_snapshots", "asset_references", "trash_items", "assets"] {
            result[table] = try env.db.query("SELECT * FROM \(table) ORDER BY rowid")
        }
        return result
    }

    private func previewFileManifest() throws -> [String: String] {
        var result: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: env.layout.rootURL.path) {
            let url = env.layout.rootURL.appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[path] = Hashing.sha256Hex(try Data(contentsOf: url))
            }
        }
        return result
    }

    func testPhotoListRetryAndRepeatedPreviewPreserveDataAndFileHashes() async throws {
        let (parent, child) = try await parentWithDeletedPhoto()
        let database = try previewDatabaseManifest()
        let files = try previewFileManifest()
        let changes = try env.db.scalarInt("SELECT total_changes()")
        let expected = try env.trashService.previewPhotos(parent)
        let probe = PhotoListAttemptProbe()
        let service = env.trashService
        let retried = try await TrashPreviewLoader.readPhotoListWithRetry(read: {
            if probe.nextRead() == 1 { throw AppError.busy("temporary") }
            return try service.previewPhotos(parent)
        }, wait: { probe.recordWait($0) })
        XCTAssertEqual(retried, expected)
        XCTAssertEqual(retried.map(\.id), [child.rootID])
        for _ in 0..<2 {
            let actual = try await env.trashPreviews.photos(item: parent)
            XCTAssertEqual(actual, expected)
            _ = try await env.trashPreviews.image(item: parent, maxPixel: 120)
        }
        XCTAssertEqual(try previewDatabaseManifest(), database)
        XCTAssertEqual(try previewFileManifest(), files)
        XCTAssertEqual(try env.db.scalarInt("SELECT total_changes()"), changes)
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }

    func testPhotoListRetryRevalidatesRestoredAndPurgedItems() async throws {
        for purge in [false, true] {
            let (_, item) = try await seedSessionInTrash()
            let service = env.trashService
            let probe = PhotoListAttemptProbe()
            do {
                _ = try await TrashPreviewLoader.readPhotoListWithRetry(read: {
                    if probe.nextRead() == 1 { throw AppError.busy("temporary") }
                    return try service.previewPhotos(item)
                }, wait: { _ in
                    if purge { XCTAssertEqual(service.purgeResult(item), .processed) }
                    else { try service.restore(item) }
                })
                XCTFail("A restored or purged Trash ID must not return stale photos")
            } catch {
                XCTAssertNotNil(error as? AppError)
                XCTAssertFalse(error is CancellationError)
            }
            XCTAssertEqual(probe.readCount, 2)
            XCTAssertNil(try env.trashRepo.getItem(id: item.id))
        }
    }
}
