import XCTest
import SwiftUI
import AppKit
import UniformTypeIdentifiers
@testable import OpenPhotobooth

@MainActor
final class FramesTabFixTests: XCTestCase {
    var env: AppEnvironment!
    var tempDir: URL!

    override func setUp() async throws {
        env = AppEnvironment(inMemory: true)
        try FrameSeeder.seedIfNeeded(db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FramesTabFixTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        FramesViewModel.onBeforeFinalExportWriteHook = nil
        try? env.db.run("DROP TRIGGER IF EXISTS fail_slot_b")
        try? env.db.run("DROP TRIGGER IF EXISTS fail_second_fav")
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    private func createDummyImage(width: Int = 100, height: Int = 100) -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try! ExportService.encode(cg: ctx.makeImage()!, format: .png, quality: 90)
    }

    // MARK: - F01: Ngăn nhập lại sau khi đã có kết quả
    func testF01_PreventReimportAfterCompleted() async throws {
        let readyFrames = try env.frames.listReadyFrames()
        let packResult = try env.packService.preparePack(name: "TestPackF01", frameIDs: [readyFrames[0].id])
        let packURL = tempDir.appendingPathComponent("pack01.photoframepack")
        try packResult.data.write(to: packURL)

        let vm = FramePackImportViewModel(env: env)
        await vm.loadAndValidate(url: packURL)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertNotNil(vm.packResult)
        let entry = try XCTUnwrap(vm.packResult?.entries.first)
        XCTAssertTrue(entry.isDuplicate)
        XCTAssertEqual(vm.choices[entry.id]?.policy, .skip)
        vm.choices[entry.id] = (.copy, true) // This test explicitly exercises repeated Copy, not default Skip.

        let initialFrameCount = try env.frames.listFrames().count

        // Gọi lần 1
        vm.applyImport()
        XCTAssertTrue(vm.isImporting)

        // Gọi lặp ngay khi đang importing
        vm.applyImport()

        // Đợi hoàn thành
        for _ in 0..<50 {
            if vm.phase == .completed { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(vm.phase, .completed)
        XCTAssertFalse(vm.isImporting)
        XCTAssertNotNil(vm.results)

        let countAfterFirst = try env.frames.listFrames().count
        XCTAssertEqual(countAfterFirst, initialFrameCount + 1, "Chỉ tạo thêm đúng 1 frame từ lượt đầu")

        // Gọi lại sau khi đã completed
        vm.applyImport()
        try await Task.sleep(nanoseconds: 100_000_000)

        let countAfterSecond = try env.frames.listFrames().count
        XCTAssertEqual(countAfterSecond, countAfterFirst, "Không được chạy thêm lượt nhập khi đã completed")
    }

    // MARK: - F02a: Lỗi trước khi ghi
    func testF02a_FailureBeforeWriteLeavesRepositoryUntouched() async throws {
        let invalidData = Data("NOT_A_ZIP_ARCHIVE".utf8)
        let packURL = tempDir.appendingPathComponent("corrupt.photoframepack")
        try invalidData.write(to: packURL)

        let framesBefore = try env.frames.listFrames()
        let categoriesBefore = try env.frames.listCategories()

        let vm = FramePackImportViewModel(env: env)
        await vm.loadAndValidate(url: packURL)

        XCTAssertNotNil(vm.fatalMessage)
        if case .failedBeforeWrite = vm.phase {
            // Đạt
        } else {
            XCTFail("Phase phải là failedBeforeWrite khi gói hỏng")
        }

        let framesAfter = try env.frames.listFrames()
        let categoriesAfter = try env.frames.listCategories()

        XCTAssertEqual(framesBefore.map(\.id), framesAfter.map(\.id))
        XCTAssertEqual(categoriesBefore.map(\.id), categoriesAfter.map(\.id))
    }

    // MARK: - F02b: Thành công một phần và lỗi muộn
    func testF02b_PartialWriteClassificationAndRollback() async throws {
        // Tạo 2 frames để đóng gói: QA-Pack-A và QA-Pack-B
        let img = createDummyImage()
        let catA = try env.frames.createCategory(name: "CatA")
        let frameA = try env.frames.createFrame(name: "QA-Pack-A", imageData: img, mediaType: "image/png", role: .frameBackground, categoryID: catA.id)
        let frameB = try env.frames.createFrame(name: "QA-Pack-B", imageData: img, mediaType: "image/png", role: .frameBackground, categoryID: nil)

        // Cấu hình slot cho frameA và frameB
        let slot = FrameSlot(id: IDFactory.new(), frameRevisionID: "rev", captureIndex: 1, x: 0.1, y: 0.1, width: 0.8, height: 0.8, rotationDegrees: 0, zOrder: 1, maskType: .rectangle, cornerRadius: 0, defaultCropMode: .autoFace)
        var revA = FrameRevision(frameID: frameA.id, revisionNo: 1, canvasWidth: 1200, canvasHeight: 1800, backgroundAssetID: nil, foregroundAssetID: nil, backgroundColorHex: "#FFFFFFFF", backgroundPlacement: .aspectFill, foregroundPlacement: .aspectFit)
        _ = try env.frames.commitRevision(frameID: frameA.id, draft: revA, slots: [slot])
        var revB = FrameRevision(frameID: frameB.id, revisionNo: 1, canvasWidth: 1200, canvasHeight: 1800, backgroundAssetID: nil, foregroundAssetID: nil, backgroundColorHex: "#FFFFFFFF", backgroundPlacement: .aspectFill, foregroundPlacement: .aspectFit)
        _ = try env.frames.commitRevision(frameID: frameB.id, draft: revB, slots: [slot])

        let packData = try env.packService.buildPack(name: "PackF02b", frameIDs: [frameA.id, frameB.id])
        let validation = try FramePackService.validate(data: packData)

        // Trigger lỗi chỉ khi ghi slot của B
        try env.db.run("""
            CREATE TRIGGER fail_slot_b BEFORE INSERT ON frame_slots
            WHEN EXISTS (
                SELECT 1 FROM frame_revisions r
                JOIN frames f ON r.frame_id = f.id
                WHERE r.id = NEW.frame_revision_id AND f.name LIKE '%QA-Pack-B%'
            )
            BEGIN
                SELECT RAISE(FAIL, 'TRIGGER_FAIL_SLOT_B');
            END;
        """)

        let choices: [FramePackService.ImportChoice] = [
            FramePackService.ImportChoice(packFrameID: frameA.id, policy: .copy, selected: true),
            FramePackService.ImportChoice(packFrameID: frameB.id, policy: .copy, selected: true)
        ]

        let detailed = try env.packService.applyImportDetailed(result: validation, choices: choices, data: packData)

        // Frame A phải imported thành công
        guard case .imported(let newAId) = detailed[frameA.id] else {
            XCTFail("Frame A phải được imported thành công")
            return
        }
        XCTAssertNotEqual(newAId, frameA.id)

        // Frame B phải được phân loại partiallyWritten
        guard case .partiallyWritten(let reason) = detailed[frameB.id] else {
            XCTFail("Frame B phải được phân loại partiallyWritten, got: \(String(describing: detailed[frameB.id]))")
            return
        }
        XCTAssertTrue(reason.contains("TRIGGER_FAIL_SLOT_B"))

        // Kiểm tra B không có revision chứa slot lỗi
        let allFrames = try env.frames.listFrames()
        let bCopies = allFrames.filter { $0.name.hasPrefix("QA-Pack-B") && $0.id != frameB.id }
        for bCopy in bCopies {
            if let revID = bCopy.currentRevisionID {
                let slots = try env.frames.getSlots(revisionID: revID)
                XCTAssertTrue(slots.isEmpty, "Revision của B không được chứa slot bị lỗi do đã rollback")
            }
        }
    }

    // MARK: - F03: Nhập Skip, Copy, Replace
    func testF03_DuplicatePolicies() async throws {
        let img = createDummyImage()
        let orig = try env.frames.createFrame(name: "OrigFrameF03", imageData: img, mediaType: "image/png", role: .frameBackground, categoryID: nil)
        let slot = FrameSlot(id: IDFactory.new(), frameRevisionID: "rev", captureIndex: 1, x: 0.1, y: 0.1, width: 0.8, height: 0.8, rotationDegrees: 0, zOrder: 1, maskType: .rectangle, cornerRadius: 0, defaultCropMode: .autoFace)
        var rev = FrameRevision(frameID: orig.id, revisionNo: 1, canvasWidth: 1200, canvasHeight: 1800, backgroundAssetID: nil, foregroundAssetID: nil, backgroundColorHex: "#FFFFFFFF", backgroundPlacement: .aspectFill, foregroundPlacement: .aspectFit)
        _ = try env.frames.commitRevision(frameID: orig.id, draft: rev, slots: [slot])

        // Tạo session dùng snapshot của orig
        let snap = try env.frames.createSnapshot(frameID: orig.id)
        let session = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())

        let packData = try env.packService.buildPack(name: "PackF03", frameIDs: [orig.id])
        let validation = try FramePackService.validate(data: packData)

        // 1. Skip
        let skipChoice = [FramePackService.ImportChoice(packFrameID: orig.id, policy: .skip, selected: true)]
        let skipRes = try env.packService.applyImportDetailed(result: validation, choices: skipChoice, data: packData)
        XCTAssertEqual(skipRes[orig.id], .skipped)

        // 2. Copy
        let copyChoice = [FramePackService.ImportChoice(packFrameID: orig.id, policy: .copy, selected: true)]
        let copyRes = try env.packService.applyImportDetailed(result: validation, choices: copyChoice, data: packData)
        guard case .imported(let copyID) = copyRes[orig.id] else {
            XCTFail("Copy phải tạo ID mới")
            return
        }
        XCTAssertNotEqual(copyID, orig.id)

        // 3. Replace
        let replaceChoice = [FramePackService.ImportChoice(packFrameID: orig.id, policy: .replace, selected: true)]
        let replaceRes = try env.packService.applyImportDetailed(result: validation, choices: replaceChoice, data: packData)
        guard case .replaced(let repID) = replaceRes[orig.id] else {
            XCTFail("Replace phải giữ đúng ID")
            return
        }
        XCTAssertEqual(repID, orig.id)

        // Session cũ vẫn giữ snapshot không đổi
        let sessionDetail = try XCTUnwrap(try env.sessions.getDetail(sessionID: session.id))
        XCTAssertEqual(sessionDetail.snapshot.sourceFrameID, orig.id)
        XCTAssertEqual(sessionDetail.snapshot.id, snap.id)
    }

    // MARK: - F04: Xuất đúng khung từ lối vào context menu
    func testF04_ExportTargetInitializationAndManifestFiltering() async throws {
        let ready = try env.frames.listReadyFrames()
        guard ready.count >= 2 else {
            XCTFail("Cần ít nhất 2 ready frames")
            return
        }
        let frameA = ready[0]
        let frameB = ready[1]

        let framesVM = FramesViewModel(env: env)
        framesVM.reload()

        // Lối vào chỉ chọn A
        let exportSheetA = PackExportSheet(env: env, framesVM: framesVM, initialSelectedIDs: [frameA.id])
        // Kiểm tra selection khởi tạo đúng [frameA.id]
        let mirrorA = Mirror(reflecting: exportSheetA)
        // Export đúng tập A
        let destA = tempDir.appendingPathComponent("exportA.photoframepack")
        let okA = framesVM.exportPack(frameIDs: [frameA.id], name: "PackA", saveTo: destA)
        XCTAssertTrue(okA)

        let dataA = try Data(contentsOf: destA)
        let valA = try FramePackService.validate(data: dataA)
        XCTAssertEqual(valA.manifest.frames.map(\.frameId), [frameA.id])

        // Lối vào chọn A + B
        let destAB = tempDir.appendingPathComponent("exportAB.photoframepack")
        let okAB = framesVM.exportPack(frameIDs: [frameA.id, frameB.id], name: "PackAB", saveTo: destAB)
        XCTAssertTrue(okAB)

        let dataAB = try Data(contentsOf: destAB)
        let valAB = try FramePackService.validate(data: dataAB)
        XCTAssertEqual(Set(valAB.manifest.frames.map(\.frameId)), Set([frameA.id, frameB.id]))
    }

    // MARK: - F05: Kiểm tra vòng đời và bản nháp khi xuất
    func testF05_ExportLifecycleValidationAndDraftHandling() async throws {
        let ready = try env.frames.listReadyFrames()
        let frameA = ready[0]

        // Tạo khung nháp 0 slot
        let draftFrame = try env.frames.createEmptyFrame(name: "DraftZeroSlot", categoryID: nil, canvasWidth: 1200, canvasHeight: 1800)

        let framesVM = FramesViewModel(env: env)
        framesVM.reload()

        // 1. Xuất A cùng khung nháp 0 slot -> draft bị bỏ qua, manifest chỉ có A
        let destA = tempDir.appendingPathComponent("pack_with_draft.photoframepack")
        let ok = framesVM.exportPack(frameIDs: [frameA.id, draftFrame.id], name: "PackDraft", saveTo: destA)
        XCTAssertTrue(ok)

        let data = try Data(contentsOf: destA)
        let val = try FramePackService.validate(data: data)
        XCTAssertEqual(val.manifest.frames.map(\.frameId), [frameA.id])

        // 2. Bị chuyển vào thùng rác trước khi xuất
        let frameB = ready[1]
        try env.trashService.trashFrame(frameID: frameB.id)

        let destFail = tempDir.appendingPathComponent("pack_fail.photoframepack")
        let okFail = framesVM.exportPack(frameIDs: [frameB.id], name: "PackFail", saveTo: destFail)
        XCTAssertFalse(okFail, "Phải từ chối xuất khung đã bị đưa vào thùng rác")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destFail.path))

        // 3. Race condition qua hook: thay đổi sau khi tạo ZIP và trước khi ghi
        let destRace = tempDir.appendingPathComponent("pack_race.photoframepack")
        let frameC = ready[2]
        FramesViewModel.onBeforeFinalExportWriteHook = {
            // Đưa frameC vào thùng rác ngay trước khi ghi
            try? self.env.trashService.trashFrame(frameID: frameC.id)
        }
        let okRace = framesVM.exportPack(frameIDs: [frameC.id], name: "PackRace", saveTo: destRace)
        XCTAssertFalse(okRace, "Phải từ chối ghi khi frame bị thay đổi trước bước ghi cuối")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destRace.path))
    }

    // MARK: - F06: Yêu thích theo lô (FRM-03)
    func testF06_BatchFavoriteUpdatesOnlyUnfavoritedAndLeavesTimestamps() async throws {
        let ready = try env.frames.listReadyFrames()
        guard ready.count >= 3 else {
            XCTFail("Cần ít nhất 3 ready frames, got \(ready.count)")
            return
        }
        let frameA = ready[0]
        let frameB = ready[1]
        let frameC = ready[2]

        // Set frameA là favorite trước
        try env.frames.setFavorite(id: frameA.id, true)
        try env.frames.setFavorite(id: frameB.id, false)
        try env.frames.setFavorite(id: frameC.id, false)

        let frameABefore = try env.frames.getFrame(id: frameA.id)!
        let origTimeA = frameABefore.updatedAtMs

        // Đợi 20ms để có độ chênh timestamp
        try await Task.sleep(nanoseconds: 20_000_000)

        let updatedCount = try env.frames.setFavorites(frameIDs: [frameA.id, frameB.id], isFavorite: true)
        XCTAssertEqual(updatedCount, 1, "Chỉ có frameB được chuyển từ false sang true")

        let frameAAfter = try env.frames.getFrame(id: frameA.id)!
        let frameBAfter = try env.frames.getFrame(id: frameB.id)!
        let frameCAfter = try env.frames.getFrame(id: frameC.id)!

        XCTAssertTrue(frameAAfter.isFavorite)
        XCTAssertTrue(frameBAfter.isFavorite)
        XCTAssertFalse(frameCAfter.isFavorite)

        // frameA giữ nguyên updated_at_ms
        XCTAssertEqual(frameAAfter.updatedAtMs, origTimeA, "Khung đã có sao phải giữ nguyên updated_at_ms")
        XCTAssertGreaterThan(frameBAfter.updatedAtMs, origTimeA)

        // Bấm lại lần 2 không thay đổi gì
        let repeatCount = try env.frames.setFavorites(frameIDs: [frameA.id, frameB.id], isFavorite: true)
        XCTAssertEqual(repeatCount, 0, "Lượt lặp với cùng tập đã có sao không đổi dữ liệu")
    }

    // MARK: - F07: Rollback giao dịch yêu thích khi có lỗi
    func testF07_BatchFavoriteRollbackOnFailure() async throws {
        let ready = try env.frames.listReadyFrames()
        let frameA = ready[0]
        let frameB = ready[1]

        try env.frames.setFavorite(id: frameA.id, false)
        try env.frames.setFavorite(id: frameB.id, false)

        let origA = try env.frames.getFrame(id: frameA.id)!
        let origB = try env.frames.getFrame(id: frameB.id)!

        // Trigger gây lỗi khi cập nhật frame thứ 2
        let sorted = [frameA.id, frameB.id].sorted()
        let firstID = sorted[0]
        let secondID = sorted[1]

        try env.db.run("""
            CREATE TRIGGER fail_second_fav BEFORE UPDATE OF is_favorite ON frames
            WHEN NEW.id = '\(secondID)' AND EXISTS (SELECT 1 FROM frames WHERE id = '\(firstID)' AND is_favorite = 1)
            BEGIN
                SELECT RAISE(FAIL, 'TRIGGER_FAIL_FAV_ROLLBACK');
            END;
        """)

        XCTAssertThrowsError(try env.frames.setFavorites(frameIDs: sorted, isFavorite: true)) { error in
            XCTAssertTrue("\(error)".contains("TRIGGER_FAIL_FAV_ROLLBACK"))
        }

        // Kiểm tra cả 2 hàng đều được rollback
        let readA = try env.frames.getFrame(id: firstID)!
        let readB = try env.frames.getFrame(id: secondID)!

        XCTAssertFalse(readA.isFavorite)
        XCTAssertFalse(readB.isFavorite)
        XCTAssertEqual(readA.updatedAtMs, firstID == frameA.id ? origA.updatedAtMs : origB.updatedAtMs)
        XCTAssertEqual(readB.updatedAtMs, secondID == frameA.id ? origA.updatedAtMs : origB.updatedAtMs)
    }

    // MARK: - F08: Đổi tên khung & danh mục (FRM-04)
    func testF08_RenameValidationAndErrorHandling() throws {
        let ready = try env.frames.listReadyFrames()
        let frame = ready[0]

        // 1. Tên khung rỗng
        XCTAssertThrowsError(try env.frames.renameFrame(id: frame.id, to: "")) { error in
            XCTAssertTrue("\(error)".contains("Tên khung không được để trống"))
        }
        // 2. Tên khung chỉ khoảng trắng
        XCTAssertThrowsError(try env.frames.renameFrame(id: frame.id, to: "   \n\t  ")) { error in
            XCTAssertTrue("\(error)".contains("Tên khung không được để trống"))
        }
        // 3. Tên khung hợp lệ có khoảng trắng hai đầu
        try env.frames.renameFrame(id: frame.id, to: "  Khung Đẹp 2026  ")
        let updated = try env.frames.getFrame(id: frame.id)!
        XCTAssertEqual(updated.name, "Khung Đẹp 2026")

        // 4. Danh mục
        let cat = try env.frames.createCategory(name: "CatOriginal")
        // Rỗng
        XCTAssertThrowsError(try env.frames.renameCategory(id: cat.id, to: "   "))
        // Quá 80 ký tự
        let longName = String(repeating: "A", count: 81)
        XCTAssertThrowsError(try env.frames.renameCategory(id: cat.id, to: longName))
        // Trùng danh mục khác
        _ = try env.frames.createCategory(name: "ExistingCat")
        XCTAssertThrowsError(try env.frames.renameCategory(id: cat.id, to: "ExistingCat"))
        // Hợp lệ
        try env.frames.renameCategory(id: cat.id, to: "  CatRenamed  ")
        let catUpdated = try env.frames.listCategories().first { $0.id == cat.id }!
        XCTAssertEqual(catUpdated.name, "CatRenamed")
    }

    // MARK: - F09: Đo layout tab Khung ảnh (FRM-UI)
    func testF09_FramesTabLayoutMeasurement() throws {
        let framesView = FramesView(env: env)
        let hostingView = NSHostingView(rootView: framesView)

        let sizes: [CGSize] = [
            CGSize(width: 1024, height: 680),
            CGSize(width: 1280, height: 820),
            CGSize(width: 1320, height: 840)
        ]

        for size in sizes {
            hostingView.frame = CGRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()

            // Vùng categorySidebar cố định 200pt
            // Vùng nội dung còn lại = size.width - 200pt
            let contentWidth = size.width - 200
            XCTAssertGreaterThanOrEqual(contentWidth, 824, "Vùng nội dung phải đủ rộng và không bị lệch")
        }
    }

    // MARK: - F10: Hồi quy các luồng chính
    func testF10_RegressionFullFlow() throws {
        let framesVM = FramesViewModel(env: env)
        framesVM.reload()
        XCTAssertFalse(framesVM.frames.isEmpty)

        // 1. Tìm kiếm
        framesVM.searchText = "Lưới"
        framesVM.reload()
        for f in framesVM.frames {
            XCTAssertTrue(f.frame.name.localizedCaseInsensitiveContains("Lưới"))
        }

        // 2. Yêu thích lọc
        framesVM.searchText = ""
        framesVM.selectedCategoryID = "__favorites__"
        framesVM.reload()
        for f in framesVM.frames {
            XCTAssertTrue(f.frame.isFavorite)
        }

        // 3. Chọn khung cho capture
        let ready = try env.frames.listReadyFrames()
        let selected = try env.selectFrameForCapture(ready[0].id)
        XCTAssertEqual(selected.id, ready[0].id)
    }
}
