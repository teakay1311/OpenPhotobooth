import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditCountTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    func testLibraryCountAfterShrinkingFrame() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame4 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Lưới 4 ảnh" })
        let frame3 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap4 = try env.frames.createSnapshot(frameID: frame4.id)
        let rec = try env.sessions.createSession(snapshot: snap4, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot(),
                                                 frameNameAtCapture: frame4.name)
        for idx in snap4.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                                   width: 200, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)
        let snap3 = try env.frames.createSnapshot(frameID: frame3.id)
        try env.sessions.changeFrame(sessionID: rec.id, newSnapshot: snap3)

        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id))
        let card = try XCTUnwrap(try env.sessions.listSessions().first { $0.session.id == rec.id })
        print("AUDIT-COUNT detail=\(detail.committedCount)/\(detail.snapshot.requiredCaptureCount) card=\(card.committedCount)/\(card.session.requiredCaptureCount)")
        XCTAssertEqual(card.committedCount, 3, "Thẻ Thư viện đếm cả ảnh ngoài snapshot sau khi thu nhỏ khung")
    }

    func testCaptureProgressAfterShrinkingFrame() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame4 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Lưới 4 ảnh" })
        let frame3 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap4 = try env.frames.createSnapshot(frameID: frame4.id)
        let rec = try env.sessions.createSession(snapshot: snap4, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        for idx in snap4.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                                   width: 200, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)
        let snap3 = try env.frames.createSnapshot(frameID: frame3.id)
        try env.sessions.changeFrame(sessionID: rec.id, newSnapshot: snap3)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id))
        env.engine.adoptSession(record: detail.session, snapshot: detail.snapshot,
                                committed: detail.currentRevisions(), forReview: true)
        print("AUDIT-COUNT2 committed=\(env.engine.committedShots.count) required=\(env.engine.requiredIndices.count)")
        XCTAssertLessThanOrEqual(env.engine.committedShots.count, env.engine.requiredIndices.count,
                                 "Tiến độ màn Chụp vượt số lượt của khung hiện hành")
    }
}