import Foundation

// MARK: - Session models (§5, §9, §11.1, §16.2)

public struct CaptureSessionRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var status: SessionStatus
    public var activeFrameSnapshotID: String
    public var requiredCaptureCount: Int
    public var currentCaptureIndex: Int
    public var captureMode: CaptureMode
    public var cameraID: String?
    public var defaults: SessionDefaultsSnapshot
    public var revisionNo: Int
    public var createdAtMs: Int64
    public var updatedAtMs: Int64
    public var completedAtMs: Int64?
    public var frameNameAtCapture: String?
    public var countdownSeconds: Int
    public var intermissionSeconds: Int

    public var awaitsFrame: Bool {
        defaults.plannedCaptureCount != nil && defaults.selectedCaptureOrder == nil
    }

    public var pendingSelectionCount: Int? {
        guard defaults.plannedCaptureCount == nil, defaults.selectedCaptureOrder == nil,
              let count = defaults.selectionCaptureCount,
              (1...ResourceLimits.maxCaptureIndices).contains(count) else { return nil }
        return count
    }

    public var captureCount: Int { pendingSelectionCount ?? requiredCaptureCount }

    public func captureIndices(in snapshot: FrameSnapshot) -> Set<Int> {
        if awaitsFrame, let count = defaults.plannedCaptureCount { return Set(1...count) }
        if let count = pendingSelectionCount { return Set(1...count) }
        return snapshot.requiredIndices
    }

    public init(id: String = IDFactory.new(), status: SessionStatus = .inProgress,
                activeFrameSnapshotID: String, requiredCaptureCount: Int,
                currentCaptureIndex: Int = 1, captureMode: CaptureMode,
                cameraID: String? = nil, defaults: SessionDefaultsSnapshot,
                revisionNo: Int = 1, createdAtMs: Int64 = Time.nowMs(),
                updatedAtMs: Int64 = Time.nowMs(), completedAtMs: Int64? = nil,
                frameNameAtCapture: String? = nil,
                countdownSeconds: Int = 3, intermissionSeconds: Int = 2) {
        self.id = id; self.status = status
        self.activeFrameSnapshotID = activeFrameSnapshotID
        self.requiredCaptureCount = requiredCaptureCount
        self.currentCaptureIndex = currentCaptureIndex
        self.captureMode = captureMode
        self.cameraID = cameraID
        self.defaults = defaults
        self.revisionNo = revisionNo
        self.createdAtMs = createdAtMs; self.updatedAtMs = updatedAtMs
        self.completedAtMs = completedAtMs
        self.frameNameAtCapture = frameNameAtCapture
        self.countdownSeconds = countdownSeconds
        self.intermissionSeconds = intermissionSeconds
    }
}

public struct SessionShot: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var sessionID: String
    public var captureIndex: Int
    public var currentPhotoRevisionID: String?

    public init(id: String = IDFactory.new(), sessionID: String, captureIndex: Int, currentPhotoRevisionID: String? = nil) {
        self.id = id; self.sessionID = sessionID
        self.captureIndex = captureIndex; self.currentPhotoRevisionID = currentPhotoRevisionID
    }
}

public struct PhotoRevision: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var shotID: String
    public var revisionNo: Int
    public var relativePath: String
    public var sha256: String
    public var width: Int
    public var height: Int
    public var orientation: Int
    public var codec: String
    public var colorProfile: String?
    public var captureRequestID: String
    public var capturedAtMs: Int64
    public var state: PhotoRevisionState

    public init(id: String = IDFactory.new(), shotID: String, revisionNo: Int,
                relativePath: String, sha256: String, width: Int, height: Int,
                orientation: Int = 1, codec: String = "jpeg", colorProfile: String? = nil,
                captureRequestID: String, capturedAtMs: Int64 = Time.nowMs(),
                state: PhotoRevisionState = .available) {
        self.id = id; self.shotID = shotID; self.revisionNo = revisionNo
        self.relativePath = relativePath; self.sha256 = sha256
        self.width = width; self.height = height; self.orientation = orientation
        self.codec = codec; self.colorProfile = colorProfile
        self.captureRequestID = captureRequestID; self.capturedAtMs = capturedAtMs
        self.state = state
    }
}

/// Vị trí đặt ảnh cho một snapshot slot (§9.2 — một slot snapshot, dù share ảnh với slot khác).
public struct SlotPlacement: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var sessionID: String
    public var frameSnapshotID: String
    public var snapshotSlotID: String
    public var cropMode: CropMode
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var manualOverride: Bool
    public var updatedAtMs: Int64

    public init(id: String = IDFactory.new(), sessionID: String, frameSnapshotID: String,
                snapshotSlotID: String, cropMode: CropMode, scale: Double = 1,
                offsetX: Double = 0, offsetY: Double = 0, manualOverride: Bool = false,
                updatedAtMs: Int64 = Time.nowMs()) {
        self.id = id; self.sessionID = sessionID; self.frameSnapshotID = frameSnapshotID
        self.snapshotSlotID = snapshotSlotID
        self.cropMode = cropMode; self.scale = scale
        self.offsetX = offsetX; self.offsetY = offsetY
        self.manualOverride = manualOverride; self.updatedAtMs = updatedAtMs
    }

    public var placement: PhotoPlacement {
        PhotoPlacement(scale: scale, offsetX: offsetX, offsetY: offsetY)
    }
}

// MARK: - Kết quả tổng hợp cho Review/Render

public struct SessionDetail: Equatable, Sendable {
    public var session: CaptureSessionRecord
    public var snapshot: FrameSnapshot
    public var shots: [SessionShot]
    public var photoRevisions: [String: [PhotoRevision]] // shotID -> revisions (theo revisionNo tăng dần)
    public var overrides: [Int: PhotoOverride]           // captureIndex -> override của current revision
    public var placements: [String: SlotPlacement]       // snapshotSlotID -> placement

    public init(session: CaptureSessionRecord, snapshot: FrameSnapshot, shots: [SessionShot],
                photoRevisions: [String: [PhotoRevision]], overrides: [Int: PhotoOverride],
                placements: [String: SlotPlacement]) {
        self.session = session; self.snapshot = snapshot; self.shots = shots
        self.photoRevisions = photoRevisions; self.overrides = overrides
        self.placements = placements
    }

    /// Ảnh nguồn đang dùng theo capture index (chỉ những lượt đã chụp).
    public func currentRevisions(includeUnassigned: Bool = false) -> [Int: PhotoRevision] {
        var result: [Int: PhotoRevision] = [:]
        let selected = includeUnassigned ? nil : session.defaults.selectedCaptureOrder.map(Set.init)
        for shot in shots {
            if let selected, !selected.contains(shot.captureIndex) { continue }
            guard let revID = shot.currentPhotoRevisionID,
                  let revs = photoRevisions[shot.id],
                  let rev = revs.first(where: { $0.id == revID }) else { continue }
            result[shot.captureIndex] = rev
        }
        return result
    }

    /// Các chỉ số ảnh đã chụp và thuộc snapshot hiện hành (A5).
    public var availableIndicesForSnapshot: Set<Int> {
        Set(currentRevisions().filter { $0.value.state == .available }.keys)
            .intersection(session.captureIndices(in: snapshot))
    }

    public var committedCount: Int { availableIndicesForSnapshot.count }
    public var missingIndices: Set<Int> { session.captureIndices(in: snapshot).subtracting(availableIndicesForSnapshot) }
    public var missingCount: Int { missingIndices.count }
    public var needsPhotoSelection: Bool { session.pendingSelectionCount != nil && missingIndices.isEmpty }
    public var hasEnoughPhotos: Bool { !session.awaitsFrame && session.pendingSelectionCount == nil && missingIndices.isEmpty }
    public var nextPendingIndex: Int? { missingIndices.min() }
}

// MARK: - Trash

public struct TrashItem: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var rootType: TrashRootType
    public var rootID: String
    public var displayName: String
    public var deletedAtMs: Int64
    public var expiresAtMs: Int64
    public var originalParentID: String?
    public var estimatedBytes: Int64
    public var status: TrashStatus
    public var lastError: String?

    public init(id: String = IDFactory.new(), rootType: TrashRootType, rootID: String,
                displayName: String, deletedAtMs: Int64, expiresAtMs: Int64,
                originalParentID: String? = nil, estimatedBytes: Int64 = 0,
                status: TrashStatus = .trashed, lastError: String? = nil) {
        self.id = id; self.rootType = rootType; self.rootID = rootID
        self.displayName = displayName; self.deletedAtMs = deletedAtMs
        self.expiresAtMs = expiresAtMs; self.originalParentID = originalParentID
        self.estimatedBytes = estimatedBytes; self.status = status; self.lastError = lastError
    }
}

// MARK: - Export record

public struct ExportRecordModel: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var sessionID: String
    public var sessionRevisionNo: Int
    public var format: ExportImageFormat
    public var filename: String
    public var destinationDisplayPath: String?
    public var destinationBookmarkID: String?
    public var width: Int
    public var height: Int
    public var quality: Int?
    public var sha256: String?
    public var status: ExportStatus
    public var createdAtMs: Int64
    public var completedAtMs: Int64?

    public init(id: String = IDFactory.new(), sessionID: String, sessionRevisionNo: Int,
                format: ExportImageFormat, filename: String,
                destinationDisplayPath: String? = nil, destinationBookmarkID: String? = nil,
                width: Int, height: Int, quality: Int? = nil, sha256: String? = nil,
                status: ExportStatus = .preparing, createdAtMs: Int64 = Time.nowMs(),
                completedAtMs: Int64? = nil) {
        self.id = id; self.sessionID = sessionID; self.sessionRevisionNo = sessionRevisionNo
        self.format = format; self.filename = filename
        self.destinationDisplayPath = destinationDisplayPath
        self.destinationBookmarkID = destinationBookmarkID
        self.width = width; self.height = height; self.quality = quality
        self.sha256 = sha256; self.status = status
        self.createdAtMs = createdAtMs; self.completedAtMs = completedAtMs
    }
}

// MARK: - Category

public struct Category: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var sortOrder: Int
    public var createdAtMs: Int64
    public var updatedAtMs: Int64
    public var lifecycle: FrameLifecycle

    public init(id: String = IDFactory.new(), name: String, sortOrder: Int = 0,
                createdAtMs: Int64 = Time.nowMs(), updatedAtMs: Int64 = Time.nowMs(),
                lifecycle: FrameLifecycle = .active) {
        self.id = id; self.name = name; self.sortOrder = sortOrder
        self.createdAtMs = createdAtMs; self.updatedAtMs = updatedAtMs
        self.lifecycle = lifecycle
    }
}

public struct PresetRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var isSystem: Bool
    public var parameters: ColorParameterSet
    public var parameterVersion: Int
    public var lifecycle: FrameLifecycle
    public var createdAtMs: Int64
    public var updatedAtMs: Int64

    public init(id: String = IDFactory.new(), name: String, isSystem: Bool,
                parameters: ColorParameterSet, parameterVersion: Int = 1,
                lifecycle: FrameLifecycle = .active,
                createdAtMs: Int64 = Time.nowMs(), updatedAtMs: Int64 = Time.nowMs()) {
        self.id = id; self.name = name; self.isSystem = isSystem
        self.parameters = parameters; self.parameterVersion = parameterVersion
        self.lifecycle = lifecycle; self.createdAtMs = createdAtMs; self.updatedAtMs = updatedAtMs
    }
}

public struct OperationIntentRecord: Equatable, Codable, Sendable {
    public var id: String
    public var opType: String
    public var rootID: String
    public var payloadJSON: String
    public var status: OperationStatus
    public var createdAtMs: Int64
    public var updatedAtMs: Int64
    public var lastError: String?
}
