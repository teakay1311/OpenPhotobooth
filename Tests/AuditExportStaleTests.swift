import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditExportStaleTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    private func setup(env: AppEnvironment) async throws -> String {
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        for idx in snap.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                                   width: 240, height: 320, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)
        return rec.id
    }

    private func export(_ env: AppEnvironment, detail: SessionDetail, tag: String) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audit-x-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let req = ExportService.ExportRequest(sessionID: detail.session.id, format: .jpeg, quality: 90,
                                              width: detail.snapshot.canvasWidth,
                                              height: detail.snapshot.canvasHeight,
                                              filenameBase: "A-\(tag)", destinationFolder: tmp)
        let (rec, _) = try await env.exportService.export(detail: detail, request: req)
        print("AUDIT-STALE \(tag) -> \(rec.filename)")
    }

    func testAUD04PreviewUsesUnlockedOutputAspectWithoutChangingReviewAspect() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        await env.boot()
        let id = try await setup(env: env)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        let requested = await env.renderBuilder.renderPreview(detail: detail, maxDimension: 480,
                                                              format: .png, outputSize: (1200, 900))
        let exportPreview = try XCTUnwrap(requested)
        XCTAssertEqual(exportPreview.width, 480)
        XCTAssertEqual(exportPreview.height, 360)
        let original = await env.renderBuilder.renderPreview(detail: detail, maxDimension: 480)
        let reviewPreview = try XCTUnwrap(original)
        XCTAssertEqual(reviewPreview.width, 320)
        XCTAssertEqual(reviewPreview.height, 480)
    }

    func testExportAfterColorEdit() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let sid = try await setup(env: env)
        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: sid)
        try await export(env, detail: try XCTUnwrap(vm.detail), tag: "before-edit")

        vm.selectPhoto(index: 1)
        vm.setColorValue("exposure", 50)
        try await Task.sleep(nanoseconds: 700_000_000)   // chờ debounce lưu override
        let detail = try XCTUnwrap(vm.detail)
        let dbRev = try XCTUnwrap(env.sessions.getSession(id: sid)).revisionNo
        print("AUDIT-STALE revisions detail=\(detail.session.revisionNo) db=\(dbRev)")
        do {
            try await export(env, detail: detail, tag: "after-edit")
        } catch {
            print("AUDIT-STALE export failed:", (error as? AppError)?.message ?? "\(error)")
            XCTFail("Xuất ảnh hỏng sau khi chỉnh màu: \(error)")
        }
    }

    func testExportAfterPlacementEdit() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let sid = try await setup(env: env)
        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: sid)
        vm.selectedSlotID = try XCTUnwrap(vm.detail?.snapshot.slots.first?.id)
        vm.selectedPhotoIndex = 1
        vm.updatePlacement(scale: 1.2, isFinal: true)
        let detail = try XCTUnwrap(vm.detail)
        let dbRev = try XCTUnwrap(env.sessions.getSession(id: sid)).revisionNo
        print("AUDIT-STALE-PLACE revisions detail=\(detail.session.revisionNo) db=\(dbRev)")
        do {
            try await export(env, detail: detail, tag: "after-placement")
        } catch {
            print("AUDIT-STALE-PLACE export failed:", (error as? AppError)?.message ?? "\(error)")
            XCTFail("Xuất ảnh hỏng sau khi chỉnh vị trí: \(error)")
        }
    }
}