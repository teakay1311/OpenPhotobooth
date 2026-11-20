import XCTest
import Foundation
import AppKit
import Combine
import CoreGraphics
import ImageIO
@testable import OpenPhotobooth

@MainActor
final class AuditPendingEditTests: XCTestCase {

    private func jpegBytes() throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
        return try ExportService.encode(cg: ctx.makeImage()!, format: .jpeg, quality: 90)
    }

    private func makeSession(env: AppEnvironment) async throws -> (String, PhotoRevision) {
        let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Dải 3 ảnh" })
        let snap = try env.frames.createSnapshot(frameID: frame.id)
        let rec = try env.sessions.createSession(snapshot: snap, mode: .automatic, cameraID: nil,
                                                 defaults: env.settings.sessionDefaultsSnapshot())
        var first: PhotoRevision?
        let jpeg = try jpegBytes()
        for idx in snap.requiredIndices.sorted() {
            let rev = try await env.safetySave.savePhoto(sessionID: rec.id, captureIndex: idx,
                                                         payloadData: jpeg, requestID: UUID().uuidString,
                                                         width: 240, height: 320, orientation: 1,
                                                         codec: "jpeg", colorProfile: nil)
            if idx == 1 { first = rev }
        }
        try env.sessions.setStatus(sessionID: rec.id, status: .reviewable)
        return (rec.id, try XCTUnwrap(first))
    }

    // T7: rời màn Xem lại ngay sau khi kéo slider -> chỉnh sửa phải được lưu (spec §2.2)
    func testPendingColorEditSurvivesNavigation() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, rev) = try await makeSession(env: env)

        var vm: ReviewViewModel? = ReviewViewModel(env: env)
        await vm!.load(sessionID: sid)
        vm!.selectPhoto(index: 1)
        vm!.setColorValue("exposure", 80)      // debounce 400ms
        vm = nil                                // view bị huỷ khi rời màn (Cmd+3 / nút quay lại)
        try await Task.sleep(nanoseconds: 900_000_000)

        let saved = try env.sessions.getOverride(photoRevisionID: rev.id)
        print("AUDIT-PENDING-NAV override=", saved.map { "exposure=\($0.color?.exposure ?? -99)" } ?? "nil")
        XCTAssertNotNil(saved, "Chỉnh màu trong 400ms cuối bị mất khi rời màn Xem lại")
        XCTAssertEqual(saved?.color?.exposure ?? 0, 0.8, accuracy: 0.001)
    }

    // T8: bấm Hoàn thành ngay sau khi kéo slider -> phải lưu xong trước khi complete/auto export
    func testCompleteFlushesPendingColorEditFirst() async throws {
        let env = AppEnvironment(inMemory: true)
        await env.boot()
        let (sid, rev) = try await makeSession(env: env)

        let vm = ReviewViewModel(env: env)
        await vm.load(sessionID: sid)
        vm.selectPhoto(index: 1)
        vm.setColorValue("saturation", 60)   // debounce 400ms
        await vm.complete()

        let immediately = try env.sessions.getOverride(photoRevisionID: rev.id)
        print("AUDIT-PENDING-COMPLETE immediate=", immediately?.color?.saturation.map { "\($0)" } ?? "nil")
        try await Task.sleep(nanoseconds: 900_000_000)
        let later = try env.sessions.getOverride(photoRevisionID: rev.id)
        print("AUDIT-PENDING-COMPLETE afterDebounce=", later?.color?.saturation.map { "\($0)" } ?? "nil")
        XCTAssertNotNil(immediately,
                        "complete() phải flush chỉnh màu đang chờ TRƯỚC khi hoàn thành/auto export")
    }
}

@MainActor
final class FiveFixesRegressionTests: XCTestCase {
  func environment() -> AppEnvironment {
    AppEnvironment(
      inMemory: true, camera: FakeCameraService(),
      faceAnalysis: FaceAnalysisService(detector: { _ in [] }))
  }

  func makeFrame(_ env: AppEnvironment) throws -> Frame {
    let f = try env.frames.createEmptyFrame(
      name: "Five fixes QA", categoryID: nil, canvasWidth: 256, canvasHeight: 256)
    let draft = FrameRevision(frameID: f.id, revisionNo: 1, canvasWidth: 256, canvasHeight: 256)
    _ = try env.frames.commitRevision(
      frameID: f.id, draft: draft,
      slots: [
        FrameSlot(
          captureIndex: 1, x: 0, y: 0, width: 1, height: 1, zOrder: 0, defaultCropMode: .fill)
      ])
    try env.frames.setValidationStatus(frameID: f.id, status: .ready)
    return try XCTUnwrap(env.frames.getFrame(id: f.id))
  }

  func makeSession(_ env: AppEnvironment) async throws -> String {
    let f = try makeFrame(env)
    var defaults = env.settings.sessionDefaultsSnapshot()
    defaults.smartFace = false
    let s = try env.sessions.createSession(
      snapshot: env.frames.createSnapshot(frameID: f.id), mode: .manual, cameraID: "QA",
      defaults: defaults, frameNameAtCapture: f.name)
    let ctx = try XCTUnwrap(
      CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let data = try ExportService.encode(cg: XCTUnwrap(ctx.makeImage()), format: .png, quality: 95)
    _ = try await env.safetySave.savePhoto(
      sessionID: s.id, captureIndex: 1, payloadData: data, requestID: UUID().uuidString, width: 64,
      height: 64, orientation: 1, codec: "png", colorProfile: nil)
    try env.sessions.setStatus(sessionID: s.id, status: .reviewable)
    return s.id
  }

  func loadedReview(_ env: AppEnvironment, _ id: String) async throws -> ReviewViewModel {
    let vm = ReviewViewModel(env: env)
    let loaded = await vm.load(sessionID: id)
    XCTAssertTrue(loaded)
    vm.selectPhoto(index: 1)
    return vm
  }

  func testF03NewPendingColorEditInvalidatesRedoWithoutWritingOldHistory() async throws {
    let env = environment()
    let id = try await makeSession(env)
    let vm = try await loadedReview(env, id)
    vm.setColorValue("exposure", 40)
    let saved = await vm.flushPendingEdits()
    XCTAssertTrue(saved)
    vm.undo()
    await vm.reload()
    XCTAssertTrue(vm.canRedo)
    let before = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
    vm.setColorEditing(true)
    vm.setColorValue("exposure", 80)
    XCTAssertTrue(vm.hasPendingEdits)
    XCTAssertFalse(vm.canRedo)
    vm.redo()
    let during = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
    XCTAssertEqual(
      during.session.revisionNo, before.session.revisionNo, "Redo during pending must not write")
    XCTAssertEqual(during.overrides, before.overrides)
    XCTAssertEqual(vm.draftColor.exposure, 0.8)
    let flushed = await vm.flushPendingEdits()
    XCTAssertTrue(flushed)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id)?.overrides[1]?.color?.exposure, 0.8)
    vm.undo()
    await vm.reload()
    XCTAssertTrue(vm.canRedo)
    vm.redo()
    await vm.reload()
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id)?.overrides[1]?.color?.exposure, 0.8)
  }

  func measure(_ env: AppEnvironment) async -> AppEnvironment.StorageMeasurementStatus {
    let done = expectation(description: "storage measurement")
    env.onStorageMeasurementFinished = { _, _ in done.fulfill() }
    env.requestStorageMeasurement()
    await fulfillment(of: [done], timeout: 5)
    env.onStorageMeasurementFinished = nil
    return env.storageMeasurement
  }

  func testF05MissingRootReportsFailureAndRetainsPreviousMeasurement() async throws {
    let env = environment()
    _ = try makeFrame(env)
    let file = env.layout.rootURL.appendingPathComponent("measurement.dat")
    try Data(repeating: 7, count: 4096).write(to: file)
    let first = await measure(env)
    guard case .current(let bytes, let formatted) = first else {
      return XCTFail("Initial measurement must succeed")
    }
    XCTAssertGreaterThanOrEqual(bytes, 4096)
    try FileManager.default.removeItem(at: env.layout.rootURL)
    let failed = await measure(env)
    XCTAssertEqual(failed, .failed(previous: (bytes, formatted)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: env.layout.rootURL.path))
  }

  func testLibraryScalePerformanceComparison() async throws {
    for count in [10, 100, 1000] {
      let env = environment()
      let f = try makeFrame(env)
      let snapshot = try env.frames.createSnapshot(frameID: f.id)
      for _ in 0..<count {
        _ = try env.sessions.createSession(
          snapshot: snapshot, mode: .manual, cameraID: nil,
          defaults: env.settings.sessionDefaultsSnapshot())
      }
      let vm = LibraryViewModel(env: env)
      await vm.reload().value
      for batch in 1...3 {
        var samples: [Double] = []
        for _ in 0..<5 {
          let start = ProcessInfo.processInfo.systemUptime
          await vm.reload().value
          samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        XCTAssertEqual(vm.cards.count, count)
        print(
          "FIVE-FIXES-PERF count=\(count) batch=\(batch) medianMS=\(samples.sorted()[2]) samples=\(samples)"
        )
      }
    }
  }
}

extension FiveFixesRegressionTests {
  func libraryCard(_ env: AppEnvironment, _ id: String) throws -> SessionCardModel {
    let card = try XCTUnwrap(env.sessions.listSessions().first { $0.id == id })
    return SessionCardModel(
      card: card, frameName: "Five fixes QA", preview: nil, formattedDate: "QA")
  }

  func testF01ShareReportsMissingAndCorruptSourcesAndRecoversWithoutChangingSession() async throws {
    let env = environment()
    let id = try await makeSession(env)
    let library = LibraryViewModel(env: env)
    let card = try libraryCard(env, id)
    let before = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
    let rev = try XCTUnwrap(before.currentRevisions()[1])
    let source = try env.sessions.fileURL(for: rev)
    let original = try Data(contentsOf: source)
    let held = source.appendingPathExtension("qa-held")
    try FileManager.default.moveItem(at: source, to: held)
    defer {
      try? original.write(to: source)
      try? FileManager.default.removeItem(at: held)
    }
    let missing = await library.prepareShareFile(for: card)
    XCTAssertNil(missing)
    XCTAssertEqual(env.toast?.kind, .warning)
    XCTAssertTrue(env.toast?.text.contains("chia sẻ") == true)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
    try Data("corrupt QA image".utf8).write(to: source)
    env.dismissToast()
    let corrupt = await library.prepareShareFile(for: card)
    XCTAssertNil(corrupt)
    XCTAssertEqual(env.toast?.kind, .warning)
    try original.write(to: source)
    env.dismissToast()
    let shared = await library.prepareShareFile(for: card)
    let output = try XCTUnwrap(shared)
    XCTAssertNotNil(CGImage.createFrom(data: try Data(contentsOf: output)))
    XCTAssertNil(env.toast)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
    XCTAssertNil(try env.db.integrityCheck())
    XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
  }

  func testF01ShareRejectsBusyAndTrashedSessionAndSilentCancellation() async throws {
    let env = environment()
    let id = try await makeSession(env)
    let library = LibraryViewModel(env: env)
    let card = try libraryCard(env, id)
    let token = try env.coordinator.acquire(key: "session:\(id)", reason: "QA share contention")
    let busy = await library.prepareShareFile(for: card)
    XCTAssertNil(busy)
    XCTAssertEqual(env.toast?.kind, .warning)
    token.release()
    env.dismissToast()
    let cancelled = Task { @MainActor in await library.prepareShareFile(for: card) }
    cancelled.cancel()
    let result = await cancelled.value
    XCTAssertNil(result)
    XCTAssertNil(env.toast)
    try env.trashService.trashSession(sessionID: id)
    let before = try env.sessions.getDetail(sessionID: id)
    let trashed = await library.prepareShareFile(for: card)
    XCTAssertNil(trashed)
    XCTAssertEqual(env.toast?.kind, .warning)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
    let item = try XCTUnwrap(env.trashRepo.find(rootType: .session, rootID: id))
    try env.trashService.restore(item)
    let retry = await library.prepareShareFile(for: card)
    XCTAssertNotNil(retry)
  }

  func testF01ShareRejectsMissingFrameLayerWithoutWritingSession() async throws {
    let env = environment()
    try FrameSeeder.seedIfNeeded(
      db: env.db, frameRepo: env.frames, presetRepo: env.presets, assets: env.assets)
    let frame = try XCTUnwrap(env.frames.listReadyFrames().first { $0.name == "Một ảnh lớn" })
    let snap = try env.frames.createSnapshot(frameID: frame.id)
    let id = try await makeSession(env)
    try env.sessions.changeFrame(sessionID: id, newSnapshot: snap)
    let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
    let layer = try XCTUnwrap(detail.snapshot.foreground ?? detail.snapshot.background)
    let asset = try XCTUnwrap(env.assets.assetInfo(assetID: layer.assetID))
    let url = try env.layout.absoluteURL(forRelativePath: asset.relativePath)
    let held = url.appendingPathExtension("qa-held")
    try FileManager.default.moveItem(at: url, to: held)
    defer { try? FileManager.default.moveItem(at: held, to: url) }
    let library = LibraryViewModel(env: env)
    let result = await library.prepareShareFile(for: try libraryCard(env, id))
    XCTAssertNil(result)
    XCTAssertEqual(env.toast?.kind, .warning)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), detail)
  }

  func testF03UnchangedColorAndIntensityPreserveRedoAndDoNotWrite() async throws {
    let env = environment()
    let id = try await makeSession(env)
    let vm = try await loadedReview(env, id)
    vm.setColorValue("exposure", 20)
    _ = await vm.flushPendingEdits()
    vm.setColorValue("exposure", 40)
    _ = await vm.flushPendingEdits()
    vm.undo()
    await vm.reload()
    XCTAssertTrue(vm.canRedo)
    let before = try env.sessions.getDetail(sessionID: id)
    vm.setColorEditing(true)
    vm.setColorValue("exposure", 20)
    vm.setPresetIntensity(vm.draftPresetIntensity)
    XCTAssertFalse(vm.hasPendingEdits)
    XCTAssertTrue(vm.canRedo)
    vm.setColorEditing(false)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
    vm.redo()
    await vm.reload()
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id)?.overrides[1]?.color?.exposure, 0.4)
  }

  func testF03PendingIntensityDiscardDoesNotResurrectRedo() async throws {
    let env = environment()
    let id = try await makeSession(env)
    let vm = try await loadedReview(env, id)
    vm.setPresetIntensity(0.4)
    _ = await vm.flushPendingEdits()
    vm.undo()
    await vm.reload()
    XCTAssertTrue(vm.canRedo)
    let before = try env.sessions.getDetail(sessionID: id)
    vm.setColorEditing(true)
    vm.setPresetIntensity(0.8)
    XCTAssertTrue(vm.hasPendingEdits)
    XCTAssertFalse(vm.canRedo)
    vm.redo()
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
    vm.discardPendingEdits()
    vm.setColorEditing(false)
    XCTAssertFalse(vm.hasPendingEdits)
    XCTAssertFalse(vm.canRedo)
    XCTAssertEqual(vm.draftPresetIntensity, 1)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
  }

  func testF03PlacementNoOpAndPendingEditFollowSameRedoBoundary() async throws {
    let env = environment()
    let id = try await makeSession(env)
    let initial = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
    let slot = try XCTUnwrap(initial.snapshot.slots.first)
    try env.sessions.setPlacement(
      sessionID: id, snapshotSlotID: slot.id, placement: PhotoPlacement(), cropMode: .fill,
      manualOverride: true)
    let vm = try await loadedReview(env, id)
    vm.updatePlacement(scale: 1.2, isFinal: true)
    vm.undo()
    await vm.reload()
    XCTAssertTrue(vm.canRedo)
    let before = try env.sessions.getDetail(sessionID: id)
    vm.setPlacementEditing(true)
    vm.updatePlacement(scale: 1)
    XCTAssertFalse(vm.hasPendingEdits)
    XCTAssertTrue(vm.canRedo)
    vm.updatePlacement(scale: 1.7)
    XCTAssertTrue(vm.hasPendingEdits)
    XCTAssertFalse(vm.canRedo)
    vm.redo()
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
    vm.discardPendingEdits()
    vm.setPlacementEditing(false)
    XCTAssertFalse(vm.canRedo)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
  }

  func testF03FailedSaveRetainsDraftAndNewHistoryAfterRetry() async throws {
    let env = environment()
    let id = try await makeSession(env)
    let vm = try await loadedReview(env, id)
    vm.setColorValue("exposure", 20)
    _ = await vm.flushPendingEdits()
    vm.setColorValue("exposure", 40)
    _ = await vm.flushPendingEdits()
    vm.undo()
    await vm.reload()
    vm.setColorEditing(true)
    vm.setColorValue("exposure", 80)
    try env.db.run(
      "CREATE TRIGGER qa_f03_fail BEFORE UPDATE ON photo_adjustments BEGIN SELECT RAISE(ABORT, 'QA write failure'); END"
    )
    defer { try? env.db.run("DROP TRIGGER IF EXISTS qa_f03_fail") }
    let flushed = await vm.flushPendingEdits()
    XCTAssertFalse(flushed)
    XCTAssertTrue(vm.hasPendingEdits)
    XCTAssertFalse(vm.canRedo)
    XCTAssertEqual(vm.draftColor.exposure, 0.8)
    let before = try env.sessions.getDetail(sessionID: id)
    vm.redo()
    vm.undo()
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
    try env.db.run("DROP TRIGGER qa_f03_fail")
    await vm.retrySave()
    XCTAssertFalse(vm.hasPendingEdits)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id)?.overrides[1]?.color?.exposure, 0.8)
    vm.undo()
    await vm.reload()
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id)?.overrides[1]?.color?.exposure, 0.2)
    vm.redo()
    await vm.reload()
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id)?.overrides[1]?.color?.exposure, 0.8)
  }

  func testF05EmptyDirectoryAndNonDirectoryHaveDifferentOutcomes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F05-empty-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(try AppEnvironment.measureStorageBytes(at: root), 0)
    let file = root.appendingPathComponent("not-a-directory")
    try Data([1, 2, 3]).write(to: file)
    XCTAssertThrowsError(try AppEnvironment.measureStorageBytes(at: file))
    XCTAssertThrowsError(
      try AppEnvironment.measureStorageBytes(at: root.appendingPathComponent("absent")))
  }

  func testF05UnreadableChildDoesNotReportPartialTotal() async throws {
    let env = environment()
    let blocked = env.layout.rootURL.appendingPathComponent("Unreadable")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 64).write(to: blocked.appendingPathComponent("hidden"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
    }
    let status = await measure(env)
    XCTAssertEqual(status, .failed(previous: nil))
  }

  func cleanAndWait(_ env: AppEnvironment) async {
    let finished = expectation(description: "cache clean completed")
    let subscription = env.$cacheCleanTaskID.dropFirst().filter { $0 == nil }.prefix(1).sink { _ in
      finished.fulfill()
    }
    env.cleanCache()
    await fulfillment(of: [finished], timeout: 5)
    subscription.cancel()
  }

  func testF05RepeatedFailureAndPostCleanFailureRetainLastAcceptedSize() async throws {
    let env = environment()
    let id = try await makeSession(env)
    let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
    let photo = try XCTUnwrap(detail.currentRevisions()[1])
    let source = try env.sessions.fileURL(for: photo)
    let bytes = try Data(contentsOf: source)
    let initial = await measure(env)
    guard case .current(let count, let text) = initial else {
      return XCTFail("Initial measurement failed")
    }
    env.storageSizeReader = { _ in throw AppError.ioFailure("QA measurement failure") }
    for _ in 0..<2 {
      let status = await measure(env)
      XCTAssertEqual(status, .failed(previous: (count, text)))
    }
    _ = env.thumbnails.store(
      data: Data([4, 5, 6]), key: "five-fixes-cache", expectedGeneration: env.thumbnails.generation)
    await cleanAndWait(env)
    XCTAssertEqual(env.storageMeasurement, .stale(bytes: count, formatted: text))
    XCTAssertEqual(env.toast?.kind, .warning)
    XCTAssertTrue(env.toast?.text.contains("chưa đo lại") == true)
    XCTAssertEqual(try Data(contentsOf: source), bytes)
    XCTAssertEqual(try env.sessions.getDetail(sessionID: id), detail)
    env.storageSizeReader = { try AppEnvironment.measureStorageBytes(at: $0) }
    let recovered = await measure(env)
    guard case .current = recovered else { return XCTFail("Measurement did not recover") }
    XCTAssertNil(try env.db.integrityCheck())
    XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
  }

  func testF05OutOfOrderSuccessAndFailureCannotOverwriteNewerMeasurement() async throws {
    for oldFails in [false, true] {
      let env = environment()
      let started = expectation(description: "old reader started")
      let gate = DispatchSemaphore(value: 0)
      env.storageSizeReader = { _ in
        started.fulfill()
        guard gate.wait(timeout: .now() + 5) == .success else {
          throw AppError.ioFailure("QA gate timeout")
        }
        if oldFails { throw AppError.ioFailure("QA old failure") }
        return 999
      }
      env.requestStorageMeasurement()
      let old = try XCTUnwrap(env.storageMeasurementTask)
      await fulfillment(of: [started], timeout: 5)
      env.storageSizeReader = { _ in 123 }
      let accepted = expectation(description: "new measurement accepted")
      var callbacks = 0
      env.onStorageMeasurementFinished = { _, _ in
        callbacks += 1
        accepted.fulfill()
      }
      env.requestStorageMeasurement(isPostClean: true)
      await fulfillment(of: [accepted], timeout: 5)
      gate.signal()
      await old.value
      XCTAssertEqual(callbacks, 1)
      XCTAssertEqual(
        env.storageMeasurement, .current(bytes: 123, formatted: FileLayout.formattedBytes(123)))
      env.onStorageMeasurementFinished = nil
    }
  }

  func testF05OldCacheCleanCannotOverwriteNewMeasurementOrToast() async throws {
    let env = environment()
    let started = expectation(description: "clean measurement started")
    let gate = DispatchSemaphore(value: 0)
    env.storageSizeReader = { _ in
      started.fulfill()
      guard gate.wait(timeout: .now() + 5) == .success else {
        throw AppError.ioFailure("QA gate timeout")
      }
      return 999
    }
    env.cleanCache()
    let old = try XCTUnwrap(env.storageMeasurementTask)
    await fulfillment(of: [started], timeout: 5)
    env.storageSizeReader = { _ in 123 }
    let accepted = expectation(description: "new accepted")
    env.onStorageMeasurementFinished = { _, _ in accepted.fulfill() }
    env.requestStorageMeasurement(isPostClean: true)
    await fulfillment(of: [accepted], timeout: 5)
    let marker = ToastMessage(text: "New measurement accepted", kind: .info)
    env.showToast(marker.text, kind: marker.kind)
    gate.signal()
    await old.value
    XCTAssertFalse(env.isCleaningCache)
    XCTAssertEqual(
      env.storageMeasurement, .current(bytes: 123, formatted: FileLayout.formattedBytes(123)))
    XCTAssertEqual(env.toast, marker)
    env.onStorageMeasurementFinished = nil
  }
}

@MainActor
final class CenterPreviewRegressionTests: XCTestCase {
    private func fixture(smartFace: Bool = false) async throws -> (AppEnvironment, String) {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService(),
                                 faceAnalysis: FaceAnalysisService(detector: { _ in [] }))
        let frame = try env.frames.createEmptyFrame(name: "Center preview QA", categoryID: nil,
                                                    canvasWidth: 512, canvasHeight: 256)
        _ = try env.frames.commitRevision(frameID: frame.id,
            draft: FrameRevision(frameID: frame.id, revisionNo: 1, canvasWidth: 512, canvasHeight: 256),
            slots: (1...2).map { FrameSlot(captureIndex: $0, x: Double($0 - 1) * 0.5, y: 0,
                                          width: 0.5, height: 1, zOrder: $0 - 1,
                                          defaultCropMode: smartFace ? .autoFace : .fill) })
        try env.frames.setValidationStatus(frameID: frame.id, status: .ready)
        var defaults = env.settings.sessionDefaultsSnapshot()
        defaults.smartFace = smartFace
        defaults.autoFacePlacementVersion = 1
        defaults.color = .neutral
        defaults.presetIntensity = 0
        defaults.outputMirror = false
        let session = try env.sessions.createSession(snapshot: env.frames.createSnapshot(frameID: frame.id),
            mode: .manual, cameraID: "QA", defaults: defaults, frameNameAtCapture: frame.name)
        for index in 1...2 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: index == 1 ? 1 : 0, green: 0,
                                         blue: index == 2 ? 1 : 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: index == 1 ? 4 : 48, y: 4, width: 12, height: 12))
            let data = try ExportService.encode(cg: XCTUnwrap(context.makeImage()), format: .png, quality: 95)
            _ = try await env.safetySave.savePhoto(sessionID: session.id, captureIndex: index,
                payloadData: data, requestID: UUID().uuidString, width: 64, height: 64,
                orientation: 1, codec: "png", colorProfile: nil)
        }
        try env.sessions.setStatus(sessionID: session.id, status: .reviewable)
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: session.id))
        for slot in detail.snapshot.slots {
            try env.sessions.setPlacement(sessionID: session.id, snapshotSlotID: slot.id,
                placement: PhotoPlacement(), cropMode: smartFace ? .autoFace : .fill,
                manualOverride: !smartFace)
        }
        return (env, session.id)
    }

    private func settled(_ vm: ReviewViewModel, after sequence: Int? = nil) async throws -> CGImage {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let image = vm.previewImage, vm.previewSequence == vm.lastDisplayedPreviewSequence,
               sequence.map({ vm.previewSequence > $0 }) ?? true { return image }
            await Task.yield()
        }
        XCTFail("Preview did not finish the expected request within five seconds")
        throw AppError.invalidState("QA preview deadline")
    }

    private func review(_ env: AppEnvironment, _ id: String) async throws -> ReviewViewModel {
        let vm = ReviewViewModel(env: env)
        let loaded = await vm.load(sessionID: id)
        XCTAssertTrue(loaded)
        _ = try await settled(vm)
        return vm
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private func assertComposite(_ image: CGImage, env: AppEnvironment, id: String,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        let rendered = await env.renderBuilder.renderPreview(detail: detail, maxDimension: 1100)
        let expected = try XCTUnwrap(rendered)
        XCTAssertEqual(image.width, expected.width, file: file, line: line)
        XCTAssertEqual(image.height, expected.height, file: file, line: line)
        let actual = try rgba(image)
        XCTAssertTrue(actual == (try rgba(expected)), "Preview must match the saved session composition", file: file, line: line)
        if image.width == 1100 && image.height == 550 {
            let left = (275 * image.width + 275) * 4
            let right = (275 * image.width + 825) * 4
            XCTAssertGreaterThan(actual[left], actual[left + 2], "Left slot must contain red photo 1", file: file, line: line)
            XCTAssertGreaterThan(actual[right + 2], actual[right], "Right slot must contain blue photo 2", file: file, line: line)
        }
    }

    private func writes(_ env: AppEnvironment) throws -> Int {
        try XCTUnwrap(env.db.query("SELECT total_changes() AS count").first?["count"].intValue)
    }

    private func sources(_ env: AppEnvironment, _ id: String) throws -> [String: String] {
        let detail = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        return try Dictionary(uniqueKeysWithValues: detail.currentRevisions().values.map {
            ($0.id, Hashing.sha256Hex(try Data(contentsOf: env.sessions.fileURL(for: $0))))
        })
    }

    func testCenteredPhotoSwitchesToCompositeWithoutWritingOrClearingRedo() async throws {
        let (env, id) = try await fixture()
        let vm = try await review(env, id)
        defer { vm.cancelPreviewPipeline() }
        vm.setColorValue("exposure", 20)
        _ = await vm.flushPendingEdits()
        vm.setColorValue("exposure", 40)
        _ = await vm.flushPendingEdits()
        vm.undo()
        await vm.reload()
        _ = try await settled(vm)
        XCTAssertTrue(vm.canRedo)
        let start = vm.previewSequence
        vm.setPreviewMode(.singlePhoto)
        _ = try await settled(vm, after: start)
        let before = try env.sessions.getDetail(sessionID: id)
        let placements = try env.db.query("SELECT * FROM slot_placements WHERE session_id=? ORDER BY id", [.text(id)])
        let count = try writes(env)
        let hashes = try sources(env, id)
        let sequence = vm.previewSequence
        vm.centerPlacement()
        XCTAssertEqual(vm.previewMode, .inFrame)
        XCTAssertGreaterThan(vm.previewSequence, sequence)
        let image = try await settled(vm)
        try await assertComposite(image, env: env, id: id)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
        XCTAssertEqual(try env.db.query("SELECT * FROM slot_placements WHERE session_id=? ORDER BY id", [.text(id)]), placements)
        XCTAssertEqual(try writes(env), count)
        XCTAssertEqual(try sources(env, id), hashes)
        XCTAssertTrue(vm.canRedo)
        XCTAssertFalse(vm.hasPendingEdits)
        XCTAssertNil(try env.db.integrityCheck())
        XCTAssertTrue(try env.db.foreignKeyCheck().isEmpty)
        print("CENTER-P2 mode=\(vm.previewMode) sequenceBefore=\(sequence) sequenceAfter=\(vm.previewSequence) image=\(image.width)x\(image.height) SQLWritesDelta=\(try writes(env) - count) canRedo=\(vm.canRedo)")
    }

    func testCenteredInFrameDoesNotEnqueueOrWrite() async throws {
        let (env, id) = try await fixture()
        let vm = try await review(env, id)
        defer { vm.cancelPreviewPipeline() }
        let before = try env.sessions.getDetail(sessionID: id)
        let count = try writes(env)
        let sequence = vm.previewSequence
        let undo = vm.canUndo
        let redo = vm.canRedo
        vm.centerPlacement()
        XCTAssertEqual(vm.previewSequence, sequence)
        XCTAssertEqual(try writes(env), count)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
        XCTAssertEqual(vm.canUndo, undo)
        XCTAssertEqual(vm.canRedo, redo)
        try await assertComposite(try await settled(vm), env: env, id: id)
    }

    func testCenterChangedOffsetsPreservesScaleAndUndoRedo() async throws {
        let (env, id) = try await fixture()
        let initial = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        let slot = try XCTUnwrap(initial.snapshot.slots.first)
        let offset = PhotoPlacement(scale: 1.3, offsetX: 0.2, offsetY: -0.1)
        try env.sessions.setPlacement(sessionID: id, snapshotSlotID: slot.id, placement: offset,
                                      cropMode: .fill, manualOverride: true)
        let vm = try await review(env, id)
        defer { vm.cancelPreviewPipeline() }
        vm.centerPlacement()
        let centered = PhotoPlacement(scale: 1.3, offsetX: 0, offsetY: 0)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: id)?.placements[slot.id]?.placement, centered)
        try await assertComposite(try await settled(vm), env: env, id: id)
        vm.undo()
        await vm.reload()
        _ = try await settled(vm)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: id)?.placements[slot.id]?.placement, offset)
        vm.redo()
        await vm.reload()
        try await assertComposite(try await settled(vm), env: env, id: id)
        XCTAssertEqual(try env.sessions.getDetail(sessionID: id)?.placements[slot.id]?.placement, centered)
    }

    func testCenterFailedPendingSaveKeepsDraftAndRetries() async throws {
        let (env, id) = try await fixture()
        let vm = try await review(env, id)
        defer { vm.cancelPreviewPipeline() }
        vm.setPlacementEditing(true)
        vm.updatePlacement(scale: 1.4, offsetX: 0.2)
        XCTAssertTrue(vm.hasPendingEdits)
        let before = try env.sessions.getDetail(sessionID: id)
        try env.db.run("CREATE TRIGGER qa_center_fail BEFORE UPDATE ON slot_placements BEGIN SELECT RAISE(ABORT, 'QA center write failure'); END")
        defer { try? env.db.run("DROP TRIGGER IF EXISTS qa_center_fail") }
        vm.centerPlacement()
        XCTAssertTrue(vm.hasPendingEdits)
        XCTAssertNotNil(vm.saveErrorMessage)
        XCTAssertEqual(vm.draftPlacement, PhotoPlacement(scale: 1.4, offsetX: 0, offsetY: 0))
        XCTAssertEqual(try env.sessions.getDetail(sessionID: id), before)
        try env.db.run("DROP TRIGGER qa_center_fail")
        await vm.retrySave()
        vm.setPlacementEditing(false)
        XCTAssertFalse(vm.hasPendingEdits)
        let saved = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        XCTAssertEqual(saved.placements[try XCTUnwrap(vm.selectedSlotID)]?.placement,
                       PhotoPlacement(scale: 1.4, offsetX: 0, offsetY: 0))
        try await assertComposite(try await settled(vm), env: env, id: id)
    }

    func testRapidSelectionAndSmartFaceKeepLatestComposition() async throws {
        let (env, id) = try await fixture(smartFace: true)
        let vm = try await review(env, id)
        defer { vm.cancelPreviewPipeline() }
        XCTAssertTrue(vm.canEditPlacement)
        vm.setPreviewMode(.singlePhoto)
        vm.selectPhoto(index: 2)
        vm.setPreviewMode(.inFrame)
        vm.selectPhoto(index: 1)
        let start = vm.previewSequence
        await vm.regeneratePreview()
        let image = try await settled(vm, after: start)
        XCTAssertEqual(vm.selectedPhotoIndex, 1)
        XCTAssertEqual(vm.previewMode, .inFrame)
        XCTAssertTrue(vm.canEditPlacement)
        try await assertComposite(image, env: env, id: id)
        let before = try XCTUnwrap(env.sessions.getDetail(sessionID: id))
        XCTAssertTrue(before.placements.values.allSatisfy { !$0.manualOverride })
        XCTAssertFalse(vm.hasPendingEdits)
    }
}
