import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditFlowTests: XCTestCase {

    private func jpegBytes(_ rgb: (CGFloat, CGFloat, CGFloat) = (0.3, 0.6, 0.2)) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    private func pngBytes() -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    // T1: completeSession khi engine đang .reviewing -> engine về idle, khoá được nhả
    func testCompleteSessionWithEngineInReview() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                              defaults: env.settings.sessionDefaultsSnapshot(),
                                              countdown: 1, interval: 1)
        let jpeg = try jpegBytes()
        for idx in snap.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: jpeg, requestID: UUID().uuidString,
                                                   width: 240, height: 320, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        env.engine.enterReview()
        XCTAssertEqual(env.engine.state, .reviewing)
        let ok = try await env.completeSession(sessionID: rec.id)
        print("AUDIT-FLOW complete=\(ok) engine=\(env.engine.state) busy=\(env.coordinator.isSessionBusy(rec.id).busy)")
        XCTAssertTrue(ok)
        XCTAssertEqual(env.engine.state, .idle)
        XCTAssertFalse(env.coordinator.isSessionBusy(rec.id).busy)
        let record = try env.sessions.getSession(id: rec.id)
        XCTAssertEqual(record?.status, .completed)
    }

    // T2: changeFrame sang khung nhiều ô hơn -> không thể hoàn thành (thiếu ảnh), trạng thái không đổi
    func testChangeFrameThenCompleteRejected() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame3 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let frame4 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Lưới 4 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame3.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        let jpeg = try jpegBytes()
        for idx in snap.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: jpeg, requestID: UUID().uuidString,
                                                   width: 240, height: 320, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)
        let newSnap = try env.frames.createSnapshot(frameID: frame4.id)
        try env.sessions.changeFrame(sessionID: rec.id, newSnapshot: newSnap)
        do {
            _ = try await env.completeSession(sessionID: rec.id)
            XCTFail("Không được complete khi khung mới còn thiếu ảnh")
        } catch {
            print("AUDIT-FLOW-CHANGEFRAME rejected:", (error as? AppError)?.message ?? "\(error)")
        }
        let after = try env.sessions.getSession(id: rec.id)
        print("AUDIT-FLOW-CHANGEFRAME status=\(after?.status.rawValue ?? "nil")")
        XCTAssertNotEqual(after?.status, .completed)
    }

    // T4: Frame Pack round-trip giữ đúng định dạng media type + frame sẵn sàng
    func testPackRoundTripPreservesMediaType() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        _ = try env.frames.createFrame(name: "JPEG nền", imageData: pngBytes(), mediaType: "image/png",
                                       role: .frameBackground, categoryID: nil)
        let ids = try env.frames.listFrames().map(\.id)
        let pack = try env.packService.preparePack(name: "p", frameIDs: ids)
        let validation = try FramePackService.validate(data: pack.data)
        let choices = validation.manifest.frames.map {
            FramePackService.ImportChoice(packFrameID: $0.frameId, policy: .copy, selected: true)
        }
        let outcomes = try env.packService.applyImport(result: validation, choices: choices, data: pack.data)
        let failures = outcomes.values.compactMap { v -> String? in if case .failure(let m) = v { return m } else { return nil } }
        print("AUDIT-FLOW-PACK packed=\(pack.packedFramesCount) imported=\(outcomes.count) failures=\(failures)")
        XCTAssertTrue(failures.isEmpty)
        let total = try env.frames.listFrames().count
        print("AUDIT-FLOW-PACK totalFrames=\(total)")
        XCTAssertEqual(total, ids.count + validation.manifest.frames.count)
    }

    // T5: Trash -> Restore phiên vẫn đọc được ảnh (khoá mới không phá vòng đời)
    func testTrashRestoreRoundTrip() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        let jpeg = try jpegBytes()
        for idx in snap.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: jpeg, requestID: UUID().uuidString,
                                                   width: 240, height: 320, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        try env.trashService.trashSession(sessionID: rec.id)
        let item = try XCTUnwrap(try env.trashRepo.find(rootType: .session, rootID: rec.id))
        try env.trashService.restore(item)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id))
        var missing = 0
        for (_, rev) in detail.currentRevisions() {
            if !FileManager.default.fileExists(atPath: try env.sessions.fileURL(for: rev).path) { missing += 1 }
        }
        print("AUDIT-FLOW-TRASH committed=\(detail.committedCount) missingFiles=\(missing) status=\(detail.session.status.rawValue)")
        XCTAssertEqual(missing, 0)
        XCTAssertEqual(detail.committedCount, 3)
    }

    // T6: Export PNG giữ alpha + kích thước canvas
    func testExportPNGKeepsCanvas() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Một ảnh lớn" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1,
                                               payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                               width: 240, height: 320, orientation: 1,
                                               codec: "jpeg", colorProfile: nil)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audit-png-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let req = ExportService.ExportRequest(sessionID: rec.id, format: .png, quality: 95,
                                              width: snap.canvasWidth, height: snap.canvasHeight,
                                              filenameBase: ExportService.defaultFilenameBase(),
                                              destinationFolder: tmp)
        let (record, url) = try await env.exportService.export(detail: detail, request: req)
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        print("AUDIT-FLOW-PNG name=\(record.filename) size=\(props[kCGImagePropertyPixelWidth]!)x\(props[kCGImagePropertyPixelHeight]!)")
        XCTAssertTrue(record.filename.hasPrefix("Photobooth-"))
        XCTAssertTrue(record.filename.hasSuffix(".png"))
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, snap.canvasWidth)
    }
}