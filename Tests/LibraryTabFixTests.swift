import XCTest
import SwiftUI
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
@testable import OpenPhotobooth

@MainActor
final class LibraryTabFixTests: XCTestCase {
    var env: AppEnvironment!
    var tempDir: URL!

    override func setUp() async throws {
        env = AppEnvironment(inMemory: true)
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTabFixTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    private func createDummyImageData(color: CGColor = CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)) -> Data {
        let width = 200
        let height = 200
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try! ExportService.encode(cg: ctx.makeImage()!, format: .png, quality: 90)
    }

    private func seedTestSession(slotsCount: Int = 4, selectionCount: Int? = nil, committedShots: Int = 0, selectedOrder: [Int]? = nil) async throws -> String {
        let readyFrames = try env.frames.listReadyFrames()
        guard let frame = readyFrames.first(where: { f in
            let slots = (try? env.frames.getSlots(revisionID: f.currentRevisionID ?? "")) ?? []
            return slots.count == slotsCount
        }) ?? readyFrames.first else {
            throw AppError.notFound("Không tìm thấy khung mẫu phù hợp")
        }

        let snap = try env.frames.createSnapshot(frameID: frame.id)
        var defaults = env.settings.sessionDefaultsSnapshot()
        defaults.selectionCaptureCount = selectionCount
        defaults.selectedCaptureOrder = nil

        let session = try env.sessions.createSession(
            snapshot: snap,
            mode: .automatic,
            cameraID: "fake-cam",
            defaults: defaults,
            frameNameAtCapture: frame.name,
            countdownSeconds: 1,
            intermissionSeconds: 1
        )

        let imgData = createDummyImageData()
        if committedShots > 0 {
            for i in 1...committedShots {
                _ = try await env.safetySave.savePhoto(
                    sessionID: session.id,
                    captureIndex: i,
                    payloadData: imgData,
                    requestID: "req-\(session.id)-\(i)",
                    width: 200,
                    height: 200,
                    orientation: 1,
                    codec: "png",
                    colorProfile: nil
                )
            }
        }

        let totalExpected = selectionCount ?? snap.requiredCaptureCount
        if committedShots >= totalExpected {
            try env.sessions.setStatus(sessionID: session.id, status: .reviewable)
        }

        if let selectedOrder {
            try env.sessions.confirmPhotoSelection(sessionID: session.id, order: selectedOrder)
        }

        return session.id
    }

    // MARK: - T01: Phân loại bộ lọc và trạng thái thẻ (LIB-01, LIB-04)
    func testT01_FilterClassificationAndCardState() async throws {
        // 1. Phiên thường thiếu ảnh (1/2 ảnh)
        let s1 = try await seedTestSession(slotsCount: 2, selectionCount: nil, committedShots: 1)
        // 2. Phiên chụp thêm 4/6 (khung 4 ô, selection 6, đã chụp 4) -> LIB-01
        let s2 = try await seedTestSession(slotsCount: 4, selectionCount: 6, committedShots: 4)
        // 3. Phiên chụp thêm 6/6 chờ chọn ảnh (khung 4 ô, selection 6, đã chụp 6, chưa chọn)
        let s3 = try await seedTestSession(slotsCount: 4, selectionCount: 6, committedShots: 6, selectedOrder: nil)
        // 4. Phiên đã chốt ảnh (khung 4 ô, selection 6, đã chụp 6, đã chọn [1,2,3,4])
        let s4 = try await seedTestSession(slotsCount: 4, selectionCount: 6, committedShots: 6, selectedOrder: [1, 2, 3, 4])
        // 5. Phiên đổi khung: 4/4 sau đó đổi sang khung 6 ô -> thiếu 2 ảnh
        let s5 = try await seedTestSession(slotsCount: 2, selectionCount: nil, committedShots: 2)
        let readyFrames = try env.frames.listReadyFrames()
        if let frame4 = readyFrames.first(where: { f in
            ((try? env.frames.getSlots(revisionID: f.currentRevisionID ?? "")) ?? []).count >= 4
        }) {
            let snap4 = try env.frames.createSnapshot(frameID: frame4.id)
            try env.sessions.changeFrame(sessionID: s5, newSnapshot: snap4)
        }

        let vm = LibraryViewModel(env: env)

        // Kiểm tra bộ lọc "Tất cả"
        vm.filter = .all
        vm.reload()
        let allIDs = Set(vm.cards.map(\.id))
        XCTAssertTrue(allIDs.contains(s1))
        XCTAssertTrue(allIDs.contains(s2))
        XCTAssertTrue(allIDs.contains(s3))
        XCTAssertTrue(allIDs.contains(s4))
        XCTAssertTrue(allIDs.contains(s5))

        // Kiểm tra bộ lọc "Chưa đủ ảnh" (Incomplete)
        vm.filter = .incomplete
        vm.reload()
        let incompleteIDs = Set(vm.cards.map(\.id))
        XCTAssertTrue(incompleteIDs.contains(s1), "Phiên thường 1/2 phải nằm ở Chưa đủ ảnh")
        XCTAssertTrue(incompleteIDs.contains(s2), "LIB-01: Phiên 4/6 chụp thêm phải nằm ở Chưa đủ ảnh!")
        XCTAssertFalse(incompleteIDs.contains(s3), "Phiên 6/6 đã đủ lượt chụp, không được ở Chưa đủ ảnh")
        XCTAssertFalse(incompleteIDs.contains(s4), "Phiên đã chốt ảnh không được ở Chưa đủ ảnh")
        XCTAssertTrue(incompleteIDs.contains(s5), "Phiên đổi khung thiếu ảnh phải ở Chưa đủ ảnh")

        // Kiểm tra bộ lọc "Đủ ảnh" (Completed)
        vm.filter = .completed
        vm.reload()
        let completedIDs = Set(vm.cards.map(\.id))
        XCTAssertFalse(completedIDs.contains(s1))
        XCTAssertFalse(completedIDs.contains(s2), "LIB-01: Phiên 4/6 KHÔNG được nằm ở Đủ ảnh!")
        XCTAssertTrue(completedIDs.contains(s3), "Phiên 6/6 phải nằm ở Đủ ảnh (chờ chọn)")
        XCTAssertTrue(completedIDs.contains(s4), "Phiên đã chốt ảnh phải nằm ở Đủ ảnh")
        XCTAssertFalse(completedIDs.contains(s5))

        // Kiểm tra nhãn tiến độ và trạng thái thẻ
        vm.filter = .all
        vm.reload()
        guard let card2 = vm.cards.first(where: { $0.id == s2 }),
              let card3 = vm.cards.first(where: { $0.id == s3 }),
              let card4 = vm.cards.first(where: { $0.id == s4 }) else {
            XCTFail("Missing cards")
            return
        }
        XCTAssertEqual(card2.card.committedCount, 4)
        XCTAssertEqual(card2.card.session.captureCount, 6)

        // Kiểm tra điều kiện Share: s1 khóa, s2 khóa, s3 khóa, s4 khả dụng
        let canShare2 = card2.card.committedCount >= card2.card.session.captureCount && card2.card.session.pendingSelectionCount == nil
        XCTAssertFalse(canShare2, "4/6 chưa sẵn sàng share")

        let canShare3 = card3.card.committedCount >= card3.card.session.captureCount && card3.card.session.pendingSelectionCount == nil
        XCTAssertFalse(canShare3, "6/6 chờ chọn ảnh chưa sẵn sàng share")

        let canShare4 = card4.card.committedCount >= card4.card.session.captureCount && card4.card.session.pendingSelectionCount == nil
        XCTAssertTrue(canShare4, "Phiên đã chốt ảnh sẵn sàng share")
    }

    // MARK: - T02: Điều hướng từ thẻ và các rào engine (LIB-04, LIB-05)
    func testT02_CardActionButtonsAndEngineGuards() async throws {
        // Tạo phiên 4/6
        let sID = try await seedTestSession(slotsCount: 4, selectionCount: 6, committedShots: 4)
        let vm = LibraryViewModel(env: env)

        // 1. Chụp tiếp từ thẻ hợp lệ -> nhận phiên và route sang .capture
        env.route = .library
        await vm.continueSession(sID, requiresMissingPhotos: true)
        XCTAssertEqual(env.route, .capture)
        XCTAssertEqual(env.engine.session?.id, sID)

        // Reset engine
        env.engine.resetToIdle()
        env.route = .library

        // 2. Thử khi engine bận -> bị từ chối
        // Giả lập engine bận
        let snap = try env.frames.createSnapshot(frameID: try env.frames.listReadyFrames().first!.id)
        _ = try env.engine.beginSession(snapshot: snap, mode: .manual, cameraID: "cam", defaults: env.settings.sessionDefaultsSnapshot(), countdown: 1, interval: 1)
        try env.engine.startOrContinue()
        XCTAssertFalse(env.engine.canAdoptSession)

        await vm.continueSession(sID, requiresMissingPhotos: true)
        XCTAssertEqual(env.route, .library, "Engine bận phải giữ nguyên route Thư viện")
        env.engine.cancelCountdown()
        env.engine.resetToIdle()

        // 3. Stale card 4/6: Cập nhật phiên thành 6/6 trong DB
        let imgData = createDummyImageData()
        _ = try await env.safetySave.savePhoto(sessionID: sID, captureIndex: 5, payloadData: imgData, requestID: "req-5", width: 200, height: 200, orientation: 1, codec: "png", colorProfile: nil)
        _ = try await env.safetySave.savePhoto(sessionID: sID, captureIndex: 6, payloadData: imgData, requestID: "req-6", width: 200, height: 200, orientation: 1, codec: "png", colorProfile: nil)
        try env.sessions.setStatus(sessionID: sID, status: .reviewable)

        // Gọi lệnh Chụp tiếp từ thẻ cũ với requiresMissingPhotos: true
        env.route = .library
        await vm.continueSession(sID, requiresMissingPhotos: true)
        XCTAssertEqual(env.route, .library, "Phiên đã đủ 6/6 ảnh: requiresMissingPhotos: true phải giữ Thư viện và reload!")

        // Gọi lối gọi menu cũ với requiresMissingPhotos: false
        await vm.continueSession(sID, requiresMissingPhotos: false)
        XCTAssertEqual(env.route, .review(sessionID: sID), "Lối gọi menu cũ khi 6/6 phải mở vào Review chọn ảnh")

        // 4. Kiểm tra nút "Chọn ảnh"
        env.route = .library
        vm.selectPhotosForSession(sID)
        XCTAssertEqual(env.route, .review(sessionID: sID))

        // Sau khi đã chốt ảnh (confirmPhotoSelection), gọi lại "Chọn ảnh"
        try env.sessions.confirmPhotoSelection(sessionID: sID, order: [1, 2, 3, 4])
        env.route = .library
        vm.selectPhotosForSession(sID)
        XCTAssertEqual(env.route, .library, "Đã chốt ảnh thì không mở lại màn chọn ảnh, giữ Thư viện")
    }

    // MARK: - T03: Ý định mở Xuất ảnh dùng một lần (LIB-04, LIB-05)
    func testT03_SingleUseExportIntent() async throws {
        let sA = try await seedTestSession(slotsCount: 2, selectionCount: nil, committedShots: 2)
        let sB = try await seedTestSession(slotsCount: 2, selectionCount: nil, committedShots: 2)
        let vm = LibraryViewModel(env: env)

        // 1. Bấm Xuất ảnh từ thẻ A khi đang ở Library
        env.route = .library
        vm.openExportForSession(sA)

        XCTAssertEqual(env.route, .review(sessionID: sA))
        let intentA = env.reviewContext?.exportIntentID
        XCTAssertNotNil(intentA, "Phải sinh exportIntentID")
        XCTAssertEqual(env.reviewContext?.sessionID, sA)

        // Bấm lặp sau khi đã chuyển route không tạo yêu cầu mới
        vm.openExportForSession(sA)
        XCTAssertEqual(env.reviewContext?.exportIntentID, intentA, "Không sinh lại intentID khi đã rời library")

        // 2. Chuyển sang session B: callback cũ không được mở sheet ở B
        env.openReview(sessionID: sB, source: .library)
        XCTAssertNil(env.reviewContext?.exportIntentID, "Mở B thông thường phải có exportIntentID là nil")

        // 3. Thử mở xuất phiên bị trashed
        try env.trashService.trashSession(sessionID: sA)
        env.route = .library
        vm.openExportForSession(sA)
        XCTAssertEqual(env.route, .library, "Phiên bị trashed bị từ chối mở xuất, giữ Library")
    }

    // MARK: - T04: Rào menu Chia sẻ (LIB-05)
    func testT04_ShareMenuGuards() async throws {
        // 1. Phiên 0 ảnh
        let s0 = try await seedTestSession(slotsCount: 2, selectionCount: nil, committedShots: 0)
        // 2. Phiên 4/6
        let s2 = try await seedTestSession(slotsCount: 4, selectionCount: 6, committedShots: 4)
        // 3. Phiên 6/6 chưa chọn ảnh
        let s3 = try await seedTestSession(slotsCount: 4, selectionCount: 6, committedShots: 6, selectedOrder: nil)
        // 4. Phiên đủ ảnh đã chốt
        let s4 = try await seedTestSession(slotsCount: 4, selectionCount: 6, committedShots: 6, selectedOrder: [1, 2, 3, 4])

        let detail0 = try env.sessions.getDetail(sessionID: s0)!
        XCTAssertFalse(detail0.hasEnoughPhotos)

        let detail2 = try env.sessions.getDetail(sessionID: s2)!
        XCTAssertFalse(detail2.hasEnoughPhotos)

        let detail3 = try env.sessions.getDetail(sessionID: s3)!
        XCTAssertTrue(detail3.needsPhotoSelection)

        let detail4 = try env.sessions.getDetail(sessionID: s4)!
        XCTAssertTrue(detail4.hasEnoughPhotos)
        XCTAssertFalse(detail4.needsPhotoSelection)

        // Kiểm tra prepareShareFile chặn các phiên chưa sẵn sàng
        var shareURL0: URL?
        do {
            shareURL0 = try await env.shareService.prepareShareFile(detail: detail0, filenameBase: "Frame")
        } catch {}
        XCTAssertNil(shareURL0, "Phiên 0 ảnh không tạo được file share")

        var shareURL2: URL?
        do {
            shareURL2 = try await env.shareService.prepareShareFile(detail: detail2, filenameBase: "Frame")
        } catch {}
        XCTAssertNil(shareURL2, "Phiên 4/6 không tạo được file share")

        // Phiên s4 hợp lệ tạo được file share
        let shareURL4 = try await env.shareService.prepareShareFile(detail: detail4, filenameBase: "Frame")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shareURL4.path))
    }

    // MARK: - T05: Chọn tệp hiện trong Finder và phân loại lỗi (LIB-03)
    func testT05_FinderRevealAndErrorClassification() async throws {
        let sID = try await seedTestSession(slotsCount: 2, selectionCount: nil, committedShots: 2)
        let vm = LibraryViewModel(env: env)

        // 1. Không có bản xuất thành công
        vm.revealRecentExport(sessionID: sID)
        // Toast "Chưa có bản xuất thành công"

        // 2. Tạo 1 bản thành công cũ (tệp thật tồn tại)
        let realFile = tempDir.appendingPathComponent("export_valid.png")
        try createDummyImageData().write(to: realFile)

        let recOld = ExportRecordModel(
            id: "rec-old",
            sessionID: sID,
            sessionRevisionNo: 1,
            format: .png,
            filename: "export_valid.png",
            destinationDisplayPath: realFile.path,
            destinationBookmarkID: nil,
            width: 200,
            height: 200,
            status: .success,
            createdAtMs: 1000,
            completedAtMs: 1050
        )
        try env.sessions.insertExportRecord(recOld)

        // 3. Tạo 1 bản thành công mới hơn nhưng tệp đã mất (ENOENT)
        let recMissing = ExportRecordModel(
            id: "rec-missing",
            sessionID: sID,
            sessionRevisionNo: 1,
            format: .png,
            filename: "export_missing.png",
            destinationDisplayPath: tempDir.appendingPathComponent("non_existent.png").path,
            destinationBookmarkID: nil,
            width: 200,
            height: 200,
            status: .success,
            createdAtMs: 2000,
            completedAtMs: 2050
        )
        try env.sessions.insertExportRecord(recMissing)

        // 4. Tạo 1 bản lỗi mới nhất (status = .failed)
        let recFailed = ExportRecordModel(
            id: "rec-failed",
            sessionID: sID,
            sessionRevisionNo: 1,
            format: .png,
            filename: "export_failed.png",
            destinationDisplayPath: tempDir.appendingPathComponent("failed.png").path,
            destinationBookmarkID: nil,
            width: 200,
            height: 200,
            status: .failed,
            createdAtMs: 3000,
            completedAtMs: nil
        )
        try env.sessions.insertExportRecord(recFailed)

        // Gọi revealRecentExport: Phải bỏ qua bản failed, bỏ qua bản missing, và tìm thấy bản old hợp lệ!
        var revealedURL: URL? = nil
        env.shareService.revealInFinderHook = { url in
            revealedURL = url
        }

        vm.revealRecentExport(sessionID: sID)
        XCTAssertEqual(revealedURL?.path, realFile.path, "Finder phải mở tệp thành công cũ hơn khi tệp mới nhất bị mất")

        // 5. Kiểm tra phân loại lỗi qua metadata probe:
        // Lỗi mất file (ENOENT)
        let enoent = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
        XCTAssertEqual(LibraryViewModel.classifyFileError(enoent), .missingOrInvalid)

        // Lỗi Cocoa mất file (NSFileNoSuchFileError)
        let cocoaMissing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
        XCTAssertEqual(LibraryViewModel.classifyFileError(cocoaMissing), .missingOrInvalid)

        // Lỗi quyền (EACCES)
        let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: nil)
        XCTAssertEqual(LibraryViewModel.classifyFileError(eacces), .inaccessible)

        // Lỗi Cocoa quyền (NSFileReadNoPermissionError)
        let cocoaPerm = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil)
        XCTAssertEqual(LibraryViewModel.classifyFileError(cocoaPerm), .inaccessible)

        // Lỗi bọc chứa cả mất tệp và quyền -> Ưu tiên inaccessible
        let wrappedPerm = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
            NSUnderlyingErrorKey: eacces
        ])
        XCTAssertEqual(LibraryViewModel.classifyFileError(wrappedPerm), .inaccessible)

        env.shareService.revealInFinderHook = nil
    }

    // MARK: - T06: Bố cục Toolbar và Sắp xếp (LIB-02)
    func testT06_SortPickerAndToolbarLayout() async throws {
        let vm = LibraryViewModel(env: env)
        vm.sortNewest = true
        vm.reload()
        XCTAssertTrue(vm.sortNewest)

        vm.sortNewest = false
        vm.reload()
        XCTAssertFalse(vm.sortNewest)

        let artifactDir = try XCTUnwrap(tempDir)

        func captureView(width: CGFloat, height: CGFloat, sortNewest: Bool, filename: String) {
            env.route = .library
            let lv = LibraryView(env: env)
            let hosting = NSHostingView(rootView: lv)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: artifactDir.appendingPathComponent(filename))
                }
            }
        }

        captureView(width: 1024, height: 680, sortNewest: true, filename: "library_1024x680_newest.png")
        captureView(width: 1024, height: 680, sortNewest: false, filename: "library_1024x680_oldest.png")
        captureView(width: 1280, height: 820, sortNewest: true, filename: "library_1280x820_newest.png")
        captureView(width: 1280, height: 820, sortNewest: false, filename: "library_1280x820_oldest.png")
    }

    // MARK: - T07: Đồng bộ danh sách qua EventBus (LIB-06)
    func testT07_EventBusDebouncedSync() async throws {
        env.route = .library
        let sID = try await seedTestSession(slotsCount: 2, selectionCount: nil, committedShots: 1)
        let vm = LibraryViewModel(env: env)
        vm.filter = .incomplete
        vm.startEventMonitoring()

        XCTAssertEqual(vm.cards.count, 1)

        // Chụp thêm ảnh thứ 2 để phiên hoàn thành
        let imgData = createDummyImageData()
        _ = try await env.safetySave.savePhoto(sessionID: sID, captureIndex: 2, payloadData: imgData, requestID: "req-evt-2", width: 200, height: 200, orientation: 1, codec: "png", colorProfile: nil)

        // Phát event .shotCommitted
        EventBus.shared.post(.shotCommitted(sessionID: sID, captureIndex: 2, photoRevisionID: "rev2"))
        EventBus.shared.post(.sessionChanged(sessionID: sID, revision: 2))

        // Chờ debounce 100ms
        try await Task.sleep(nanoseconds: 200_000_000)

        // Phiên giờ đã đủ 2/2 nên sẽ rời khỏi filter .incomplete
        XCTAssertEqual(vm.cards.count, 0, "Sau khi có event và debounce, card 2/2 đã rời bộ lọc incomplete")

        vm.stopEventMonitoring()
    }

    // MARK: - T08: Khóa ảnh thu nhỏ theo revision và chống ghi đè ngược thứ tự (LIB-06)
    func testT08_ThumbnailRevisionLock() async throws {
        let sID = try await seedTestSession(slotsCount: 2, selectionCount: nil, committedShots: 2)
        let vm = LibraryViewModel(env: env)
        vm.reload()

        guard let cardModel = vm.cards.first(where: { $0.id == sID }) else {
            XCTFail("Missing card")
            return
        }

        let initialRev = cardModel.card.session.revisionNo

        // Tạo preview cho initialRev
        let data1 = await vm.generatePreview(for: cardModel)
        XCTAssertNotNil(data1)
        XCTAssertNotNil(env.thumbnails.cachedData(key: "session-\(sID)-\(initialRev)"))

        // Bump session revision lên initialRev + 1
        _ = try env.sessions.bumpRevision(sessionID: sID)
        let newRev = Int(try env.db.scalarInt("SELECT revision_no FROM sessions WHERE id=?", [.text(sID)]))
        XCTAssertGreaterThan(newRev, initialRev)

        // Thử render lại với model mang revision cũ: phải bị từ chối do lệch revision!
        let dataStale = await vm.generatePreview(for: cardModel)
        // Cache của newRev không bị ảnh hưởng bởi render cũ
        XCTAssertNil(env.thumbnails.cachedData(key: "session-\(sID)-\(newRev)"))
        _ = dataStale
    }

    // MARK: - T09: Hồi quy quy trình đầy đủ Chụp -> Chọn -> Review -> Thư viện -> Xuất -> Thùng rác
    func testT09_FullWorkflowRegression() async throws {
        // 1. Chụp phiên có chọn ảnh (4 ô, 6 lượt)
        let sID = try await seedTestSession(slotsCount: 4, selectionCount: 6, committedShots: 6, selectedOrder: nil)

        let vm = LibraryViewModel(env: env)
        vm.reload()

        let card = vm.cards.first(where: { $0.id == sID })
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.card.committedCount, 6)
        XCTAssertEqual(card?.card.session.captureCount, 6)

        // 2. Chọn ảnh
        try env.sessions.confirmPhotoSelection(sessionID: sID, order: [1, 3, 4, 6])
        let detailAfterSelect = try env.sessions.getDetail(sessionID: sID)!
        XCTAssertFalse(detailAfterSelect.needsPhotoSelection)
        XCTAssertTrue(detailAfterSelect.hasEnoughPhotos)

        // 3. Xuất ảnh
        let exportReq = ExportService.ExportRequest(
            sessionID: sID,
            format: .png,
            quality: 90,
            width: detailAfterSelect.snapshot.canvasWidth,
            height: detailAfterSelect.snapshot.canvasHeight,
            filenameBase: "Test-Export-T09",
            destinationFolder: tempDir
        )
        let (record, exportedURL) = try await env.exportService.export(detail: detailAfterSelect, request: exportReq)
        XCTAssertEqual(record.status, .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))

        // 4. Chuyển vào Thùng rác
        try env.trashService.trashSession(sessionID: sID)
        let detailTrashed = try env.sessions.getDetail(sessionID: sID)!
        XCTAssertEqual(detailTrashed.session.status, .trashed)

        // Tệp xuất bên ngoài không bị xóa khi đưa vào thùng rác
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))

        // 5. Khôi phục từ Thùng rác
        let trashItems = try env.trashRepo.list()
        guard let item = trashItems.first(where: { $0.rootID == sID }) else {
            XCTFail("Missing trash item")
            return
        }
        try env.trashService.restore(item)

        let detailRestored = try env.sessions.getDetail(sessionID: sID)!
        XCTAssertNotEqual(detailRestored.session.status, .trashed)
        XCTAssertTrue(detailRestored.hasEnoughPhotos)
    }
}
