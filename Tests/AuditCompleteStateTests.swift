import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditCompleteStateTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    func testCompletedSessionNotRevertedByChupTiep() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        for idx in snap.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                                   width: 200, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        // Engine đang giữ phiên ở .ready (trường hợp sau khi Đổi khung hoặc Esc hủy retake)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id))
        env.engine.adoptSession(record: detail.session, snapshot: detail.snapshot,
                                committed: detail.currentRevisions(), forReview: false)
        XCTAssertEqual(env.engine.state, .ready)

        let done = try await env.completeSession(sessionID: rec.id)
        print("AUDIT-COMPLETE-STATE completed=\(done) engine=\(env.engine.state) status=\(try env.sessions.getSession(id: rec.id)?.status.rawValue ?? "nil")")

        // Người dùng quay lại màn Chụp và bấm nút chính "Chụp tiếp"
        let vm = CaptureViewModel(env: env)
        print("AUDIT-COMPLETE-STATE button=\(vm.startButtonTitle)")
        await vm.primaryAction()
        let after = try env.sessions.getSession(id: rec.id)?.status
        print("AUDIT-COMPLETE-STATE afterPrimary=\(after?.rawValue ?? "nil") engine=\(env.engine.state)")
        XCTAssertEqual(after, .completed, "Phiên đã hoàn thành bị hạ về trạng thái khác khi bấm Chụp tiếp")
    }
}