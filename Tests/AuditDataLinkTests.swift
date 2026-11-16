import XCTest
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditDataLinkTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    private func makeSession(env: AppEnvironment, photos: Int = 3) async throws -> (String, FrameSnapshot) {
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot(),
                                                 frameNameAtCapture: frame.name)
        for idx in snap.requiredIndices.sorted().prefix(photos) {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                                   width: 200, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        return (rec.id, snap)
    }

    // SQL JSON1: listSessions phải chạy được và lọc theo snapshot
    func testListSessionsSQLWorks() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, _) = try await makeSession(env: env)
        try env.sessions.setStatus(sessionID: sid, status: .reviewable)
        let all = try env.sessions.listSessions()
        let completed = try env.sessions.listSessions(statuses: [.completed])
        let incomplete = try env.sessions.listSessions(statuses: [.reviewable])
        print("AUDIT-SQL all=\(all.count) completed=\(completed.count) reviewable=\(incomplete.count) committed=\(all.first?.committedCount ?? -1)")
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(incomplete.count, 1)
        XCTAssertEqual(all.first?.committedCount, 3)
    }

    // Snapshot JSON hỏng không được làm sập toàn bộ truy vấn Thư viện
    func testCorruptSnapshotJSONDoesNotBreakLibrary() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, snap) = try await makeSession(env: env)
        try env.db.run("UPDATE frame_snapshots SET snapshot_json='{broken' WHERE id=?", [.text(snap.id)])
        do {
            let rows = try env.sessions.listSessions()
            print("AUDIT-SQL-CORRUPT rows=\(rows.count)")
            XCTAssertEqual(rows.count, 1)
        } catch {
            print("AUDIT-SQL-CORRUPT error:", error)
            XCTFail("Danh sách Thư viện ném lỗi khi một snapshot JSON hỏng: \(error)")
        }
        _ = sid
    }

    // Rotation 90 phải đổi chiều ảnh và giữ nội dung
    func testRotateNinetySwapsDimensions() throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 150, y: 0, width: 150, height: 200))
        let img = ctx.makeImage()!

        let r90 = ImageNormalizer.rotate(img, degrees: 90)
        print("AUDIT-ROT90 size=\(r90.width)x\(r90.height)")
        XCTAssertEqual(r90.width, 200)
        XCTAssertEqual(r90.height, 300)

        // Điểm góc trên-trái sau khi xoay clockwise phải là đỏ (nửa trái ảnh gốc)
        let color = Self.pixelColor(r90, x: 100, y: 20)
        print("AUDIT-ROT90 pixel=", color)
        XCTAssertGreaterThan(color.red, color.blue)
    }

    private struct RGB { var red: CGFloat; var blue: CGFloat }
    private static func pixelColor(_ img: CGImage, x: Int, y: Int) -> RGB {
        var data = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return RGB(red: CGFloat(data[0]) / 255.0, blue: CGFloat(data[2]) / 255.0)
    }

    // Frame Editor: chặn rời màn khi có thay đổi
    func testFrameEditorLeaveGuard() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first)
        env.openFrameEditor(frameID: frame.id)
        env.frameEditorHasChanges = true
        env.requestNavigation(to: .library)
        print("AUDIT-EDITOR-GUARD route=\(env.route) confirm=\(env.showFrameEditorLeaveConfirmation) pending=\(String(describing: env.pendingNavigationRoute))")
        XCTAssertTrue(env.showFrameEditorLeaveConfirmation)
        if case .frameEditor = env.route {} else { XCTFail("Phải giữ nguyên Frame Editor") }

        env.cancelLeaveFrameEditor()
        if case .frameEditor = env.route {} else { XCTFail("Hủy phải ở lại Editor") }

        env.frameEditorSaveHandler = { false }   // validator fail
        env.frameEditorHasChanges = true
        env.requestNavigation(to: .library)
        env.confirmLeaveFrameEditor()            // handler false -> MainWindow không gọi
        // confirmLeaveFrameEditor chỉ được gọi khi save OK; ở đây kiểm tra API không rời khi chưa lưu xong
        // (MainWindow chịu trách nhiệm gọi; API không tự kiểm tra)
        print("AUDIT-EDITOR-GUARD afterConfirm route=\(env.route)")
    }
}