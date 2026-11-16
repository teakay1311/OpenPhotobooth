import XCTest
import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditColorPreviewTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 95)
    }

    private func hash(_ img: CGImage?) -> String? {
        guard let img else { return nil }
        let data = CIContextHolder.shared.context.pngRepresentation(of: CIImage(cgImage: img),
                                                                  format: .RGBA8,
                                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testColorSliderUpdatesPreview() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Một ảnh lớn" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1,
                                               payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                               width: 300, height: 300, orientation: 1,
                                               codec: "jpeg", colorProfile: nil)
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)
        vm.selectPhoto(index: 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = hash(vm.previewImage)

        vm.setColorValue("exposure", 90)
        try await Task.sleep(nanoseconds: 1_200_000_000)   // > debounce 400ms

        let after = hash(vm.previewImage)
        let override = try env.sessions.getOverride(photoRevisionID: try XCTUnwrap(vm.selectedRevision).id)
        print("AUDIT-COLOR-PREVIEW changed=\(before != after) savedExposure=\(override?.color?.exposure ?? -9) detailExposure=\(vm.detail?.overrides[1]?.color?.exposure ?? -9)")
        XCTAssertNotNil(override, "Chỉnh màu phải được lưu")
        XCTAssertNotEqual(before, after, "Preview không cập nhật sau khi kéo slider màu")
    }
}