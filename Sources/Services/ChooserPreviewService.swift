import Foundation
import CoreGraphics

/// Validation survives viewport cancellation; rendering remains serial per chooser service.
actor ChooserPreviewService {
    struct Result {
        let snapshot: FrameSnapshot
        let frame: CGImage
        let selection: CGImage?
    }
    private let frames: FrameRepository
    private let builder: SessionRenderBuilder
    private var validations: [String: Task<FrameSnapshot, Error>] = [:]
    private var tail: Task<Void, Never>?

    init(frames: FrameRepository, builder: SessionRenderBuilder) {
        self.frames = frames
        self.builder = builder
    }

    func snapshot(frameID: String, revision: String) async throws -> FrameSnapshot {
        let key = "\(frameID):\(revision)"
        if let task = validations[key] { return try await task.value }
        let frames = frames
        let task = Task.detached(priority: .userInitiated) {
            for delay in [0, 100, 200, 400] {
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                do {
                    return try frames.validatedSnapshotForUse(frameID: frameID, expectedRevisionID: revision)
                } catch AppError.busy where delay != 400 {
                    continue
                }
            }
            throw AppError.invalidState("Không thể kiểm tra khung")
        }
        validations[key] = task
        defer { validations.removeValue(forKey: key) }
        return try await task.value
    }

    func render(detail: SessionDetail, frameID: String, revision: String, order: [Int],
                width: Int, height: Int) async throws -> Result {
        let previous = tail
        let builder = builder
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            let snapshot = try await self.snapshot(frameID: frameID, revision: revision)
            try Task.checkCancellation()
            let frame = try await builder.renderChooserPreview(detail: detail, snapshot: snapshot, order: [], width: width, height: height)
            try Task.checkCancellation()
            let selection = order.isEmpty ? nil : try await builder.renderChooserPreview(detail: detail, snapshot: snapshot, order: order, width: width, height: height)
            try Task.checkCancellation()
            return Result(snapshot: snapshot, frame: frame, selection: selection)
        }
        tail = Task { _ = await task.result }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
