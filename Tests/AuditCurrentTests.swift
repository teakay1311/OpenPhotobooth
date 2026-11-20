import XCTest
import Foundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
@testable import OpenPhotobooth

/// Audit test cho bản mã 19:27 (sau đợt sửa). Mỗi test khẳng định HÀNH VI MONG ĐỢI;
/// fail = lỗi. In marker AUDIT-* để trích dẫn.
@MainActor
final class AuditCurrentTests: XCTestCase {

    private func pngBytes(w: Int = 200, h: Int = 200, alpha: Bool = false) -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info: UInt32 = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                 : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs, bitmapInfo: info)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func jpegBytes(w: Int = 200, h: Int = 200) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    private func makeSession(env: AppEnvironment, frameName: String,
                             mode: CaptureMode = .automatic) async throws -> (String, FrameSnapshot) {
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == frameName })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: mode, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot(),
                                                 frameNameAtCapture: frame.name)
        let jpeg = try jpegBytes()
        for idx in snap.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: jpeg, requestID: UUID().uuidString,
                                                   width: 200, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        return (rec.id, snap)
    }

    // MARK: - A1: Frame Pack bỏ qua bản nháp, không làm hỏng backup

    func testPackSkipsDraftFrame() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        _ = try env.frames.createFrame(name: "Khung nháp", imageData: pngBytes(w: 400, h: 600),
                                       mediaType: "image/png", role: .frameBackground, categoryID: nil)
        let ids = try env.frames.listFrames().map(\.id)
        do {
            let result = try env.packService.preparePack(name: "backup", frameIDs: ids)
            print("AUDIT-PACK packed=\(result.packedFramesCount) skipped=\(result.skippedDraftCount)")
            XCTAssertEqual(result.skippedDraftCount, 1)
            XCTAssertEqual(result.packedFramesCount, ids.count - 1)
            _ = try FramePackService.validate(data: result.data)
        } catch {
            print("AUDIT-PACK-ERROR:", (error as? AppError)?.message ?? "\(error)")
            XCTFail("Backup vẫn hỏng khi có khung nháp: \(error)")
        }
    }

    // MARK: - A2: Auto Export dùng kích thước canvas

    func testAutoExportUsesCanvasSize() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, snap) = try await makeSession(env: env, frameName: "Lưới 4 ảnh")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-exp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Service fixture. The signed Release UI covers app-scoped bookmark creation.
        let blob = try tmp.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let bm = try env.trashRepo.saveBookmark(purpose: "exportFolder", blob: blob, displayPath: tmp.path)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: sid))
        let res = await env.exportService.autoExport(detail: detail, folderBookmarkID: bm)
        switch res {
        case .success(let url):
            let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
            let w = props[kCGImagePropertyPixelWidth] as! Int
            let h = props[kCGImagePropertyPixelHeight] as! Int
            print("AUDIT-AUTOEXPORT size=\(w)x\(h) canvas=\(snap.canvasWidth)x\(snap.canvasHeight)")
            XCTAssertEqual(w, snap.canvasWidth)
            XCTAssertEqual(h, snap.canvasHeight)
        case .failure(let e):
            XCTFail("Auto Export lỗi: \(e.message)")
        }
    }

    // MARK: - A3: Thumbnail giữ tỉ lệ canvas

    func testThumbnailKeepsCanvasAspect() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let rev = try XCTUnwrap(env.frames.getRevision(id: try XCTUnwrap(frame.currentRevisionID)))
        let data = await env.frameThumbnails.requestThumbnail(frameID: frame.id,
                                                              revisionID: try XCTUnwrap(frame.currentRevisionID))
        let png = try XCTUnwrap(data)
        let src = CGImageSourceCreateWithData(png as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        let w = props[kCGImagePropertyPixelWidth] as! Int
        let h = props[kCGImagePropertyPixelHeight] as! Int
        print("AUDIT-THUMB size=\(w)x\(h) canvas=\(rev.canvasWidth)x\(rev.canvasHeight)")
        let expected = Double(rev.canvasWidth) / Double(rev.canvasHeight)
        let actual = Double(w) / Double(h)
        XCTAssertEqual(actual, expected, accuracy: 0.02)
    }

    // MARK: - L2: Khung chọn tay không bị ghi đè khi quay lại màn Chụp

    func testPreferredFrameFollowsManualSelection() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frames = try env.frames.listReadyFrames()
        let a = frames[0], b = frames[1]
        let vm1 = CaptureViewModel(env: env)
        vm1.reloadFrames()
        vm1.selectFrame(a.id)
        vm1.selectFrame(b.id)
        print("AUDIT-PREFERRED preferred=\(env.preferredFrameID ?? "nil") selected=\(b.id)")
        let vm2 = CaptureViewModel(env: env)
        vm2.reloadFrames()
        print("AUDIT-PREFERRED-REENTRY=\(vm2.selectedFrameID ?? "nil") expected=\(b.id)")
        XCTAssertEqual(vm2.selectedFrameID, b.id)
    }

    // MARK: - A6: Giới hạn 12 ô, index liên tục

    func testSlotLimitAndReindex() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let vm = FrameEditorViewModel(env: env)
        vm.load(frameID: frame.id)
        for _ in 0..<20 { vm.addSlot() }
        print("AUDIT-SLOTS count=\(vm.slots.count) indices=\(vm.slots.map(\.captureIndex).sorted())")
        XCTAssertEqual(vm.slots.count, 12)
        XCTAssertEqual(Set(vm.slots.map(\.captureIndex)), Set(1...12))
        let deadline = ContinuousClock.now + .seconds(5)
        while vm.isValidating, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(vm.isValidating)
        XCTAssertTrue(vm.canSave)
    }

    // MARK: - A8: Hoàn thành + Auto Export đúng một lần

    func testCompleteSessionOnlyOnce() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, _) = try await makeSession(env: env, frameName: "Dải 3 ảnh")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-exp2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Service fixture. The signed Release UI covers app-scoped bookmark creation.
        let blob = try tmp.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        env.settings.exportFolderBookmarkID = try env.trashRepo.saveBookmark(purpose: "exportFolder", blob: blob, displayPath: tmp.path)
        env.settings.autoExport = true
        env.settings.exportFormat = .png

        let first = try await env.completeSession(sessionID: sid)
        let second = try await env.completeSession(sessionID: sid)
        let records = try env.sessions.listExportRecords(sessionID: sid)
        print("AUDIT-COMPLETE first=\(first) second=\(second) exportRecords=\(records.count)")
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(records.count, 1, "Auto Export phải chạy đúng một lần cho mỗi lần chuyển trạng thái")
        let record = try XCTUnwrap(records.first)
        let session = try XCTUnwrap(env.sessions.getSession(id: sid))
        XCTAssertEqual(record.format, .png)
        XCTAssertEqual(record.sessionRevisionNo, session.revisionNo)
        XCTAssertEqual(record.status, .success)
        let path = try XCTUnwrap(record.destinationDisplayPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - A7: Rotation + Smart Face có hiệu lực

    func testRotationAndSmartFaceAffectSession() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        env.settings.rotation = 90
        env.settings.smartFace = false
        let defaults = env.settings.sessionDefaultsSnapshot()
        let resolved = ResolvedPhotoParams.resolve(defaults: defaults, override: nil)
        print("AUDIT-SETTINGS rotation=\(resolved.photoRotation) smartFace=\(defaults.smartFace ?? true)")
        XCTAssertEqual(resolved.photoRotation, 90)
        XCTAssertEqual(defaults.smartFace, false)
    }

    // MARK: - L7: Không cho trash/ghi khi phiên đang chụp

    func testTrashBlockedWhileCountdownRunning() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                              defaults: env.settings.sessionDefaultsSnapshot(),
                                              countdown: 5, interval: 2)
        try env.engine.startOrContinue()
        do {
            try env.trashService.trashSession(sessionID: rec.id)
            print("AUDIT-TRASH-DURING-CAPTURE allowed")
            XCTFail("Cho phép trash phiên đang đếm ngược")
        } catch {
            print("AUDIT-TRASH-DURING-CAPTURE blocked:", (error as? AppError)?.message ?? "\(error)")
        }
        env.engine.cancelCountdown()
    }

    // MARK: - Validator: index trùng

    func testValidatorRejectsDuplicateCaptureIndex() {
        let slots = [
            FrameSlot(captureIndex: 1, x: 0.1, y: 0.1, width: 0.4, height: 0.4, zOrder: 0),
            FrameSlot(captureIndex: 1, x: 0.5, y: 0.1, width: 0.4, height: 0.4, zOrder: 1)
        ]
        let issues = FrameValidator.validate(canvasWidth: 1200, canvasHeight: 1800, slots: slots,
                                            hasBackground: true, hasForeground: false,
                                            backgroundColorHex: "#FFFFFFFF")
        print("AUDIT-VALIDATOR codes=", issues.map(\.code))
        XCTAssertTrue(issues.contains { $0.code == "F-VAL-03" })
    }
}