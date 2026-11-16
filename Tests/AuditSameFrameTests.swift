import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditSameFrameTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    func testReselectingSameFrameResetsCrops() async throws {
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
        let slotID = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id)?.snapshot.slots.first?.id)
        try env.sessions.setPlacement(sessionID: rec.id, snapshotSlotID: slotID,
                                      placement: PhotoPlacement(scale: 2.0, offsetX: 0.1, offsetY: 0.1),
                                      cropMode: .fill, manualOverride: true)
        let before = try env.sessions.getDetail(sessionID: rec.id)?.placements[slotID]?.scale

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)
        await vm.changeFrame(to: frame.id)   // chọn LẠI đúng khung hiện tại
        let after = try env.sessions.getDetail(sessionID: rec.id)?.placements[slotID]?.scale
        print("AUDIT-SAME-FRAME before=\(before ?? -1) after=\(after ?? -1)")
        XCTAssertEqual(after ?? -1, before ?? -2, accuracy: 0.001,
                       "Chọn lại đúng khung hiện tại làm mất chỉnh crop")
    }
}