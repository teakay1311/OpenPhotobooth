import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditStateRegressionTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    // Luồng UI thật: Xem lại -> Đổi khung -> Hoàn thành -> về Chụp -> Chụp tiếp
    func testChangeFrameThenCompleteThenContinueDowngrades() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let f3 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let f1 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Một ảnh lớn" })
        let snap = try env.frames.createSnapshot(frameID: f3.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        for idx in snap.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                                   width: 200, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        env.engine.adoptSession(record: try XCTUnwrap(env.sessions.getSession(id: rec.id)),
                                snapshot: snap, committed: try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id)).currentRevisions(),
                                forReview: true)
        env.openReview(sessionID: rec.id, source: .capture)
        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)

        await vm.changeFrame(to: f1.id)          // đổi sang khung 1 ô (đủ ảnh)
        print("AUDIT-REGRESS afterChangeFrame status=\(try env.sessions.getSession(id: rec.id)?.status.rawValue ?? "nil") engine=\(env.engine.state)")
        await vm.complete()
        print("AUDIT-REGRESS afterComplete status=\(try env.sessions.getSession(id: rec.id)?.status.rawValue ?? "nil") engine=\(env.engine.state)")

        env.route = .capture
        let captureVM = CaptureViewModel(env: env)
        print("AUDIT-REGRESS captureButton=\(captureVM.startButtonTitle)")
        await captureVM.primaryAction()
        let final = try env.sessions.getSession(id: rec.id)?.status
        print("AUDIT-REGRESS afterPrimary=\(final?.rawValue ?? "nil")")
        XCTAssertEqual(final, .completed, "Phiên completed bị hạ cấp khi bấm Chụp tiếp sau khi đổi khung")
    }
}