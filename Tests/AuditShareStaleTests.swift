import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditShareStaleTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    func testShareAfterEditAndExportAfterReload() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
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

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)
        vm.selectPhoto(index: 1)
        vm.setColorValue("contrast", 40)
        try await Task.sleep(nanoseconds: 700_000_000)

        do {
            _ = try await vm.prepareShare()
            print("AUDIT-SHARE after-edit OK")
        } catch {
            print("AUDIT-SHARE after-edit failed:", error)
        }
        let shareOK = (try? await vm.prepareShare()) != nil
        print("AUDIT-SHARE result=\(shareOK)")
        XCTAssertTrue(shareOK, "Chia sẻ phải hoạt động sau khi chỉnh ảnh")

        // Workaround: reload rồi export
        await vm.reload()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audit-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let detail = try XCTUnwrap(vm.detail)
        let req = ExportService.ExportRequest(sessionID: rec.id, format: .jpeg, quality: 90,
                                              width: detail.snapshot.canvasWidth,
                                              height: detail.snapshot.canvasHeight,
                                              filenameBase: "reload", destinationFolder: tmp)
        do {
            _ = try await env.exportService.export(detail: detail, request: req)
            print("AUDIT-EXPORT after-reload OK")
        } catch {
            print("AUDIT-EXPORT after-reload failed:", error)
            XCTFail("Export vẫn hỏng sau khi reload")
        }
    }
}