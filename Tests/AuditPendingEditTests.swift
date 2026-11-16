import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditPendingEditTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    private func makeSession(env: AppEnvironment) async throws -> (String, PhotoRevision) {
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        var first: PhotoRevision?
        let jpeg = try jpegBytes()
        for idx in snap.requiredIndices.sorted() {
            let rev = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                         payloadData: jpeg, requestID: UUID().uuidString,
                                                         width: 240, height: 320, orientation: 1,
                                                         codec: "jpeg", colorProfile: nil)
            if idx == 1 { first = rev }
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)
        return (rec.id, try XCTUnwrap(first))
    }

    // T7: rời màn Xem lại ngay sau khi kéo slider -> chỉnh sửa phải được lưu (spec §2.2)
    func testPendingColorEditSurvivesNavigation() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, rev) = try await makeSession(env: env)

        var vm: ReviewViewModel? = ReviewViewModel(env: env)
        await vm!.load(sessionID: sid)
        vm!.selectPhoto(index: 1)
        vm!.setColorValue("exposure", 80)      // debounce 400ms
        vm = nil                                // view bị huỷ khi rời màn (Cmd+3 / nút quay lại)
        try await Task.sleep(nanoseconds: 900_000_000)

        let saved = try env.sessions.getOverride(photoRevisionID: rev.id)
        print("AUDIT-PENDING-NAV override=", saved.map { "exposure=\($0.color?.exposure ?? -99)" } ?? "nil")
        XCTAssertNotNil(saved, "Chỉnh màu trong 400ms cuối bị mất khi rời màn Xem lại")
        XCTAssertEqual(saved?.color?.exposure ?? 0, 0.8, accuracy: 0.001)
    }

    // T8: bấm Hoàn thành ngay sau khi kéo slider -> phải lưu xong trước khi complete/auto export
    func testCompleteFlushesPendingColorEditFirst() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, rev) = try await makeSession(env: env)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: sid)
        vm.selectPhoto(index: 1)
        vm.setColorValue("saturation", 60)   // debounce 400ms
        await vm.complete()

        let immediately = try env.sessions.getOverride(photoRevisionID: rev.id)
        print("AUDIT-PENDING-COMPLETE immediate=", immediately?.color?.saturation.map { "\($0)" } ?? "nil")
        try await Task.sleep(nanoseconds: 900_000_000)
        let later = try env.sessions.getOverride(photoRevisionID: rev.id)
        print("AUDIT-PENDING-COMPLETE afterDebounce=", later?.color?.saturation.map { "\($0)" } ?? "nil")
        XCTAssertNotNil(immediately,
                        "complete() phải flush chỉnh màu đang chờ TRƯỚC khi hoàn thành/auto export")
    }
}