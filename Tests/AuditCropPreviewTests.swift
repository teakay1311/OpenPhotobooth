import XCTest
import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditCropPreviewTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 150, y: 0, width: 150, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    private func pngHash(_ img: CGImage?) -> String? {
        guard let img else { return nil }
        let data = CIContextHolder.shared.context.pngRepresentation(of: CIImage(cgImage: img),
                                                                  format: .RGBA8,
                                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testCropChangeUpdatesPreviewAndDetail() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        for idx in snap.requiredIndices.sorted() {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                                   width: 300, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)
        let slotID = try XCTUnwrap(vm.detail?.snapshot.slots.first?.id)
        vm.selectSlot(id: slotID)
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = pngHash(vm.previewImage)

        vm.updatePlacement(scale: 2.0, offsetX: 0.3, isFinal: true)
        try await Task.sleep(nanoseconds: 500_000_000)

        let dbPlacement = try env.sessions.getDetail(sessionID: rec.id)?.placements[slotID]?.scale
        let memPlacement = vm.detail?.placements[slotID]?.scale
        let after = pngHash(vm.previewImage)
        print("AUDIT-CROP dbScale=\(dbPlacement ?? -1) detailScale=\(memPlacement ?? -1) previewChanged=\(before != after) revDetail=\(vm.detail?.session.revisionNo ?? -1) revDB=\(try env.sessions.getSession(id: rec.id)?.revisionNo ?? -1)")

        XCTAssertEqual(dbPlacement ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(memPlacement ?? -1, 2.0, accuracy: 0.001, "detail trong bộ nhớ không cập nhật placement sau khi lưu -> preview dùng dữ liệu cũ")
        XCTAssertNotEqual(before, after, "Preview không đổi sau khi zoom/crop")
    }
}