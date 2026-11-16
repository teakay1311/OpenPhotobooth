import XCTest
import Foundation
@testable import OpenPhotobooth

@MainActor
final class AuditLockTests: XCTestCase {

    func testCancelCountdownReleasesSessionLock() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                              defaults: env.settings.sessionDefaultsSnapshot(),
                                              countdown: 5, interval: 2)
        try env.engine.startOrContinue()
        print("AUDIT-LOCK during=\(env.coordinator.isSessionBusy(rec.id))")
        env.engine.cancelCountdown()
        XCTAssertEqual(env.engine.state, .ready)
        print("AUDIT-LOCK afterCancel=\(env.coordinator.isSessionBusy(rec.id))")
        XCTAssertFalse(env.coordinator.isSessionBusy(rec.id).busy,
                       "Sau khi Esc hủy đếm ngược, khoá phiên phải được nhả")

        // Hệ quả thực tế: không thể chuyển phiên vào Thùng rác
        do {
            try env.trashService.trashSession(sessionID: rec.id)
            print("AUDIT-LOCK trash=OK")
        } catch {
            print("AUDIT-LOCK trash=BLOCKED:", (error as? AppError)?.message ?? "\(error)")
            XCTFail("Không thể trash phiên sau khi Esc vì khoá chưa nhả")
        }
    }

    func testCancelIntermissionReleasesSessionLock() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.engine.beginSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                              defaults: env.settings.sessionDefaultsSnapshot(),
                                              countdown: 0, interval: 0)
        try env.engine.startOrContinue()
        // countdown 0 -> sẽ vào capturing rất nhanh; thay vào đó huỷ ngay lập tức
        env.engine.cancelCountdown()
        print("AUDIT-LOCK2 state=\(env.engine.state) busy=\(env.coordinator.isSessionBusy(rec.id))")
        XCTAssertFalse(env.coordinator.isSessionBusy(rec.id).busy)
    }
}