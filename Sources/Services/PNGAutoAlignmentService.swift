import Foundation
import CoreGraphics
import CoreImage
import AppKit

public enum FrameImportLayoutKind: String, CaseIterable, Identifiable {
    case grid2x2 = "Lưới 4 (2×2)"
    case strip1x4 = "Dải dọc 4 (1×4)"

    public var id: String { rawValue }
    public var slotCount: Int { 4 }
}

public struct SlotRect: Equatable {
    public var x: Double // 0...1 relative to canvas
    public var y: Double // 0...1 relative to canvas
    public var width: Double // 0...1 relative to canvas
    public var height: Double // 0...1 relative to canvas

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2.0 }
    public var centerY: Double { y + height / 2.0 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func intersects(_ other: SlotRect) -> Bool {
        return !(x >= other.maxX || maxX <= other.x || y >= other.maxY || maxY <= other.y)
    }
}

public struct AutoAlignmentResult: Equatable {
    public let slots: [SlotRect]
    public let isAutoAligned: Bool
    public let requiresInspection: Bool
    public let inspectionReason: String?
    public let blockedSlotIndices: [Int] // 1-based indices of slots blocked by opaque overlay

    public init(slots: [SlotRect], isAutoAligned: Bool, requiresInspection: Bool, inspectionReason: String?, blockedSlotIndices: [Int]) {
        self.slots = slots
        self.isAutoAligned = isAutoAligned
        self.requiresInspection = requiresInspection
        self.inspectionReason = inspectionReason
        self.blockedSlotIndices = blockedSlotIndices
    }
}

public enum PNGAutoAlignmentService {

    public static func defaultSlots(for layout: FrameImportLayoutKind) -> [SlotRect] {
        switch layout {
        case .grid2x2:
            return [
                SlotRect(x: 0.10, y: 0.10, width: 0.38, height: 0.38),
                SlotRect(x: 0.52, y: 0.10, width: 0.38, height: 0.38),
                SlotRect(x: 0.10, y: 0.52, width: 0.38, height: 0.38),
                SlotRect(x: 0.52, y: 0.52, width: 0.38, height: 0.38)
            ]
        case .strip1x4:
            return [
                SlotRect(x: 0.125, y: 0.05, width: 0.75, height: 0.20),
                SlotRect(x: 0.125, y: 0.28, width: 0.75, height: 0.20),
                SlotRect(x: 0.125, y: 0.51, width: 0.75, height: 0.20),
                SlotRect(x: 0.125, y: 0.74, width: 0.75, height: 0.20)
            ]
        }
    }

    /// Phân tích tự căn ô cho ảnh PNG/JPG (§4.2).
    public static func align(image: CGImage, hasAlpha: Bool, layout: FrameImportLayoutKind) -> AutoAlignmentResult {
        align(alpha: hasAlpha ? AlphaGrid(image: image) : nil, layout: layout)
    }

    struct AlphaGrid {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        private let visible: [Bool]
        let hasTransparency: Bool

        init?(image: CGImage) {
            let scale = min(1, 1024 / Double(max(image.width, image.height)))
            let width = max(1, Int(Double(image.width) * scale))
            let height = max(1, Int(Double(image.height) * scale))
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let alpha: [UInt8]? = buffer.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                // Bitmap memory is already in top-to-bottom row order.
                return (0..<(width * height)).map { raw[$0 * 4 + 3] }
            }
            guard let alpha else { return nil }
            self.width = width
            self.height = height
            pixels = alpha
            let visibility = alpha.map { $0 < 255 }
            visible = visibility
            hasTransparency = visibility.contains(true)
        }

        func blockedSlots(_ slots: [SlotRect]) -> [Int] {
            PNGAutoAlignmentService.checkBlockedSlots(slots: slots, grid: visible,
                                                      width: width, height: height)
        }
    }

    static func blockedSlots(overlay: CGImage, draft: FrameRevision, slots: [FrameSlot]) throws -> [Int] {
        let scale = min(1, 1024.0 / Double(max(draft.canvasWidth, draft.canvasHeight)))
        let width = max(1, Int((Double(draft.canvasWidth) * scale).rounded()))
        let height = max(1, Int((Double(draft.canvasHeight) * scale).rounded()))
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        guard let layer = CompositeRenderer.placeLayer(CIImage(cgImage: overlay),
                                                       canvasWidth: width, canvasHeight: height,
                                                       placement: draft.foregroundPlacement),
              let image = CIContextHolder.shared.context.createCGImage(layer, from: canvas),
              let alpha = AlphaGrid(image: image) else { throw AppError.frameFileCorrupt }
        let bounds = slots.map { slot in
            let rect = FrameGeometry.rotatedPixelBounds(slot.rect, rotationDegrees: slot.rotationDegrees,
                                                        canvasWidth: width, canvasHeight: height)
            return SlotRect(x: rect.minX / Double(width), y: rect.minY / Double(height),
                            width: rect.width / Double(width), height: rect.height / Double(height))
        }
        return alpha.blockedSlots(bounds)
    }

    static func align(alpha: AlphaGrid?, layout: FrameImportLayoutKind) -> AutoAlignmentResult {
        let defaults = defaultSlots(for: layout)
        guard let alpha, alpha.hasTransparency else {
            return AutoAlignmentResult(slots: defaults, isAutoAligned: false, requiresInspection: false,
                                       inspectionReason: nil, blockedSlotIndices: [])
        }
        let targetW = alpha.width
        let targetH = alpha.height
        let transparentGrid = alpha.pixels.map { $0 <= 32 }

        // Nối theo 4 hướng, bỏ vùng chạm mép và vùng chiếm dưới 1% diện tích canvas (§4.2)
        var visited = [Bool](repeating: false, count: targetW * targetH)
        var components: [(minX: Int, maxX: Int, minY: Int, maxY: Int, area: Int)] = []
        let minArea = Int(ceil(0.01 * Double(targetW * targetH)))

        for y in 0..<targetH {
            for x in 0..<targetW {
                let idx = y * targetW + x
                if transparentGrid[idx] && !visited[idx] {
                    // BFS 4-way
                    var q = [idx]
                    visited[idx] = true
                    var head = 0
                    var area = 0
                    var minX = x, maxX = x
                    var minY = y, maxY = y
                    var touchesBorder = false

                    while head < q.count {
                        let cur = q[head]
                        head += 1
                        area += 1
                        let cx = cur % targetW
                        let cy = cur / targetW

                        if cx == 0 || cx == targetW - 1 || cy == 0 || cy == targetH - 1 {
                            touchesBorder = true
                        }
                        if cx < minX { minX = cx }
                        if cx > maxX { maxX = cx }
                        if cy < minY { minY = cy }
                        if cy > maxY { maxY = cy }

                        let neighbors = [
                            (cx - 1, cy), (cx + 1, cy),
                            (cx, cy - 1), (cx, cy + 1)
                        ]
                        for (nx, ny) in neighbors {
                            if nx >= 0 && nx < targetW && ny >= 0 && ny < targetH {
                                let nIdx = ny * targetW + nx
                                if transparentGrid[nIdx] && !visited[nIdx] {
                                    visited[nIdx] = true
                                    q.append(nIdx)
                                }
                            }
                        }
                    }

                    if !touchesBorder && area >= minArea {
                        components.append((minX: minX, maxX: maxX, minY: minY, maxY: maxY, area: area))
                    }
                }
            }
        }

        // Chỉ tự căn khi số vùng còn lại đúng số ô (4 ô) (§4.2)
        guard components.count == 4 else {
            let reason = components.count < 4
                ? "Thiếu vùng trong suốt (tìm thấy \(components.count)/4 vùng)"
                : "Thừa vùng trong suốt (tìm thấy \(components.count)/4 vùng)"
            let blocked = alpha.blockedSlots(defaults)
            return AutoAlignmentResult(
                slots: defaults,
                isAutoAligned: false,
                requiresInspection: true,
                inspectionReason: reason,
                blockedSlotIndices: blocked
            )
        }

        // Kiểm tra hình bao không chồng nhau và vùng trong suốt chiếm >= 75% diện tích hình bao (§4.2)
        var normSlots: [SlotRect] = []
        for c in components {
            let bw = c.maxX - c.minX + 1
            let bh = c.maxY - c.minY + 1
            let bboxArea = bw * bh
            let density = Double(c.area) / Double(bboxArea)
            if density < 0.75 {
                let blocked = alpha.blockedSlots(defaults)
                return AutoAlignmentResult(
                    slots: defaults,
                    isAutoAligned: false,
                    requiresInspection: true,
                    inspectionReason: "Vùng trong suốt không phủ kín ô (mật độ < 75%)",
                    blockedSlotIndices: blocked
                )
            }
            normSlots.append(SlotRect(
                x: Double(c.minX) / Double(targetW),
                y: Double(c.minY) / Double(targetH),
                width: Double(bw) / Double(targetW),
                height: Double(bh) / Double(targetH)
            ))
        }

        for i in 0..<normSlots.count {
            for j in (i + 1)..<normSlots.count {
                if normSlots[i].intersects(normSlots[j]) {
                    let blocked = alpha.blockedSlots(defaults)
                    return AutoAlignmentResult(
                        slots: defaults,
                        isAutoAligned: false,
                        requiresInspection: true,
                        inspectionReason: "Các ô bị chồng lấn nhau",
                        blockedSlotIndices: blocked
                    )
                }
            }
        }

        // Ràng buộc hình học theo bố cục (§4.2)
        switch layout {
        case .grid2x2:
            // Sắp theo tâm dọc thành hai hàng hai ô
            let sortedByY = normSlots.sorted { $0.centerY < $1.centerY }
            var row1 = [sortedByY[0], sortedByY[1]]
            var row2 = [sortedByY[2], sortedByY[3]]

            // Trong mỗi hàng, chênh lệch tâm dọc tối đa 10% chiều cao canvas
            if abs(row1[0].centerY - row1[1].centerY) > 0.10 ||
               abs(row2[0].centerY - row2[1].centerY) > 0.10 {
                let blocked = alpha.blockedSlots(defaults)
                return AutoAlignmentResult(
                    slots: defaults,
                    isAutoAligned: false,
                    requiresInspection: true,
                    inspectionReason: "Hai ô trong cùng hàng lệch tâm dọc > 10%",
                    blockedSlotIndices: blocked
                )
            }

            // Sắp mỗi hàng từ trái sang phải
            row1.sort { $0.centerX < $1.centerX }
            row2.sort { $0.centerX < $1.centerX }

            // Trong mỗi cột, chênh lệch tâm ngang tối đa 10% chiều rộng canvas
            let col1 = [row1[0], row2[0]]
            let col2 = [row1[1], row2[1]]

            if abs(col1[0].centerX - col1[1].centerX) > 0.10 ||
               abs(col2[0].centerX - col2[1].centerX) > 0.10 {
                let blocked = alpha.blockedSlots(defaults)
                return AutoAlignmentResult(
                    slots: defaults,
                    isAutoAligned: false,
                    requiresInspection: true,
                    inspectionReason: "Hai ô trong cùng cột lệch tâm ngang > 10%",
                    blockedSlotIndices: blocked
                )
            }

            // Tâm hai hàng và hai cột phải tách biệt lần lượt ít nhất 15%
            let avgRow1Y = (row1[0].centerY + row1[1].centerY) / 2.0
            let avgRow2Y = (row2[0].centerY + row2[1].centerY) / 2.0
            let avgCol1X = (col1[0].centerX + col1[1].centerX) / 2.0
            let avgCol2X = (col2[0].centerX + col2[1].centerX) / 2.0

            if (avgRow2Y - avgRow1Y) < 0.15 || (avgCol2X - avgCol1X) < 0.15 {
                let blocked = alpha.blockedSlots(defaults)
                return AutoAlignmentResult(
                    slots: defaults,
                    isAutoAligned: false,
                    requiresInspection: true,
                    inspectionReason: "Khoảng cách giữa các hàng hoặc cột < 15%",
                    blockedSlotIndices: blocked
                )
            }

            let ordered2x2 = [row1[0], row1[1], row2[0], row2[1]]
            let blocked = alpha.blockedSlots(ordered2x2)
            return AutoAlignmentResult(
                slots: ordered2x2,
                isAutoAligned: true,
                requiresInspection: false,
                inspectionReason: nil,
                blockedSlotIndices: blocked
            )

        case .strip1x4:
            // Sắp theo tâm dọc từ trên xuống
            let sortedByY = normSlots.sorted { $0.centerY < $1.centerY }

            // Hai tâm liên tiếp cách nhau ít nhất 10% chiều cao
            for i in 0..<3 {
                if (sortedByY[i + 1].centerY - sortedByY[i].centerY) < 0.10 {
                    let blocked = alpha.blockedSlots(defaults)
                    return AutoAlignmentResult(
                        slots: defaults,
                        isAutoAligned: false,
                        requiresInspection: true,
                        inspectionReason: "Khoảng cách giữa hai ô liên tiếp < 10%",
                        blockedSlotIndices: blocked
                    )
                }
            }

            // Bốn hình bao có một khoảng ngang giao nhau
            let maxMinX = sortedByY.map(\.x).max() ?? 0
            let minMaxX = sortedByY.map(\.maxX).min() ?? 1
            if maxMinX >= minMaxX {
                let blocked = alpha.blockedSlots(defaults)
                return AutoAlignmentResult(
                    slots: defaults,
                    isAutoAligned: false,
                    requiresInspection: true,
                    inspectionReason: "Bốn ô không cùng chung dải ngang giao nhau",
                    blockedSlotIndices: blocked
                )
            }

            let blocked = alpha.blockedSlots(sortedByY)
            return AutoAlignmentResult(
                slots: sortedByY,
                isAutoAligned: true,
                requiresInspection: false,
                inspectionReason: nil,
                blockedSlotIndices: blocked
            )
        }
    }

    /// Kiểm tra lớp phủ che kín ô: nếu mọi pixel trong một ô đều đục (§4.1, §4.2)
    public static func checkBlockedSlots(slots: [SlotRect], grid: [Bool], width: Int, height: Int) -> [Int] {
        guard width > 0, height > 0, grid.count == width * height else { return [] }
        var blocked: [Int] = []
        for (i, slot) in slots.enumerated() {
            let startX = max(0, min(width - 1, Int(slot.x * Double(width))))
            let endX = max(0, min(width - 1, Int(ceil(slot.maxX * Double(width))) - 1))
            let startY = max(0, min(height - 1, Int(slot.y * Double(height))))
            let endY = max(0, min(height - 1, Int(ceil(slot.maxY * Double(height))) - 1))

            guard startX <= endX, startY <= endY else {
                blocked.append(i + 1)
                continue
            }
            var hasTransparentPixel = false
            for y in startY...endY {
                for x in startX...endX {
                    if grid[y * width + x] {
                        hasTransparentPixel = true
                        break
                    }
                }
                if hasTransparentPixel { break }
            }

            if !hasTransparentPixel {
                blocked.append(i + 1) // 1-based index
            }
        }
        return blocked
    }
}
