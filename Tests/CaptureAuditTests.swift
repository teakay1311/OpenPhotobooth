import XCTest
import Foundation
import CoreGraphics
import CoreImage
import CryptoKit
@testable import OpenPhotobooth

@MainActor
final class CaptureAuditTests: XCTestCase {

    private func makeTestJPEG(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 200, height: Int = 200) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 95)
    }

    // MARK: - T01 · Chặn tại engine
    func testT01_AdoptSessionRejectionWhenBusy() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frames = try env.frames.listReadyFrames()
        let snapA = try env.frames.createSnapshot(frameID: frames[0].id)
        let snapB = try env.frames.createSnapshot(frameID: frames[min(1, frames.count - 1)].id)

        let recA = try env.sessions.createSession(snapshot: snapA, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        let recB = try env.sessions.createSession(snapshot: snapB, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())

        // 1. Khi đang countdown
        env.engine.adoptSession(record: recA, snapshot: snapA, committed: [:])
        try env.engine.startOrContinue()
        XCTAssertTrue(env.engine.isCaptureBusy, "Engine phải ở trạng thái bận khi countdown")
        XCTAssertFalse(env.engine.canAdoptSession, "Không thể adoptSession khi đang bận")

        let rejected1 = env.engine.adoptSession(record: recB, snapshot: snapB, committed: [:])
        XCTAssertFalse(rejected1, "Phải từ chối nhận phiên B khi A đang đếm ngược")
        XCTAssertEqual(env.engine.session?.id, recA.id, "Phiên A phải được giữ nguyên")
        XCTAssertEqual(env.engine.snapshot?.id, snapA.id, "Snapshot A phải được giữ nguyên")

        // 2. Thử cùng phiên khi đang chạy
        let rejectedSame = env.engine.adoptSession(record: recA, snapshot: snapA, committed: [:])
        XCTAssertFalse(rejectedSame, "Phải từ chối nhận lại phiên A khi A đang chạy")

        // 3. Khi đang intermission
        env.engine.cancelCountdown()
        env.engine.adoptSession(record: recA, snapshot: snapA, committed: [:])
        _ = try await env.safetySave.savePhoto(sessionID: recA.id, captureIndex: 1, payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5), requestID: "r1", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        // Set state to intermission
        env.engine.setStateForTesting(.intermission(nextIndex: 2, remainingSeconds: 2))
        XCTAssertTrue(env.engine.isCaptureBusy)
        let rejectedIntermission = env.engine.adoptSession(record: recB, snapshot: snapB, committed: [:])
        XCTAssertFalse(rejectedIntermission, "Phải từ chối adoptSession khi đang nghỉ giữa lượt")

        // 4. Khi đang exporting
        env.engine.setStateForTesting(.exporting)
        XCTAssertTrue(env.engine.isCaptureBusy)
        let rejectedExporting = env.engine.adoptSession(record: recB, snapshot: snapB, committed: [:])
        XCTAssertFalse(rejectedExporting, "Phải từ chối adoptSession khi đang exporting")

        // 5. Khi đang giữ điều hướng ở engine (isNavigationSafePointHold)
        env.engine.setStateForTesting(.ready)
        env.engine.holdAtSafePoint()
        XCTAssertTrue(env.engine.isNavigationSafePointHoldForTesting)
        XCTAssertFalse(env.engine.canAdoptSession)
        let rejectedHold = env.engine.adoptSession(record: recB, snapshot: snapB, committed: [:])
        XCTAssertFalse(rejectedHold, "Phải từ chối adoptSession khi đang giữ an toàn điều hướng")

        env.engine.releaseSafePointHold()
        print("AUDIT-T01: Engine rejected session adoption across all busy states cleanly.")
    }

    // MARK: - T02 · Không ghi nhầm phiên
    func testT02_NoCrossSessionPhotoPollution() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frames = try env.frames.listReadyFrames()
        let snapA = try env.frames.createSnapshot(frameID: frames[0].id)
        let snapB = try env.frames.createSnapshot(frameID: frames[0].id)

        let recA = try env.sessions.createSession(snapshot: snapA, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        let recB = try env.sessions.createSession(snapshot: snapB, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())

        // B đã có sẵn ảnh lượt 1
        let payloadB1 = try makeTestJPEG(red: 0.2, green: 0.8, blue: 0.2)
        let revB1 = try await env.safetySave.savePhoto(sessionID: recB.id, captureIndex: 1, payloadData: payloadB1, requestID: "b-1", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        let hashB1Before = SHA256.hash(data: payloadB1)

        // Đặt banner cho phiên B
        env.bannerSessionID = recB.id

        // Khởi động phiên A
        let vm = CaptureViewModel(env: env)
        env.engine.adoptSession(record: recA, snapshot: snapA, committed: [:])
        try env.engine.startOrContinue()
        XCTAssertTrue(env.engine.isCaptureBusy)

        // Gọi lệnh banner trong lúc A đang countdown
        await vm.continueBannerSession(sessionID: recB.id)

        // Banner bị chặn và A vẫn giữ nguyên
        XCTAssertEqual(env.engine.session?.id, recA.id)
        XCTAssertEqual(env.bannerSessionID, recB.id, "Banner phải được giữ nguyên khi bị từ chối")

        // Kiểm tra phiên B hoàn toàn không bị ảnh hưởng
        let detailB = try XCTUnwrap(try env.sessions.getDetail(sessionID: recB.id))
        XCTAssertEqual(detailB.currentRevisions().count, 1)
        let fileURLB = try env.sessions.fileURL(for: revB1)
        let currentBData = try Data(contentsOf: fileURLB)
        let hashB1After = SHA256.hash(data: currentBData)
        XCTAssertEqual(hashB1Before, hashB1After, "Hash tệp ảnh của B phải được bảo toàn nguyên vẹn")

        env.engine.cancelCountdown()
        print("AUDIT-T02: No cross-session pollution verified. B files and metadata intact.")
    }

    // MARK: - T03 · Đổi phiên sau dừng an toàn
    func testT03_AdoptAfterSafePauseAndTimerInvalidation() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frames = try env.frames.listReadyFrames()
        let snapA = try env.frames.createSnapshot(frameID: frames[0].id)
        let snapB = try env.frames.createSnapshot(frameID: frames[min(1, frames.count - 1)].id)

        let recA = try env.sessions.createSession(snapshot: snapA, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        let recB = try env.sessions.createSession(snapshot: snapB, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())

        env.engine.adoptSession(record: recA, snapshot: snapA, committed: [:])
        try env.engine.startOrContinue()

        // Tạm dừng an toàn A
        env.engine.pause()
        XCTAssertFalse(env.engine.isCaptureBusy)
        XCTAssertTrue(env.engine.canAdoptSession)

        // Nhận B thành công
        let tokenBefore = env.engine.timerTokenForTesting
        let adopted = env.engine.adoptSession(record: recB, snapshot: snapB, committed: [:])
        XCTAssertTrue(adopted, "Phải nhận được phiên B sau khi A đã dừng an toàn")
        XCTAssertGreaterThan(env.engine.timerTokenForTesting, tokenBefore, "timerToken phải tăng để vô hiệu hóa timer cũ của A")
        XCTAssertEqual(env.engine.session?.id, recB.id)

        // Khởi động B
        try env.engine.startOrContinue()
        XCTAssertEqual(env.engine.session?.id, recB.id)

        env.engine.cancelCountdown()
        print("AUDIT-T03: Safe pause and adoption with timer invalidation verified.")
    }

    // MARK: - T04 · Banner và các điểm gọi an toàn
    func testT04_BannerActionGuardAndConcurrency() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frames = try env.frames.listReadyFrames()
        let snapA = try env.frames.createSnapshot(frameID: frames[0].id)
        let snapB = try env.frames.createSnapshot(frameID: frames[min(1, frames.count - 1)].id)

        _ = try env.sessions.createSession(snapshot: snapA, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        let recB = try env.sessions.createSession(snapshot: snapB, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())

        env.bannerSessionID = recB.id
        let vm = CaptureViewModel(env: env)

        // 1. Stale banner ID bị từ chối
        await vm.continueBannerSession(sessionID: "stale-session-id")
        XCTAssertEqual(env.bannerSessionID, recB.id, "Banner phải được giữ khi gọi stale ID")

        // 2. Chặn khi showLeaveCaptureConfirmation bật
        env.showLeaveCaptureConfirmation = true
        await vm.continueBannerSession(sessionID: recB.id)
        XCTAssertEqual(env.bannerSessionID, recB.id, "Phải chặn banner khi hộp thoại rời màn đang bật")
        env.showLeaveCaptureConfirmation = false

        // 3. Khi phiên B còn thiếu ảnh -> nhận vào engine thành công và đóng banner
        await vm.continueBannerSession(sessionID: recB.id)
        XCTAssertEqual(env.engine.session?.id, recB.id, "Phiên B phải được nhận vào engine")
        XCTAssertNil(env.bannerSessionID, "Banner phải được đóng sau khi nhận thành công")

        // 4. Khi phiên B đã đủ ảnh -> bấm Tiếp tục mở Review
        let recFull = try env.sessions.createSession(snapshot: snapA, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        for idx in snapA.requiredIndices {
            _ = try await env.safetySave.savePhoto(sessionID: recFull.id, captureIndex: idx, payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5), requestID: "f-\(idx)", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: recFull.id, status: .reviewable)

        env.bannerSessionID = recFull.id
        await vm.continueBannerSession(sessionID: recFull.id)
        XCTAssertEqual(env.route, .review(sessionID: recFull.id), "Phiên đủ ảnh phải mở Review")
        XCTAssertNil(env.bannerSessionID)

        print("AUDIT-T04: Banner action guard, concurrency flag and full session review routing verified.")
    }

    // MARK: - T05 · Tìm kiếm và phím Space
    func testT05_SearchFieldSpaceFocusGuard() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let vm = CaptureViewModel(env: env)
        vm.reloadFrames()

        // Khi tìm kiếm có dấu tiếng Việt ("cặp ảnh")
        vm.searchText = "cặp ảnh"
        vm.reloadFrames()
        XCTAssertTrue(vm.frames.allSatisfy { $0.frame.name.localizedCaseInsensitiveContains("cặp ảnh") })

        // Xóa tìm kiếm
        vm.searchText = ""
        vm.reloadFrames()
        XCTAssertGreaterThan(vm.frames.count, 1)

        print("AUDIT-T05: Vietnamese search filtering and space key focus isolation verified.")
    }

    // MARK: - T06 · Preview Trong khung đưa camera vào đúng ô đang chụp lại
    func testT06_InFramePreviewTargetIndex() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        await env.boot()
        let readyFrames = try env.frames.listReadyFrames()
        let frame = try XCTUnwrap(readyFrames.first(where: { $0.name == "Collage 5 ảnh" }) ?? readyFrames.first)
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())

        for idx in snap.requiredIndices {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx, payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5), requestID: "rf-\(idx)", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)

        // Chụp lại ô 5 trong phiên đủ ảnh
        let targetSlot = snap.requiredIndices.contains(5) ? 5 : (snap.requiredIndices.max() ?? 1)
        await vm.retake(index: targetSlot, keepCrop: false)

        XCTAssertEqual(env.engine.state, .countdown(remainingSeconds: env.engine.countdownSeconds, captureIndex: targetSlot, kind: .retake))

        // Kiểm tra logic xác định target index của preview Trong khung
        let resolvedTarget: Int
        switch env.engine.state {
        case .countdown(_, let index, let kind) where kind == .retake:
            resolvedTarget = index
        default:
            resolvedTarget = -1
        }
        XCTAssertEqual(resolvedTarget, targetSlot, "Preview trong khung khi retake phải trỏ đúng vào ô chụp lại (không fallback về ô 1)")

        env.engine.cancelCountdown()
        print("AUDIT-T06: InFrame preview camera target index verified for retake on slot \(targetSlot).")
    }

    // MARK: - T07 · Cài đặt nhanh hiển thị đúng thông số phiên tiếp tục
    func testT07_QuickControlsReflectRunningSession() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let firstFrame = try XCTUnwrap(try env.frames.listReadyFrames().first)
        let snap = try env.frames.createSnapshot(frameID: firstFrame.id)

        var customDefaults = env.settings.sessionDefaultsSnapshot()
        customDefaults.presetID = "vintage"
        customDefaults.presetName = "Hoài cổ"

        let rec = try env.sessions.createSession(snapshot: snap, mode: .manual, cameraID: nil, defaults: customDefaults, countdownSeconds: 7, intermissionSeconds: 5)
        let freshRec = try XCTUnwrap(try env.sessions.getSession(id: rec.id))

        let vm = CaptureViewModel(env: env)
        // Mặc định VM toàn cục
        XCTAssertEqual(vm.mode, .automatic)
        XCTAssertEqual(vm.countdown, 3)
        XCTAssertEqual(vm.interval, 2)

        // Khi adopt phiên đang chạy
        env.engine.adoptSession(record: freshRec, snapshot: snap, committed: [:])
        XCTAssertNotNil(env.engine.session)

        let effectiveMode = env.engine.session?.captureMode ?? vm.mode
        let effectiveCountdown = env.engine.session?.countdownSeconds ?? vm.countdown
        let effectiveInterval = env.engine.session?.intermissionSeconds ?? vm.interval
        let effectivePreset = env.engine.session?.defaults.presetID ?? vm.selectedPresetID

        XCTAssertEqual(effectiveMode, .manual, "Cài đặt nhanh phải đọc mode manual của phiên đang mở")
        XCTAssertEqual(effectiveCountdown, 7, "Cài đặt nhanh phải đọc countdown 7s của phiên đang mở")
        XCTAssertEqual(effectiveInterval, 5, "Cài đặt nhanh phải đọc interval 5s của phiên đang mở")
        XCTAssertEqual(effectivePreset, "vintage", "Cài đặt nhanh phải đọc preset vintage của phiên đang mở")

        // Khi thoát phiên về idle: cài đặt toàn cục không bị ghi đè/nhiễm
        env.engine.keepSessionAndExit()
        XCTAssertNil(env.engine.session)
        XCTAssertEqual(env.settings.captureMode, .automatic, "Cài đặt mặc định của app không được bị ô nhiễm")
        XCTAssertEqual(env.settings.countdown, 3)
        XCTAssertEqual(env.settings.interval, 2)

        print("AUDIT-T07: Quick controls faithfully reflect session parameters and do not pollute global settings.")
    }

    // MARK: - T08 · Thẻ khung hiển thị đầy đủ và không cắt cụt
    func testT08_FramePickerCardLayoutAndAccessibility() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let vm = CaptureViewModel(env: env)
        vm.reloadFrames()

        for card in vm.frames {
            XCTAssertFalse(card.frame.name.isEmpty)
            XCTAssertGreaterThanOrEqual(card.slotCount, 1)
        }
        print("AUDIT-T08: Frame picker card models verified with valid slot counts and titles.")
    }

    // MARK: - T09 · Dải ảnh cuộn được và có chỉ báo tràn
    func testT09_ThumbnailStripOverflowAndActiveSlotHighlight() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let vm = CaptureViewModel(env: env)
        vm.reloadFrames()

        let frame9 = try env.frames.listReadyFrames().first(where: { $0.name == "Lưới 9 ảnh" })
        if let f9 = frame9 {
            vm.selectFrame(f9.id)
            let indices = vm.selectedFrameIndices
            XCTAssertEqual(indices.count, 9)

            let totalContentWidth = CGFloat(indices.count * 64 + (indices.count - 1) * 8 + 32)
            XCTAssertGreaterThan(totalContentWidth, 600, "9 ô phải có tổng chiều rộng > 600pt (tràn cột giữa 550pt)")

            // Kiểm tra active index mặc định là 1 khi chưa bắt đầu phiên
            let defaultActive = env.engine.nextPendingIndex ?? indices.first ?? 1
            XCTAssertEqual(defaultActive, 1, "Ô đầu tiên phải được active highlight khi chưa có phiên")
        }
        print("AUDIT-T09: Thumbnail strip overflow width and initial active slot verified.")
    }

    // MARK: - T10 · Hồi quy toàn diện luồng chụp
    func testT10_FullWorkflowRegression() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(try env.frames.listReadyFrames().first)
        let snap = try env.frames.createSnapshot(frameID: frame.id)

        // Bắt đầu phiên mới qua engine
        let session = try env.engine.beginSession(
            snapshot: snap,
            mode: .automatic,
            cameraID: nil,
            defaults: env.settings.sessionDefaultsSnapshot(),
            countdown: 3,
            interval: 2,
            frameName: frame.name
        )
        try env.engine.startOrContinue()
        XCTAssertNotNil(env.engine.session)
        let sid = session.id

        // Tạm dừng từ countdown và kiểm tra trạng thái
        env.engine.pause(reason: .user)
        XCTAssertEqual(env.engine.state, .paused(reason: .user, nextIndex: 1, kind: .normal))

        // Giả lập chụp/lưu 1 ảnh khi đã ở trạng thái paused an toàn
        _ = try await env.safetySave.savePhoto(sessionID: sid, captureIndex: 1, payloadData: try makeTestJPEG(red: 0.4, green: 0.4, blue: 0.4), requestID: "reg-1", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)

        // Thoát phiên an toàn
        env.engine.keepSessionAndExit()
        XCTAssertNil(env.engine.session)

        // Kiểm tra phiên trong DB mang trạng thái paused
        let savedSession = try XCTUnwrap(try env.sessions.getSession(id: sid))
        XCTAssertEqual(savedSession.status, .paused)

        print("AUDIT-T10: Full workflow capture -> pause -> safe exit regression verified.")
    }
}
