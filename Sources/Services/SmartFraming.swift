import Foundation
import CoreGraphics

/// Smart Face Positioning (§9.1): tính PhotoPlacementProposal từ face observations.
/// 1.2 không xây dựng identity/tracking database.
public struct PhotoPlacementProposal: Equatable, Sendable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var fitMode: CropMode
    public var confidence: Double
    public var reason: String

    public init(scale: Double, offsetX: Double, offsetY: Double, fitMode: CropMode,
                confidence: Double, reason: String) {
        self.scale = scale; self.offsetX = offsetX; self.offsetY = offsetY
        self.fitMode = fitMode; self.confidence = confidence; self.reason = reason
    }
}

public enum SmartFraming {
    public static let confidenceThreshold: Double = 0.5
    public static let groupMargin: Double = 0.15          // 12–20% group bounds (§9.1)
    public static let eyeLineTarget: Double = 0.40        // 35–45% chiều cao slot

    /// Đề xuất placement cho một slot.
    /// - faces: normalized top-left theo ảnh nguồn (W,H ảnh nguồn).
    public static func propose(sourceWidth: Double, sourceHeight: Double,
                               slotWidth: Double, slotHeight: Double,
                               faces: [FaceBox],
                               userManualOverride: Bool,
                               defaultMode: CropMode) -> PhotoPlacementProposal {
        // (c) user đã manual crop → không auto ghi đè
        if userManualOverride {
            return PhotoPlacementProposal(scale: 1, offsetX: 0, offsetY: 0, fitMode: .fill,
                                          confidence: 1, reason: "Giữ chỉnh thủ công")
        }
        let active = faces.filter { $0.confidence >= confidenceThreshold }
        guard !active.isEmpty else {
            // (a) không mặt → Fill center
            return PhotoPlacementProposal(scale: 1, offsetX: 0, offsetY: 0,
                                          fitMode: defaultMode == .fit ? .fit : .fill,
                                          confidence: 0,
                                          reason: "Không tìm thấy khuôn mặt — căn giữa")
        }

        // Group bounds (normalized theo ảnh nguồn, top-left)
        let minX = active.map(\.x).min()!
        let minY = active.map(\.y).min()!
        let maxX = active.map { $0.x + $0.width }.max()!
        let maxY = active.map { $0.y + $0.height }.max()!
        let groupW = max(maxX - minX, 0.01)
        let groupH = max(maxY - minY, 0.01)
        let marginX = groupW * groupMargin
        let marginY = groupH * groupMargin
        let padX = max(0, minX - marginX)
        let padY = max(0, minY - marginY)
        let padW = min(groupW + marginX * 2, 1.0 - padX)
        let padH = min(groupH + marginY * 2, 1.0 - padY)
        let groupCX = padX + padW / 2
        let groupCY = padY + padH / 2

        let baseFill = SlotGeometry.baseScale(sourceWidth: CGFloat(sourceWidth), sourceHeight: CGFloat(sourceHeight),
                                              slotWidth: CGFloat(slotWidth), slotHeight: CGFloat(slotHeight),
                                              cropMode: .fill)
        // Nhóm (kèm margin) phải nằm trọn trong slot khi Fill:
        // chiều rộng nhóm chiếm slot = padW * sourceW * baseFill*scale / slotW ≤ 1
        let needScaleX = slotWidth / (padW * sourceWidth * Double(baseFill))
        let needScaleY = slotHeight / (padH * sourceHeight * Double(baseFill))
        let fitScale = min(needScaleX, needScaleY)

        if fitScale >= 1 {
            // Nhóm vừa trong Fill → căn group center về tâm slot (Y ưu tiên eye-line với 1 mặt)
            let drawnW = sourceWidth * Double(baseFill)
            let drawnH = sourceHeight * Double(baseFill)
            let targetY: Double = active.count == 1 ? eyeLineTarget : 0.5
            var offsetX = (0.5 - groupCX) * drawnW / slotWidth
            var offsetY = (targetY - groupCY) * drawnH / slotHeight
            let p = SlotGeometry.clampPlacement(sourceWidth: CGFloat(sourceWidth), sourceHeight: CGFloat(sourceHeight),
                                                slotWidth: CGFloat(slotWidth), slotHeight: CGFloat(slotHeight),
                                                cropMode: .fill,
                                                placement: PhotoPlacement(scale: 1, offsetX: offsetX, offsetY: offsetY))
            offsetX = p.offsetX; offsetY = p.offsetY
            return PhotoPlacementProposal(scale: 1, offsetX: offsetX, offsetY: offsetY, fitMode: .fill,
                                          confidence: active.map(\.confidence).min() ?? 0,
                                          reason: active.count == 1
                                            ? "1 khuôn mặt — ưu tiên eye-line \(Int(eyeLineTarget * 100))%"
                                            : "Nhóm \(active.count) khuôn mặt — Fill")
        }

        // (b) ≥2 mặt không thể giữ toàn bộ bằng Fill → Fit
        if active.count >= 2 {
            return PhotoPlacementProposal(scale: 1, offsetX: 0, offsetY: 0, fitMode: .fit,
                                          confidence: active.map(\.confidence).min() ?? 0,
                                          reason: "Không thể giữ đủ \(active.count) khuôn mặt ở Fill — đề xuất Fit")
        }

        // 1 mặt hơi to: Fill nhưng cho crop nhẹ (giữ mặt, ưu tiên không cắt người)
        let drawnW = sourceWidth * Double(baseFill)
        let drawnH = sourceHeight * Double(baseFill)
        var offsetX = (0.5 - groupCX) * drawnW / slotWidth
        var offsetY = (eyeLineTarget - groupCY) * drawnH / slotHeight
        let p = SlotGeometry.clampPlacement(sourceWidth: CGFloat(sourceWidth), sourceHeight: CGFloat(sourceHeight),
                                            slotWidth: CGFloat(slotWidth), slotHeight: CGFloat(slotHeight),
                                            cropMode: .fill,
                                            placement: PhotoPlacement(scale: 1, offsetX: offsetX, offsetY: offsetY))
        offsetX = p.offsetX; offsetY = p.offsetY
        return PhotoPlacementProposal(scale: 1, offsetX: offsetX, offsetY: offsetY, fitMode: .fill,
                                      confidence: (active.map(\.confidence).min() ?? 0) * fitScale,
                                      reason: "1 khuôn mặt — Fill ưu tiên eye-line")
    }
}
