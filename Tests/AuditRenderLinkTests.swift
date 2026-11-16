import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditRenderLinkTests: XCTestCase {

    private func landscapeJPEG() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 150, y: 0, width: 150, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 95)
    }

    func testRotationAppliedInRenderPipeline() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        env.settings.rotation = 90
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Một ảnh lớn" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1,
                                               payloadData: try landscapeJPEG(), requestID: UUID().uuidString,
                                               width: 300, height: 200, orientation: 1,
                                               codec: "jpeg", colorProfile: nil)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id))
        let model = await env.renderBuilder.buildModel(detail: detail,
                                                       targetWidth: snap.canvasWidth,
                                                       targetHeight: snap.canvasHeight)
        let img = try XCTUnwrap(model.sources[1]?.image)
        print("AUDIT-ROT-PIPELINE source=\(img.width)x\(img.height)")
        XCTAssertEqual(img.width, 200, "Rotation 90 phải đổi chiều rộng/chiều cao ảnh nguồn")
        XCTAssertEqual(img.height, 300)
    }

    func testChangeFrameToBiggerThenContinueStartsCountdown() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        await env.boot()
        let f4 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Lưới 4 ảnh" })
        let f1 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Một ảnh lớn" })
        let snap = try env.frames.createSnapshot(frameID: f1.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1,
                                               payloadData: try landscapeJPEG(), requestID: UUID().uuidString,
                                               width: 300, height: 200, orientation: 1,
                                               codec: "jpeg", colorProfile: nil)
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id))
        env.engine.adoptSession(record: detail.session, snapshot: detail.snapshot,
                                committed: detail.currentRevisions(), forReview: true)
        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)
        await vm.changeFrame(to: f4.id)
        let after = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id))
        print("AUDIT-CHANGE-BIG status=\(after.session.status.rawValue) missing=\(after.missingCount)")
        XCTAssertEqual(after.missingCount, 3)

        env.route = .capture
        let cap = CaptureViewModel(env: env)
        print("AUDIT-CHANGE-BIG button=\(cap.startButtonTitle)")
        await cap.refreshCameraState()
        XCTAssertTrue(cap.isCameraReady)
        await cap.primaryAction()
        print("AUDIT-CHANGE-BIG engine=\(env.engine.state)")
        if case .countdown(_, let idx, _) = env.engine.state {
            XCTAssertTrue([2, 3, 4].contains(idx))
        } else {
            XCTFail("Chụp tiếp sau khi đổi sang khung 4 ô phải bắt đầu đếm ngược")
        }
        env.engine.cancelCountdown()
    }

    func testPackReplacePolicy() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let ids = try env.frames.listFrames().map(\.id)
        let pack = try env.packService.preparePack(name: "p", frameIDs: ids)
        let validation = try FramePackService.validate(data: pack.data)
        let choices = validation.manifest.frames.map {
            FramePackService.ImportChoice(packFrameID: $0.frameId, policy: .replace, selected: true)
        }
        let before = try env.frames.listFrames().count
        let outcomes = try env.packService.applyImport(result: validation, choices: choices, data: pack.data)
        let after = try env.frames.listFrames().count
        let failures = outcomes.values.compactMap { v -> String? in if case .failure(let m) = v { return m } else { return nil } }
        print("AUDIT-PACK-REPLACE before=\(before) after=\(after) failures=\(failures)")
        XCTAssertEqual(before, after, "Replace không được tạo frame mới")
        XCTAssertTrue(failures.isEmpty)
    }
}