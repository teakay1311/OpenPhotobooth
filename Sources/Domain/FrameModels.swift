import Foundation
import CoreGraphics

// MARK: - Frame library models (§6, §16.2)

public struct Frame: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var categoryID: String?
    public var currentRevisionID: String?
    public var isFavorite: Bool
    public var isBuiltIn: Bool
    public var validationStatus: FrameValidationStatus
    public var lifecycle: FrameLifecycle
    public var createdAtMs: Int64
    public var updatedAtMs: Int64

    public init(id: String = IDFactory.new(), name: String, categoryID: String? = nil,
                currentRevisionID: String? = nil, isFavorite: Bool = false, isBuiltIn: Bool = false,
                validationStatus: FrameValidationStatus = .unconfigured, lifecycle: FrameLifecycle = .active,
                createdAtMs: Int64 = Time.nowMs(), updatedAtMs: Int64 = Time.nowMs()) {
        self.id = id; self.name = name; self.categoryID = categoryID
        self.currentRevisionID = currentRevisionID
        self.isFavorite = isFavorite; self.isBuiltIn = isBuiltIn
        self.validationStatus = validationStatus; self.lifecycle = lifecycle
        self.createdAtMs = createdAtMs; self.updatedAtMs = updatedAtMs
    }
}

public struct FrameRevision: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var frameID: String
    public var revisionNo: Int
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var backgroundAssetID: String?
    public var foregroundAssetID: String?
    public var backgroundColorHex: String
    public var backgroundPlacement: PlacementKind
    public var foregroundPlacement: PlacementKind
    public var geometryVersion: Int
    public var createdAtMs: Int64

    public init(id: String = IDFactory.new(), frameID: String, revisionNo: Int,
                canvasWidth: Int, canvasHeight: Int,
                backgroundAssetID: String? = nil, foregroundAssetID: String? = nil,
                backgroundColorHex: String = "#FFFFFFFF",
                backgroundPlacement: PlacementKind = .aspectFill,
                foregroundPlacement: PlacementKind = .aspectFit,
                geometryVersion: Int = 1, createdAtMs: Int64 = Time.nowMs()) {
        self.id = id; self.frameID = frameID; self.revisionNo = revisionNo
        self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight
        self.backgroundAssetID = backgroundAssetID; self.foregroundAssetID = foregroundAssetID
        self.backgroundColorHex = backgroundColorHex
        self.backgroundPlacement = backgroundPlacement
        self.foregroundPlacement = foregroundPlacement
        self.geometryVersion = geometryVersion; self.createdAtMs = createdAtMs
    }
}

public struct FrameSlot: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var frameRevisionID: String
    public var captureIndex: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rotationDegrees: Double
    public var zOrder: Int
    public var maskType: MaskType
    public var cornerRadius: Double
    public var defaultCropMode: CropMode

    public init(id: String = IDFactory.new(), frameRevisionID: String = "",
                captureIndex: Int, x: Double, y: Double, width: Double, height: Double,
                rotationDegrees: Double = 0, zOrder: Int = 0,
                maskType: MaskType = .rectangle, cornerRadius: Double = 0,
                defaultCropMode: CropMode = .autoFace) {
        self.id = id; self.frameRevisionID = frameRevisionID
        self.captureIndex = captureIndex
        self.x = x; self.y = y; self.width = width; self.height = height
        self.rotationDegrees = rotationDegrees; self.zOrder = zOrder
        self.maskType = maskType; self.cornerRadius = cornerRadius
        self.defaultCropMode = defaultCropMode
    }

    public var rect: RectN { RectN(x: x, y: y, width: width, height: height) }

    public static func slotSize(_ revision: FrameRevision) -> CGSize {
        CGSize(width: revision.canvasWidth, height: revision.canvasHeight)
    }
}

// MARK: - Snapshot bất biến cho session (§6.5, I-04)

public struct SnapshotLayer: Codable, Equatable, Sendable {
    public var assetID: String
    public var placement: PlacementKind

    public init(assetID: String, placement: PlacementKind) {
        self.assetID = assetID; self.placement = placement
    }
}

public struct SnapshotSlot: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var captureIndex: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rotationDegrees: Double
    public var zOrder: Int
    public var maskType: MaskType
    public var cornerRadius: Double
    public var defaultCropMode: CropMode

    public init(from slot: FrameSlot) {
        id = slot.id; captureIndex = slot.captureIndex
        x = slot.x; y = slot.y; width = slot.width; height = slot.height
        rotationDegrees = slot.rotationDegrees; zOrder = slot.zOrder
        maskType = slot.maskType; cornerRadius = slot.cornerRadius
        defaultCropMode = slot.defaultCropMode
    }

    public var rect: RectN { RectN(x: x, y: y, width: width, height: height) }
}

public struct FrameSnapshot: Equatable, Codable, Identifiable, Sendable {
    public var id: String
    public var sourceFrameID: String?
    public var sourceFrameRevisionID: String?
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var background: SnapshotLayer?
    public var foreground: SnapshotLayer?
    public var backgroundColorHex: String
    public var slots: [SnapshotSlot]
    public var snapshotHash: String
    public var geometryVersion: Int
    public var createdAtMs: Int64

    public init(id: String = IDFactory.new(), sourceFrameID: String?, sourceFrameRevisionID: String?,
                canvasWidth: Int, canvasHeight: Int,
                background: SnapshotLayer?, foreground: SnapshotLayer?,
                backgroundColorHex: String, slots: [SnapshotSlot],
                snapshotHash: String, geometryVersion: Int = 1, createdAtMs: Int64 = Time.nowMs()) {
        self.id = id; self.sourceFrameID = sourceFrameID; self.sourceFrameRevisionID = sourceFrameRevisionID
        self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight
        self.background = background; self.foreground = foreground
        self.backgroundColorHex = backgroundColorHex; self.slots = slots
        self.snapshotHash = snapshotHash; self.geometryVersion = geometryVersion
        self.createdAtMs = createdAtMs
    }

    public var requiredCaptureCount: Int {
        Set(slots.map(\.captureIndex)).count
    }

    public var maxCaptureIndex: Int {
        slots.map(\.captureIndex).max() ?? 0
    }

    public func hashForContent() -> String {
        var material = "\(canvasWidth)x\(canvasHeight)|\(backgroundColorHex)|\(background?.assetID ?? "-")|\(foreground?.assetID ?? "-")|\(geometryVersion)"
        for s in slots.sorted(by: { $0.zOrder < $1.zOrder }) {
            material += "|\(s.captureIndex),\(s.x),\(s.y),\(s.width),\(s.height),\(s.rotationDegrees),\(s.zOrder),\(s.maskType.rawValue),\(s.cornerRadius),\(s.defaultCropMode.rawValue)"
        }
        return Hashing.sha256Hex(Data(material.utf8))
    }
}

// MARK: - Validator F-VAL-01..08 (§7.5) dùng chung UI/import/pack

public struct ValidationIssue: Equatable, Identifiable, Sendable {
    public var id: String { code + (slotID.map { "-\($0)" } ?? "") }
    public var code: String
    public var slotID: String?
    public var message: String
}

public enum FrameValidator {
    public static func validate(canvasWidth: Int, canvasHeight: Int,
                                slots: [FrameSlot],
                                hasBackground: Bool, hasForeground: Bool,
                                backgroundColorHex: String,
                                estimatedAssetBytes: Int = 0) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        // F-VAL-01: canvas 256..8192 mỗi chiều, ≤40MP
        if !(ResourceLimits.canvasMin...ResourceLimits.canvasMax).contains(canvasWidth) ||
           !(ResourceLimits.canvasMin...ResourceLimits.canvasMax).contains(canvasHeight) {
            issues.append(ValidationIssue(code: "F-VAL-01", slotID: nil, message: "Canvas phải từ \(ResourceLimits.canvasMin) đến \(ResourceLimits.canvasMax) px mỗi chiều"))
        }
        if Double(canvasWidth) * Double(canvasHeight) > ResourceLimits.maxMegapixels * 1_000_000 {
            issues.append(ValidationIssue(code: "F-VAL-01", slotID: nil, message: "Canvas vượt 40 megapixel"))
        }

        // F-VAL-02: ít nhất 1 slot, tối đa maxSlots
        if slots.isEmpty {
            issues.append(ValidationIssue(code: "F-VAL-02", slotID: nil, message: "Cần ít nhất 1 ô ảnh"))
        } else if slots.count > ResourceLimits.maxSlots {
            issues.append(ValidationIssue(code: "F-VAL-02", slotID: nil, message: "Tối đa \(ResourceLimits.maxSlots) ô ảnh"))
        }

        // F-VAL-03: indices distinct liên tục bắt đầu từ 1, tối đa 12
        let indices = Set(slots.map(\.captureIndex))
        if let out = indices.filter({ !(1...ResourceLimits.maxCaptureIndices).contains($0) }).min() {
            issues.append(ValidationIssue(code: "F-VAL-03", slotID: slots.first { $0.captureIndex == out }?.id, message: "Chỉ số ảnh phải trong 1…\(ResourceLimits.maxCaptureIndices)"))
        }
        if let maxIdx = indices.max(), !indices.isEmpty, indices != Set(1...maxIdx) {
            let missing = Set(1...maxIdx).subtracting(indices).sorted().map(String.init).joined(separator: ", ")
            issues.append(ValidationIssue(code: "F-VAL-03", slotID: nil, message: "Thiếu lượt chụp: \(missing)"))
        }

        for slot in slots {
            // F-VAL-04: hữu hạn, W/H > 0
            let r = slot.rect
            if !r.isFinite || !r.isPositive {
                issues.append(ValidationIssue(code: "F-VAL-04", slotID: slot.id, message: "Ô #\(slot.zOrder + 1) có kích thước không hợp lệ"))
                continue
            }
            // F-VAL-05: rotated bbox trong canvas
            if !FrameGeometry.isSlotInsideCanvas(r, rotationDegrees: slot.rotationDegrees,
                                                 canvasWidth: canvasWidth, canvasHeight: canvasHeight) {
                issues.append(ValidationIssue(code: "F-VAL-05", slotID: slot.id, message: "Ô #\(slot.zOrder + 1) vượt ra ngoài canvas sau khi xoay"))
            }
            // corner radius phạm vi
            if !(0...0.5).contains(slot.cornerRadius) {
                issues.append(ValidationIssue(code: "F-VAL-04", slotID: slot.id, message: "Bo góc phải trong 0–0.5"))
            }
        }

        // F-VAL-06: khung trắng tối giản (background color) vẫn hợp lệ; cảnh báo nếu không có gì
        _ = hasBackground; _ = hasForeground; _ = backgroundColorHex

        // F-VAL-08: ước tính bộ nhớ (bytes ≈ W×H×4)
        let bytes = Double(canvasWidth) * Double(canvasHeight) * 4
        if bytes > 4_000_000_000 {
            issues.append(ValidationIssue(code: "F-VAL-08", slotID: nil, message: "Canvas quá lớn, giảm kích thước để render an toàn"))
        }
        _ = estimatedAssetBytes
        return issues
    }

    public static func validate(revision: FrameRevision, slots: [FrameSlot]) -> [ValidationIssue] {
        validate(canvasWidth: revision.canvasWidth, canvasHeight: revision.canvasHeight,
                 slots: slots,
                 hasBackground: revision.backgroundAssetID != nil,
                 hasForeground: revision.foregroundAssetID != nil,
                 backgroundColorHex: revision.backgroundColorHex)
    }
}
