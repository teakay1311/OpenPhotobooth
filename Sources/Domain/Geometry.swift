import Foundation
import CoreGraphics

/// Hình học canvas/slot theo §7.1: tọa độ normalized, origin (0,0) = góc trên trái,
/// X tăng sang phải, Y tăng xuống, rotation độ clockwise quanh tâm slot.
public struct RectN: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }
    public var isPositive: Bool { width > 0 && height > 0 }

    public func pixelRect(canvasWidth: Int, canvasHeight: Int) -> CGRect {
        CGRect(x: x * Double(canvasWidth), y: y * Double(canvasHeight),
               width: width * Double(canvasWidth), height: height * Double(canvasHeight))
    }
}

public enum FrameGeometry {
    /// Bounding box pixel sau khi quay quanh tâm slot. Dùng cho validator F-VAL-05 và hit-test.
    public static func rotatedPixelBounds(_ r: RectN, rotationDegrees: Double, canvasWidth: Int, canvasHeight: Int) -> CGRect {
        let px = r.pixelRect(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        return rotatedBounds(of: px, degrees: rotationDegrees)
    }

    public static func rotatedBounds(of rect: CGRect, degrees: Double) -> CGRect {
        guard degrees.truncatingRemainder(dividingBy: 360) != 0 else { return rect }
        let radians = degrees * Double.pi / 180
        let cos = CGFloat(abs(cos(radians))), sin = CGFloat(abs(sin(radians)))
        let w = rect.width * cos + rect.height * sin
        let h = rect.width * sin + rect.height * cos
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Slot hợp lệ khi rotated bbox nằm trong canvas (F-VAL-05).
    public static func isSlotInsideCanvas(_ r: RectN, rotationDegrees: Double, canvasWidth: Int, canvasHeight: Int) -> Bool {
        let b = rotatedPixelBounds(r, rotationDegrees: rotationDegrees, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        return b.minX >= -0.5 && b.minY >= -0.5 &&
               b.maxX <= Double(canvasWidth) + 0.5 && b.maxY <= Double(canvasHeight) + 0.5
    }

    public static func containsPixel(_ r: RectN, rotationDegrees: Double, canvasWidth: Int, canvasHeight: Int, point: CGPoint) -> Bool {
        let px = r.pixelRect(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let center = CGPoint(x: px.midX, y: px.midY)
        let radians = rotationDegrees * Double.pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        let c = cos(-radians), s = sin(-radians)
        let local = CGPoint(x: dx * CGFloat(c) - dy * CGFloat(s), y: dx * CGFloat(s) + dy * CGFloat(c))
        return CGRect(x: -px.width / 2, y: -px.height / 2, width: px.width, height: px.height).contains(local)
    }
}

// MARK: - Đặt ảnh trong slot (§7.3)

/// Placement của ảnh nguồn trong slot, tính ra và lưu (crop mode auto_face cũng lưu placement).
/// scale: bội so với scale cơ bản của crop mode; offsetX/Y: normalized theo kích thước slot (0 = giữa).
public struct PhotoPlacement: Codable, Equatable, Sendable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(scale: Double = 1.0, offsetX: Double = 0.0, offsetY: Double = 0.0) {
        self.scale = scale; self.offsetX = offsetX; self.offsetY = offsetY
    }
}

public enum SlotGeometry {
    /// Điểm quy đổi: tỉ lệ giữa ảnh nguồn và slot pixel cho từng crop mode.
    /// - Returns: (baseScale, có được phép offset không) — Fill không cho lộ vùng rỗng.
    public static func baseScale(sourceWidth: CGFloat, sourceHeight: CGFloat,
                                 slotWidth: CGFloat, slotHeight: CGFloat, cropMode: CropMode) -> CGFloat {
        switch cropMode {
        case .fill, .autoFace:
            return max(slotWidth / sourceWidth, slotHeight / sourceHeight)
        case .fit:
            return min(slotWidth / sourceWidth, slotHeight / sourceHeight)
        }
    }

    /// Clamp offset cho Fill để không lộ vùng rỗng (§7.3).
    public static func clampPlacement(sourceWidth: CGFloat, sourceHeight: CGFloat,
                                      slotWidth: CGFloat, slotHeight: CGFloat,
                                      cropMode: CropMode, placement: PhotoPlacement) -> PhotoPlacement {
        var p = placement
        guard sourceWidth > 0, sourceHeight > 0, slotWidth > 0, slotHeight > 0 else { return p }
        let base = baseScale(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                             slotWidth: slotWidth, slotHeight: slotHeight, cropMode: cropMode)
        p.scale = max(p.scale.isFinite ? p.scale : 1, 0.05)
        let drawnW = sourceWidth * base * CGFloat(p.scale)
        let drawnH = sourceHeight * base * CGFloat(p.scale)
        let freeX = max(0, (drawnW - slotWidth) / 2)
        let freeY = max(0, (drawnH - slotHeight) / 2)
        switch cropMode {
        case .fill, .autoFace:
            p.offsetX = min(max(p.offsetX, -freeX / slotWidth), freeX / slotWidth)
            p.offsetY = min(max(p.offsetY, -freeY / slotHeight), freeY / slotHeight)
        case .fit:
            p.offsetX = min(max(p.offsetX, -0.5), 0.5)
            p.offsetY = min(max(p.offsetY, -0.5), 0.5)
        }
        return p
    }

    /// Ma trận transform CIImage: scale theo placement rồi dịch offset.
    /// Ảnh nguồn được chuẩn hóa orientation trước khi gọi hàm này.
    public static func photoTransform(sourceWidth: CGFloat, sourceHeight: CGFloat,
                                      slotPixel: CGRect, cropMode: CropMode,
                                      placement: PhotoPlacement) -> (scale: CGFloat, translation: CGPoint) {
        let clamped = SlotGeometry.clampPlacement(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            slotWidth: slotPixel.width, slotHeight: slotPixel.height,
            cropMode: cropMode, placement: placement)
        let base = baseScale(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                             slotWidth: slotPixel.width, slotHeight: slotPixel.height, cropMode: cropMode)
        let s = base * CGFloat(clamped.scale)
        let drawnW = sourceWidth * s, drawnH = sourceHeight * s
        // Ảnh nguồn CI gốc có origin góc dưới trái; đặt tâm ảnh vào tâm slot + offset.
        let tx = slotPixel.midX - drawnW / 2 + CGFloat(clamped.offsetX) * slotPixel.width
        let ty = slotPixel.midY - drawnH / 2 + CGFloat(clamped.offsetY) * slotPixel.height
        return (s, CGPoint(x: tx, y: ty))
    }

    /// Radius pixel cho mask bo góc (cornerRadius normalized theo cạnh nhỏ canvas, clamp trong slot).
    public static func cornerRadiusPixels(_ cornerRadius: Double, slotPixel: CGRect, canvasWidth: Int, canvasHeight: Int) -> CGFloat {
        let raw = CGFloat(cornerRadius) * CGFloat(min(canvasWidth, canvasHeight))
        return min(raw, min(slotPixel.width, slotPixel.height) / 2)
    }
}
