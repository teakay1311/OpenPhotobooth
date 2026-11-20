import Foundation
import XCTest
@testable import OpenPhotobooth

#if DEBUG
@MainActor
final class ToastLifecycleTests: XCTestCase {
    func testIdenticalToastReplacesTimerAndOnlyCurrentTimerCanDismiss() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let first = WaitGate()
        let second = WaitGate()
        defer { first.resume(); second.resume() }

        env.toastWaitForTesting = { await first.wait() }
        env.showToast("QA toast", kind: .warning)
        let firstID = try XCTUnwrap(env.activeToast?.id)
        let firstTask = try XCTUnwrap(env.toastDismissTask)
        await fulfillment(of: [first.started], timeout: 2)

        env.toastWaitForTesting = { await second.wait() }
        env.showToast("QA toast", kind: .warning)
        let secondID = try XCTUnwrap(env.activeToast?.id)
        let secondTask = try XCTUnwrap(env.toastDismissTask)
        await fulfillment(of: [second.started], timeout: 2)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(firstTask.isCancelled)

        first.resume()
        await firstTask.value
        XCTAssertEqual(env.activeToast?.id, secondID)
        XCTAssertEqual(env.toast, ToastMessage(text: "QA toast", kind: .warning))

        second.resume()
        await secondTask.value
        XCTAssertNil(env.toast)
        XCTAssertNil(env.toastDismissTask)
    }

    func testManualDismissCancelsPendingTimer() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let gate = WaitGate()
        defer { gate.resume() }
        env.toastWaitForTesting = { await gate.wait() }
        env.showToast("QA toast")
        let task = try XCTUnwrap(env.toastDismissTask)
        await fulfillment(of: [gate.started], timeout: 2)

        env.dismissToast()
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(env.toast)
        XCTAssertNil(env.toastDismissTask)
        gate.resume()
        await task.value
        XCTAssertNil(env.toast)
    }

    func testLaunchRecoveryToastExpiresWithoutClearingRecoveryReport() async throws {
        let env = AppEnvironment(inMemory: true, camera: FakeCameraService())
        let gate = WaitGate()
        defer { gate.resume(); env.trashScheduler.stop() }
        env.toastWaitForTesting = { await gate.wait() }
        let sessionID = IDFactory.new()
        try env.layout.ensureSessionDirs(sessionID)
        let partial = env.layout.sessionOriginalsDir(sessionID).appendingPathComponent("qa.partial")
        try Data("QA partial image".utf8).write(to: partial)

        await env.boot()
        let report = try XCTUnwrap(env.recoveryReport)
        XCTAssertEqual(report.quarantinedFiles, 1)
        XCTAssertEqual(env.toast?.kind, .info)
        XCTAssertTrue(env.toast?.text.hasPrefix("Khởi động an toàn:") == true)
        let task = try XCTUnwrap(env.toastDismissTask)
        await fulfillment(of: [gate.started], timeout: 2)

        gate.resume()
        await task.value
        XCTAssertNil(env.toast)
        XCTAssertEqual(env.recoveryReport, report)
    }

    @MainActor
    private final class WaitGate {
        let started = XCTestExpectation(description: "Toast timer is waiting")
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            started.fulfill()
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func resume() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}
#endif
