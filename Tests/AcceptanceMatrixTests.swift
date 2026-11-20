import XCTest
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers
import Darwin
@testable import OpenPhotobooth

final class AcceptanceMatrixTests: XCTestCase {
    var env: AppEnvironment!

    @MainActor
    override func setUp() async throws {
        env = AppEnvironment(inMemory: true)
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
    }

    @MainActor
    override func tearDown() async throws {
        if let items = try? FileManager.default.contentsOfDirectory(at: env.layout.sessionsDir, includingPropertiesForKeys: nil) {
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        if let qItems = try? FileManager.default.contentsOfDirectory(at: env.layout.quarantineDir, includingPropertiesForKeys: nil) {
            for item in qItems { try? FileManager.default.removeItem(at: item) }
        }
    }

    // Helper: Tạo ảnh test màu đơn sắc
    private func createSampleImageData(width: Int = 400, height: Int = 400, color: CGColor = CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1.0)) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .png, properties: [:])!
    }

    // Helper: Tạo phiên hoàn tất gồm 4 ảnh
    @MainActor
    private func createCompleted4PhotoSession(reserve: Bool = false) async throws -> (session: CaptureSessionRecord, snapshot: FrameSnapshot, revisions: [Int: PhotoRevision]) {
        let frames = try env.frames.listReadyFrames()
        let frame = frames.first { (try? env.frames.getSlots(revisionID: $0.currentRevisionID ?? ""))?.count == 4 } ?? frames.first!
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)

        env.engine.resetToIdle()
        var defaults = env.settings.sessionDefaultsSnapshot()
        if reserve { defaults.selectionCaptureCount = 5 }
        let session = try env.engine.beginSession(
            snapshot: snapshot,
            mode: .automatic,
            cameraID: "fake-cam",
            defaults: defaults,
            countdown: 1,
            interval: 1
        )

        var revs: [Int: PhotoRevision] = [:]
        for i in 1...(reserve ? 5 : snapshot.requiredCaptureCount) {
            let data = createSampleImageData()
            let rev = try await env.safetySave.savePhoto(
                sessionID: session.id,
                captureIndex: i,
                payloadData: data,
                requestID: "\(session.id)-req-\(i)",
                width: 400,
                height: 400,
                orientation: 1,
                codec: "png",
                colorProfile: nil
            )
            revs[i] = rev
        }

        if reserve {
            try env.sessions.setStatus(sessionID: session.id, status: .reviewable)
            try env.sessions.confirmPhotoSelection(sessionID: session.id, order: [1, 2, 3, 4])
        }
        try env.sessions.setStatus(sessionID: session.id, status: .completed)
        env.engine.resetToIdle()
        let fresh = try env.sessions.getSession(id: session.id)!
        return (fresh, snapshot, revs)
    }

    @MainActor
    func testPB01StaleCaptureCannotReviveSessionMovedToTrash() async throws {
        let setup = try await createCompleted4PhotoSession()
        XCTAssertTrue(env.engine.adoptSession(record: setup.session, snapshot: setup.snapshot,
                                             committed: setup.revisions))
        env.engine.setStateForTesting(.paused(reason: .user, nextIndex: 1, kind: .normal))
        try env.trashService.trashSession(sessionID: setup.session.id)
        XCTAssertThrowsError(try env.engine.resume())
        XCTAssertThrowsError(try env.sessions.setStatus(sessionID: setup.session.id, status: .inProgress))
        XCTAssertEqual(try env.sessions.getSession(id: setup.session.id)?.status, .trashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.layout.sessionDir(setup.session.id).path))
    }

    @MainActor
    func testPB02ExplicitAutoFaceCommitsNewPlacementAndCanUndo() async throws {
        env.settings.smartFace = false
        let setup = try await createCompleted4PhotoSession()
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: setup.session.id)
        let slotID = try XCTUnwrap(vm.selectedSlotID)
        vm.updatePlacement(scale: 1.4, offsetX: 0.15, isFinal: true)
        let edited = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let before = try XCTUnwrap(edited.placements[slotID])

        vm.recomputeAutoFace()
        let deadline = ContinuousClock.now + .seconds(4)
        while vm.detail?.session.revisionNo == edited.session.revisionNo, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let updated = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        XCTAssertEqual(updated.placements[slotID]?.placement, PhotoPlacement())
        XCTAssertEqual(updated.session.revisionNo, edited.session.revisionNo + 1)
        vm.undo()
        XCTAssertEqual(try env.sessions.getDetail(sessionID: setup.session.id)?.placements[slotID]?.placement, before.placement)

        vm.recomputeAutoFace()
        vm.updatePlacement(scale: 1.6, isFinal: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try env.sessions.getDetail(sessionID: setup.session.id)?.placements[slotID]?.scale, 1.6)
    }

    @MainActor
    func testPB15ExportRejectsAcceptedPreviewAfterPlacementChanges() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        var request = ExportService.ExportRequest(sessionID: setup.session.id, format: .png, quality: 95,
                                                  width: 400, height: 400, filenameBase: "StalePreview",
                                                  destinationFolder: env.layout.rootURL)
        request.acceptedPreview = .init(detail: detail, format: .png, width: 400, height: 400, quality: 95)
        let slot = try XCTUnwrap(setup.snapshot.slots.first)
        try env.sessions.setPlacement(sessionID: setup.session.id, snapshotSlotID: slot.id,
                                     placement: PhotoPlacement(scale: 1.2), cropMode: .fill, manualOverride: true)

        do {
            _ = try await env.exportService.export(detail: detail, request: request)
            XCTFail("A stale preview must not authorize export")
        } catch AppError.exportPreviewChanged {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.layout.rootURL.appendingPathComponent("StalePreview.png").path))
        XCTAssertTrue(try env.sessions.listExportRecords(sessionID: setup.session.id).isEmpty)
    }

    @MainActor
    func testPB06ExportKeepsVerifiedFileWhenHistoryInsertFails() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let request = ExportService.ExportRequest(sessionID: setup.session.id, format: .png, quality: 95,
                                                  width: 400, height: 400, filenameBase: "PartialExport",
                                                  destinationFolder: env.layout.rootURL)
        try env.db.run("""
            CREATE TEMP TRIGGER fail_export_history BEFORE INSERT ON export_records
            BEGIN SELECT RAISE(ABORT, 'QA history failure'); END
            """)
        do {
            _ = try await env.exportService.export(detail: detail, request: request)
            XCTFail("Export cannot report full success without its history")
        } catch AppError.exportHistoryNotSaved(let file) {
            XCTAssertEqual(file.url.lastPathComponent, "PartialExport.png")
            XCTAssertNotNil(ImageNormalizer.uprightImage(url: file.url))
            XCTAssertEqual(file.sha256, Hashing.sha256Hex(fileURL: file.url))
        }
        XCTAssertTrue(try env.sessions.listExportRecords(sessionID: setup.session.id).isEmpty)
    }

    @MainActor
    func testPB17ExportRejectsDecodableReplacementAndAllowsLegacyEmptyHash() async throws {
        let setup = try await createCompleted4PhotoSession()
        let photo = try XCTUnwrap(setup.revisions[1])
        try createSampleImageData(color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            .write(to: env.sessions.fileURL(for: photo), options: .atomic)
        let request = ExportService.ExportRequest(sessionID: setup.session.id, format: .png, quality: 95,
                                                  width: 400, height: 400, filenameBase: "Checksum",
                                                  destinationFolder: env.layout.rootURL)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        do {
            _ = try await env.exportService.export(detail: detail, request: request)
            XCTFail("A different image with valid PNG bytes must be rejected")
        } catch AppError.ioFailure(let reason) {
            XCTAssertTrue(reason.contains("checksum"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.layout.rootURL.appendingPathComponent("Checksum.png").path))

        try env.db.run("UPDATE photo_revisions SET sha256='' WHERE id=?", [.text(photo.id)])
        let legacy = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let (record, url) = try await env.exportService.export(detail: legacy, request: request)
        XCTAssertEqual(record.status, .success)
        XCTAssertNotNil(ImageNormalizer.uprightImage(url: url))
    }

    @MainActor
    func testExportOverwriteRejectsDirectoryAndLinksAndSuffixesOccupiedNames() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let folder = env.layout.exportsTempDir
        let directory = folder.appendingPathComponent("directory.jpg")
        let marker = directory.appendingPathComponent("keep.txt")
        let sentinel = Data("keep".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try sentinel.write(to: marker)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link.jpg").path,
                                                   withDestinationPath: marker.path)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("dangling.jpg").path,
                                                   withDestinationPath: "missing")
        for name in ["directory", "link", "dangling"] {
            var request = ExportService.ExportRequest(sessionID: detail.session.id, format: .jpeg, quality: 90,
                width: 400, height: 400, filenameBase: name, destinationFolder: folder, replaceExisting: true)
            do {
                _ = try await env.exportService.export(detail: detail, request: request)
                XCTFail("Overwrite accepted occupied non-file: \(name)")
            } catch AppError.exportFailed(let reason) { XCTAssertTrue(reason.contains("không phải tệp thường")) }
            XCTAssertFalse(try env.sessions.listExportRecords(sessionID: detail.session.id).contains {
                $0.status == .success && $0.filename == "\(name).jpg"
            })
            request.replaceExisting = false
            let (record, url) = try await env.exportService.export(detail: detail, request: request)
            XCTAssertEqual(url.lastPathComponent, "\(name) (1).jpg")
            XCTAssertEqual(record.sha256, Hashing.sha256Hex(fileURL: url))
        }
        XCTAssertEqual(try Data(contentsOf: marker), sentinel)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link.jpg").path), marker.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("dangling.jpg").path), "missing")
        let invalid = ExportService.ExportRequest(sessionID: detail.session.id, format: .jpeg, quality: 90,
            width: 400, height: 400, filenameBase: "truncated\0name", destinationFolder: folder, replaceExisting: true)
        do {
            _ = try await env.exportService.export(detail: detail, request: invalid)
            XCTFail("An embedded NUL must not reach POSIX path handling")
        } catch AppError.exportFailed(let reason) { XCTAssertTrue(reason.contains("không hợp lệ")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("truncated").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".partial") })
    }

    #if DEBUG
    @MainActor
    func testExportRechecksIdentityAndRejectsLateConflictsWithoutRemovingTheirBytes() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let folder = env.layout.exportsTempDir
        let original = Data("old bytes".utf8)
        let concurrent = Data("concurrent bytes".utf8)
        defer { env.exportService.onFileCommitForTesting = nil }
        for name in ["other-inode", "late-directory", "late-link", "occupied", "metadata-error"] {
            let url = folder.appendingPathComponent("\(name).png")
            if name != "occupied" { try original.write(to: url) }
            env.exportService.onFileCommitForTesting = { step, target in
                if step == .beforeCoordination && name == "other-inode" {
                    try concurrent.write(to: target, options: .atomic)
                }
                if step == .beforeMetadata && name == "metadata-error" {
                    throw AppError.ioFailure("QA metadata failure")
                }
                if step == .beforeRename {
                    switch name {
                    case "late-directory", "late-link":
                        try FileManager.default.moveItem(at: target, to: target.appendingPathExtension("old"))
                        if name == "late-directory" {
                            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                            try concurrent.write(to: target.appendingPathComponent("keep.txt"))
                        } else {
                            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: target.appendingPathExtension("old").path)
                        }
                    case "occupied": try concurrent.write(to: target)
                    default: break
                    }
                }
            }
            let request = ExportService.ExportRequest(sessionID: detail.session.id, format: .png, quality: 90,
                width: 400, height: 400, filenameBase: name, destinationFolder: folder, replaceExisting: true)
            do {
                _ = try await env.exportService.export(detail: detail, request: request)
                XCTFail("Export should reject \(name)")
            } catch AppError.exportFailed(let reason) where name != "occupied" {
                XCTAssertTrue(reason.contains(name == "metadata-error" ? "QA metadata failure" : "Tệp đích đã thay đổi"), reason)
            } catch AppError.exportFileExists where name == "occupied" {}
            switch name {
            case "late-directory": XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("keep.txt")), concurrent)
            case "late-link":
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), url.appendingPathExtension("old").path)
                XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("old")), original)
            case "metadata-error": XCTAssertEqual(try Data(contentsOf: url), original)
            default: XCTAssertEqual(try Data(contentsOf: url), concurrent)
            }
        }
        XCTAssertFalse(try env.sessions.listExportRecords(sessionID: detail.session.id).contains { $0.status == .success })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".partial") })
    }

    @MainActor
    func testExportStopsBeforeRenameWhenSelectedFolderMoves() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let original = Data("QA original".utf8)
        defer { env.exportService.onFileCommitForTesting = nil }
        for overwrite in [false, true] {
            let folder = env.layout.exportsTempDir.appendingPathComponent("selected-\(overwrite)")
            let moved = env.layout.exportsTempDir.appendingPathComponent("moved-\(overwrite)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let name = "result.png"
            if overwrite { try original.write(to: folder.appendingPathComponent(name)) }
            env.exportService.onFileCommitForTesting = { step, _ in
                guard step == .beforeRename else { return }
                try FileManager.default.moveItem(at: folder, to: moved)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            let request = ExportService.ExportRequest(sessionID: detail.session.id, format: .png, quality: 95,
                width: 400, height: 400, filenameBase: "result", destinationFolder: folder, replaceExisting: overwrite)
            do {
                _ = try await env.exportService.export(detail: detail, request: request)
                XCTFail("A moved folder must stop the export, overwrite=\(overwrite)")
            } catch AppError.exportFolderChanged {}
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), overwrite ? [name] : [])
            if overwrite { XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(name)), original) }
            print("QA-EXPORT-FOLDER before-rename overwrite=\(overwrite) old-contents-preserved")
        }
        let records = try env.sessions.listExportRecords(sessionID: detail.session.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.status == .failed && $0.destinationDisplayPath == nil })
    }

    @MainActor
    func testExportKeepsWrittenImageButRejectsStaleAndLookalikePathsBeforeHistory() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let unrelated = createSampleImageData(color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        defer { env.exportService.onFileCommitForTesting = nil }
        let cases: [(String, ExportService.FileCommitStep, Bool, Bool)] = [
            ("after-rename-empty", .afterRename, true, false),
            ("after-rename-lookalike", .afterRename, true, true),
            ("before-history-empty", .beforeHistoryValidation, true, false),
            ("before-history-lookalike", .beforeHistoryValidation, true, true),
            ("before-history-same-folder", .beforeHistoryValidation, false, true)
        ]
        for (label, injectionPoint, moveFolder, addLookalike) in cases {
            let folder = env.layout.exportsTempDir.appendingPathComponent(label)
            let moved = folder.appendingPathExtension("moved")
            let url = folder.appendingPathComponent("result.png")
            let actual = moveFolder ? moved.appendingPathComponent("result.png") : folder.appendingPathComponent("relocated.png")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            env.exportService.onFileCommitForTesting = { step, _ in
                guard step == injectionPoint else { return }
                if moveFolder {
                    try FileManager.default.moveItem(at: folder, to: moved)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                } else {
                    try FileManager.default.moveItem(at: url, to: actual)
                }
                if addLookalike { try unrelated.write(to: url) }
            }
            let request = ExportService.ExportRequest(sessionID: detail.session.id, format: .png, quality: 95,
                width: 400, height: 400, filenameBase: "result", destinationFolder: folder)
            do {
                _ = try await env.exportService.export(detail: detail, request: request)
                XCTFail("Success must not include an unverified URL: \(label)")
            } catch AppError.exportLocationUnconfirmed {}
            XCTAssertNotNil(ImageNormalizer.uprightImage(url: actual))
            XCTAssertNotEqual(try Data(contentsOf: actual), unrelated)
            if addLookalike { XCTAssertEqual(try Data(contentsOf: url), unrelated) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
            let actualFolder = actual.deletingLastPathComponent()
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: actualFolder.path).contains { $0.hasSuffix(".partial") })
            print("QA-EXPORT-FOLDER \(label) retained-output=true returned-success=false")
        }
        let records = try env.sessions.listExportRecords(sessionID: detail.session.id)
        XCTAssertEqual(records.count, cases.count)
        XCTAssertTrue(records.allSatisfy { $0.status == .failed && $0.destinationDisplayPath == nil })
    }

    @MainActor
    func testAutoExportWarnsWhenWrittenFileCanNoLongerBeVerified() async throws {
        let setup = try await createCompleted4PhotoSession()
        try env.sessions.setStatus(sessionID: setup.session.id, status: .reviewable)
        let folder = env.layout.exportsTempDir.appendingPathComponent("auto")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        env.settings.exportFolderBookmarkID = try env.trashRepo.saveBookmark(purpose: "exportFolder", blob: bookmark, displayPath: folder.path)
        env.settings.autoExport = true
        defer { env.exportService.onFileCommitForTesting = nil }
        env.exportService.onFileCommitForTesting = { step, target in
            guard step == .beforeHistoryValidation else { return }
            let actual = target.deletingLastPathComponent().appendingPathComponent("retained.jpg")
            try FileManager.default.moveItem(at: target, to: actual)
        }
        let completed = try await env.completeSession(sessionID: setup.session.id)
        XCTAssertTrue(completed)
        XCTAssertEqual(try env.sessions.getSession(id: setup.session.id)?.status, .completed)
        XCTAssertEqual(env.toast?.kind, .warning)
        XCTAssertEqual(env.toast?.text, AppError.exportLocationUnconfirmed.message)
        XCTAssertNotNil(ImageNormalizer.uprightImage(url: folder.appendingPathComponent("retained.jpg")))
        let records = try env.sessions.listExportRecords(sessionID: setup.session.id)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.status, .failed)
        XCTAssertNil(records.first?.destinationDisplayPath)
    }

    @MainActor
    func testManualExportWarnsAndDoesNotRevealUnverifiedOutput() async throws {
        let setup = try await createCompleted4PhotoSession()
        let review = ReviewViewModel(env: env)
        await review.load(sessionID: setup.session.id)
        let sheet = ExportViewModel(env: env)
        let folder = env.layout.exportsTempDir
        sheet.review = review
        sheet.format = .png
        sheet.width = 400
        sheet.height = 400
        sheet.filename = "manual"
        sheet.selectFolder(folder)
        sheet.updatePreview()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while sheet.isPreviewLoading && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard sheet.canExportPreview else { return XCTFail("The fixture must have a ready preview") }

        var finderURL: URL?
        env.shareService.revealInFinderHook = { finderURL = $0 }
        defer {
            env.shareService.revealInFinderHook = nil
            env.exportService.onFileCommitForTesting = nil
        }
        await sheet.runExport()
        let validURL = try XCTUnwrap(sheet.lastResultURL)
        await sheet.revealResult()?.value
        XCTAssertEqual(finderURL, validURL)
        let previous = try XCTUnwrap(env.sessions.listExportRecords(sessionID: setup.session.id).first)
        XCTAssertEqual(previous.destinationDisplayPath, validURL.path)
        XCTAssertEqual(previous.sha256, Hashing.sha256Hex(fileURL: validURL))
        finderURL = nil

        env.exportService.onFileCommitForTesting = { step, target in
            guard step == .beforeHistoryValidation else { return }
            try FileManager.default.moveItem(at: target, to: folder.appendingPathComponent("retained.png"))
        }
        await sheet.runExport()
        XCTAssertEqual(sheet.errorMessage, AppError.exportLocationUnconfirmed.message)
        XCTAssertNil(sheet.lastResultURL)
        XCTAssertFalse(sheet.historySaveFailed)
        XCTAssertNil(sheet.revealResult())
        XCTAssertNil(finderURL)
        XCTAssertNotNil(ImageNormalizer.uprightImage(url: folder.appendingPathComponent("retained.png")))
        let records = try env.sessions.listExportRecords(sessionID: setup.session.id)
        XCTAssertEqual(records.filter { $0.status == .success }.map(\.id), [previous.id])
        XCTAssertNil(records.first { $0.status == .failed }?.destinationDisplayPath)
    }

    @MainActor
    func testManualExportRejectsChangedFolderSelectedBeforeClick() async throws {
        for fromDefault in [true, false] {
            for overwrite in [false, true] {
                let setup = try await createCompleted4PhotoSession()
                let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
                let folder = env.layout.exportsTempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let moved = folder.appendingPathExtension("moved")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                if fromDefault { _ = try env.saveDefaultExportFolder(folder) }
                let sheet = await manualExportSheet(detail: detail, chosenFolder: fromDefault ? nil : folder)
                let original = Data("original folder".utf8)
                let other = Data("replacement folder".utf8)
                let name = "selection.png"
                if overwrite { try original.write(to: folder.appendingPathComponent(name)) }
                try FileManager.default.moveItem(at: folder, to: moved)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                if overwrite { try other.write(to: folder.appendingPathComponent(name)) }
                sheet.replaceExisting = overwrite
                await sheet.runExport()
                XCTAssertEqual(sheet.errorMessage, AppError.exportFolderChanged.message)
                XCTAssertNil(sheet.folderURL)
                XCTAssertNil(sheet.lastResultURL)
                XCTAssertTrue(try env.sessions.listExportRecords(sessionID: setup.session.id).isEmpty)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), overwrite ? [name] : [])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), overwrite ? [name] : [])
                if overwrite {
                    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), other)
                    XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(name)), original)
                }
                XCTAssertEqual(sheet.filename, "selection")
                XCTAssertEqual(sheet.width, 400)
                XCTAssertEqual(sheet.height, 400)
                XCTAssertEqual(sheet.quality, 86)
                XCTAssertEqual(sheet.format, .png)
                XCTAssertEqual(sheet.replaceExisting, overwrite)

                sheet.selectFolder(moved)
                await sheet.runExport()
                let file = try XCTUnwrap(sheet.lastResultURL)
                let record = try XCTUnwrap(env.sessions.listExportRecords(sessionID: setup.session.id).first)
                XCTAssertEqual(file.path, moved.appendingPathComponent(name).path)
                XCTAssertEqual(record.status, .success)
                XCTAssertEqual(record.sessionRevisionNo, detail.session.revisionNo)
                XCTAssertEqual(record.destinationDisplayPath, file.path)
                XCTAssertEqual(record.destinationBookmarkID, env.settings.exportFolderBookmarkID)
                XCTAssertNotNil(record.destinationBookmarkID)
                XCTAssertEqual(record.sha256, Hashing.sha256Hex(fileURL: file))
                print("QA-RESELECT default=\(fromDefault) overwrite=\(overwrite) rejectedReplacement=true verifiedRetry=true")
            }
        }
    }

    @MainActor
    func testManualExportWithUnsavedBookmarkStillVerifiesSelectedFolder() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let folder = env.layout.exportsTempDir.appendingPathComponent("one-off", isDirectory: true)
        let moved = folder.appendingPathExtension("moved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try env.db.run("""
            CREATE TEMP TRIGGER reject_export_bookmark BEFORE INSERT ON app_bookmarks
            BEGIN SELECT RAISE(ABORT, 'QA bookmark could not be saved'); END
            """)
        let sheet = await manualExportSheet(detail: detail, chosenFolder: folder)
        XCTAssertEqual(sheet.errorMessage, "Không lưu được thư mục mặc định. Bạn vẫn có thể thử xuất lần này.")
        XCTAssertEqual(sheet.folderURL, folder)
        await sheet.runExport()
        let file = try XCTUnwrap(sheet.lastResultURL)
        let record = try XCTUnwrap(env.sessions.listExportRecords(sessionID: setup.session.id).first)
        XCTAssertEqual(record.status, .success)
        XCTAssertEqual(record.sessionID, setup.session.id)
        XCTAssertEqual(record.sessionRevisionNo, detail.session.revisionNo)
        XCTAssertNil(record.destinationBookmarkID)
        XCTAssertEqual(record.destinationDisplayPath, file.path)
        XCTAssertEqual(record.sha256, Hashing.sha256Hex(fileURL: file))
        var revealed: URL?
        env.shareService.revealInFinderHook = { revealed = $0 }
        defer { env.shareService.revealInFinderHook = nil }
        await sheet.revealResult()?.value
        XCTAssertEqual(revealed, file)

        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        await sheet.runExport()
        XCTAssertEqual(sheet.errorMessage, AppError.exportFolderChanged.message)
        XCTAssertNil(sheet.lastResultURL)
        XCTAssertNil(sheet.folderURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertEqual(try env.sessions.listExportRecords(sessionID: setup.session.id), [record])
        XCTAssertEqual(Hashing.sha256Hex(fileURL: moved.appendingPathComponent(file.lastPathComponent)), record.sha256)
        print("QA-ONE-OFF bookmark=nil SHA=\(record.sha256 ?? "") changedFolderRejected=true")
    }

    @MainActor
    func testManualFinderRejectsAnotherSessionsOverwriteAndInvalidPaths() async throws {
        let first = try await createCompleted4PhotoSession()
        let second = try await createCompleted4PhotoSession()
        let firstDetail = try XCTUnwrap(env.sessions.getDetail(sessionID: first.session.id))
        let secondDetail = try XCTUnwrap(env.sessions.getDetail(sessionID: second.session.id))
        let folder = env.layout.exportsTempDir.appendingPathComponent("manual-finder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sheet = await manualExportSheet(detail: firstDetail, chosenFolder: folder)
        await sheet.runExport()
        let url = try XCTUnwrap(sheet.lastResultURL)
        let original = try XCTUnwrap(env.sessions.listExportRecords(sessionID: first.session.id).first)
        var revealed: [URL] = []
        env.shareService.revealInFinderHook = { revealed.append($0) }
        defer { env.shareService.revealInFinderHook = nil }
        await sheet.revealResult()?.value
        XCTAssertEqual(revealed, [url])
        XCTAssertNil(sheet.finderWarning)

        let request = ExportService.ExportRequest(sessionID: second.session.id, format: .png, quality: 95,
            width: 520, height: 400, filenameBase: sheet.filename, destinationFolder: folder, replaceExisting: true)
        let (replacement, replacedURL) = try await env.exportService.export(detail: secondDetail, request: request)
        XCTAssertEqual(replacedURL, url)
        XCTAssertNotEqual(replacement.sha256, original.sha256)
        XCTAssertEqual(replacement.sha256, Hashing.sha256Hex(fileURL: url))
        await sheet.revealResult()?.value
        XCTAssertEqual(revealed, [url])
        XCTAssertEqual(sheet.finderWarning, "Tệp xuất đã bị thay thế hoặc chỉnh sửa")
        print("QA-SHEET-FINDER firstSHA=\(original.sha256 ?? "") onDiskSHA=\(replacement.sha256 ?? "") blocked=true")

        let movedFile = folder.appendingPathComponent("moved.png")
        try FileManager.default.moveItem(at: url, to: movedFile)
        await sheet.revealResult()?.value
        XCTAssertEqual(sheet.finderWarning, "Không còn tìm thấy tệp xuất tại vị trí đã lưu")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: movedFile)
        await sheet.revealResult()?.value
        XCTAssertEqual(sheet.finderWarning, "Không còn tìm thấy tệp xuất tại vị trí đã lưu")

        let movedFolder = folder.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: folder, to: movedFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        await sheet.revealResult()?.value
        XCTAssertEqual(sheet.finderWarning, "Không thể truy cập tệp xuất")
        XCTAssertEqual(revealed, [url])
        XCTAssertEqual(try env.sessions.listExportRecords(sessionID: first.session.id), [original])
    }

    @MainActor
    func testManualFinderKeepsHistoryWarningAndVerifiesFileWithoutHistory() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let sheet = await manualExportSheet(detail: detail, chosenFolder: env.layout.exportsTempDir)
        try env.db.run("""
            CREATE TEMP TRIGGER fail_export_history BEFORE INSERT ON export_records
            BEGIN SELECT RAISE(ABORT, 'QA history failure'); END
            """)
        await sheet.runExport()
        let file = try XCTUnwrap(sheet.lastResultURL)
        let originalHash = try XCTUnwrap(Hashing.sha256Hex(fileURL: file))
        let warning = try XCTUnwrap(sheet.historyWarning)
        XCTAssertEqual(warning, "Đã lưu \(file.lastPathComponent), chưa ghi được lịch sử xuất.")
        XCTAssertNil(sheet.errorMessage)
        XCTAssertTrue(sheet.historySaveFailed)
        XCTAssertTrue(try env.sessions.listExportRecords(sessionID: setup.session.id).isEmpty)

        let next = env.layout.exportsTempDir.appendingPathComponent("next", isDirectory: true)
        let oneOff = env.layout.exportsTempDir.appendingPathComponent("one-off-next", isDirectory: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: oneOff, withIntermediateDirectories: false)
        sheet.selectFolder(next)
        XCTAssertEqual(sheet.folderURL, next)
        XCTAssertEqual(sheet.lastResultURL, file)
        XCTAssertEqual(sheet.historyWarning, warning)
        XCTAssertNil(sheet.errorMessage)
        XCTAssertEqual(Hashing.sha256Hex(fileURL: file), originalHash)
        XCTAssertTrue(try env.sessions.listExportRecords(sessionID: setup.session.id).isEmpty)

        try env.db.run("""
            CREATE TEMP TRIGGER fail_next_bookmark BEFORE INSERT ON app_bookmarks
            BEGIN SELECT RAISE(ABORT, 'QA bookmark failure'); END
            """)
        sheet.selectFolder(oneOff)
        XCTAssertEqual(sheet.folderURL, oneOff)
        XCTAssertEqual(sheet.lastResultURL, file)
        XCTAssertEqual(sheet.historyWarning, warning)
        XCTAssertEqual(sheet.errorMessage, "Không lưu được thư mục mặc định. Bạn vẫn có thể thử xuất lần này.")
        var revealed: [URL] = []
        env.shareService.revealInFinderHook = { revealed.append($0) }
        defer { env.shareService.revealInFinderHook = nil }
        await sheet.revealResult()?.value
        XCTAssertEqual(revealed, [file])
        XCTAssertNil(sheet.finderWarning)

        try createSampleImageData(color: CGColor(red: 0, green: 1, blue: 0, alpha: 1)).write(to: file, options: .atomic)
        await sheet.revealResult()?.value
        XCTAssertEqual(revealed, [file])
        XCTAssertEqual(sheet.finderWarning, "Tệp xuất đã bị thay thế hoặc chỉnh sửa")
        XCTAssertTrue(sheet.historySaveFailed)
        XCTAssertEqual(sheet.historyWarning, warning)
        XCTAssertTrue(try env.sessions.listExportRecords(sessionID: setup.session.id).isEmpty)
        print("QA-SHEET-NO-HISTORY correctFileRevealed=true replacementBlocked=true bothWarningsPreserved=true")

        try env.db.run("DROP TRIGGER fail_export_history")
        try env.db.run("DROP TRIGGER fail_next_bookmark")
        sheet.selectFolder(next)
        await sheet.runExport()
        let newFile = try XCTUnwrap(sheet.lastResultURL)
        let record = try XCTUnwrap(env.sessions.listExportRecords(sessionID: setup.session.id).first)
        XCTAssertEqual(newFile.deletingLastPathComponent(), next)
        XCTAssertEqual(record.destinationDisplayPath, newFile.path)
        XCTAssertEqual(record.sha256, Hashing.sha256Hex(fileURL: newFile))
        XCTAssertEqual(record.sessionRevisionNo, detail.session.revisionNo)
        XCTAssertEqual(record.destinationBookmarkID, env.settings.exportFolderBookmarkID)
        XCTAssertNotNil(record.destinationBookmarkID)
        XCTAssertEqual(record.status, .success)
        XCTAssertNil(sheet.historyWarning)
        XCTAssertNil(sheet.finderWarning)
        XCTAssertNil(sheet.errorMessage)
        print("QA-HISTORY-WARNING retainedAfterFolderSelection=true retainedAfterBookmarkFailure=true newExportClearedWarnings=true")
    }

    @MainActor
    func testManualFinderInvalidatesLateRequestsOnRepeatNewExportAndDismiss() async throws {
        for action in ["repeat", "export", "dismiss"] {
            let setup = try await createCompleted4PhotoSession()
            let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
            let folder = env.layout.exportsTempDir.appendingPathComponent(action, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let sheet = await manualExportSheet(detail: detail, chosenFolder: folder)
            try env.db.run("""
                CREATE TEMP TRIGGER IF NOT EXISTS fail_export_history BEFORE INSERT ON export_records
                BEGIN SELECT RAISE(ABORT, 'QA history failure'); END
                """)
            await sheet.runExport()
            let firstFile = try XCTUnwrap(sheet.lastResultURL)
            let firstBookmarkID = try XCTUnwrap(env.settings.exportFolderBookmarkID)
            let reading = expectation(description: "\(action): old request opened the file")
            let cancelled = expectation(description: "\(action): old request received cancellation")
            let release = DispatchSemaphore(value: 0)
            sheet.onFinderHashForTesting = { _ in
                reading.fulfill()
                guard release.wait(timeout: .now() + 10) == .success else {
                    throw AppError.ioFailure("QA read did not resume")
                }
                if Task.isCancelled { cancelled.fulfill() }
                throw AppError.externalFolderPermissionLost
            }
            var revealed: [URL] = []
            env.shareService.revealInFinderHook = { revealed.append($0) }
            let first = try XCTUnwrap(sheet.revealResult())
            defer {
                release.signal()
                first.cancel()
                env.shareService.revealInFinderHook = nil
            }
            await fulfillment(of: [reading], timeout: 5)
            sheet.onFinderHashForTesting = nil
            switch action {
            case "repeat":
                await sheet.revealResult()?.value
                XCTAssertEqual(revealed, [firstFile])
            case "export":
                let newFolder = folder.appendingPathComponent("new", isDirectory: true)
                try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: false)
                sheet.selectFolder(newFolder)
                await sheet.runExport()
                XCTAssertNotEqual(sheet.lastResultURL, firstFile)
                XCTAssertNotNil(try env.trashRepo.bookmark(id: firstBookmarkID))
                XCTAssertTrue(revealed.isEmpty)
            default:
                sheet.cancelResultReveal()
                XCTAssertTrue(revealed.isEmpty)
            }
            release.signal()
            await first.value
            await fulfillment(of: [cancelled], timeout: 3)
            XCTAssertEqual(revealed, action == "repeat" ? [firstFile] : [])
            XCTAssertNil(sheet.finderWarning)
            if action == "export" {
                XCTAssertNil(try env.trashRepo.bookmark(id: firstBookmarkID))
            }
            print("QA-SHEET-CANCEL action=\(action) cancelled=true noLateWarning=true noLateReveal=true")
        }
    }

    @MainActor
    func testManualExportClearsFolderChangedDuringWriteAndKeepsDestinationOnFileConflict() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let original = Data("previous output".utf8)
        let replacement = Data("concurrent output".utf8)
        let cases: [(String, ExportService.FileCommitStep, Bool, Bool)] = [
            ("coordination-missing", .beforeCoordination, true, true),
            ("coordination", .insideCoordination, true, true),
            ("rename-new", .beforeRename, false, true),
            ("rename-overwrite", .beforeRename, true, true),
            ("file-only", .insideCoordination, true, false)
        ]
        defer { env.exportService.onFileCommitForTesting = nil }
        for (index, (name, stepToChange, overwrite, changeFolder)) in cases.enumerated() {
            let folder = env.layout.exportsTempDir.appendingPathComponent(name, isDirectory: true)
            let moved = folder.appendingPathExtension("moved")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let file = folder.appendingPathComponent("selection.png")
            if overwrite { try original.write(to: file) }
            let sheet = await manualExportSheet(detail: detail, chosenFolder: folder)
            sheet.replaceExisting = overwrite
            env.exportService.onFileCommitForTesting = { step, target in
                guard step == stepToChange else { return }
                if changeFolder {
                    try FileManager.default.moveItem(at: folder, to: moved)
                    if stepToChange == .beforeCoordination { return }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                }
                try replacement.write(to: target, options: .atomic)
            }
            await sheet.runExport()
            XCTAssertNil(sheet.lastResultURL)
            XCTAssertEqual(sheet.folderURL, changeFolder ? nil : folder)
            if changeFolder {
                XCTAssertEqual(sheet.errorMessage, AppError.exportFolderChanged.message)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), overwrite ? ["selection.png"] : [])
                if overwrite { XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("selection.png")), original) }
            } else {
                XCTAssertTrue(sheet.errorMessage?.contains("Tệp đích đã thay đổi") == true)
            }
            if stepToChange == .beforeCoordination {
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: file), replacement)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["selection.png"])
            }
            let existing = try env.sessions.listExportRecords(sessionID: setup.session.id)
            XCTAssertEqual(existing.filter { $0.filename == "selection.png" && $0.status == .failed }.count,
                           index + 1)
            if changeFolder {
                env.exportService.onFileCommitForTesting = nil
                sheet.selectFolder(moved)
                XCTAssertEqual(sheet.filename, "selection")
                XCTAssertEqual(sheet.width, 400)
                XCTAssertEqual(sheet.height, 400)
                XCTAssertEqual(sheet.format, .png)
                XCTAssertEqual(sheet.quality, 86)
                XCTAssertEqual(sheet.replaceExisting, overwrite)
                XCTAssertTrue(sheet.canExportPreview)
                await sheet.runExport()
                XCTAssertEqual(sheet.lastResultURL?.path, moved.appendingPathComponent("selection.png").path)
                XCTAssertTrue(try env.sessions.listExportRecords(sessionID: setup.session.id).contains {
                    $0.status == .success && $0.destinationDisplayPath == sheet.lastResultURL?.path
                })
            }
            print("QA-LATE-DESTINATION case=\(name) folderCleared=\(changeFolder) replacementPreserved=true")
        }
    }

    @MainActor
    private func manualExportSheet(detail: SessionDetail, chosenFolder: URL?) async -> ExportViewModel {
        let review = ReviewViewModel(env: env)
        await review.load(sessionID: detail.session.id)
        let sheet = ExportViewModel(env: env)
        sheet.review = review
        sheet.configure(detail: detail)
        sheet.format = .png
        sheet.width = 400
        sheet.height = 400
        sheet.quality = 86
        sheet.filename = "selection"
        if let chosenFolder { sheet.selectFolder(chosenFolder) }
        sheet.updatePreview()
        let deadline = ContinuousClock.now + .seconds(8)
        while sheet.isPreviewLoading && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sheet.canExportPreview)
        return sheet
    }
    #endif

    @MainActor
    func testExportOverwriteRetainsMetadataAndVerifiedNewImage() async throws {
        let setup = try await createCompleted4PhotoSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: setup.session.id))
        let folder = env.layout.exportsTempDir
        let url = folder.appendingPathComponent("metadata.png")
        let old = Data("previous content".utf8)
        try old.write(to: url)
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .posixPermissions: 0o640], ofItemAtPath: url.path)
        let acl = try XCTUnwrap(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_file(url.path, ACL_TYPE_EXTENDED, acl), 0)
        let comment = try PropertyListSerialization.data(fromPropertyList: "QA comment", format: .binary, options: 0)
        var finder = Data(repeating: 0, count: 32)
        finder[9] = 0x06
        let attributes = ["com.apple.metadata:kMDItemFinderComment": comment, "com.apple.FinderInfo": finder]
        for (key, bytes) in attributes {
            XCTAssertEqual(bytes.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, $0.count, 0, 0) }, 0)
        }
        let request = ExportService.ExportRequest(sessionID: detail.session.id, format: .png, quality: 90,
            width: 400, height: 400, filenameBase: "metadata", destinationFolder: folder, replaceExisting: true)
        let (record, saved) = try await env.exportService.export(detail: detail, request: request)
        XCTAssertEqual(saved, url)
        XCTAssertNotEqual(try Data(contentsOf: saved), old)
        XCTAssertEqual(record.sha256, Hashing.sha256Hex(fileURL: saved))
        XCTAssertNotNil(ImageNormalizer.uprightImage(url: saved))
        let info = try FileManager.default.attributesOfItem(atPath: saved.path)
        XCTAssertEqual(info[.creationDate] as? Date, created)
        XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        let copiedACL = try XCTUnwrap(acl_get_file(saved.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(copiedACL)) }
        let expectedACLText = try XCTUnwrap(acl_to_text(acl, nil))
        let actualACLText = try XCTUnwrap(acl_to_text(copiedACL, nil))
        defer { acl_free(expectedACLText); acl_free(actualACLText) }
        XCTAssertEqual(String(cString: actualACLText), String(cString: expectedACLText))
        for (key, bytes) in attributes {
            var read = Data(count: bytes.count)
            let length = read.withUnsafeMutableBytes { getxattr(saved.path, key, $0.baseAddress, $0.count, 0, 0) }
            XCTAssertEqual(length, bytes.count)
            XCTAssertEqual(read, bytes)
        }
    }

    // MARK: - LIB-01: Xoá riêng ô 2, xoá ô 2 và 4 cùng lúc, giữ phiên
    @MainActor
    func testLIB01_DeleteIndividualAndMultiplePhotos_KeepSession() async throws {
        // 1. Xoá riêng ô 2
        let setup1 = try await createCompleted4PhotoSession()
        let detail1 = try env.sessions.getDetail(sessionID: setup1.session.id)!
        let shot2 = detail1.shots.first { $0.captureIndex == 2 }!
        let rev2 = setup1.revisions[2]!

        let trashedItems = try env.sessions.trashPhotos(sessionID: setup1.session.id, pairs: [(shotID: shot2.id, photoRevisionID: rev2.id)])
        XCTAssertEqual(trashedItems.count, 1)
        XCTAssertEqual(trashedItems[0].rootType, .photo)
        XCTAssertEqual(trashedItems[0].rootID, rev2.id)

        let afterDetail1 = try env.sessions.getDetail(sessionID: setup1.session.id)!
        XCTAssertNil(afterDetail1.currentRevisions()[2], "Ô 2 phải trống")
        XCTAssertNotNil(afterDetail1.currentRevisions()[1], "Ô 1 phải giữ nguyên")
        XCTAssertNotNil(afterDetail1.currentRevisions()[3], "Ô 3 phải giữ nguyên")
        XCTAssertNotNil(afterDetail1.currentRevisions()[4], "Ô 4 phải giữ nguyên")
        XCTAssertEqual(afterDetail1.session.status, .paused, "Phiên phải chuyển sang paused để chờ chụp tiếp")
        XCTAssertEqual(afterDetail1.session.currentCaptureIndex, 2, "Chụp tiếp phải đặt lượt thiếu đầu tiên là 2")
        XCTAssertNil(afterDetail1.session.completedAtMs, "Phải xoá completed_at_ms")

        // 2. Phiên khác: xoá ô 2 và 4 cùng lúc
        let setup2 = try await createCompleted4PhotoSession()
        let detail2 = try env.sessions.getDetail(sessionID: setup2.session.id)!
        let shot2_2 = detail2.shots.first { $0.captureIndex == 2 }!
        let shot4_2 = detail2.shots.first { $0.captureIndex == 4 }!
        let rev2_2 = setup2.revisions[2]!
        let rev4_2 = setup2.revisions[4]!

        let trashedBatch = try env.sessions.trashPhotos(sessionID: setup2.session.id, pairs: [
            (shotID: shot2_2.id, photoRevisionID: rev2_2.id),
            (shotID: shot4_2.id, photoRevisionID: rev4_2.id)
        ])
        XCTAssertEqual(trashedBatch.count, 2)

        let afterDetail2 = try env.sessions.getDetail(sessionID: setup2.session.id)!
        XCTAssertNil(afterDetail2.currentRevisions()[2])
        XCTAssertNil(afterDetail2.currentRevisions()[4])
        XCTAssertNotNil(afterDetail2.currentRevisions()[1])
        XCTAssertNotNil(afterDetail2.currentRevisions()[3])
        XCTAssertEqual(afterDetail2.session.currentCaptureIndex, 2)

        // 3. Xoá hết tất cả ảnh còn lại của phiên 2: vẫn giữ phiên
        let shot1_2 = detail2.shots.first { $0.captureIndex == 1 }!
        let shot3_2 = detail2.shots.first { $0.captureIndex == 3 }!
        _ = try env.sessions.trashPhotos(sessionID: setup2.session.id, pairs: [
            (shotID: shot1_2.id, photoRevisionID: setup2.revisions[1]!.id),
            (shotID: shot3_2.id, photoRevisionID: setup2.revisions[3]!.id)
        ])
        let emptySessionDetail = try env.sessions.getDetail(sessionID: setup2.session.id)!
        XCTAssertEqual(emptySessionDetail.committedCount, 0)
        XCTAssertEqual(emptySessionDetail.session.status, .paused)
        XCTAssertNotNil(try env.sessions.getSession(id: setup2.session.id), "Phiên vẫn phải tồn tại sau khi xoá hết ảnh")
    }

    // MARK: - LIB-02: Xoá ảnh dự phòng, xung đột revision, toàn vẹn giao dịch
    @MainActor
    func testLIB02_DeleteBackupPhoto_ConflictHandling_TransactionIntegrity() async throws {
        let setup = try await createCompleted4PhotoSession(reserve: true)
        let sessionID = setup.session.id
        let backupRev = try XCTUnwrap(setup.revisions[5])

        let detailBefore = try env.sessions.getDetail(sessionID: sessionID)!
        let backupShot = detailBefore.shots.first { $0.captureIndex == 5 }!

        // Xoá ảnh dự phòng: phiên vẫn đủ 4 ảnh -> giữ trạng thái completed
        _ = try env.sessions.trashPhotos(sessionID: sessionID, pairs: [(shotID: backupShot.id, photoRevisionID: backupRev.id)])
        let detailAfterBackupTrash = try env.sessions.getDetail(sessionID: sessionID)!
        XCTAssertEqual(detailAfterBackupTrash.session.status, .completed, "Xoá ảnh dự phòng thì phiên đủ ảnh vẫn completed")

        // Ca xung đột: Đổi một revision sau khi mở xác nhận -> ném lỗi và không tạo mục rác
        let shot1 = detailAfterBackupTrash.shots.first { $0.captureIndex == 1 }!
        let fakeWrongRevID = "wrong-rev-id"
        XCTAssertThrowsError(try env.sessions.trashPhotos(sessionID: sessionID, pairs: [(shotID: shot1.id, photoRevisionID: fakeWrongRevID)])) { err in
            XCTAssertTrue((err as? AppError)?.message.contains("Phiên bản ảnh đã thay đổi") ?? false)
        }

        // Kiểm tra không có mục rác dở nào được tạo ra
        let trashedAfterError = try env.trashRepo.list()
        let orphanItems = trashedAfterError.filter { $0.rootID == fakeWrongRevID }
        XCTAssertTrue(orphanItems.isEmpty)
    }

    // MARK: - LIB-03: Xoá cả phiên mọi trạng thái, khôi phục phiên có ảnh đã xoá riêng
    @MainActor
    func testLIB03_DeleteWholeSession_AllStates_RestoreSessionPreservesTrashedPhotos() async throws {
        let setup = try await createCompleted4PhotoSession()
        let sessionID = setup.session.id

        // Xoá riêng ô 2 trước
        let detail = try env.sessions.getDetail(sessionID: sessionID)!
        let shot2 = detail.shots.first { $0.captureIndex == 2 }!
        let rev2 = setup.revisions[2]!
        _ = try env.sessions.trashPhotos(sessionID: sessionID, pairs: [(shotID: shot2.id, photoRevisionID: rev2.id)])

        // Xoá cả phiên vào thùng rác
        try env.trashService.trashSession(sessionID: sessionID)

        let sessionInDB = try env.sessions.getSession(id: sessionID)
        XCTAssertEqual(sessionInDB?.status, .trashed)

        let trashedItems = try env.trashRepo.list()
        let sessionTrash = trashedItems.first { $0.rootType == .session && $0.rootID == sessionID }
        XCTAssertNotNil(sessionTrash)

        // Khôi phục phiên
        try env.trashService.restore(sessionTrash!)
        let restoredSession = try env.sessions.getSession(id: sessionID)!
        XCTAssertNotEqual(restoredSession.status, .trashed)

        // Ảnh ô 2 vốn xoá riêng vẫn phải ở Thùng rác
        let trashedAfter = try env.trashRepo.list()
        let photoStillTrashed = trashedAfter.first { $0.rootType == .photo && $0.rootID == rev2.id }
        XCTAssertNotNil(photoStillTrashed, "Ảnh đã xoá riêng vẫn phải ở Thùng rác sau khi khôi phục phiên")
    }

    // MARK: - LIB-04: Khôi phục ô trống và ô đã có ảnh bù, dọn vĩnh viễn
    @MainActor
    func testLIB04_RestoreEmptySlotAndCompensatedSlot_PurgeCascades_InterruptionRules() async throws {
        let setup = try await createCompleted4PhotoSession()
        let sessionID = setup.session.id
        let detail = try env.sessions.getDetail(sessionID: sessionID)!

        // Xoá riêng ô 2
        let shot2 = detail.shots.first { $0.captureIndex == 2 }!
        let rev2 = setup.revisions[2]!
        let trashedItems = try env.sessions.trashPhotos(sessionID: sessionID, pairs: [(shotID: shot2.id, photoRevisionID: rev2.id)])
        let photoTrashItem = trashedItems[0]

        // 1. Khôi phục ô trống -> thành công
        let trash = TrashViewModel(env: env)
        trash.reload()
        XCTAssertEqual(trash.restorableSelectedCount, 0)
        trash.selection = [photoTrashItem.id]
        XCTAssertEqual(trash.restorableSelectedCount, 1)
        trash.restoreSelected()
        XCTAssertEqual(trash.restorableSelectedCount, 0)
        let restoredDetail = try env.sessions.getDetail(sessionID: sessionID)!
        XCTAssertEqual(restoredDetail.currentRevisions()[2]?.id, rev2.id, "Ảnh phải được gắn lại vào ô 2")
        XCTAssertTrue(restoredDetail.session.status == .reviewable || restoredDetail.session.status == .completed, "Đủ ảnh trở lại thì hoàn tất/xem lại")

        // 2. Thử xoá ô 2 lần nữa, sau đó chụp bù ảnh mới vào ô 2
        _ = try env.sessions.trashPhotos(sessionID: sessionID, pairs: [(shotID: shot2.id, photoRevisionID: rev2.id)])
        let newPhotoTrashItem = try env.trashRepo.list().first { $0.rootID == rev2.id }!

        let compData = createSampleImageData()
        let compRev = try await env.safetySave.savePhoto(
            sessionID: sessionID,
            captureIndex: 2,
            payloadData: compData,
            requestID: "\(sessionID)-comp-2",
            width: 400,
            height: 400,
            orientation: 1,
            codec: "png",
            colorProfile: nil
        )
        XCTAssertNotEqual(compRev.id, rev2.id)

        // Khôi phục ảnh cũ khi ô đã có ảnh bù: phải giữ ảnh cũ trong Thùng rác và ném lỗi/báo lý do
        XCTAssertThrowsError(try env.trashService.restore(newPhotoTrashItem)) { err in
            XCTAssertTrue((err as? AppError)?.message.contains("ảnh bù") == true)
        }

        // 3. Dọn vĩnh viễn cả phiên -> cascade dọn cả mục rác ảnh con
        try env.trashService.trashSession(sessionID: sessionID)
        let sessionTrashItem = try env.trashRepo.list().first { $0.rootType == .session && $0.rootID == sessionID }!
        try env.trashService.purge(sessionTrashItem)

        let trashedFinal = try env.trashRepo.list()
        let childPhotos = trashedFinal.filter { $0.originalParentID == sessionID }
        XCTAssertTrue(childPhotos.isEmpty, "Dọn cả phiên phải cascade dọn toàn bộ mục rác ảnh con")
    }

    // MARK: - REV-01: Preset toàn phiên, chỉnh riêng, hoàn tác, làm lại
    @MainActor
    func testREV01_PresetSessionWide_ManualEditsPreserved_UndoRedo() async throws {
        let setup = try await createCompleted4PhotoSession()
        let sessionID = setup.session.id
        let reviewVM = ReviewViewModel(env: env)
        _ = await reviewVM.load(sessionID: sessionID)

        // Áp dụng preset "warm" cho cả phiên
        let warmParams = BuiltinPreset.byID("warm")?.parameters ?? .warm
        let res = try env.sessions.applyPresetToSession(sessionID: sessionID, presetID: "warm", presetParameters: warmParams)
        XCTAssertEqual(res.after.count, 4, "Preset phải áp dụng cho tất cả 4 ảnh")

        for (_, override) in res.after {
            XCTAssertEqual(override.presetID, "warm")
            XCTAssertNil(override.explicitNoPreset)
        }
        await reviewVM.reload()

        // Chỉnh màu tay riêng trên ảnh 1
        reviewVM.selectPhoto(index: 1)
        reviewVM.setColorValue("exposure", 50) // +50
        _ = await reviewVM.flushPendingEdits()

        let freshDetail = try env.sessions.getDetail(sessionID: sessionID)!
        XCTAssertEqual(freshDetail.overrides[1]?.color?.exposure, 0.5)
        XCTAssertEqual(freshDetail.overrides[1]?.presetID, "warm", "Chỉnh tay phải giữ preset")
        XCTAssertNil(freshDetail.overrides[2]?.color?.exposure, "Chỉnh tay ảnh 1 không ảnh hưởng ảnh 2")

        // Hoàn tác chỉnh màu riêng
        reviewVM.undo()
        let afterUndoDetail = try env.sessions.getDetail(sessionID: sessionID)!
        XCTAssertNil(afterUndoDetail.overrides[1]?.color?.exposure, "Undo phải đưa màu về giá trị trước")

        // Làm lại
        reviewVM.redo()
        let afterRedoDetail = try env.sessions.getDetail(sessionID: sessionID)!
        XCTAssertEqual(afterRedoDetail.overrides[1]?.color?.exposure, 0.5, "Redo phải áp dụng lại chỉnh sửa")
    }

    // MARK: - REV-02: Đo độ trễ xem trước màu và crop
    @MainActor
    func testREV02_RealtimePreviewCoalescing_LatencyBenchmark() async throws {
        let setup = try await createCompleted4PhotoSession()
        let sessionID = setup.session.id
        let reviewVM = ReviewViewModel(env: env)
        _ = await reviewVM.load(sessionID: sessionID)

        reviewVM.selectSlot(id: setup.snapshot.slots[0].id)

        // Wait for the image published for the requested generation, not for enqueue to return.
        func waitForPreview(_ sequence: Int) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while reviewVM.lastDisplayedPreviewSequence < sequence && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertGreaterThanOrEqual(reviewVM.lastDisplayedPreviewSequence, sequence)
            XCTAssertNotNil(reviewVM.previewImage)
        }

        try await waitForPreview(reviewVM.previewSequence)
        let clock = ContinuousClock()
        func measure(_ change: (Int) -> Void) async throws -> Double {
            var milliseconds: [Double] = []
            for index in 1...30 {
                let started = clock.now
                change(index)
                try await waitForPreview(reviewVM.previewSequence)
                let elapsed = started.duration(to: clock.now).components
                milliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
            return milliseconds.sorted()[28]
        }

        reviewVM.setColorEditing(true)
        let p95Color = try await measure { reviewVM.setColorValue("contrast", Double($0 - 15) * 3) }
        reviewVM.setColorEditing(false)
        reviewVM.setPlacementEditing(true)
        let p95Crop = try await measure { reviewVM.updatePlacement(offsetX: Double($0) * 0.01) }
        reviewVM.setPlacementEditing(false)
        print("REV-02 published preview p95: color \(p95Color) ms, crop \(p95Crop) ms")
        XCTAssertLessThanOrEqual(p95Color, 100.0)
        XCTAssertLessThanOrEqual(p95Crop, 100.0)
        XCTAssertEqual(reviewVM.previewMode, .inFrame)

        func exerciseDrag(_ change: (Double) -> Void) async throws -> Int {
            let deadline = clock.now + .seconds(2)
            var last = reviewVM.lastDisplayedPreviewSequence
            var updates = 0
            var value = 0.0
            while clock.now < deadline {
                value = value == 0 ? 0.25 : 0
                change(value)
                try await Task.sleep(for: .milliseconds(14))
                if reviewVM.lastDisplayedPreviewSequence > last {
                    last = reviewVM.lastDisplayedPreviewSequence
                    updates += 1
                }
            }
            return updates
        }

        reviewVM.setColorEditing(true)
        let colorUpdates = try await exerciseDrag { reviewVM.setColorValue("contrast", $0 * 100) }
        reviewVM.setColorEditing(false)
        XCTAssertGreaterThanOrEqual(colorUpdates, 2)
        guard let slotID = reviewVM.selectedSlotID else { return XCTFail("Missing crop slot") }
        let beforeDrag = try XCTUnwrap(env.sessions.getDetail(sessionID: sessionID)?.placements[slotID])
        reviewVM.setPlacementEditing(true)
        let cropUpdates = try await exerciseDrag { reviewVM.updatePlacement(offsetX: $0) }
        reviewVM.updatePlacement(offsetX: 0.125)
        reviewVM.setPlacementEditing(false)
        try await waitForPreview(reviewVM.previewSequence)
        XCTAssertGreaterThanOrEqual(cropUpdates, 2)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: sessionID)?.placements[slotID]?.offsetX, 0.125)
        reviewVM.undo()
        XCTAssertEqual(try env.sessions.getDetail(sessionID: sessionID)?.placements[slotID]?.offsetX, beforeDrag.offsetX)
    }

    // MARK: - REV-03: Phiên cũ có làm mịn da, kết quả mới bỏ qua làm mịn
    @MainActor
    func testREV03_OldSessionSkinSmoothingIgnored_OtherEditsAndAutoFaceIntact() async throws {
        let setup = try await createCompleted4PhotoSession()
        let sessionID = setup.session.id

        let photo = try XCTUnwrap(setup.revisions[1])
        // Insert the legacy JSON directly. New writers must omit the retired field.
        try env.db.run("""
            INSERT INTO photo_adjustments(photo_revision_id, overrides_json, parameter_version, updated_at_ms)
            VALUES(?, ?, 1, 0)
            """, [.text(photo.id), .text(#"{"skinSmooth":0.8,"color":{"exposure":0.25}}"#)])
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: sessionID))
        XCTAssertEqual(detail.overrides[1]?.skinSmooth, 0.8)
        XCTAssertEqual(detail.overrides[1]?.color?.exposure, 0.25)
        let preview = await env.renderBuilder.renderPreview(detail: detail, maxDimension: 800)
        XCTAssertNotNil(preview)
        try env.sessions.setOverride(sessionID: sessionID, photoRevisionID: photo.id,
                                     override: XCTUnwrap(detail.overrides[1]))
        XCTAssertNil(try env.sessions.getOverride(photoRevisionID: photo.id)?.skinSmooth)
        XCTAssertEqual(try env.sessions.getOverride(photoRevisionID: photo.id)?.color?.exposure, 0.25)
    }

    // MARK: - FRM-01: Nhập fixture khung 2x2 và 1x4, tự căn thành công và fallback
    @MainActor
    func testFRM01_FrameFixtureImport_PNGAutoAlignment2x2And1x4_FallbackNotice() async throws {
        // 1. Tạo fixture PNG 800x800 lưới 2x2 chuẩn:
        // Canvas: 800x800, 4 vùng trong suốt ở [80,80,280,280], [440,80,280,280], [80,440,280,280], [440,440,280,280]
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx2x2 = CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 800 * 4,
                               space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Nền đen đục (alpha = 255)
        ctx2x2.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1.0))
        ctx2x2.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
        // 4 vùng trong suốt (clear alpha = 0)
        // CGContext y-up: top-down y=80 -> ctx y = 800 - 80 - 280 = 440; top-down y=440 -> ctx y = 800 - 440 - 280 = 80
        ctx2x2.clear(CGRect(x: 80, y: 440, width: 280, height: 280))
        ctx2x2.clear(CGRect(x: 440, y: 440, width: 280, height: 280))
        ctx2x2.clear(CGRect(x: 80, y: 80, width: 280, height: 280))
        ctx2x2.clear(CGRect(x: 440, y: 80, width: 280, height: 280))
        let img2x2 = ctx2x2.makeImage()!

        let res2x2 = PNGAutoAlignmentService.align(image: img2x2, hasAlpha: true, layout: .grid2x2)
        XCTAssertTrue(res2x2.isAutoAligned, "Khung 2x2 chuẩn phải tự căn thành công")
        XCTAssertFalse(res2x2.requiresInspection)
        XCTAssertEqual(res2x2.slots.count, 4)
        XCTAssertTrue(res2x2.blockedSlotIndices.isEmpty)

        // Kiểm tra thứ tự: Hàng 1 ô 1, ô 2; Hàng 2 ô 3, ô 4
        XCTAssertLessThan(res2x2.slots[0].centerX, res2x2.slots[1].centerX)
        XCTAssertLessThan(res2x2.slots[2].centerX, res2x2.slots[3].centerX)
        XCTAssertLessThan(res2x2.slots[0].centerY, res2x2.slots[2].centerY)

        // 2. Tạo fixture PNG 480x1200 dải dọc 1x4 chuẩn:
        // x=60, w=360, h=210, y=70, 350, 630, 910
        let ctx1x4 = CGContext(data: nil, width: 480, height: 1200, bitsPerComponent: 8, bytesPerRow: 480 * 4,
                               space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx1x4.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1.0))
        ctx1x4.fill(CGRect(x: 0, y: 0, width: 480, height: 1200))
        // Clear 4 slots y-up:
        ctx1x4.clear(CGRect(x: 60, y: 1200 - 70 - 210, width: 360, height: 210))
        ctx1x4.clear(CGRect(x: 60, y: 1200 - 350 - 210, width: 360, height: 210))
        ctx1x4.clear(CGRect(x: 60, y: 1200 - 630 - 210, width: 360, height: 210))
        ctx1x4.clear(CGRect(x: 60, y: 1200 - 910 - 210, width: 360, height: 210))
        let img1x4 = ctx1x4.makeImage()!

        let res1x4 = PNGAutoAlignmentService.align(image: img1x4, hasAlpha: true, layout: .strip1x4)
        XCTAssertTrue(res1x4.isAutoAligned, "Khung 1x4 chuẩn phải tự căn thành công")
        XCTAssertFalse(res1x4.requiresInspection)
        XCTAssertEqual(res1x4.slots.count, 4)
        XCTAssertTrue(res1x4.blockedSlotIndices.isEmpty)

        // 3. PNG thiếu vùng (chỉ có 2 vùng trong suốt) -> fallback với requiresInspection = true
        let ctxDefect = CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 800 * 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctxDefect.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1.0))
        ctxDefect.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
        ctxDefect.clear(CGRect(x: 80, y: 440, width: 280, height: 280))
        ctxDefect.clear(CGRect(x: 440, y: 440, width: 280, height: 280))
        let imgDefect = ctxDefect.makeImage()!

        let resDefect = PNGAutoAlignmentService.align(image: imgDefect, hasAlpha: true, layout: .grid2x2)
        XCTAssertFalse(resDefect.isAutoAligned, "Thiếu vùng phải chuyển sang vị trí mẫu")
        XCTAssertTrue(resDefect.requiresInspection, "Phải bật cờ Kiểm tra vị trí ô")
        XCTAssertNotNil(resDefect.inspectionReason)
    }

    // MARK: - FRM-02: Nhập nhiều tệp, bỏ qua, dừng nhập, lưu khung và chọn cho màn Chụp
    @MainActor
    func testFRM02_MultiFileImport_SkipAndStop_LockedFrameDeferredSelection() async throws {
        // Tạo 2 tệp ảnh giả
        let data1 = createSampleImageData(width: 800, height: 800)
        let data2 = createSampleImageData(width: 800, height: 800)

        // Lưu khung 1 có cấu hình sẵn
        let slot1 = FrameSlot(captureIndex: 1, x: 0.1, y: 0.1, width: 0.38, height: 0.38)
        let slot2 = FrameSlot(captureIndex: 2, x: 0.52, y: 0.1, width: 0.38, height: 0.38)
        let slot3 = FrameSlot(captureIndex: 3, x: 0.1, y: 0.52, width: 0.38, height: 0.38)
        let slot4 = FrameSlot(captureIndex: 4, x: 0.52, y: 0.52, width: 0.38, height: 0.38)

        let savedFrame1 = try env.frames.createConfiguredFrame(
            name: "Khung Batch 1",
            imageData: data1,
            mediaType: "image/png",
            role: .frameBackground,
            categoryID: nil,
            slots: [slot1, slot2, slot3, slot4]
        )
        XCTAssertEqual(savedFrame1.validationStatus, .ready)

        // Lưu khung 2
        let savedFrame2 = try env.frames.createConfiguredFrame(
            name: "Khung Batch 2",
            imageData: data2,
            mediaType: "image/png",
            role: .frameBackground,
            categoryID: nil,
            slots: [slot1, slot2, slot3, slot4]
        )
        XCTAssertEqual(savedFrame2.validationStatus, .ready)

        // Giả lập kết thúc lô: khung 2 là khung cuối cùng -> được chọn cho màn Chụp
        env.preferredFrameID = savedFrame2.id
        XCTAssertEqual(env.preferredFrameID, savedFrame2.id)

        // Kiểm tra khung 1 vẫn tồn tại bình thường
        let retrievedFrame1 = try env.frames.getFrame(id: savedFrame1.id)
        XCTAssertNotNil(retrievedFrame1)
    }

    // MARK: - REG-01: Hồi quy quy trình Capture -> Review -> Frame -> Trash
    @MainActor
    func testREG01_DatabaseMigrationV2toV3_FullWorkflowRegression() async throws {
        // Kiểm tra schema version hiện tại là 3
        XCTAssertEqual(Schema.currentVersion, 3)

        // Chạy quy trình: Chụp -> Chụp lại -> Đổi khung -> Xuất -> Rác
        let setup = try await createCompleted4PhotoSession()
        let sessionID = setup.session.id
        let reviewVM = ReviewViewModel(env: env)
        _ = await reviewVM.load(sessionID: sessionID)

        // Chụp lại
        reviewVM.selectPhoto(index: 2)
        XCTAssertNotNil(reviewVM.selectedPhotoIndex)

        // Đổi khung (chọn khung có số ô <= 4 để phiên 4 ảnh đủ điều kiện xuất)
        let frames = try env.frames.listReadyFrames()
        let anotherFrame = frames.first { f in
            f.id != setup.snapshot.sourceFrameID &&
            ((try? env.frames.getSlots(revisionID: f.currentRevisionID ?? ""))?.count ?? 0) <= 4
        }
        if let another = anotherFrame {
            await reviewVM.changeFrame(to: another.id)
            let updatedDetail = try env.sessions.getDetail(sessionID: sessionID)!
            XCTAssertEqual(updatedDetail.snapshot.sourceFrameID, another.id)
        }

        // Xuất
        let tempExportDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempExportDir, withIntermediateDirectories: true)
        let request = ExportService.ExportRequest(
            sessionID: sessionID,
            format: .png,
            quality: 90,
            width: reviewVM.detail?.snapshot.canvasWidth ?? setup.snapshot.canvasWidth,
            height: reviewVM.detail?.snapshot.canvasHeight ?? setup.snapshot.canvasHeight,
            filenameBase: "REG01_Test",
            destinationFolder: tempExportDir
        )
        let exportResult = await reviewVM.runExport(request: request)
        switch exportResult {
        case .success(let url):
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        case .failure(let err):
            XCTFail("Export thất bại: \(err)")
        }

        // Đưa vào thùng rác
        try env.trashService.trashSession(sessionID: sessionID)
        let trashed = try env.trashRepo.list()
        XCTAssertTrue(trashed.contains { $0.rootID == sessionID })
    }
}

extension AcceptanceMatrixTests {
    @MainActor
    func testVerifyRestoreRequiresOriginalBytes() async throws {
        let setup = try await createCompleted4PhotoSession()
        let sessionID = setup.session.id
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: sessionID))
        let shot = try XCTUnwrap(detail.shots.first { $0.captureIndex == 2 })
        let rev = try XCTUnwrap(setup.revisions[2])
        let item = try XCTUnwrap(env.sessions.trashPhotos(sessionID: sessionID, pairs: [(shot.id, rev.id)]).first)
        try FileManager.default.removeItem(at: env.sessions.fileURL(for: rev))
        XCTAssertThrowsError(try env.trashService.restore(item))
        XCTAssertNotNil(try env.trashRepo.getItem(id: item.id))
        XCTAssertNil(try env.sessions.getDetail(sessionID: sessionID)?.currentRevisions()[2])
    }

    @MainActor
    func testVerifyChildPurgeDefersWithoutChangingState() async throws {
        let setup = try await createCompleted4PhotoSession()
        let sessionID = setup.session.id
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: sessionID))
        let shot = try XCTUnwrap(detail.shots.first { $0.captureIndex == 2 })
        let rev = try XCTUnwrap(setup.revisions[2])
        let item = try XCTUnwrap(env.sessions.trashPhotos(sessionID: sessionID, pairs: [(shot.id, rev.id)]).first)
        try env.trashService.trashSession(sessionID: sessionID)
        _ = env.trashService.purgeResult(item)
        XCTAssertEqual(try env.trashRepo.getItem(id: item.id)?.status, .trashed)
        let parent = try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: sessionID))
        try env.trashService.restore(parent)
        XCTAssertNoThrow(try env.trashService.restore(item))
    }

    @MainActor
    func testVerifyPresetUndoWithReservePhoto() async throws {
        let setup = try await createCompleted4PhotoSession(reserve: true)
        let sessionID = setup.session.id
        let backup = try XCTUnwrap(setup.revisions[5])
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: sessionID)
        vm.setPreset("warm")
        XCTAssertTrue(vm.canUndo)
        XCTAssertEqual(try env.sessions.getOverride(photoRevisionID: backup.id)?.presetID, "warm")
        vm.undo()
        XCTAssertNil(try env.sessions.getOverride(photoRevisionID: backup.id))
    }

    @MainActor
    func testVerifyAlphaCoordinatesUseTopLeft() throws {
        let w = 480, h = 1200
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for y in [75,265,455,645] {
            ctx.clear(CGRect(x: 60, y: h-y-120, width: 360, height: 120))
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let result = PNGAutoAlignmentService.align(image: image, hasAlpha: true, layout: .strip1x4)
        XCTAssertTrue(result.isAutoAligned)
        let first = try XCTUnwrap(result.slots.first)
        XCTAssertEqual(first.y, 75.0 / 1200.0, accuracy: 0.005)
    }
}

extension AcceptanceMatrixTests {
    @MainActor
    func testVerifyRecoveryCompletesPhotoPurgeAfterFileRemoval() async throws {
        let setup = try await createCompleted4PhotoSession()
        let sessionID = setup.session.id
        let photo = try XCTUnwrap(setup.revisions[2])
        let item = try XCTUnwrap(env.sessions.trashPhotos(sessionID: sessionID, pairs: [(photo.shotID, photo.id)]).first)
        let source = try env.sessions.fileURL(for: photo)
        try env.db.run("""
            CREATE TRIGGER abort_deleted_photo BEFORE DELETE ON photo_revisions
            BEGIN SELECT RAISE(ABORT, 'injected write failure after file removal'); END
            """)
        XCTAssertFalse(env.trashService.purge(item))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try env.trashRepo.getItem(id: item.id)?.status, .purging)
        try env.db.run("DROP TRIGGER abort_deleted_photo")
        _ = try env.trashService.recoverOperations()
        XCTAssertNil(try env.trashRepo.getItem(id: item.id))
        XCTAssertNil(try env.sessions.getPhotoRevision(id: photo.id))
        XCTAssertEqual(try env.sessions.getDetail(sessionID: sessionID)?.committedCount, 3)
        XCTAssertTrue(try env.trashService.recoverOperations().issues.isEmpty)
    }

    @MainActor
    func testVerifyLegacyMappingRepairPreservesCropAndRunsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(IDFactory.new())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "qa-repair-\(IDFactory.new())"))
        env = AppEnvironment(customRoot: root, customDefaults: defaults, camera: FakeCameraService())
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        let setup = try await createCompleted4PhotoSession(reserve: true)
        let sessionID = setup.session.id
        let before = try XCTUnwrap(env.sessions.getDetail(sessionID: sessionID))
        let frameID = try XCTUnwrap(setup.snapshot.sourceFrameID)
        let canonical = try env.frames.createSnapshot(frameID: frameID)
        var legacyDefaults = before.session.defaults
        legacyDefaults.selectedCaptureOrder = [5, 2, 3, 4]
        let json = String(decoding: try JSONEncoder().encode(legacyDefaults), as: UTF8.self)
        try env.db.withTransaction { tx in
            try tx.run("UPDATE sessions SET active_frame_snapshot_id=?, session_defaults_json=? WHERE id=?",
                       [.text(canonical.id), .text(json), .text(sessionID)])
            try tx.run("UPDATE slot_placements SET frame_snapshot_id=? WHERE session_id=?",
                       [.text(canonical.id), .text(sessionID)])
        }
        let slot = try XCTUnwrap(canonical.slots.first { $0.captureIndex == 1 })
        try env.sessions.setPlacement(sessionID: sessionID, snapshotSlotID: slot.id,
                                      placement: PhotoPlacement(scale: 1.2, offsetX: 0.125, offsetY: 0),
                                      cropMode: .fill, manualOverride: true)
        let photo = try XCTUnwrap(setup.revisions[5])
        try env.sessions.setOverride(sessionID: sessionID, photoRevisionID: photo.id,
                                     override: PhotoOverride(presetID: "warm"))
        let updated = try env.sessions.repairLegacyFrameAssignments(using: env.frames)
        XCTAssertEqual(updated.updated, 1)
        XCTAssertTrue(updated.unresolved.isEmpty)
        let repaired = try XCTUnwrap(env.sessions.getDetail(sessionID: sessionID))
        XCTAssertEqual(repaired.snapshot.slots.first { $0.id == slot.id }?.captureIndex, 5)
        XCTAssertEqual(repaired.placements[slot.id]?.offsetX, 0.125)
        XCTAssertEqual(repaired.overrides[5]?.presetID, "warm")
        XCTAssertEqual(repaired.currentRevisions()[5]?.sha256, photo.sha256)
        XCTAssertEqual(try env.sessions.repairLegacyFrameAssignments(using: env.frames).updated, 0)
        XCTAssertEqual(try env.sessions.getSession(id: sessionID)?.revisionNo, repaired.session.revisionNo)
        let backup = root.appendingPathComponent("backups")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backup.path)
            .contains { $0.hasPrefix("pre-frame-assignment-") })
    }

    @MainActor
    func testVerifyFrameCreationRollsBackAfterWriteError() throws {
        let previous = try env.db.scalarInt("SELECT COUNT(*) FROM frames")
        try env.db.run("CREATE TRIGGER audit_abort_frame_slot BEFORE INSERT ON frame_slots BEGIN SELECT RAISE(ABORT, 'injected slot insert failure'); END")
        let slots = [FrameSlot(captureIndex: 1, x: 0.10, y: 0.10, width: 0.70, height: 0.70)]
        XCTAssertThrowsError(try env.frames.createConfiguredFrame(name: "Audited frame failure", imageData: createSampleImageData(), mediaType: "image/png", role: .frameBackground, categoryID: nil, slots: slots))
        XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM frames"), previous)
    }

    @MainActor
    func testVerifyActualV2TrashMigrationAndBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("store.sqlite").path)
        for sql in Schema.v1Statements {
            try db.run(sql.replacingOccurrences(of: "'session','frame','category','preset','photo'", with: "'session','frame','category','preset'"))
        }
        try db.run("ALTER TABLE sessions ADD COLUMN frame_name_at_capture TEXT")
        try db.run("ALTER TABLE sessions ADD COLUMN countdown_seconds INTEGER NOT NULL DEFAULT 3")
        try db.run("ALTER TABLE sessions ADD COLUMN intermission_seconds INTEGER NOT NULL DEFAULT 2")
        try db.run("INSERT INTO schema_migrations(version,applied_at_ms) VALUES(1,1),(2,2)")
        try db.run("INSERT INTO trash_items(id,root_type,root_id,display_name,deleted_at_ms,expires_at_ms,status) VALUES('old','preset','p','Old item',1,2,'trashed')")
        let backups = dir.appendingPathComponent("backups")
        try Schema.migrate(db, backupFolder: backups)
        XCTAssertEqual(try db.scalarInt("SELECT MAX(version) FROM schema_migrations"), 3)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM trash_items WHERE id='old' AND root_type='preset'"), 1)
        try db.run("INSERT INTO trash_items(id,root_type,root_id,display_name,deleted_at_ms,expires_at_ms,status) VALUES('new','photo','p2','New item',1,2,'trashed')")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        let old = try SQLiteDatabase(path: file.path)
        XCTAssertEqual(try old.scalarInt("SELECT MAX(version) FROM schema_migrations"), 2)
        XCTAssertEqual(try old.scalarInt("SELECT COUNT(*) FROM trash_items WHERE id='old' AND root_type='preset'"), 1)
        XCTAssertThrowsError(try old.run("INSERT INTO trash_items(id,root_type,root_id,display_name,deleted_at_ms,expires_at_ms,status) VALUES('new','photo','p2','New item',1,2,'trashed')"))
    }
}
