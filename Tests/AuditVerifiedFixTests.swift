import XCTest
import Foundation
import CoreGraphics
import SwiftUI
import AppKit
import CoreImage
@testable import OpenPhotobooth

@MainActor
final class AuditVerifiedFixTests: XCTestCase {
    private func setupSession() async throws -> (AppEnvironment, String) {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        await env.boot()
        env.trashScheduler.stop()
        let f = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: f.id)
        let s = try env.sessions.createSession(snapshot: snap, mode: .manual, cameraID: "fixture", defaults: env.settings.sessionDefaultsSnapshot())
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 256, height: 384, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.6, green: 0.2, blue: 0.4, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 384))
        let data = try ExportService.encode(cg: XCTUnwrap(ctx.makeImage()), format: .png, quality: 95)
        for i in snap.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: s.id, captureIndex: i, payloadData: data, requestID: UUID().uuidString, width: 256, height: 384, orientation: 1, codec: "png", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: s.id, status: .reviewable)
        return (env,s.id)
    }

    func testRotatedSlotRendersAtItsOwnCentre() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let source = try XCTUnwrap(ctx.makeImage())
        for angle in [0.0, 45.0, 90.0] {
            let slot = FrameSlot(captureIndex: 1, x: 0.25, y: 0.25, width: 0.5, height: 0.5, rotationDegrees: angle, defaultCropMode: .fill)
            XCTAssertTrue(FrameValidator.validate(canvasWidth: 512, canvasHeight: 512, slots: [slot], hasBackground: false, hasForeground: false, backgroundColorHex: "#00000000").isEmpty)
            let snap = FrameSnapshot(sourceFrameID: nil, sourceFrameRevisionID: nil, canvasWidth: 512, canvasHeight: 512, background: nil, foreground: nil, backgroundColorHex: "#00000000", slots: [SnapshotSlot(from: slot)], snapshotHash: "fixture")
            let mask = MaskBuilder.CanvasSlot(slot: snap.slots[0], width: 512, height: 512)
            let center = CGPoint(x: 256,y: 256), moved = center.applying(mask.rotation)
            let model = CompositionModel(snapshot: snap, sources: [1: RenderSource(image: source)], defaults: SessionDefaultsSnapshot(presetID: nil,presetName: nil,presetResolvedParameters: .neutral,presetIntensity: 0,color: .neutral,skinSmooth: 0,outputMirror: false),overrides: [:],placements: [:],cropModes: [:],assetImages: [:],options: RenderOptions(targetWidth: 512,targetHeight: 512,transparentBackground: true))
            let result = try CompositeRenderer.render(model: model)
            var pixel = [UInt8](repeating: 0,count: 4)
            let sample = try XCTUnwrap(CGContext(data: &pixel,width: 1,height: 1,bitsPerComponent: 8,bytesPerRow: 4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            sample.draw(result,in: CGRect(x: -256,y: -256,width: 512,height: 512))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-slot-rotation-\(Int(angle)).png")
            try ExportService.encode(cg: result,format: .png,quality: 95).write(to: url)
            print("INDEPENDENT-ROTATION artifact=\(url.path) angle=\(angle) center=\(moved) RGBA=\(pixel)")
            XCTAssertEqual(moved.x,center.x,accuracy: 0.001,"Slot rotation moves its own centre")
            XCTAssertEqual(moved.y,center.y,accuracy: 0.001,"Slot rotation moves its own centre")
            XCTAssertGreaterThan(pixel[0],200,"Rotated red photo disappears from the centre")
            XCTAssertGreaterThan(pixel[3],200,"Rotated slot is transparent at its centre")
        }
    }

    func testDuplicatedReadyFrameRemainsUsable() async throws {
        let env=AppEnvironment(inMemory:true,camera:FakeCameraService());await env.boot();env.trashScheduler.stop()
        let source=try XCTUnwrap(env.frames.listReadyFrames().first)
        let copy=try env.frames.duplicateFrame(id:source.id)
        let stored=try XCTUnwrap(env.frames.getFrame(id:copy.id))
        print("INDEPENDENT-DUPLICATE source=\(source.validationStatus.rawValue) copy=\(stored.validationStatus.rawValue) slots=\(try env.frames.getSlots(revisionID:XCTUnwrap(stored.currentRevisionID)).count)")
        XCTAssertEqual(stored.validationStatus,source.validationStatus,"Duplicating a ready frame must preserve its usability")
        XCTAssertTrue(try env.frames.listReadyFrames().contains { $0.id==copy.id })
        XCTAssertNoThrow(try env.frames.validatedSnapshotForUse(frameID: copy.id))
    }

    func testUndoApplyAllMustNotSilentlySucceedWhenDeleteFails() async throws {
        let (env,id) = try await setupSession()
        let vm = ReviewViewModel(env: env)
        let loaded = await vm.load(sessionID: id); XCTAssertTrue(loaded)
        vm.selectPhoto(index: 1)
        vm.setColorValue("exposure", 40)
        let saved = await vm.flushPendingEdits(); XCTAssertTrue(saved)
        vm.applyColorToAll()
        await vm.reload()
        let before = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        let blocked = try XCTUnwrap(before.currentRevisions()[2])
        XCTAssertNotNil(try env.sessions.getOverride(photoRevisionID: blocked.id))
        try env.db.run("CREATE TRIGGER audit_block_undo BEFORE DELETE ON photo_adjustments WHEN OLD.photo_revision_id='\(blocked.id)' BEGIN SELECT RAISE(ABORT, 'QA simulated delete failure'); END")
        defer { try? env.db.run("DROP TRIGGER audit_block_undo") }
        vm.undo()
        let after = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        print("INDEPENDENT-UNDO remaining=\(after.overrides.keys.sorted()) canUndo=\(vm.canUndo) canRedo=\(vm.canRedo) toast=\(env.toast?.text ?? "nil")")
        XCTAssertFalse(vm.canRedo, "Failed Undo must not move the action to Redo")
        XCTAssertEqual(after.overrides, before.overrides, "Failed Undo must roll back every override")
        XCTAssertEqual(after.session, before.session)
        XCTAssertEqual(after.placements, before.placements)
    }

    func testStaleCategoryCannotAcquireNewFrameReferences() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        await env.boot(); env.trashScheduler.stop()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first)
        let category = try env.frames.createCategory(name: "Audit target")
        let vm = FramesViewModel(env: env); vm.reload()
        try env.trashService.trashCategory(categoryID: category.id)
        vm.moveToCategory([frame.id], categoryID: category.id)
        let stored = try XCTUnwrap(env.frames.getFrame(id: frame.id))
        let active = try env.frames.listCategories().map(\.id)
        print("INDEPENDENT-CATEGORY frameCategory=\(stored.categoryID ?? "nil") active=\(active) toast=\(env.toast?.text ?? "nil")")
        XCTAssertTrue(stored.categoryID == nil || active.contains(stored.categoryID!), "Frame linked to a trashed category after a stale menu action")
    }

    func testLegacyCompletionMustRejectMissingOriginal() async throws {
        let (env,id) = try await setupSession()
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        let photo = try XCTUnwrap(detail.currentRevisions()[1])
        try FileManager.default.removeItem(at: env.sessions.fileURL(for: photo))
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: id)
        let completed = await vm.complete()
        let stored = try XCTUnwrap(env.sessions.getSession(id: id))
        print("INDEPENDENT-COMPLETE result=\(completed) status=\(stored.status.rawValue) missing=\(vm.missingPhotos) canExport=\(vm.canExport)")
        XCTAssertFalse(completed, "Legacy session completion accepted a missing original")
        XCTAssertNotEqual(stored.status, .completed)
        XCTAssertEqual(vm.missingPhotos, 1)
        XCTAssertFalse(vm.canExport)
    }

}

extension AuditVerifiedFixTests {
    private func png(_ color: CGColor = CGColor(red: 0.7, green: 0.2, blue: 0.3, alpha: 1)) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 384, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 384))
        return try ExportService.encode(cg: XCTUnwrap(context.makeImage()), format: .png, quality: 95)
    }

    private func frame(_ env: AppEnvironment, background: Bool = false) throws -> Frame {
        let owner = IDFactory.new()
        let asset = try background ? env.assets.store(data: png(), mediaType: "image/png", purpose: "background",
            ownerType: "frame_revision", ownerID: owner).id : nil
        let draft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: 512, canvasHeight: 768,
                                  backgroundAssetID: asset)
        let slots = (0..<3).map { FrameSlot(captureIndex: $0 + 1, x: 0.1, y: 0.05 + Double($0) * 0.3,
            width: 0.8, height: 0.22, zOrder: $0, defaultCropMode: .fill) }
        return try env.frames.createConfiguredFrame(name: "Verified fixture", categoryID: nil,
            draft: draft, slots: slots, stagedOwnerID: owner, explicitWhite: true)
    }

    private func session(_ env: AppEnvironment, planned: Bool = false, reserve: Bool = false,
                         background: Bool = false) async throws -> SessionDetail {
        env.settings.autoExport = false
        let configuredFrame = try frame(env, background: background)
        var defaults = env.settings.sessionDefaultsSnapshot()
        if planned { defaults.plannedCaptureCount = 3 }
        if reserve { defaults.selectionCaptureCount = 4 }
        let snapshot = planned ? FrameSnapshot.awaitingFrame() : try env.frames.createSnapshot(frameID: configuredFrame.id)
        let session = try env.sessions.createSession(snapshot: snapshot, mode: .manual, cameraID: "fake-built-in",
            defaults: defaults, countdownSeconds: 0, intermissionSeconds: 0)
        let bytes = try png()
        for index in 1...(reserve ? 4 : 3) {
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: index, payloadData: bytes,
                requestID: IDFactory.new(), width: 256, height: 384, orientation: 1, codec: "png", colorProfile: "sRGB")
        }
        try env.sessions.setStatus(sessionID: session.id, status: .reviewable)
        if planned {
            let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
            let ids = detail.currentRevisions(includeUnassigned: true).sorted { $0.key < $1.key }.map { $0.value.id }
            try env.sessions.applyCaptureFrame(sessionID: session.id, expectedRevision: detail.session.revisionNo,
                frameID: configuredFrame.id, frameRevisionID: XCTUnwrap(configuredFrame.currentRevisionID), orderedPhotoIDs: ids,
                frames: env.frames, assets: env.assets)
        } else if reserve {
            try env.sessions.confirmPhotoSelection(sessionID: session.id, order: [1, 2, 3])
        }
        return try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
    }

    private func rows(_ env: AppEnvironment) throws -> [String: [SQLiteRow]] {
        var result: [String: [SQLiteRow]] = [:]
        for table in ["frames", "frame_revisions", "frame_slots", "assets", "asset_references", "app_state",
                      "sessions", "session_shots", "photo_revisions", "photo_adjustments", "slot_placements",
                      "frame_snapshots", "categories", "category_restore_links", "trash_items", "export_records"] {
            result[table] = try env.db.query("SELECT * FROM \(table) ORDER BY rowid")
        }
        return result
    }

    private func hashes(_ env: AppEnvironment) throws -> [String: String] {
        var result: [String: String] = [:]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: env.layout.rootURL,
            includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in files {
            guard url.path.contains("/Originals/") || url.path.contains("/Assets/"),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[url.path] = Hashing.sha256Hex(try Data(contentsOf: url))
        }
        return result
    }

    private func healthy(_ env: AppEnvironment, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(try env.db.integrityCheck(), file: file, line: line)
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty, file: file, line: line)
        XCTAssertEqual(try env.db.scalarInt("""
            SELECT COUNT(*) FROM frames f JOIN categories c ON f.category_id=c.id
            WHERE f.lifecycle='active' AND c.lifecycle!='active'
            """), 0, file: file, line: line)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return bytes
    }

    func testRotationMatrixMasksAndExportEncoding() throws {
        let source = try XCTUnwrap(CGImage.createFrom(data: png(CGColor(red: 1, green: 0, blue: 0, alpha: 1))))
        let defaults = SessionDefaultsSnapshot(presetID: nil, presetName: nil, presetResolvedParameters: .neutral,
            presetIntensity: 0, color: .neutral, skinSmooth: 0, outputMirror: false)
        var renders = 0
        for size in [320, 512] {
            for mask in MaskType.allCases {
                for crop in [CropMode.fill, .fit] {
                    for angle in [0.0, -45, 45, -90, 90, 180, 360] {
                        let slot = FrameSlot(captureIndex: 1, x: 0.52, y: 0.34, width: 0.26, height: 0.32,
                            rotationDegrees: angle, maskType: mask, cornerRadius: 0.05, defaultCropMode: crop)
                        let snapshot = FrameSnapshot(sourceFrameID: nil, sourceFrameRevisionID: nil,
                            canvasWidth: 512, canvasHeight: 512, background: nil, foreground: nil,
                            backgroundColorHex: "#00000000", slots: [SnapshotSlot(from: slot)], snapshotHash: "rotation")
                        let model = CompositionModel(snapshot: snapshot, sources: [1: RenderSource(image: source)],
                            defaults: defaults, overrides: [:], placements: [:], cropModes: [:], assetImages: [:],
                            options: RenderOptions(targetWidth: size, targetHeight: size, transparentBackground: true))
                        let geometry = MaskBuilder.CanvasSlot(slot: snapshot.slots[0], width: size, height: size)
                        let center = CGPoint(x: 0.65 * Double(size), y: 0.5 * Double(size))
                        let transformed = center.applying(geometry.rotation)
                        XCTAssertEqual(transformed.x, center.x, accuracy: 0.000001)
                        XCTAssertEqual(transformed.y, center.y, accuracy: 0.000001)
                        let marker = CGPoint(x: center.x + 10, y: center.y).applying(geometry.rotation)
                        XCTAssertEqual(marker.x, center.x + 10 * cos(-angle * .pi / 180), accuracy: 0.000001)
                        XCTAssertEqual(marker.y, center.y + 10 * sin(-angle * .pi / 180), accuracy: 0.000001)
                        let rendered = try CompositeRenderer.render(model: model)
                        XCTAssertGreaterThanOrEqual(try pixel(rendered, x: Int(center.x), y: Int(center.y))[3], 250)
                        XCTAssertLessThanOrEqual(try pixel(rendered, x: 4, y: 4)[3], 5)
                        for format in [ExportImageFormat.png, .jpeg] {
                            let encoded = try ExportService.encode(cg: rendered, format: format, quality: 100)
                            let decoded = try XCTUnwrap(CGImage.createFrom(data: encoded))
                            let p = try pixel(decoded, x: Int(center.x), y: Int(center.y))
                            XCTAssertGreaterThan(p[0], 200)
                            XCTAssertLessThan(p[1], 60)
                        }
                        renders += 1
                    }
                }
            }
        }
        print("FIX5 rotation matrix renders=\(renders)")
    }

    func testCompositeCachesIgnorePreviousRenderVersionAndKeepOriginalCache() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let detail = try await session(env)
        let frameID = try XCTUnwrap(detail.snapshot.sourceFrameID)
        let revision = try XCTUnwrap(detail.snapshot.sourceFrameRevisionID)
        let sentinel = try png(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        env.thumbnails.store(data: sentinel, key: "frame-v2-\(revision)")
        env.thumbnails.store(data: sentinel, key: "session-\(detail.session.id)-\(detail.session.revisionNo)")
        let shot = try XCTUnwrap(detail.currentRevisions()[1])
        env.thumbnails.store(data: sentinel, key: "shot-\(shot.id)")
        let before = try hashes(env)
        XCTAssertNil(env.frameThumbnails.cachedThumbnail(frameID: frameID, revisionID: revision))
        let thumb = await env.frameThumbnails.requestThumbnail(frameID: frameID, revisionID: revision)
        XCTAssertNotNil(thumb)
        XCTAssertNotEqual(thumb, sentinel)
        XCTAssertEqual(thumb, env.frameThumbnails.cachedThumbnail(frameID: frameID, revisionID: revision))
        let library = LibraryViewModel(env: env)
        await library.reload().value
        let card = try XCTUnwrap(library.cards.first)
        let preview = await library.generatePreview(for: card)
        XCTAssertNotNil(preview)
        XCTAssertNotEqual(preview, sentinel)
        XCTAssertEqual(preview, env.thumbnails.cachedData(key: "session-r\(CompositeRenderer.renderCacheVersion)-\(card.id)-\(card.card.session.revisionNo)"))
        XCTAssertEqual(env.thumbnails.cachedData(key: "shot-\(shot.id)"), sentinel)
        XCTAssertEqual(try hashes(env), before)
        try healthy(env)
    }

    func testApplyAllUndoRedoIsOneRevisionAndPreservesPlacementsAndFiles() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let initial = try await session(env, reserve: true)
        let first = try XCTUnwrap(initial.currentRevisions()[1])
        try env.sessions.setOverride(sessionID: initial.session.id, photoRevisionID: first.id,
            override: PhotoOverride(color: ColorOverrides(exposure: 0.4)))
        let reserve = try XCTUnwrap(initial.currentRevisions(includeUnassigned: true)[4])
        let reserved = PhotoOverride(color: ColorOverrides(saturation: -0.3))
        try env.sessions.setOverride(sessionID: initial.session.id, photoRevisionID: reserve.id, override: reserved)
        let before = try XCTUnwrap(env.sessions.getDetail(sessionID: initial.session.id))
        let files = try hashes(env)
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: before.session.id)
        defer { vm.cancelPreviewPipeline() }
        vm.selectPhoto(index: 1)
        vm.applyColorToAll()
        let after = try XCTUnwrap(env.sessions.getDetail(sessionID: before.session.id))
        XCTAssertEqual(after.session.revisionNo, before.session.revisionNo + 1)
        XCTAssertEqual(after.overrides.count, 4)
        XCTAssertEqual(after.overrides[4], reserved)
        vm.undo()
        let undone = try XCTUnwrap(env.sessions.getDetail(sessionID: before.session.id))
        XCTAssertEqual(undone.overrides, before.overrides)
        XCTAssertEqual(undone.session.revisionNo, after.session.revisionNo + 1)
        XCTAssertTrue(vm.canRedo)
        vm.redo()
        let redone = try XCTUnwrap(env.sessions.getDetail(sessionID: before.session.id))
        XCTAssertEqual(redone.overrides, after.overrides)
        XCTAssertEqual(redone.session.revisionNo, undone.session.revisionNo + 1)
        XCTAssertEqual(redone.placements, before.placements)
        XCTAssertEqual(redone.snapshot, before.snapshot)
        XCTAssertEqual(try env.sessions.getOverride(photoRevisionID: reserve.id), reserved)
        XCTAssertEqual(try hashes(env), files)
        try healthy(env)
    }

    func testUndoAndRedoRollbackForDeleteAndUpsertErrors() async throws {
        for operation in ["DELETE", "INSERT"] {
            let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
            let initial = try await session(env)
            let first = try XCTUnwrap(initial.currentRevisions()[1])
            try env.sessions.setOverride(sessionID: initial.session.id, photoRevisionID: first.id,
                override: PhotoOverride(color: ColorOverrides(exposure: 0.4)))
            let vm = ReviewViewModel(env: env)
            _ = await vm.load(sessionID: initial.session.id)
            defer { vm.cancelPreviewPipeline() }
            vm.selectPhoto(index: 1)
            vm.applyColorToAll()
            let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: initial.session.id))
            let blocked = try XCTUnwrap(detail.currentRevisions()[operation == "DELETE" ? 2 : 1])
            let record = operation == "DELETE" ? "OLD" : "NEW"
            try env.db.run("CREATE TEMP TRIGGER fail_undo BEFORE \(operation) ON photo_adjustments WHEN \(record).photo_revision_id='\(blocked.id)' BEGIN SELECT RAISE(ABORT, 'verified undo failure'); END")
            let before = try rows(env)
            vm.undo()
            XCTAssertEqual(try rows(env), before)
            XCTAssertTrue(vm.canUndo)
            XCTAssertFalse(vm.canRedo)
            XCTAssertTrue(env.toast?.text.contains("Hoàn tác không thành công") == true)
            try env.db.run("DROP TRIGGER fail_undo")
            vm.undo()
            XCTAssertTrue(vm.canRedo)
            try env.db.run("CREATE TEMP TRIGGER fail_redo BEFORE INSERT ON photo_adjustments BEGIN SELECT RAISE(ABORT, 'verified redo failure'); END")
            let undone = try rows(env)
            vm.redo()
            XCTAssertEqual(try rows(env), undone)
            XCTAssertTrue(vm.canRedo)
            XCTAssertTrue(env.toast?.text.contains("Làm lại không thành công") == true)
            try env.db.run("DROP TRIGGER fail_redo")
            vm.redo()
            XCTAssertFalse(vm.canRedo)
            try healthy(env)
        }
    }

    func testApplyAllHistoryRejectsReplacedTrashedAndBusyPhotos() async throws {
        for failure in ["retake", "trash", "busy"] {
            let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
            let detail = try await session(env)
            let vm = ReviewViewModel(env: env)
            _ = await vm.load(sessionID: detail.session.id)
            defer { vm.cancelPreviewPipeline() }
            vm.applyColorToAll()
            let photo = try XCTUnwrap(detail.currentRevisions()[2])
            if failure == "retake" {
                _ = try await env.safetySave.savePhoto(sessionID: detail.session.id, captureIndex: 2,
                    payloadData: png(), requestID: IDFactory.new(), width: 256, height: 384,
                    orientation: 1, codec: "png", colorProfile: "sRGB")
            } else if failure == "trash" {
                try env.sessions.trashPhotos(sessionID: detail.session.id, pairs: [(shotID: photo.shotID, photoRevisionID: photo.id)])
            }
            let token = failure == "busy" ? try OperationCoordinator.shared.acquire(key: "session:\(detail.session.id)", reason: "verified contention") : nil
            let before = try rows(env)
            vm.undo()
            token?.release()
            XCTAssertEqual(try rows(env), before)
            XCTAssertTrue(vm.canUndo)
            XCTAssertFalse(vm.canRedo)
            XCTAssertTrue(env.toast?.text.contains("Hoàn tác không thành công") == true)
            try healthy(env)
        }
    }

    func testApplyAllDoesNotDiscardPendingEditsWhenFlushFails() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let detail = try await session(env)
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: detail.session.id)
        defer { vm.discardPendingEdits(); vm.cancelPreviewPipeline() }
        vm.selectPhoto(index: 1)
        vm.setColorValue("exposure", 25)
        try env.db.run("CREATE TEMP TRIGGER fail_flush BEFORE INSERT ON photo_adjustments BEGIN SELECT RAISE(ABORT, 'verified pending failure'); END")
        let before = try rows(env)
        vm.applyColorToAll()
        XCTAssertEqual(try rows(env), before)
        XCTAssertTrue(vm.hasPendingEdits)
        XCTAssertFalse(vm.canRedo)
        try env.db.run("DROP TRIGGER fail_flush")
        let flushed = await vm.flushPendingEdits()
        XCTAssertTrue(flushed)
        vm.applyColorToAll()
        XCTAssertEqual(try env.sessions.getDetail(sessionID: detail.session.id)?.overrides.count, 3)
        try healthy(env)
    }

    func testLegacyAndCaptureFirstRejectMissingCorruptAndReplacedBytes() async throws {
        for planned in [false, true] {
            for failure in ["missing", "corrupt", "checksum"] {
                let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
                let detail = try await session(env, planned: planned)
                let photo = try XCTUnwrap(detail.currentRevisions()[1])
                let url = try env.sessions.fileURL(for: photo)
                if failure == "missing" { try FileManager.default.removeItem(at: url) }
                else if failure == "corrupt" { try Data([1, 2, 3]).write(to: url) }
                else { try png(CGColor(red: 0, green: 0, blue: 1, alpha: 1)).write(to: url) }
                let before = try rows(env)
                let vm = ReviewViewModel(env: env)
                _ = await vm.load(sessionID: detail.session.id)
                defer { vm.cancelPreviewPipeline() }
                XCTAssertEqual(vm.missingPhotos, 1)
                XCTAssertFalse(vm.canExport)
                let complete = await vm.complete()
                XCTAssertFalse(complete)
                XCTAssertEqual(try rows(env), before)
                _ = try await env.safetySave.savePhoto(sessionID: detail.session.id, captureIndex: 1,
                    payloadData: png(), requestID: IDFactory.new(), width: 256, height: 384,
                    orientation: 1, codec: "png", colorProfile: "sRGB")
                await vm.reload()
                XCTAssertTrue(vm.canExport)
                let repaired = await vm.complete()
                XCTAssertTrue(repaired)
                try healthy(env)
            }
        }
    }

    func testLegacyMissingFrameLayerBlocksCompletionWithoutChangingDatabase() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let detail = try await session(env, background: true)
        let layer = try XCTUnwrap(detail.snapshot.background)
        let info = try XCTUnwrap(env.assets.assetInfo(assetID: layer.assetID))
        try FileManager.default.removeItem(at: env.layout.absoluteURL(forRelativePath: info.relativePath))
        let before = try rows(env)
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: detail.session.id)
        defer { vm.cancelPreviewPipeline() }
        XCTAssertEqual(vm.missingPhotos, 0)
        XCTAssertTrue(vm.missingFrameResources)
        XCTAssertFalse(vm.canExport)
        let completed = await vm.complete()
        XCTAssertFalse(completed)
        XCTAssertEqual(try rows(env), before)
        try healthy(env)
    }

    func testLegacyEmptyChecksumAndMissingReserveRemainCompatible() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let detail = try await session(env, reserve: true)
        let first = try XCTUnwrap(detail.currentRevisions()[1])
        try env.db.run("UPDATE photo_revisions SET sha256='' WHERE id=?", [.text(first.id)])
        let reserve = try XCTUnwrap(detail.currentRevisions(includeUnassigned: true)[4])
        try FileManager.default.removeItem(at: env.sessions.fileURL(for: reserve))
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: detail.session.id)
        defer { vm.cancelPreviewPipeline() }
        XCTAssertTrue(vm.canExport)
        XCTAssertEqual(vm.missingPhotos, 0)
        let complete = await vm.complete()
        XCTAssertTrue(complete)
        let after = try rows(env)
        let repeated = try await env.completeSession(sessionID: detail.session.id)
        XCTAssertFalse(repeated)
        XCTAssertEqual(try rows(env), after)
        XCTAssertTrue(try env.sessions.listExportRecords(sessionID: detail.session.id).isEmpty)
        try healthy(env)
    }

    func testDuplicatePreservesDraftAndInvalidStatus() throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let draft = try env.frames.createEmptyFrame(name: "Empty draft", categoryID: nil)
        let draftCopy = try env.frames.duplicateFrame(id: draft.id)
        XCTAssertEqual(draftCopy.validationStatus, .unconfigured)
        XCTAssertTrue(try env.frames.getSlots(revisionID: XCTUnwrap(draftCopy.currentRevisionID)).isEmpty)
        let invalid = try frame(env)
        try env.frames.setValidationStatus(frameID: invalid.id, status: .invalid)
        let invalidCopy = try env.frames.duplicateFrame(id: invalid.id)
        XCTAssertEqual(invalidCopy.validationStatus, .invalid)
        XCTAssertThrowsError(try env.frames.validatedSnapshotForUse(frameID: invalidCopy.id))
        try healthy(env)
    }

    func testDuplicateRollbackProtectsSourceSnapshotAndSharedAssets() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let detail = try await session(env, background: true)
        let sourceID = try XCTUnwrap(detail.snapshot.sourceFrameID)
        let before = try rows(env)
        let files = try hashes(env)
        for table in ["frames", "frame_revisions", "frame_slots", "asset_references", "app_state"] {
            try env.db.run("CREATE TEMP TRIGGER fail_duplicate BEFORE INSERT ON \(table) BEGIN SELECT RAISE(ABORT, 'verified duplicate failure'); END")
            XCTAssertThrowsError(try env.frames.duplicateFrame(id: sourceID))
            XCTAssertEqual(try rows(env), before)
            XCTAssertEqual(try hashes(env), files)
            try env.db.run("DROP TRIGGER fail_duplicate")
        }
        let copy = try env.frames.duplicateFrame(id: sourceID)
        let snapshot = try env.frames.validatedSnapshotForUse(frameID: copy.id)
        XCTAssertEqual(snapshot.background, detail.snapshot.background)
        XCTAssertEqual(snapshot.explicitWhite, detail.snapshot.explicitWhite)
        XCTAssertNotEqual(snapshot.slots.map(\.id), detail.snapshot.slots.map(\.id))
        try env.trashService.trashFrame(frameID: sourceID)
        let item = try XCTUnwrap(env.trashRepo.find(rootType: .frame, rootID: sourceID))
        XCTAssertTrue(env.trashService.purge(item))
        XCTAssertNoThrow(try env.frames.validatedSnapshotForUse(frameID: copy.id))
        XCTAssertEqual(try env.sessions.getDetail(sessionID: detail.session.id)?.snapshot, detail.snapshot)
        XCTAssertEqual(try hashes(env), files)
        let model = try await env.renderBuilder.buildModelStrict(detail: detail, targetWidth: 320, targetHeight: 480)
        XCTAssertNoThrow(try CompositeRenderer.render(model: model))
        try healthy(env)
    }

    func testDuplicateRejectsMissingResourceOrBusySourceWithoutWriting() throws {
        for failure in ["missing", "busy", "trashed"] {
            let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
            let source = try frame(env, background: true)
            if failure == "missing" {
                let revision = try XCTUnwrap(env.frames.getRevision(id: XCTUnwrap(source.currentRevisionID)))
                let info = try XCTUnwrap(env.assets.assetInfo(assetID: XCTUnwrap(revision.backgroundAssetID)))
                try FileManager.default.removeItem(at: env.layout.absoluteURL(forRelativePath: info.relativePath))
            } else if failure == "trashed" { try env.trashService.trashFrame(frameID: source.id) }
            let token = failure == "busy" ? try OperationCoordinator.shared.acquire(key: "frame:\(source.id)", reason: "verified contention") : nil
            let before = try rows(env)
            XCTAssertThrowsError(try env.frames.duplicateFrame(id: source.id))
            token?.release()
            XCTAssertEqual(try rows(env), before)
            try healthy(env)
        }
    }

    func testExistingConfiguredDraftCanSaveWithoutEditingAndDoesNotAutosave() async throws {
        for rename in [false, true] {
            let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
            let source = try frame(env)
            try env.frames.setValidationStatus(frameID: source.id, status: .unconfigured)
            let before = try rows(env)
            let editor = FrameEditorViewModel(env: env)
            editor.load(frameID: source.id)
            XCTAssertFalse(editor.hasAnyChanges)
            XCTAssertTrue(editor.canSave)
            XCTAssertEqual(try rows(env), before)
            if rename { editor.draftName = "Recovered copy" }
            let saved = await editor.save()
            XCTAssertTrue(saved)
            XCTAssertEqual(editor.frame?.validationStatus, .ready)
            XCTAssertFalse(editor.canSave)
            XCTAssertFalse(editor.hasAnyChanges)
            let stored = try XCTUnwrap(env.frames.getFrame(id: source.id))
            XCTAssertEqual(stored.validationStatus, .ready)
            XCTAssertNotEqual(stored.currentRevisionID, source.currentRevisionID)
            XCTAssertEqual(stored.name, rename ? "Recovered copy" : source.name)
            XCTAssertNoThrow(try env.frames.validatedSnapshotForUse(frameID: source.id))
            try healthy(env)
        }
    }

    func testExistingDraftSaveStillRejectsStaleRevisionAndInvalidGeometry() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let source = try frame(env)
        try env.frames.setValidationStatus(frameID: source.id, status: .unconfigured)
        let editor = FrameEditorViewModel(env: env)
        editor.load(frameID: source.id)
        let revision = try XCTUnwrap(env.frames.getRevision(id: XCTUnwrap(source.currentRevisionID)))
        _ = try env.frames.saveConfiguredRevision(frameID: source.id, expectedRevisionID: revision.id, name: source.name,
            draft: revision, slots: env.frames.getSlots(revisionID: revision.id), stagedOwnerID: "newer-edit", explicitWhite: true)
        let before = try rows(env)
        let saved = await editor.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(try rows(env), before)
        let empty = try env.frames.createEmptyFrame(name: "No slots", categoryID: nil)
        editor.load(frameID: empty.id)
        XCTAssertFalse(editor.canSave)
        try healthy(env)
    }

    func testCategoryBatchRollbackAndVMErrorWhenAnyFrameOrWriteIsInvalid() throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let first = try frame(env), second = try frame(env)
        let category = try env.frames.createCategory(name: "Destination")
        let before = try rows(env)
        XCTAssertThrowsError(try env.frames.setCategory(frameIDs: [first.id, "missing"], categoryID: category.id))
        XCTAssertEqual(try rows(env), before)
        try env.db.run("CREATE TEMP TRIGGER fail_move BEFORE UPDATE OF category_id ON frames WHEN NEW.id='\([first.id,second.id].sorted().last!)' BEGIN SELECT RAISE(ABORT, 'verified move failure'); END")
        XCTAssertThrowsError(try env.frames.setCategory(frameIDs: [first.id, second.id], categoryID: category.id))
        XCTAssertEqual(try rows(env), before)
        let vm = FramesViewModel(env: env)
        vm.moveToCategory([first.id, second.id], categoryID: category.id)
        XCTAssertEqual(try rows(env), before)
        XCTAssertTrue(env.toast?.text.contains("Không thể chuyển khung") == true)
        try env.db.run("DROP TRIGGER fail_move")
        try env.frames.setCategory(frameIDs: [first.id, first.id, second.id], categoryID: category.id)
        XCTAssertEqual(try env.frames.getFrame(id: first.id)?.categoryID, category.id)
        XCTAssertEqual(try env.frames.getFrame(id: second.id)?.categoryID, category.id)
        try env.frames.setCategory(frameIDs: [first.id, second.id], categoryID: nil)
        XCTAssertNil(try env.frames.getFrame(id: first.id)?.categoryID)
        XCTAssertNil(try env.frames.getFrame(id: second.id)?.categoryID)
        try healthy(env)
    }

    func testCategoryRejectsTrashedPurgedAndBusyTargetsAndTrashedFrames() throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let source = try frame(env)
        let category = try env.frames.createCategory(name: "Removed")
        let token = try OperationCoordinator.shared.acquire(key: "category:\(category.id)", reason: "verified contention")
        let before = try rows(env)
        XCTAssertThrowsError(try env.frames.setCategory(frameID: source.id, categoryID: category.id))
        XCTAssertEqual(try rows(env), before)
        token.release()
        try env.trashService.trashCategory(categoryID: category.id)
        let trashed = try rows(env)
        XCTAssertThrowsError(try env.frames.setCategory(frameID: source.id, categoryID: category.id))
        XCTAssertEqual(try rows(env), trashed)
        XCTAssertTrue(env.trashService.purge(try XCTUnwrap(env.trashRepo.find(rootType: .category, rootID: category.id))))
        let purged = try rows(env)
        XCTAssertThrowsError(try env.frames.setCategory(frameID: source.id, categoryID: category.id))
        XCTAssertEqual(try rows(env), purged)
        try env.trashService.trashFrame(frameID: source.id)
        let frameGone = try rows(env)
        XCTAssertThrowsError(try env.frames.setCategory(frameID: source.id, categoryID: nil))
        XCTAssertEqual(try rows(env), frameGone)
        try healthy(env)
    }

    func testCategoryTrashAndRestoreDoesNotOverwriteNewClassification() throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let first = try frame(env), second = try frame(env)
        let old = try env.frames.createCategory(name: "Old")
        let new = try env.frames.createCategory(name: "New")
        try env.frames.setCategory(frameIDs: [first.id, second.id], categoryID: old.id)
        try env.trashService.trashCategory(categoryID: old.id)
        XCTAssertNil(try env.frames.getFrame(id: first.id)?.categoryID)
        try env.frames.setCategory(frameID: first.id, categoryID: new.id)
        try env.trashService.restore(XCTUnwrap(env.trashRepo.find(rootType: .category, rootID: old.id)))
        XCTAssertEqual(try env.frames.getFrame(id: first.id)?.categoryID, new.id)
        XCTAssertEqual(try env.frames.getFrame(id: second.id)?.categoryID, old.id)
        try env.frames.setCategory(frameID: second.id, categoryID: new.id)
        try env.trashService.trashCategory(categoryID: old.id)
        XCTAssertEqual(try env.frames.getFrame(id: second.id)?.categoryID, new.id)
        try healthy(env)
    }

    func testFixedFlowsRemainLinkedThroughExportRestoreAndPurge() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let initial = try await session(env, planned: true, background: true)
        let sourceID = try XCTUnwrap(initial.snapshot.sourceFrameID)
        let copy = try env.frames.duplicateFrame(id: sourceID)
        let category = try env.frames.createCategory(name: "Integration")
        try env.frames.setCategory(frameID: copy.id, categoryID: category.id)
        let ids = initial.currentRevisions().sorted { $0.key < $1.key }.map { $0.value.id }
        try env.sessions.applyCaptureFrame(sessionID: initial.session.id, expectedRevision: initial.session.revisionNo,
            frameID: copy.id, frameRevisionID: XCTUnwrap(copy.currentRevisionID), orderedPhotoIDs: ids,
            frames: env.frames, assets: env.assets)
        let vm = ReviewViewModel(env: env)
        _ = await vm.load(sessionID: initial.session.id)
        defer { vm.cancelPreviewPipeline() }
        vm.selectPhoto(index: 1)
        vm.setColorValue("exposure", 20)
        let flushed = await vm.flushPendingEdits()
        XCTAssertTrue(flushed)
        let beforeAll = try XCTUnwrap(env.sessions.getDetail(sessionID: initial.session.id))
        vm.applyColorToAll()
        vm.undo()
        XCTAssertEqual(try env.sessions.getDetail(sessionID: initial.session.id)?.overrides, beforeAll.overrides)
        vm.redo()
        await vm.reload()
        vm.updatePlacement(scale: 1.2, offsetX: 0.1, isFinal: true)
        let cropSaved = await vm.flushPendingEdits()
        XCTAssertTrue(cropSaved)
        let completed = await vm.complete()
        XCTAssertTrue(completed)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: initial.session.id))
        let request = ExportService.ExportRequest(sessionID: detail.session.id, format: .png, quality: 95,
            width: 512, height: 768, filenameBase: "fix5-integration", destinationFolder: env.layout.rootURL)
        let (_, output) = try await env.exportService.export(detail: detail, request: request)
        let exported = try Data(contentsOf: output)
        XCTAssertNotNil(CGImage.createFrom(data: exported))
        let library = LibraryViewModel(env: env)
        await library.reload().value
        XCTAssertEqual(library.cards.first?.card.session.status, .completed)
        try env.trashService.trashFrame(frameID: sourceID)
        XCTAssertTrue(env.trashService.purge(try XCTUnwrap(env.trashRepo.find(rootType: .frame, rootID: sourceID))))
        try env.trashService.trashSession(sessionID: detail.session.id)
        try env.trashService.restore(XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: detail.session.id)))
        let restored = try XCTUnwrap(env.sessions.getDetail(sessionID: detail.session.id))
        XCTAssertEqual(restored.snapshot, detail.snapshot)
        XCTAssertEqual(restored.overrides, detail.overrides)
        XCTAssertEqual(restored.placements, detail.placements)
        XCTAssertEqual(try Data(contentsOf: output), exported)
        try env.trashService.trashSession(sessionID: detail.session.id)
        XCTAssertTrue(env.trashService.purge(try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: detail.session.id))))
        XCTAssertNil(try env.sessions.getDetail(sessionID: detail.session.id))
        XCTAssertEqual(try Data(contentsOf: output), exported)
        XCTAssertNoThrow(try env.frames.validatedSnapshotForUse(frameID: copy.id))
        try healthy(env)
    }
}

#if DEBUG
private final class DuplicateTestGate: @unchecked Sendable {
    let reached: XCTestExpectation
    private let releaseSignal = DispatchSemaphore(value: 0)
    init(_ reached: XCTestExpectation) { self.reached = reached }
    func wait() throws {
        XCTAssertFalse(Thread.isMainThread, "Duplicate validation must run away from the UI thread")
        reached.fulfill()
        guard releaseSignal.wait(timeout: .now() + 10) == .success else {
            throw AppError.invalidState("QA duplicate gate timed out")
        }
    }
    func release() { releaseSignal.signal() }
}

@MainActor
private final class DuplicateEventRecorder {
    private let marker = "QA:duplicate:\(UUID().uuidString):end"
    private let task: Task<[DomainEvent], Never>
    init() {
        let stream = EventBus.shared.stream
        let marker = marker
        task = Task {
            var events: [DomainEvent] = []
            for await event in stream {
                if event == .settingsChanged(key: marker) { break }
                events.append(event)
            }
            return events
        }
    }
    func finish() async -> [DomainEvent] {
        EventBus.shared.post(.settingsChanged(key: marker))
        return await task.value
    }
    deinit { task.cancel() }
}

extension AuditVerifiedFixTests {
    func testAsyncDuplicateDeduplicatesAndCompletesAfterNavigation() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let source = try frame(env, background: true)
        let category = try env.frames.createCategory(name: "Keep current filter")
        try env.frames.setCategory(frameID: source.id, categoryID: category.id)
        let vm = FramesViewModel(env: env); vm.reload()
        let gate = DuplicateTestGate(expectation(description: "source locked"))
        env.frames.onDuplicateLockedForTesting = { try gate.wait() }
        defer { gate.release(); env.frames.onDuplicateLockedForTesting = nil }
        let recorder = DuplicateEventRecorder()
        let before = try rows(env)
        let task = Task { await vm.duplicate(source.id) }
        await fulfillment(of: [gate.reached], timeout: 10)
        XCTAssertEqual(vm.duplicatingFrameIDs, [source.id])
        XCTAssertEqual(try rows(env), before, "QA gate must be before the database transaction")
        await vm.duplicate(source.id)
        XCTAssertEqual(try rows(env), before, "A repeated request must not start another copy")
        env.route = .library
        vm.searchText = source.name
        vm.selectedCategoryID = category.id
        vm.selection = [source.id]
        gate.release()
        let done = expectation(description: "copy completed after navigation")
        Task { await task.value; done.fulfill() }
        await fulfillment(of: [done], timeout: 60)
        await task.value
        env.frames.onDuplicateLockedForTesting = nil
        let events = await recorder.finish()
        let copies = try env.frames.listFrames().filter { $0.id != source.id }
        let copy = try XCTUnwrap(copies.first)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copy.validationStatus, .ready)
        XCTAssertEqual(env.route, .library)
        XCTAssertEqual(vm.searchText, source.name)
        XCTAssertEqual(vm.selectedCategoryID, category.id)
        XCTAssertEqual(vm.selection, [source.id])
        XCTAssertTrue(vm.duplicatingFrameIDs.isEmpty)
        XCTAssertEqual(events.filter { $0 == .frameLibraryChanged(frameID: copy.id) }.count, 1)
        XCTAssertFalse(OperationCoordinator.shared.isBusy(key: "frame:\(source.id)").busy)
        XCTAssertFalse(OperationCoordinator.shared.isBusy(key: "frame:\(copy.id)").busy)
        await vm.duplicate(source.id)
        XCTAssertEqual(try env.frames.listFrames().count, 3, "A new explicit request after completion remains allowed")
        try healthy(env)
    }

    func testAsyncDuplicatePreservesConcurrentActionContracts() async throws {
        // The completed-before-copy order must use the latest committed source state.
        for operation in ["save", "move", "trash", "rename", "favorite", "trash-category"] {
            let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
            let source = try frame(env, background: true)
            let oldCategory = try env.frames.createCategory(name: "Before-copy category")
            let destination = try env.frames.createCategory(name: "Before-copy destination")
            try env.frames.setCategory(frameID: source.id, categoryID: oldCategory.id)
            switch operation {
            case "save":
                let revision = try XCTUnwrap(env.frames.getRevision(id: XCTUnwrap(source.currentRevisionID)))
                _ = try env.frames.saveConfiguredRevision(frameID: source.id, expectedRevisionID: revision.id,
                    name: "Saved before copy", draft: revision, slots: env.frames.getSlots(revisionID: revision.id),
                    stagedOwnerID: "QA prior save", explicitWhite: true)
            case "move": try env.frames.setCategory(frameID: source.id, categoryID: destination.id)
            case "trash": try env.trashService.trashFrame(frameID: source.id)
            case "rename": try env.frames.renameFrame(id: source.id, to: "Renamed before copy")
            case "favorite": try env.frames.setFavorite(id: source.id, true)
            default: try env.trashService.trashCategory(categoryID: oldCategory.id)
            }
            let latest = try XCTUnwrap(env.frames.getFrame(id: source.id))
            let vm = FramesViewModel(env: env)
            await vm.duplicate(source.id)
            let copies = try env.frames.listFrames().filter { $0.id != source.id }
            if operation == "trash" {
                XCTAssertTrue(copies.isEmpty)
                XCTAssertTrue(env.toast?.text.hasPrefix("Nhân bản lỗi:") == true)
            } else {
                let copy = try XCTUnwrap(copies.first)
                XCTAssertEqual(copies.count, 1)
                XCTAssertEqual(copy.name, latest.name + " (bản sao)")
                XCTAssertEqual(copy.categoryID, latest.categoryID)
                XCTAssertFalse(copy.isFavorite)
                let sourceSnapshot = try env.frames.validatedSnapshotForUse(frameID: source.id)
                let copied = try env.frames.validatedSnapshotForUse(frameID: copy.id)
                XCTAssertEqual(copied.background, sourceSnapshot.background)
                XCTAssertEqual(copied.foreground, sourceSnapshot.foreground)
            }
            XCTAssertTrue(vm.duplicatingFrameIDs.isEmpty)
            try healthy(env)
        }
        for operation in ["save", "move", "trash", "other-copy", "rename", "favorite", "trash-category"] {
            let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
            let source = try frame(env, background: true)
            let oldCategory = try env.frames.createCategory(name: "Source category")
            let destination = try env.frames.createCategory(name: "Destination")
            try env.frames.setCategory(frameID: source.id, categoryID: oldCategory.id)
            let revision = try XCTUnwrap(env.frames.getRevision(id: XCTUnwrap(source.currentRevisionID)))
            let slots = try env.frames.getSlots(revisionID: revision.id)
            let vm = FramesViewModel(env: env)
            let gate = DuplicateTestGate(expectation(description: "locked for \(operation)"))
            env.frames.onDuplicateLockedForTesting = { try gate.wait() }
            defer { gate.release(); env.frames.onDuplicateLockedForTesting = nil }
            let task = Task { await vm.duplicate(source.id) }
            await fulfillment(of: [gate.reached], timeout: 10)
            let before = try rows(env)
            switch operation {
            case "save":
                XCTAssertThrowsError(try env.frames.saveConfiguredRevision(frameID: source.id,
                    expectedRevisionID: revision.id, name: source.name, draft: revision, slots: slots,
                    stagedOwnerID: "QA concurrent save", explicitWhite: true))
            case "move": XCTAssertThrowsError(try env.frames.setCategory(frameID: source.id, categoryID: destination.id))
            case "trash": XCTAssertThrowsError(try env.trashService.trashFrame(frameID: source.id))
            case "other-copy": XCTAssertThrowsError(try env.frames.duplicateFrame(id: source.id))
            case "rename": try env.frames.renameFrame(id: source.id, to: "Renamed during validation")
            case "favorite": try env.frames.setFavorite(id: source.id, true)
            default: try env.trashService.trashCategory(categoryID: oldCategory.id)
            }
            if ["save", "move", "trash", "other-copy"].contains(operation) {
                XCTAssertEqual(try rows(env), before, operation)
            }
            gate.release()
            await task.value
            env.frames.onDuplicateLockedForTesting = nil
            let copies = try env.frames.listFrames().filter { $0.id != source.id }
            let copy = try XCTUnwrap(copies.first)
            XCTAssertEqual(copies.count, 1)
            XCTAssertEqual(copy.validationStatus, .ready)
            XCTAssertTrue(vm.duplicatingFrameIDs.isEmpty)
            XCTAssertEqual(copy.name, (operation == "rename" ? "Renamed during validation" : source.name) + " (bản sao)")
            XCTAssertFalse(copy.isFavorite)
            XCTAssertEqual(try env.frames.getFrame(id: source.id)?.isFavorite, operation == "favorite")
            XCTAssertEqual(copy.categoryID, operation == "trash-category" ? nil : oldCategory.id)
            if operation == "trash-category" {
                XCTAssertNil(try env.frames.getFrame(id: source.id)?.categoryID)
            } else {
                try env.trashService.trashCategory(categoryID: oldCategory.id)
                XCTAssertNil(try env.frames.getFrame(id: source.id)?.categoryID)
                XCTAssertNil(try env.frames.getFrame(id: copy.id)?.categoryID)
            }
            XCTAssertFalse(OperationCoordinator.shared.isBusy(key: "frame:\(source.id)").busy)
            try healthy(env)
        }
    }

    func testAsyncDuplicateFailuresRollbackClearStateAndPermitRetry() async throws {
        for failure in ["busy", "missing", "trashed", "frames", "frame_revisions", "frame_slots", "asset_references", "app_state"] {
            let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
            let source = try frame(env, background: true)
            let revision = try XCTUnwrap(env.frames.getRevision(id: XCTUnwrap(source.currentRevisionID)))
            let info = try XCTUnwrap(env.assets.assetInfo(assetID: XCTUnwrap(revision.backgroundAssetID)))
            let url = try env.layout.absoluteURL(forRelativePath: info.relativePath)
            let bytes = try Data(contentsOf: url)
            var token: OperationCoordinator.OperationToken?
            if failure == "busy" { token = try OperationCoordinator.shared.acquire(key: "frame:\(source.id)", reason: "QA busy source") }
            else if failure == "missing" { try FileManager.default.removeItem(at: url) }
            else if failure == "trashed" { try env.trashService.trashFrame(frameID: source.id) }
            else { try env.db.run("CREATE TEMP TRIGGER fail_async_copy BEFORE INSERT ON \(failure) BEGIN SELECT RAISE(ABORT, 'QA async duplicate failure'); END") }
            defer { token?.release() }
            let before = try rows(env), files = try hashes(env)
            let recorder = DuplicateEventRecorder()
            let vm = FramesViewModel(env: env)
            await vm.duplicate(source.id)
            let events = await recorder.finish()
            XCTAssertEqual(try rows(env), before, failure)
            XCTAssertEqual(try hashes(env), files, failure)
            XCTAssertTrue(vm.duplicatingFrameIDs.isEmpty, failure)
            XCTAssertTrue(env.toast?.text.hasPrefix("Nhân bản lỗi:") == true, failure)
            XCTAssertFalse(events.contains { if case .frameLibraryChanged = $0 { return true }; return false })
            token?.release(); token = nil
            XCTAssertFalse(OperationCoordinator.shared.isBusy(key: "frame:\(source.id)").busy)
            if failure == "missing" { try bytes.write(to: url) }
            else if failure == "trashed" {
                try env.trashService.restore(XCTUnwrap(env.trashRepo.find(rootType: .frame, rootID: source.id)))
            } else if failure != "busy" { try env.db.run("DROP TRIGGER fail_async_copy") }
            let retryRecorder = DuplicateEventRecorder()
            await vm.duplicate(source.id)
            let retryEvents = await retryRecorder.finish()
            let copy = try XCTUnwrap(env.frames.listFrames().first { $0.id != source.id })
            XCTAssertEqual(try env.frames.listFrames().count, 2, failure)
            XCTAssertEqual(copy.validationStatus, .ready)
            XCTAssertEqual(retryEvents.filter { $0 == .frameLibraryChanged(frameID: copy.id) }.count, 1)
            XCTAssertTrue(vm.duplicatingFrameIDs.isEmpty)
            try healthy(env)
        }
    }

    func testAsyncDuplicateKeepsSnapshotsAssetsMetadataAndPostCommitEventLinked() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let initial = try await session(env, background: true)
        let sourceID = try XCTUnwrap(initial.snapshot.sourceFrameID)
        let source = try XCTUnwrap(env.frames.getFrame(id: sourceID))
        let revision = try XCTUnwrap(env.frames.getRevision(id: XCTUnwrap(source.currentRevisionID)))
        let owner = IDFactory.new()
        let foreground = try env.assets.store(data: png(CGColor(gray: 0, alpha: 0)), mediaType: "image/png",
            purpose: "foreground", ownerType: "frame_revision", ownerID: owner)
        var draft = revision
        draft.backgroundImageOrientation = 6
        draft.foregroundAssetID = foreground.id
        draft.foregroundImageOrientation = 8
        _ = try env.frames.saveConfiguredRevision(frameID: sourceID, expectedRevisionID: revision.id,
            name: source.name, draft: draft, slots: env.frames.getSlots(revisionID: revision.id),
            stagedOwnerID: owner, explicitWhite: true)
        let category = try env.frames.createCategory(name: "Async data links")
        try env.frames.setCategory(frameID: sourceID, categoryID: category.id)
        let sourceBefore = try XCTUnwrap(env.frames.getFrame(id: sourceID))
        let sourceSnapshot = try env.frames.validatedSnapshotForUse(frameID: sourceID)
        let files = try hashes(env)
        let before = try rows(env)
        let vm = FramesViewModel(env: env)
        let stream = EventBus.shared.stream
        let postCommit = expectation(description: "copy readable when success event arrives")
        let observer = Task {
            for await event in stream {
                guard case .frameLibraryChanged(let id?) = event, id != sourceID else { continue }
                do {
                    let snapshot = try env.frames.validatedSnapshotForUse(frameID: id)
                    XCTAssertEqual(snapshot.background, sourceSnapshot.background)
                    XCTAssertEqual(snapshot.foreground, sourceSnapshot.foreground)
                    XCTAssertEqual(try env.frames.getFrame(id: id)?.categoryID, category.id)
                } catch { XCTFail("Event published before valid copy was readable: \(error)") }
                postCommit.fulfill()
                break
            }
        }
        defer { observer.cancel() }
        await vm.duplicate(sourceID)
        await fulfillment(of: [postCommit], timeout: 10)
        await observer.value
        let copy = try XCTUnwrap(env.frames.listFrames().first { $0.id != sourceID })
        let snapshot = try env.frames.validatedSnapshotForUse(frameID: copy.id)
        XCTAssertEqual(snapshot.background?.imageOrientation, 6)
        XCTAssertEqual(snapshot.foreground?.imageOrientation, 8)
        XCTAssertEqual(snapshot.explicitWhite, true)
        XCTAssertNotEqual(snapshot.slots.map(\.id), sourceSnapshot.slots.map(\.id))
        XCTAssertEqual(snapshot.slots.map(\.captureIndex), sourceSnapshot.slots.map(\.captureIndex))
        XCTAssertEqual(try env.frames.getFrame(id: sourceID), sourceBefore)
        XCTAssertEqual(try hashes(env), files)
        let after = try rows(env)
        for table in ["sessions", "session_shots", "photo_revisions", "photo_adjustments", "slot_placements", "frame_snapshots", "assets", "categories", "trash_items", "export_records"] {
            XCTAssertEqual(after[table], before[table], table)
        }
        let refs = try env.db.query("SELECT * FROM asset_references WHERE owner_type='frame_revision' AND owner_id=?", [.text(XCTUnwrap(copy.currentRevisionID))])
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(Set(refs.map { $0["asset_id"].stringValue }), Set([try XCTUnwrap(snapshot.background?.assetID), foreground.id]))
        try env.trashService.trashFrame(frameID: sourceID)
        XCTAssertTrue(env.trashService.purge(try XCTUnwrap(env.trashRepo.find(rootType: .frame, rootID: sourceID))))
        XCTAssertNoThrow(try env.frames.validatedSnapshotForUse(frameID: copy.id))
        let sessionAfter = try XCTUnwrap(env.sessions.getDetail(sessionID: initial.session.id))
        XCTAssertEqual(sessionAfter, initial)
        let model = try await env.renderBuilder.buildModelStrict(detail: sessionAfter, targetWidth: 320, targetHeight: 480)
        XCTAssertNoThrow(try CompositeRenderer.render(model: model))
        try healthy(env)
    }
}
#endif

private final class DuplicatePulse: @unchecked Sendable {
    private let queue = DispatchQueue(label: "qa.duplicate.heartbeat", qos: .userInteractive)
    private let group = DispatchGroup()
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var samples: [Double] = []

    func start(frameID: String) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.setEventHandler { [self] in
            guard OperationCoordinator.shared.isBusy(key: "frame:\(frameID)").busy else { return }
            let sent = ProcessInfo.processInfo.systemUptime
            group.enter()
            Task { @MainActor [self] in
                record(ProcessInfo.processInfo.systemUptime - sent)
                group.leave()
            }
        }
        timer.resume()
    }
    private func record(_ latency: Double) {
        lock.lock(); samples.append(latency); lock.unlock()
    }
    func stop(_ done: @escaping @Sendable () -> Void) {
        timer?.cancel()
        queue.async { [self] in group.notify(queue: queue, execute: done) }
    }
    func values() -> [Double] {
        lock.lock(); defer { lock.unlock() }; return samples
    }
}

extension AuditVerifiedFixTests {
    func testReleaseLargeFrameMainActorRemainsResponsive() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let c = try XCTUnwrap(CGContext(data: nil, width: 6000, height: 6000, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 6000, height: 6000))
        c.clear(CGRect(x: 5800, y: 5800, width: 30, height: 30))
        let data = try ExportService.encode(cg: XCTUnwrap(c.makeImage()), format: .png, quality: 100)
        let owner = IDFactory.new()
        let asset = try env.assets.store(data: data, mediaType: "image/png", purpose: "foreground",
            ownerType: "frame_revision", ownerID: owner)
        let draft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: 6000, canvasHeight: 6000,
            foregroundAssetID: asset.id, foregroundPlacement: .stretchToCanvas)
        let source = try env.frames.createConfiguredFrame(name: "Responsiveness fixture", categoryID: nil, draft: draft,
            slots: [FrameSlot(captureIndex: 1, x: 0.01, y: 0.01, width: 0.98, height: 0.98)], stagedOwnerID: owner, explicitWhite: true)
        let vm = FramesViewModel(env: env)
        var allSamples: [Double] = []
        for index in 1...3 {
            let pulse = DuplicatePulse(); pulse.start(frameID: source.id)
            let start = ProcessInfo.processInfo.systemUptime
            await vm.duplicate(source.id)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let drained = expectation(description: "heartbeat drained \(index)")
            pulse.stop { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 60)
            let samples = pulse.values().sorted()
            allSamples += samples
            print("DUPLICATE-RESPONSIVENESS run=\(index) workerWallSeconds=\(elapsed) samples=\(samples.count) p95Seconds=\(samples.isEmpty ? -1 : samples[Int(Double(samples.count - 1) * 0.95)]) maxSeconds=\(samples.last ?? -1) pngBytes=\(data.count)")
        }
        let sorted = allSamples.sorted()
        XCTAssertGreaterThanOrEqual(sorted.count, 20, "Insufficient samples while the actual source lock was held")
        if !sorted.isEmpty {
            XCTAssertLessThanOrEqual(sorted[Int(Double(sorted.count - 1) * 0.95)], 0.1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(sorted.last), 0.25)
        }
        XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM frames"), 4)
        XCTAssertEqual(env.toast?.text, "Đã nhân bản khung")
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }
}
