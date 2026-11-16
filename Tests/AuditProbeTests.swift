import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditProbeTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    private func makeSession(env: AppEnvironment, frameName: String, photos: Int?) async throws -> (String, FrameSnapshot) {
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == frameName })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot(),
                                                 frameNameAtCapture: frame.name)
        let jpeg = try jpegBytes()
        let indices = photos.map { Array(snap.requiredIndices.sorted().prefix($0)) } ?? snap.requiredIndices.sorted()
        for idx in indices {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                   payloadData: jpeg, requestID: UUID().uuidString,
                                                   width: 200, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
        }
        return (rec.id, snap)
    }

    // Bộ lọc Thư viện phải dựa trên SỐ ẢNH, không chỉ status lưu
    func testLibraryFilterUsesPhotoCount() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (fullID, _) = try await makeSession(env: env, frameName: "Dải 3 ảnh", photos: nil)
        let (partialID, _) = try await makeSession(env: env, frameName: "Dải 3 ảnh", photos: 1)
        // Full nhưng chưa bấm Hoàn thành
        try env.sessions.setStatus(sessionID: fullID, status: .reviewable)
        // Đánh dấu completed nhưng thiếu ảnh (dữ liệu cũ/hỏng)
        try env.sessions.setStatus(sessionID: partialID, status: .completed)

        let all = try env.sessions.listSessions()
        let completed = try env.sessions.listSessions(statuses: [.completed])
        let incomplete = try env.sessions.listSessions(statuses: [.draft, .inProgress, .paused, .reviewable])
        print("AUDIT-LIST all=\(all.count) completed=\(completed.map(\.session.id)) incomplete=\(incomplete.map(\.session.id))")
        print("AUDIT-LIST-STATUS full=\(all.first { $0.session.id == fullID }?.session.status.rawValue ?? "nil") partial=\(all.first { $0.session.id == partialID }?.session.status.rawValue ?? "nil")")
        XCTAssertTrue(completed.isEmpty, "Phiên completed nhưng thiếu ảnh không được coi là Hoàn thành")
        XCTAssertTrue(incomplete.contains { $0.session.id == partialID })
        XCTAssertTrue(incomplete.contains { $0.session.id == fullID })
    }

    func testCompleteSessionRejectsMissingPhotos() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, _) = try await makeSession(env: env, frameName: "Dải 3 ảnh", photos: 1)
        do {
            _ = try await env.completeSession(sessionID: sid)
            XCTFail("completeSession phải từ chối phiên thiếu ảnh")
        } catch {
            print("AUDIT-COMPLETE-MISSING:", (error as? AppError)?.message ?? "\(error)")
        }
    }

    func testSafetySaveRejectsTrashedSession() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, _) = try await makeSession(env: env, frameName: "Dải 3 ảnh", photos: 1)
        try env.trashService.trashSession(sessionID: sid)
        do {
            _ = try await env.safetySave.savePhoto(sessionID: sid, captureIndex: 2,
                                                   payloadData: try jpegBytes(), requestID: UUID().uuidString,
                                                   width: 200, height: 200, orientation: 1,
                                                   codec: "jpeg", colorProfile: nil)
            XCTFail("Ghi ảnh vào phiên đã trash phải bị chặn")
        } catch {
            print("AUDIT-SAVE-TRASHED:", (error as? AppError)?.message ?? "\(error)")
        }
    }

    func testExportRejectsMismatchedSession() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, snap) = try await makeSession(env: env, frameName: "Dải 3 ảnh", photos: nil)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: sid))
        let req = ExportService.ExportRequest(sessionID: "other-session", format: .jpeg, quality: 90,
                                              width: snap.canvasWidth, height: snap.canvasHeight,
                                              filenameBase: "x", destinationFolder: FileManager.default.temporaryDirectory)
        do {
            _ = try await env.exportService.export(detail: detail, request: req)
            XCTFail("Export phải từ chối sessionID không khớp")
        } catch {
            print("AUDIT-EXPORT-MISMATCH:", (error as? AppError)?.message ?? "\(error)")
        }
    }

    // Kiểm tra khoá phiên: đang export thì trash cùng phiên phải bận
    func testTrashBlockedWhileExporting() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, snap) = try await makeSession(env: env, frameName: "Dải 3 ảnh", photos: nil)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: sid))
        let token = try env.coordinator.acquire(key: "session:\(sid)", reason: "audit")
        defer { token.release() }
        do {
            try env.trashService.trashSession(sessionID: sid)
            XCTFail("Trash phải bị chặn khi phiên đang bị khoá")
        } catch {
            print("AUDIT-TRASH-BUSY:", (error as? AppError)?.message ?? "\(error)")
        }
        _ = snap
    }

    // Editor: đổi captureIndex tạo khoảng trống -> chặn lưu có thông báo
    func testEditorGapIndexBlocked() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let vm = FrameEditorViewModel(env: env)
        vm.load(frameID: frame.id)
        var slot = vm.slots[2]
        slot.captureIndex = 7
        vm.updateSlotFromInspector(slot)
        print("AUDIT-EDITOR-GAP canSave=\(vm.canSave) issues=\(vm.validationIssues.map(\.code))")
        XCTAssertFalse(vm.canSave)
    }
}