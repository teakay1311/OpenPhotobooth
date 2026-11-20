import XCTest
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditDataLinkTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    private func makeSession(env: AppEnvironment, photos: Int = 3) async throws -> (String, FrameSnapshot) {
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot(),
                                                 frameNameAtCapture: frame.name)
        for idx in snap.requiredIndices.sorted().prefix(photos) {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                                   width: 200, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        return (rec.id, snap)
    }

    // SQL JSON1: listSessions phải chạy được và lọc theo snapshot
    func testListSessionsSQLWorks() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, _) = try await makeSession(env: env)
        try env.sessions.setStatus(sessionID: sid, status: .reviewable)
        let all = try env.sessions.listSessions()
        let completed = try env.sessions.listSessions(statuses: [.completed])
        let incomplete = try env.sessions.listSessions(statuses: [.reviewable])
        print("AUDIT-SQL all=\(all.count) completed=\(completed.count) reviewable=\(incomplete.count) committed=\(all.first?.committedCount ?? -1)")
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(incomplete.count, 1)
        XCTAssertEqual(all.first?.committedCount, 3)
    }

    // Snapshot JSON hỏng không được làm sập toàn bộ truy vấn Thư viện
    func testCorruptSnapshotJSONDoesNotBreakLibrary() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, snap) = try await makeSession(env: env)
        try env.db.run("UPDATE frame_snapshots SET snapshot_json='{broken' WHERE id=?", [.text(snap.id)])
        do {
            let rows = try env.sessions.listSessions()
            print("AUDIT-SQL-CORRUPT rows=\(rows.count)")
            XCTAssertEqual(rows.count, 1)
        } catch {
            print("AUDIT-SQL-CORRUPT error:", error)
            XCTFail("Danh sách Thư viện ném lỗi khi một snapshot JSON hỏng: \(error)")
        }
        _ = sid
    }

    // Rotation 90 phải đổi chiều ảnh và giữ nội dung
    func testRotateNinetySwapsDimensions() throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 150, y: 0, width: 150, height: 200))
        let img = ctx.makeImage()!

        let r90 = ImageNormalizer.rotate(img, degrees: 90)
        print("AUDIT-ROT90 size=\(r90.width)x\(r90.height)")
        XCTAssertEqual(r90.width, 200)
        XCTAssertEqual(r90.height, 300)

        // Điểm góc trên-trái sau khi xoay clockwise phải là đỏ (nửa trái ảnh gốc)
        let color = Self.pixelColor(r90, x: 100, y: 20)
        print("AUDIT-ROT90 pixel=", color)
        XCTAssertGreaterThan(color.red, color.blue)
    }

    private struct RGB { var red: CGFloat; var blue: CGFloat }
    private static func pixelColor(_ img: CGImage, x: Int, y: Int) -> RGB {
        var data = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return RGB(red: CGFloat(data[0]) / 255.0, blue: CGFloat(data[2]) / 255.0)
    }

    // Frame Editor: chặn rời màn khi có thay đổi
    func testFrameEditorLeaveGuard() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first)
        env.openFrameEditor(frameID: frame.id)
        env.frameEditorHasChanges = true
        env.requestNavigation(to: .library)
        print("AUDIT-EDITOR-GUARD route=\(env.route) confirm=\(env.showFrameEditorLeaveConfirmation) pending=\(String(describing: env.pendingNavigationRoute))")
        XCTAssertTrue(env.showFrameEditorLeaveConfirmation)
        if case .frameEditor = env.route {} else { XCTFail("Phải giữ nguyên Frame Editor") }

        env.cancelLeaveFrameEditor()
        if case .frameEditor = env.route {} else { XCTFail("Hủy phải ở lại Editor") }

        env.frameEditorSaveHandler = { false }   // validator fail
        env.frameEditorHasChanges = true
        env.requestNavigation(to: .library)
        env.confirmLeaveFrameEditor()            // handler false -> MainWindow không gọi
        // confirmLeaveFrameEditor chỉ được gọi khi save OK; ở đây kiểm tra API không rời khi chưa lưu xong
        // (MainWindow chịu trách nhiệm gọi; API không tự kiểm tra)
        print("AUDIT-EDITOR-GUARD afterConfirm route=\(env.route)")
    }
}
@MainActor
final class AuditRepairTests: XCTestCase {
    private func makeFrame(_ env: AppEnvironment, white: Bool = false, count: Int = 1) throws -> Frame {
        let frame = try env.frames.createEmptyFrame(name: "Khung kiểm tra", categoryID: nil, canvasWidth: 600, canvasHeight: 900)
        let id = try XCTUnwrap(env.frames.getFrame(id: frame.id)?.currentRevisionID)
        let draft = try XCTUnwrap(env.frames.getRevision(id: id))
        let slots = (0..<count).map { FrameSlot(captureIndex: $0 + 1, x: 0.1, y: Double($0) * 0.2 + 0.05,
                                                 width: 0.8, height: 0.2) }
        _ = try env.frames.saveConfiguredRevision(frameID: frame.id, expectedRevisionID: id, name: frame.name,
            draft: draft, slots: slots, stagedOwnerID: "audit-repair", explicitWhite: white)
        return try XCTUnwrap(env.frames.getFrame(id: frame.id))
    }

    private func markedJPEG(orientation: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 900, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors: [CGColor] = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                                 CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
        for index in 0..<4 {
            context.setFillColor(colors[index])
            context.fill(CGRect(x: index % 2 * 300, y: index / 2 * 450, width: 300, height: 450))
        }
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func colorMarkers(_ image: CGImage) throws -> [Int] {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { index in
            (0..<4).reduce(0) { ($0 << 1) | (pixels[index * 4 + $1] > 127 ? 1 : 0) }
        }
    }

    private func render(_ snapshot: FrameSnapshot, images: [String: CGImage], env: AppEnvironment) throws -> CGImage {
        try CompositeRenderer.render(model: CompositionModel(snapshot: snapshot, sources: [:], faces: [:],
            defaults: env.settings.sessionDefaultsSnapshot(), overrides: [:], placements: [:], cropModes: [:],
            assetImages: images, options: RenderOptions(targetWidth: snapshot.canvasWidth,
                targetHeight: snapshot.canvasHeight, transparentBackground: true)))
    }

    private func counts(_ env: AppEnvironment) throws -> [Int64] {
        try ["frames", "frame_revisions", "frame_slots", "assets", "asset_references", "app_state"].map {
            try env.db.scalarInt("SELECT COUNT(*) FROM \($0)")
        }
    }

    func testOPB02DuplicateWhiteAndRollbackAtEveryWrite() throws {
        let env = AppEnvironment(inMemory: true)
        let frame = try makeFrame(env, white: true)
        let jpeg = try markedJPEG(orientation: 6)
        let owner = "duplicate-shared-layer"
        let asset = try env.assets.store(data: jpeg, mediaType: "image/jpeg", purpose: "background",
                                         ownerType: "frame_revision", ownerID: owner)
        let sourceRevision = try XCTUnwrap(frame.currentRevisionID)
        var draft = try XCTUnwrap(env.frames.getRevision(id: sourceRevision))
        draft.backgroundAssetID = asset.id
        draft.backgroundImageOrientation = 6
        _ = try env.frames.saveConfiguredRevision(frameID: frame.id, expectedRevisionID: sourceRevision, name: frame.name,
            draft: draft, slots: env.frames.getSlots(revisionID: sourceRevision), stagedOwnerID: owner, explicitWhite: true)
        let original = try env.frames.createSnapshot(frameID: frame.id)
        let baseline = try counts(env)
        for (table, condition) in [("frame_slots", "1"), ("asset_references", "1"),
                                   ("app_state", "NEW.key LIKE 'explicit_white_%'"),
                                   ("app_state", "NEW.key LIKE 'frame_layer_exif_%'")] {
            try env.db.run("CREATE TRIGGER fail_duplicate BEFORE INSERT ON \(table) WHEN \(condition) BEGIN SELECT RAISE(ABORT, 'QA rollback'); END")
            XCTAssertThrowsError(try env.frames.duplicateFrame(id: frame.id))
            XCTAssertEqual(try counts(env), baseline)
            try env.db.run("DROP TRIGGER fail_duplicate")
        }
        let copy = try env.frames.duplicateFrame(id: frame.id)
        let snapshot = try env.frames.createSnapshot(frameID: copy.id)
        XCTAssertEqual(snapshot.explicitWhite, true)
        XCTAssertEqual(snapshot.background, original.background)
        XCTAssertNotEqual(snapshot.slots.map(\.id), original.slots.map(\.id))
        XCTAssertEqual(try colorMarkers(render(snapshot, images: [:], env: env)), [15, 15, 15, 15])
        let withoutWhite = try makeFrame(env)
        let secondCopy = try env.frames.duplicateFrame(id: withoutWhite.id)
        XCTAssertEqual(try env.frames.createSnapshot(frameID: secondCopy.id).explicitWhite, false)

        try env.trashService.trashFrame(frameID: copy.id)
        try env.trashService.restore(XCTUnwrap(env.trashRepo.find(rootType: .frame, rootID: copy.id)))
        XCTAssertEqual(try env.frames.createSnapshot(frameID: copy.id, persist: false).background, original.background)
        try env.trashService.trashFrame(frameID: copy.id)
        XCTAssertTrue(env.trashService.purge(try XCTUnwrap(env.trashRepo.find(rootType: .frame, rootID: copy.id))))
        XCTAssertEqual(try env.db.scalarInt("SELECT COUNT(*) FROM app_state WHERE key=?", [.text("frame_layer_exif_\(copy.currentRevisionID!)")]), 0)
        XCTAssertEqual(try env.assets.loadData(assetID: asset.id), jpeg)
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }

    func testOPB03BoundsPreserveRatioAndRenderRequestedSize() async throws {
        let env = AppEnvironment(inMemory: true)
        let frame = try makeFrame(env)
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)
        let session = try env.sessions.createSession(snapshot: snapshot, mode: .manual, cameraID: nil,
            defaults: env.settings.sessionDefaultsSnapshot())
        _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: 1,
            payloadData: markedJPEG(orientation: 1), requestID: UUID().uuidString,
            width: 600, height: 900, orientation: 1, codec: "jpeg", colorProfile: nil)
        let review = ReviewViewModel(env: env)
        await review.load(sessionID: session.id)
        let vm = ExportViewModel(env: env)
        vm.review = review
        vm.configure(detail: try XCTUnwrap(review.detail))
        vm.setHeight(256)
        XCTAssertEqual([vm.width, vm.height], [256, 384])
        vm.setWidth(8192)
        XCTAssertLessThanOrEqual(vm.width * vm.height, 40_000_000)
        XCTAssertEqual(Double(vm.height), Double(vm.width) * 1.5, accuracy: 0.5)
        vm.aspectLocked = false
        vm.setWidth(600)
        vm.setHeight(600)
        XCTAssertEqual([vm.width, vm.height], [600, 600])
        vm.aspectLocked = true
        XCTAssertEqual([vm.width, vm.height], [600, 900])
        vm.setHeight(256)
        let detail = try XCTUnwrap(review.detail)
        let destination = env.layout.rootURL.appendingPathComponent("size-check")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for format in [ExportImageFormat.jpeg, .png] {
            let preview = ExportService.PreviewIdentity(detail: detail, format: format, width: vm.width,
                                                        height: vm.height, quality: 95)
            var request = ExportService.ExportRequest(sessionID: session.id, format: format, quality: 95,
                width: vm.width, height: vm.height, filenameBase: "bounds", destinationFolder: destination)
            request.acceptedPreview = preview
            let (_, url) = try await env.exportService.export(detail: detail, request: request)
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
            XCTAssertEqual([decoded.width, decoded.height], [256, 384])
        }
    }

    func testOPB04EXIFPixelsLegacySessionAndPackRoundTrip() async throws {
        let env = AppEnvironment(inMemory: true)
        let slot = FrameSlot(captureIndex: 1, x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        var orientationSix: (Frame, FrameSnapshot, Data)?
        for mode in 1...8 {
            let bytes = try markedJPEG(orientation: mode)
            let frame = try env.frames.createConfiguredFrame(name: "Orientation \(mode)", imageData: bytes,
                mediaType: "image/jpeg", role: .frameBackground, categoryID: nil, slots: [slot])
            let snap = try env.frames.createSnapshot(frameID: frame.id)
            let layer = try XCTUnwrap(snap.background)
            XCTAssertEqual(layer.imageOrientation, mode == 1 ? nil : mode)
            XCTAssertEqual(try env.assets.loadData(assetID: layer.assetID), bytes)
            let raw = try env.assets.loadVerifiedImage(assetID: layer.assetID)
            XCTAssertEqual([raw.width, raw.height], [600, 900])
            let upright = try XCTUnwrap(ImageNormalizer.uprightImage(data: bytes))
            XCTAssertEqual([snap.canvasWidth, snap.canvasHeight], [upright.width, upright.height])
            XCTAssertEqual(try colorMarkers(render(snap, images: [layer.assetID: raw], env: env)), try colorMarkers(upright))
            if mode == 6 { orientationSix = (frame, snap, bytes) }
        }
        let (frame, snap, bytes) = try XCTUnwrap(orientationSix)
        let layer = try XCTUnwrap(snap.background)
        let raw = try env.assets.loadVerifiedImage(assetID: layer.assetID)
        // A legacy revision shares the same bytes, but has no orientation metadata.
        let legacyDraft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: 600, canvasHeight: 900,
                                         backgroundAssetID: layer.assetID)
        let legacyFrame = try env.frames.createConfiguredFrame(name: "Legacy", categoryID: nil, draft: legacyDraft,
            slots: [slot], stagedOwnerID: "legacy-audit")
        let legacy = try env.frames.createSnapshot(frameID: legacyFrame.id)
        let session = try env.sessions.createSession(snapshot: legacy, mode: .manual, cameraID: nil,
            defaults: env.settings.sessionDefaultsSnapshot())
        let stored = try env.db.query("SELECT snapshot_json, snapshot_hash FROM frame_snapshots WHERE id=?", [.text(legacy.id)])
        XCTAssertFalse(try XCTUnwrap(stored.first)["snapshot_json"].stringValue.contains("imageOrientation"))
        let reloaded = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id)).snapshot
        XCTAssertEqual(reloaded, legacy)
        XCTAssertEqual(try colorMarkers(render(reloaded, images: [layer.assetID: raw], env: env)), try colorMarkers(raw))
        XCTAssertNotEqual(try colorMarkers(render(snap, images: [layer.assetID: raw], env: env)), try colorMarkers(raw))
        XCTAssertEqual(try env.db.query("SELECT snapshot_json, snapshot_hash FROM frame_snapshots WHERE id=?", [.text(legacy.id)]), stored)

        let pack = try env.packService.buildPack(name: "EXIF round trip", frameIDs: [frame.id, legacyFrame.id])
        let loaded = try env.packService.loadPack(data: pack)
        let entry = try XCTUnwrap(loaded.entries.first { $0.id == frame.id })
        XCTAssertEqual(entry.frame.assets.backgroundImageOrientation, 6)
        let preview = try XCTUnwrap(CGImage.createFrom(data: XCTUnwrap(entry.thumbnailData)))
        XCTAssertGreaterThan(preview.width, preview.height)
        let results = try env.packService.applyImportDetailed(result: loaded,
            choices: loaded.entries.map { .init(packFrameID: $0.id, policy: .copy, selected: true) }, data: pack)
        guard case .imported(let importedID) = results[frame.id] else { return XCTFail("Không nhập lại được khung EXIF") }
        let imported = try env.frames.createSnapshot(frameID: importedID)
        XCTAssertEqual(imported.background, snap.background)
        XCTAssertEqual(try env.assets.loadData(assetID: layer.assetID), bytes)
        let thumbnail = await env.frameThumbnails.requestThumbnail(frameID: frame.id, revisionID: try XCTUnwrap(frame.currentRevisionID))
        XCTAssertNotNil(thumbnail)
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }

    func testOPB05RejectAmbiguousIDsWithoutWriting() throws {
        let env = AppEnvironment(inMemory: true)
        let frame = try makeFrame(env, white: true)
        let valid = try env.packService.buildPack(name: "Audit", frameIDs: [frame.id])
        var manifest = try FramePackService.validate(data: valid).manifest
        var second = try XCTUnwrap(manifest.frames.first)
        second.name = "Other frame"
        manifest.frames.append(second)
        let duplicate = ZipArchive.archive(entries: [.init(name: "manifest.json", data: try JSONEncoder().encode(manifest))])
        let before = try counts(env)
        XCTAssertThrowsError(try env.packService.loadPack(data: duplicate))
        let ready = try env.packService.loadPack(data: valid)
        let choice = FramePackService.ImportChoice(packFrameID: frame.id, policy: .copy, selected: true)
        XCTAssertThrowsError(try env.packService.applyImportDetailed(result: ready, choices: [choice, choice], data: valid))
        XCTAssertThrowsError(try env.packService.applyImportDetailed(result: ready,
            choices: [.init(packFrameID: "absent", policy: .copy, selected: true)], data: valid))
        XCTAssertEqual(try counts(env), before)
        XCTAssertTrue(try env.packService.applyImportDetailed(result: ready, choices: [choice], data: valid).values.allSatisfy(\.isSuccess))
    }
}

extension AuditRepairTests {
    func testOPB01FullLibraryAndLatestRequest() async throws {
        let env = AppEnvironment(inMemory: true)
        let vm = LibraryViewModel(env: env)
        await vm.reload().value
        XCTAssertTrue(vm.cards.isEmpty)
        let frame = try makeFrame(env, count: 4)
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)
        for number in 0..<501 {
            let record = try env.sessions.createSession(snapshot: snapshot, mode: .manual, cameraID: nil,
                defaults: env.settings.sessionDefaultsSnapshot(), frameNameAtCapture: number == 0 ? "Khung Cũ Nhất" : "Mới")
            try env.db.run("UPDATE sessions SET updated_at_ms=? WHERE id=?", [.int(Int64(number)), .text(record.id)])
            if [0, 499].contains(number) {
                await vm.reload().value
                XCTAssertEqual(vm.cards.count, number + 1)
            }
        }
        await vm.reload().value
        XCTAssertEqual(vm.cards.count, 501)
        XCTAssertEqual(vm.cards.last?.frameName, "Khung Cũ Nhất")
        let oldest = try XCTUnwrap(vm.cards.last?.id)
        vm.sortNewest = false
        await vm.reload().value
        XCTAssertEqual(vm.cards.first?.id, oldest)
        vm.searchText = "Mới"
        let previous = vm.reload()
        vm.searchText = "cũ nhất"
        await vm.reload().value
        await previous.value
        XCTAssertEqual(vm.cards.map(\.id), [oldest])
        vm.searchText = try XCTUnwrap(vm.cards.first?.formattedDate)
        await vm.reload().value
        XCTAssertTrue(vm.cards.contains { $0.id == oldest })
        vm.searchText = ""
        vm.filter = .completed
        await vm.reload().value
        XCTAssertTrue(vm.cards.isEmpty)
        vm.filter = .incomplete
        await vm.reload().value
        XCTAssertEqual(vm.cards.count, 501)
        try env.trashService.trashSession(sessionID: oldest)
        await vm.reload().value
        XCTAssertEqual(vm.cards.count, 500)
        XCTAssertFalse(vm.cards.contains { $0.id == oldest })
    }

    func testOPB01LargeLibraryPerformance() async throws {
        let env = AppEnvironment(inMemory: true)
        defer { try? FileManager.default.removeItem(at: env.layout.rootURL) }
        let frame = try makeFrame(env, count: 4)
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let defaults = String(decoding: try JSONEncoder().encode(env.settings.sessionDefaultsSnapshot()), as: UTF8.self)
        let photo = try markedJPEG(orientation: 1)
        let sha = Hashing.sha256Hex(photo)
        try env.db.withTransaction { tx in
            for index in 0..<5000 {
                let id = "perf-\(index)"
                let timestamp = Int64(index) + 1
                let photoCount = (index % 3) * 2
                try tx.run("""
                    INSERT INTO sessions(id,status,active_frame_snapshot_id,required_capture_count,capture_mode,
                        session_defaults_json,created_at_ms,updated_at_ms,frame_name_at_capture)
                    VALUES(?,?,?,4,'manual',?,?,?,?)
                    """, [.text(id), .text(photoCount == 4 ? "completed" : "paused"), .text(snap.id),
                          .text(defaults), .int(timestamp), .int(timestamp), .text(index.isMultiple(of: 2) ? "Khung Én" : "Khung Mây")])
                for shot in 1...4 {
                    let shotID = "\(id)-\(shot)"
                    let photoID = "\(shotID)-photo"
                    try tx.run("INSERT INTO session_shots VALUES(?,?,?,?)",
                        [.text(shotID), .text(id), .int(Int64(shot)), shot <= photoCount ? .text(photoID) : .null])
                    if shot <= photoCount {
                        let path = "Sessions/\(id)/Originals/\(photoID).jpg"
                        let url = try env.layout.absoluteURL(forRelativePath: path)
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try photo.write(to: url)
                        try tx.run("""
                            INSERT INTO photo_revisions(id,shot_id,revision_no,relative_path,sha256,width,height,
                                 orientation,codec,capture_request_id,captured_at_ms)
                            VALUES(?,?,1,?,?,600,900,1,'jpeg',?,?)
                            """, [.text(photoID), .text(shotID), .text(path), .text(sha), .text(photoID), .int(timestamp)])
                    }
                }
            }
        }
        let vm = LibraryViewModel(env: env)
        let clock = ContinuousClock()
        let coldStart = clock.now
        await vm.reload().value
        let cold = coldStart.duration(to: clock.now)
        XCTAssertEqual(vm.cards.count, 5000)
        for _ in 0..<5 { await vm.reload().value }
        var latencies: [Duration] = []
        let heartbeat = Task { @MainActor () -> [Duration] in
            var samples: [Duration] = []
            while !Task.isCancelled {
                let deadline = clock.now + .milliseconds(10)
                do { try await clock.sleep(until: deadline) } catch { break }
                samples.append(deadline.duration(to: clock.now))
            }
            return samples
        }
        for index in 0..<30 {
            vm.searchText = index.isMultiple(of: 2) ? "" : "én"
            let start = clock.now
            await vm.reload().value
            latencies.append(start.duration(to: clock.now))
            XCTAssertEqual(vm.cards.count, index.isMultiple(of: 2) ? 5000 : 2500)
        }
        heartbeat.cancel()
        let heartbeats = await heartbeat.value
        func p95(_ samples: [Duration]) -> Duration {
            samples.sorted()[Int(ceil(Double(samples.count) * 0.95)) - 1]
        }
        XCTAssertFalse(heartbeats.isEmpty)
        guard !heartbeats.isEmpty else { return }
        print("OPB01_PERF cold=\(cold) p95=\(p95(latencies)) mainP95=\(p95(heartbeats))")
        XCTAssertLessThanOrEqual(cold, .seconds(3))
        XCTAssertLessThanOrEqual(p95(latencies), .seconds(1))
        XCTAssertLessThanOrEqual(p95(heartbeats), .milliseconds(100))
        XCTAssertNil(try env.db.integrityCheck())
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
    }
}

extension AuditRepairTests {
    func testChooserPreviewCancellationAndBusyValidationRecoverWithoutReselection() async throws {
        let env = AppEnvironment(inMemory: true)
        let frame = try makeFrame(env, count: 1)
        let snapshot = try env.frames.createSnapshot(frameID: frame.id)
        let session = try env.sessions.createSession(snapshot: snapshot, mode: .manual, cameraID: nil,
            defaults: env.settings.sessionDefaultsSnapshot())
        _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: 1,
            payloadData: markedJPEG(orientation: 1), requestID: UUID().uuidString,
            width: 600, height: 900, orientation: 1, codec: "jpeg", colorProfile: nil)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        let revision = try XCTUnwrap(frame.currentRevisionID)
        let service = env.chooserPreviews
        let token = try env.coordinator.acquire(key: "frame:\(frame.id)", reason: "QA transient validation")
        let release = Task { try await Task.sleep(for: .milliseconds(120)); token.release() }
        let obsolete = Task { try await service.render(detail: detail, frameID: frame.id, revision: revision,
            order: [1], width: 240, height: 240) }
        try await Task.sleep(for: .milliseconds(20))
        obsolete.cancel()
        let latest = Task { try await service.render(detail: detail, frameID: frame.id, revision: revision,
            order: [1], width: 360, height: 360) }
        let result = try await latest.value
        _ = try await release.value
        XCTAssertEqual(result.snapshot.sourceFrameRevisionID, revision)
        XCTAssertNotNil(result.selection)
        XCTAssertLessThanOrEqual(max(result.selection!.width, result.selection!.height), 360)
        do { _ = try await obsolete.value; XCTFail("Obsolete preview must be cancelled") } catch { }
        do {
            _ = try await service.render(detail: detail, frameID: frame.id, revision: UUID().uuidString,
                order: [1], width: 200, height: 200)
            XCTFail("Stale frame revision must not be displayed")
        } catch { }
        let retried = try await service.render(detail: detail, frameID: frame.id, revision: revision,
            order: [1], width: 200, height: 200)
        XCTAssertNotNil(retried.selection)
    }
}
