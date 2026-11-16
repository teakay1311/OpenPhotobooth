import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditDuplicateExportTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    func testReCompleteAfterDowngradeCreatesSecondAutoExport() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let f1 = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Một ảnh lớn" })
        let snap = try env.frames.createSnapshot(frameID: f1.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1,
                                               payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                               width: 200, height: 200, orientation: 1,
                                               codec: "jpeg", colorProfile: nil)
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("audit-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Service fixture. The signed Release UI covers app-scoped bookmark creation.
        let blob = try tmp.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        env.settings.exportFolderBookmarkID = try env.trashRepo.saveBookmark(purpose: "exportFolder", blob: blob, displayPath: tmp.path)
        env.settings.autoExport = true

        // Engine giữ phiên ở .ready (như sau Đổi khung)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: rec.id))
        env.engine.adoptSession(record: detail.session, snapshot: detail.snapshot,
                                committed: detail.currentRevisions(), forReview: false)

        _ = try await env.completeSession(sessionID: rec.id)
        let first = try env.sessions.listExportRecords(sessionID: rec.id).count

        // Bấm "Chụp tiếp" -> enterReview hạ trạng thái
        try? env.engine.startOrContinue()
        let downgraded = try env.sessions.getSession(id: rec.id)?.status

        // Hoàn thành lại -> auto export lần 2
        _ = try await env.completeSession(sessionID: rec.id)
        let second = try env.sessions.listExportRecords(sessionID: rec.id).count
        print("AUDIT-DUP first=\(first) downgraded=\(downgraded?.rawValue ?? "nil") second=\(second)")
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1, "Hoàn thành lại sau khi bị hạ cấp tạo thêm file Auto Export")
    }
}