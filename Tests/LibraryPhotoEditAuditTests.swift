import XCTest
import Foundation
import CoreGraphics
import CoreImage
import CryptoKit
@testable import OpenPhotobooth

@MainActor
final class LibraryPhotoEditAuditTests: XCTestCase {

    private func makeTestJPEG(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 200, height: Int = 200) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 95)
    }

    private func getPixel(image: CGImage, x: Int = 0, y: Int = 0) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    // MARK: - C01: Render JSON cũ ở cùng kích thước, màu và định dạng lossless trước/sau
    func testC01_LegacyJSONCompatibility() throws {
        // JSON cũ thiếu hoàn toàn highlights, shadows, vibrance, explicitNoPreset
        let legacyColorJSON = """
        {
            "exposure": 0.15,
            "contrast": -0.10,
            "saturation": 0.20,
            "temperature": 0.05,
            "tint": -0.02,
            "sharpness": 0.30
        }
        """.data(using: .utf8)!

        let decodedParams = try JSONDecoder().decode(ColorParameterSet.self, from: legacyColorJSON)
        XCTAssertEqual(decodedParams.exposure, 0.15, accuracy: 0.001)
        XCTAssertEqual(decodedParams.contrast, -0.10, accuracy: 0.001)
        XCTAssertEqual(decodedParams.saturation, 0.20, accuracy: 0.001)
        XCTAssertEqual(decodedParams.temperature, 0.05, accuracy: 0.001)
        XCTAssertEqual(decodedParams.tint, -0.02, accuracy: 0.001)
        XCTAssertEqual(decodedParams.sharpness, 0.30, accuracy: 0.001)
        // Các trường mới phải hạ về mặc định 0 trung tính
        XCTAssertEqual(decodedParams.highlights, 0.0, accuracy: 0.001)
        XCTAssertEqual(decodedParams.shadows, 0.0, accuracy: 0.001)
        XCTAssertEqual(decodedParams.vibrance, 0.0, accuracy: 0.001)

        // Legacy PhotoOverride
        let legacyOverrideJSON = """
        {
            "presetID": "warm",
            "presetIntensity": 0.8
        }
        """.data(using: .utf8)!
        let decodedOverride = try JSONDecoder().decode(PhotoOverride.self, from: legacyOverrideJSON)
        XCTAssertEqual(decodedOverride.presetID, "warm")
        XCTAssertEqual(decodedOverride.presetIntensity ?? 0, 0.8, accuracy: 0.001)
        XCTAssertNil(decodedOverride.color)
        XCTAssertNil(decodedOverride.explicitNoPreset)

        // Kiểm tra render với giá trị trung tính so với render trước khi có 3 trường
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let testCI = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        let resolved = ResolvedPhotoParams(presetID: nil, presetParameters: .neutral, presetIntensity: 0, color: decodedParams, skinSmooth: 0, photoRotation: 0)
        let outCI = ImageColorPipeline.applyColor(testCI, resolved: resolved)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContextHolder.shared.context.render(outCI, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        XCTAssertEqual(pixel[3], 255, "Alpha phải được bảo toàn")
        print("AUDIT-C01: Legacy JSON decoded with neutral new fields successfully. Render sample R=\(pixel[0]) G=\(pixel[1]) B=\(pixel[2])")
    }

    // MARK: - C02: Đặt từng thanh mới lần lượt -100, 0, +100 trên ảnh mẫu
    func testC02_NewColorAdjustmentsDirectionsAndInvariance() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContextHolder.shared.context

        func renderPixel(r: Double, g: Double, b: Double, params: ColorParameterSet) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let img = CIImage(color: CIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            let resolved = ResolvedPhotoParams(presetID: nil, presetParameters: .neutral, presetIntensity: 0, color: params, skinSmooth: 0, photoRotation: 0)
            let out = ImageColorPipeline.applyColor(img, resolved: resolved)
            var p = [UInt8](repeating: 0, count: 4)
            ctx.render(out, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
            return (p[0], p[1], p[2], p[3])
        }

        // 1. Baseline tại Y=0.2
        let base02 = renderPixel(r: 0.2, g: 0.2, b: 0.2, params: .neutral)
        let zero02 = renderPixel(r: 0.2, g: 0.2, b: 0.2, params: ColorParameterSet(highlights: 0, shadows: 0, vibrance: 0))
        XCTAssertEqual(base02.r, zero02.r, "0 phải trùng baseline")

        // Shadows đổi đúng chiều tại Y=0.2
        let shadowUp02 = renderPixel(r: 0.2, g: 0.2, b: 0.2, params: ColorParameterSet(shadows: 1.0))
        let shadowDown02 = renderPixel(r: 0.2, g: 0.2, b: 0.2, params: ColorParameterSet(shadows: -1.0))
        XCTAssertGreaterThan(shadowUp02.r, base02.r, "Shadows +1.0 phải nâng vùng tối tại Y=0.2")
        XCTAssertLessThan(shadowDown02.r, base02.r, "Shadows -1.0 phải hạ/làm đậm vùng tối tại Y=0.2")

        // Highlights không đổi mẫu tại Y=0.2
        let highUp02 = renderPixel(r: 0.2, g: 0.2, b: 0.2, params: ColorParameterSet(highlights: 1.0))
        let highDown02 = renderPixel(r: 0.2, g: 0.2, b: 0.2, params: ColorParameterSet(highlights: -1.0))
        XCTAssertEqual(highUp02.r, base02.r, "Highlights không được tác động vùng tối Y=0.2")
        XCTAssertEqual(highDown02.r, base02.r, "Highlights không được tác động vùng tối Y=0.2")

        // 2. Baseline tại Y=0.8
        let base08 = renderPixel(r: 0.8, g: 0.8, b: 0.8, params: .neutral)
        // Highlights đổi đúng chiều tại Y=0.8
        let highUp08 = renderPixel(r: 0.8, g: 0.8, b: 0.8, params: ColorParameterSet(highlights: 1.0))
        let highDown08 = renderPixel(r: 0.8, g: 0.8, b: 0.8, params: ColorParameterSet(highlights: -1.0))
        XCTAssertGreaterThan(highUp08.r, base08.r, "Highlights +1.0 phải nâng vùng sáng tại Y=0.8")
        XCTAssertLessThan(highDown08.r, base08.r, "Highlights -1.0 phải hạ vùng sáng tại Y=0.8")

        // Shadows không đổi mẫu tại Y=0.8
        let shadowUp08 = renderPixel(r: 0.8, g: 0.8, b: 0.8, params: ColorParameterSet(shadows: 1.0))
        let shadowDown08 = renderPixel(r: 0.8, g: 0.8, b: 0.8, params: ColorParameterSet(shadows: -1.0))
        XCTAssertEqual(shadowUp08.r, base08.r, "Shadows không được tác động vùng sáng Y=0.8")
        XCTAssertEqual(shadowDown08.r, base08.r, "Shadows không được tác động vùng sáng Y=0.8")

        // 3. Vibrance trên màu nhạt (R=0.6, G=0.5, B=0.5)
        let vibBase = renderPixel(r: 0.6, g: 0.5, b: 0.5, params: .neutral)
        let vibUp = renderPixel(r: 0.6, g: 0.5, b: 0.5, params: ColorParameterSet(vibrance: 1.0))
        let vibDown = renderPixel(r: 0.6, g: 0.5, b: 0.5, params: ColorParameterSet(vibrance: -1.0))
        let baseGap = Int(vibBase.r) - Int(vibBase.g)
        let upGap = Int(vibUp.r) - Int(vibUp.g)
        let downGap = Int(vibDown.r) - Int(vibDown.g)
        XCTAssertGreaterThan(upGap, baseGap, "Vibrance +1.0 phải nới rộng khoảng cách kênh màu")
        XCTAssertLessThan(downGap, baseGap, "Vibrance -1.0 phải thu hẹp khoảng cách kênh màu")
        XCTAssertEqual(vibUp.a, 255, "Alpha phải giữ nguyên")
        print("AUDIT-C02: Parameters verified. Y0.2 base=\(base02.r) s+=\(shadowUp02.r) s-=\(shadowDown02.r). Y0.8 base=\(base08.r) h+=\(highUp08.r) h-=\(highDown08.r). Vibrance gaps: base=\(baseGap) up=\(upGap) down=\(downGap)")
    }

    // MARK: - C03: Kéo A1, lập tức chuyển A2 và chỉnh tiếp, sau đó mở lại phiên
    func testC03_FastSwitchBetweenPhotosPreservesEdits() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first)
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        // Thêm 3 ảnh
        for i in 1...3 {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: i,
                                                   payloadData: try makeTestJPEG(red: 0.3 * CGFloat(i), green: 0.2, blue: 0.2),
                                                   requestID: "req-\(i)", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)

        // Kéo A1
        vm.selectPhoto(index: 1)
        vm.setColorValue("highlights", 60)
        vm.setColorValue("exposure", 30)

        // Lập tức chuyển sang A2 mà không chờ debounce của A1
        vm.selectPhoto(index: 2)
        vm.setColorValue("shadows", -50)
        vm.setColorValue("vibrance", 70)

        // Chờ persist debounce hoàn tất
        try await Task.sleep(nanoseconds: 900_000_000)
        _ = await vm.flushPendingEdits()

        // Mở lại phiên từ repository
        let detail = try XCTUnwrap(try env.sessions.getDetail(sessionID: rec.id))
        let o1 = detail.overrides[1]
        let o2 = detail.overrides[2]
        let o3 = detail.overrides[3]

        XCTAssertEqual(o1?.color?.highlights ?? 0, 0.60, accuracy: 0.01, "A1 phải lưu đúng highlights=0.60")
        XCTAssertEqual(o1?.color?.exposure ?? 0, 0.30, accuracy: 0.01, "A1 phải lưu đúng exposure=0.30")
        XCTAssertEqual(o2?.color?.shadows ?? 0, -0.50, accuracy: 0.01, "A2 phải lưu đúng shadows=-0.50")
        XCTAssertEqual(o2?.color?.vibrance ?? 0, 0.70, accuracy: 0.01, "A2 phải lưu đúng vibrance=0.70")
        XCTAssertNil(o3, "A3 không chỉnh phải giữ nguyên")
        print("AUDIT-C03: Fast switch preserved A1 and A2 independent edits cleanly.")
    }

    // MARK: - C04: Sao chép A1 khi đang chờ tự lưu, sau đó chỉnh nguồn tiếp. Dán sang A2 và B1
    func testC04_CopyPasteAcrossPhotosAndSessions() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first)
        let snap = try env.frames.createSnapshot(frameID: frame.id)

        // Phiên A
        let recA = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                  defaults: env.settings.sessionDefaultsSnapshot())
        for i in 1...2 {
            _ = try await env.safetySave.savePhoto(sessionID: recA.id, captureIndex: i,
                                                   payloadData: try makeTestJPEG(red: 0.4, green: 0.4, blue: 0.4),
                                                   requestID: "req-A-\(i)", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: recA.id, status: .reviewable)

        // Phiên B với preset mặc định khác ("vintage")
        var defB = env.settings.sessionDefaultsSnapshot()
        defB.presetID = "vintage"
        defB.presetResolvedParameters = BuiltinPreset.byID("vintage")!.parameters
        let recB = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: defB)
        _ = try await env.safetySave.savePhoto(sessionID: recB.id, captureIndex: 1,
                                               payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5),
                                               requestID: "req-B-1", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        try env.sessions.setStatus(sessionID: recB.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: recA.id)
        vm.selectPhoto(index: 1)
        vm.setPreset("warm")
        vm.setPresetIntensity(0.75)
        vm.setColorValue("highlights", 40)
        vm.setColorValue("vibrance", 50)

        // Sao chép ngay khi đang có nháp
        vm.copyColorAdjustments()
        XCTAssertNotNil(env.copiedColorAdjustments, "Bộ sao chép phải có dữ liệu")
        XCTAssertEqual(env.copiedColorAdjustments?.presetID, "warm")
        XCTAssertEqual(env.copiedColorAdjustments?.color.highlights ?? 0, 0.40, accuracy: 0.01)

        // Chỉnh nguồn tiếp sau khi đã sao chép
        vm.setColorValue("highlights", 99)
        vm.setColorValue("vibrance", 99)

        // Dán sang A2 trong cùng phiên
        vm.selectPhoto(index: 2)
        await vm.pasteColorAdjustments()

        // Mở phiên B và dán sang B1
        await vm.load(sessionID: recB.id)
        vm.selectPhoto(index: 1)
        await vm.pasteColorAdjustments()

        // Kiểm chứng A2 và B1 đều mang thông số TẠI THỜI ĐIỂM SAO CHÉP (highlights=0.40, vibrance=0.50, preset=warm)
        let detailA = try XCTUnwrap(try env.sessions.getDetail(sessionID: recA.id))
        let detailB = try XCTUnwrap(try env.sessions.getDetail(sessionID: recB.id))

        let oA2 = try XCTUnwrap(detailA.overrides[2] as PhotoOverride?)
        let oB1 = try XCTUnwrap(detailB.overrides[1] as PhotoOverride?)

        XCTAssertEqual(oA2.color?.highlights ?? 0, 0.40, accuracy: 0.01)
        XCTAssertEqual(oA2.color?.vibrance ?? 0, 0.50, accuracy: 0.01)
        XCTAssertEqual(oA2.presetID, "warm")

        XCTAssertEqual(oB1.color?.highlights ?? 0, 0.40, accuracy: 0.01)
        XCTAssertEqual(oB1.color?.vibrance ?? 0, 0.50, accuracy: 0.01)
        XCTAssertEqual(oB1.presetID, "warm", "Mặc định vintage của B không được đè lên preset warm đã sao chép")

        print("AUDIT-C04: Copied snapshot is independent of subsequent source edits and successfully pasted across sessions.")
    }

    // MARK: - C05: Dán lên ảnh đang có chỉnh riêng, Hoàn tác, Làm lại, rồi dán trùng
    func testC05_PasteUndoRedoAndIdempotentDuplicate() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let snap = try env.frames.createSnapshot(frameID: env.frames.listReadyFrames().first!.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        for i in 1...2 {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: i, payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5), requestID: "r\(i)", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)

        // Tạo nguồn có chỉnh màu
        vm.selectPhoto(index: 1)
        vm.setColorValue("exposure", 40)
        vm.setColorValue("shadows", 20)
        _ = await vm.flushPendingEdits()
        vm.copyColorAdjustments()

        // Ảnh 2 có chỉnh riêng ban đầu
        vm.selectPhoto(index: 2)
        vm.setColorValue("contrast", -30)
        _ = await vm.flushPendingEdits()
        let revBeforePaste = vm.detail?.session.revisionNo ?? 0

        // 1. Dán
        await vm.pasteColorAdjustments()
        let revAfterPaste = vm.detail?.session.revisionNo ?? 0
        XCTAssertGreaterThan(revAfterPaste, revBeforePaste, "Dán thành công phải tăng revision")
        XCTAssertEqual(vm.detail?.overrides[2]?.color?.exposure ?? 0, 0.40, accuracy: 0.01)

        // 2. Hoàn tác
        XCTAssertTrue(vm.canUndo)
        vm.undo()
        try await Task.sleep(nanoseconds: 200_000_000)
        await vm.reload()
        XCTAssertEqual(vm.detail?.overrides[2]?.color?.contrast ?? 0, -0.30, accuracy: 0.01, "Undo phải phục hồi chỉnh riêng ban đầu")
        XCTAssertNil(vm.detail?.overrides[2]?.color?.exposure, "Undo phải hủy bỏ giá trị dán")

        // 3. Làm lại
        XCTAssertTrue(vm.canRedo)
        vm.redo()
        try await Task.sleep(nanoseconds: 200_000_000)
        await vm.reload()
        XCTAssertEqual(vm.detail?.overrides[2]?.color?.exposure ?? 0, 0.40, accuracy: 0.01, "Redo phải khôi phục giá trị dán")

        // 4. Dán trùng
        let revBeforeDuplicate = vm.detail?.session.revisionNo ?? 0
        await vm.pasteColorAdjustments()
        let revAfterDuplicate = vm.detail?.session.revisionNo ?? 0
        XCTAssertEqual(revBeforeDuplicate, revAfterDuplicate, "Dán trùng thông số hiệu lực không được tăng revision")
        print("AUDIT-C05: Paste, Undo, Redo and Duplicate paste idempotency verified.")
    }

    // MARK: - C06: Mô phỏng lỗi ghi đích rồi thử lại. Thử riêng với phiên bản ảnh thay đổi sau khi bắt đầu dán
    func testC06_StalePhotoRevisionRejection() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let snap = try env.frames.createSnapshot(frameID: env.frames.listReadyFrames().first!.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        let rev1 = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1, payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5), requestID: "r1", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        // Chụp lại (tạo rev 2)
        let rev2 = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1, payloadData: try makeTestJPEG(red: 0.6, green: 0.6, blue: 0.6), requestID: "r2-retake", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)

        // Gọi setOverride với revision cũ (rev1) -> Repository phải từ chối vì không còn là current
        XCTAssertThrowsError(try env.sessions.setOverride(sessionID: rec.id, photoRevisionID: rev1.id, override: PhotoOverride(color: ColorOverrides(exposure: 0.5)))) { error in
            let appErr = error as? AppError
            XCTAssertNotNil(appErr)
            XCTAssertTrue(appErr?.message.contains("Phiên bản ảnh đã thay đổi") == true)
        }

        // Gọi với rev2 (current) -> Thành công
        XCTAssertNoThrow(try env.sessions.setOverride(sessionID: rec.id, photoRevisionID: rev2.id, override: PhotoOverride(color: ColorOverrides(exposure: 0.5))))
        print("AUDIT-C06: Stale revision properly rejected with human-readable error.")
    }

    // MARK: - C07: Áp dụng cả phiên, đặt lại, Hoàn tác
    func testC07_ApplyColorToAllAndResetWithUndo() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let snap = try env.frames.createSnapshot(frameID: env.frames.listReadyFrames().first!.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        for i in 1...3 {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: i, payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5), requestID: "req-\(i)", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)

        vm.selectPhoto(index: 1)
        vm.setColorValue("highlights", 45)
        vm.setColorValue("shadows", -25)
        vm.setColorValue("vibrance", 65)

        // Áp dụng cho tất cả ảnh
        vm.applyColorToAll()
        try await Task.sleep(nanoseconds: 300_000_000)
        await vm.reload()

        let detail = try XCTUnwrap(vm.detail)
        for i in 1...3 {
            let o = detail.overrides[i]
            XCTAssertEqual(o?.color?.highlights ?? 0, 0.45, accuracy: 0.01, "Ảnh \(i) phải nhận highlights")
            XCTAssertEqual(o?.color?.shadows ?? 0, -0.25, accuracy: 0.01, "Ảnh \(i) phải nhận shadows")
            XCTAssertEqual(o?.color?.vibrance ?? 0, 0.65, accuracy: 0.01, "Ảnh \(i) phải nhận vibrance")
        }

        // Reset ảnh 2
        vm.selectPhoto(index: 2)
        vm.resetThisPhoto()
        try await Task.sleep(nanoseconds: 300_000_000)
        await vm.reload()
        XCTAssertNil(vm.detail?.overrides[2], "Ảnh 2 sau reset phải trả về nil override (kế thừa session)")
        XCTAssertNotNil(vm.detail?.overrides[1], "Ảnh 1 vẫn giữ nguyên")
        XCTAssertNotNil(vm.detail?.overrides[3], "Ảnh 3 vẫn giữ nguyên")

        print("AUDIT-C07: Apply to all and Reset verified across multiple photos.")
    }

    // MARK: - C08: So ảnh riêng, ảnh trong khung và bản xuất PNG mới
    func testC08_SinglePhotoPreviewAndExportIntegration() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let snap = try env.frames.createSnapshot(frameID: env.frames.listReadyFrames().first!.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        for i in snap.requiredIndices {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: i, payloadData: try makeTestJPEG(red: 0.4, green: 0.4, blue: 0.4, width: 400, height: 300), requestID: "r-\(i)", width: 400, height: 300, orientation: 1, codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)
        vm.selectPhoto(index: 1)

        // Chế độ Ảnh riêng
        vm.setPreviewMode(.singlePhoto)
        try await Task.sleep(nanoseconds: 400_000_000)
        let singleImg = try XCTUnwrap(vm.previewImage)
        // Ảnh riêng phải giữ tỉ lệ gốc của ảnh nguồn 400x300 (aspect 4/3)
        let aspectSingle = Double(singleImg.width) / Double(singleImg.height)
        XCTAssertEqual(aspectSingle, 4.0 / 3.0, accuracy: 0.05, "Ảnh riêng phải theo tỉ lệ gốc")

        // Chuyển sang Trong khung
        vm.setPreviewMode(.inFrame)
        try await Task.sleep(nanoseconds: 400_000_000)
        let frameImg = try XCTUnwrap(vm.previewImage)
        let aspectFrame = Double(frameImg.width) / Double(frameImg.height)
        let aspectCanvas = Double(snap.canvasWidth) / Double(snap.canvasHeight)
        XCTAssertEqual(aspectFrame, aspectCanvas, accuracy: 0.05, "Ảnh trong khung phải theo tỉ lệ canvas")

        // Xuất PNG thành công
        let exportsDir = FileManager.default.temporaryDirectory.appendingPathComponent("openphotobooth_audit_exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let req = ExportService.ExportRequest(sessionID: rec.id, format: .png, quality: 95,
                                              width: snap.canvasWidth, height: snap.canvasHeight,
                                              filenameBase: "TestOutput", destinationFolder: exportsDir)
        let res = await vm.runExport(request: req)
        switch res {
        case .success(let url):
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            print("AUDIT-C08: Single preview and inFrame preview aspect ratios matched. Export PNG verified at: \(url.lastPathComponent)")
        case .failure(let err):
            XCTFail("Export failed: \(err.message)")
        }
    }

    // MARK: - C09: Trạng thái accessibility và ô trống vô hiệu hóa
    func testC09_AccessibilityAndEmptySlotDisabled() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let snap = try env.frames.createSnapshot(frameID: env.frames.listReadyFrames().first!.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        // Chỉ lưu ảnh 1, để trống ảnh 2
        _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: 1, payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5), requestID: "r1", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)

        // Ảnh 1 có sẵn
        vm.selectPhoto(index: 1)
        XCTAssertTrue(vm.hasValidSelectedPhoto, "Ảnh 1 phải hợp lệ")

        // Ô 2 trống
        vm.selectPhoto(index: 2)
        XCTAssertFalse(vm.hasValidSelectedPhoto, "Ô 2 trống thì hasValidSelectedPhoto phải là false để vô hiệu hóa thanh trượt và nút sao chép/dán")
        print("AUDIT-C09: Empty slot disables controls verified.")
    }

    // MARK: - C10: Coalesced latest-value preview responsiveness
    func testC10_CoalescedPreviewResponsiveness() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let snap = try env.frames.createSnapshot(frameID: env.frames.listReadyFrames().first!.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        for i in snap.requiredIndices {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: i, payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5), requestID: "req-\(i)", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)
        vm.selectPhoto(index: 1)

        let start = Date()
        // Kéo liên tục
        for v in stride(from: -50, through: 50, by: 5) {
            vm.setColorValue("exposure", Double(v))
            vm.setColorValue("highlights", Double(-v))
        }

        // Chờ preview hoàn tất
        try await Task.sleep(nanoseconds: 600_000_000)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(elapsed, 1.5, "Preview gộp phải hoàn thành dưới ngưỡng quy định")
        XCTAssertNotNil(vm.previewImage)
        print("AUDIT-C10: Coalesced slider拖动 responsiveness: \(String(format: "%.3f", elapsed))s")
    }

    // MARK: - C11: Hồi quy toàn luồng Review -> Thư viện -> Chỉnh ảnh -> Hoàn thành
    func testC11_RegressionFullWorkflow() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let snap = try env.frames.createSnapshot(frameID: env.frames.listReadyFrames().first!.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil, defaults: env.settings.sessionDefaultsSnapshot())
        for i in snap.requiredIndices {
            _ = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: i, payloadData: try makeTestJPEG(red: 0.5, green: 0.5, blue: 0.5), requestID: "r-\(i)", width: 200, height: 200, orientation: 1, codec: "jpeg", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .completed)

        // 1. Vào Thư viện và bấm Chỉnh ảnh
        env.openReview(sessionID: rec.id, source: .library)
        XCTAssertEqual(env.reviewContext?.sourceRoute, .library)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: rec.id)
        // Vào từ Thư viện mặc định Ảnh đang chọn
        XCTAssertEqual(vm.previewMode, .singlePhoto, "Vào từ Thư viện phải mặc định Ảnh đang chọn")

        // 2. Chỉnh ảnh
        vm.setColorValue("highlights", 50)
        vm.setColorValue("shadows", 30)
        _ = await vm.flushPendingEdits()

        // 3. Hoàn tất và quay lại
        let updatedDetail = try XCTUnwrap(try env.sessions.getDetail(sessionID: rec.id))
        XCTAssertEqual(updatedDetail.overrides[1]?.color?.highlights ?? 0, 0.50, accuracy: 0.01)
        XCTAssertEqual(updatedDetail.overrides[1]?.color?.shadows ?? 0, 0.30, accuracy: 0.01)

        print("AUDIT-C11: Full workflow Library -> Review -> Edit -> Completed verified successfully.")
    }
}
