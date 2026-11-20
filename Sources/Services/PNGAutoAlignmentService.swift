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

enum PNGOpeningStatus: Equatable {
    case ready, review, undetermined, opaque, tooManyRegions
}

public struct AutoAlignmentResult: Equatable {
    public let slots: [SlotRect]
    public let isAutoAligned: Bool
    public let requiresInspection: Bool
    public let inspectionReason: String?
    public let blockedSlotIndices: [Int] // 1-based indices of slots blocked by opaque overlay

    let pngStatus: PNGOpeningStatus?

    public init(slots: [SlotRect], isAutoAligned: Bool, requiresInspection: Bool, inspectionReason: String?, blockedSlotIndices: [Int]) {
        self.init(slots: slots, isAutoAligned: isAutoAligned, requiresInspection: requiresInspection,
                  inspectionReason: inspectionReason, blockedSlotIndices: blockedSlotIndices, pngStatus: nil)
    }

    init(slots: [SlotRect], isAutoAligned: Bool, requiresInspection: Bool,
         inspectionReason: String?, blockedSlotIndices: [Int], pngStatus: PNGOpeningStatus?) {
        self.pngStatus = pngStatus
        self.slots = slots
        self.isAutoAligned = isAutoAligned
        self.requiresInspection = requiresInspection
        self.inspectionReason = inspectionReason
        self.blockedSlotIndices = blockedSlotIndices
    }
}

public enum PNGAutoAlignmentService {

    static let opaqueImageReason = "PNG không có vùng trong suốt"

    /// Dò cửa sổ ảnh trên alpha gốc để giữ cả các khe mở chỉ rộng một pixel.
    static func detectOpenings(_ image: CGImage) -> AutoAlignmentResult {
        let width = image.width
        let height = image.height
        let pixelCount = width * height
        let alpha: [UInt8]? = {
            var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
            return rgba.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return pixelsFromRGBA(buffer, count: pixelCount)
            }
        }()
        guard let pixels = alpha else {
            return result(.undetermined, reason: "Không đọc được lớp alpha của PNG")
        }
        guard pixels.contains(where: { $0 < 255 }) else {
            return result(.opaque, reason: opaqueImageReason)
        }
        let strict = strictOpenings(pixels, width: width, height: height)
        return PNGOpeningSweep(pixels: pixels, width: width, height: height).detect(strict: strict)
    }

    private static func strictOpenings(_ pixels: [UInt8], width: Int, height: Int) -> AutoAlignmentResult {
        let pixelCount = pixels.count
        func needsAdjustment(_ reason: String) -> AutoAlignmentResult {
            result(.undetermined, reason: reason)
        }

        struct Region {
            var bounds: CGRect = .null
            var area = 0

            mutating func addRun(x: Int, y: Int, count: Int) {
                area += count
                bounds = bounds.union(CGRect(x: x, y: y, width: count, height: 1))
            }
        }

        // Một byte cho mỗi pixel, lưu riêng cờ vùng lõi và vùng chứa viền.
        var visited = [UInt8](repeating: 0, count: pixelCount)
        let minimumCoreArea = Int(ceil(Double(pixelCount) * 0.01))
        func eligible(_ index: Int, threshold: UInt8, bit: UInt8) -> Bool {
            pixels[index] <= threshold && visited[index] & bit == 0
        }
        func flood(_ start: Int, threshold: UInt8, bit: UInt8, inspectCore: Bool) -> (Region, Int, Bool) {
            var region = Region()
            var coreCount = 0
            var hasQualifiedCore = false
            var stack = [start]
            while let pixel = stack.popLast() {
                if Task.isCancelled { break }
                guard eligible(pixel, threshold: threshold, bit: bit) else { continue }
                let row = pixel / width
                let rowStart = row * width
                let rowEnd = rowStart + width - 1
                var left = pixel
                var right = pixel
                while left > rowStart && eligible(left - 1, threshold: threshold, bit: bit) { left -= 1 }
                while right < rowEnd && eligible(right + 1, threshold: threshold, bit: bit) { right += 1 }
                region.addRun(x: left - rowStart, y: row, count: right - left + 1)
                for index in left...right {
                    visited[index] |= bit
                    if inspectCore && eligible(index, threshold: 32, bit: 2) {
                        let core = flood(index, threshold: 32, bit: 2, inspectCore: false).0
                        coreCount += 1
                        if core.area >= minimumCoreArea &&
                            Double(core.area) >= core.bounds.width * core.bounds.height * 0.75 {
                            hasQualifiedCore = true
                        }
                    }
                }
                for adjacentRow in [row - 1, row + 1] where (0..<height).contains(adjacentRow) {
                    let offset = (adjacentRow - row) * width
                    var inRun = false
                    for index in (left + offset)...(right + offset) {
                        let candidate = eligible(index, threshold: threshold, bit: bit)
                        if candidate && !inRun { stack.append(index) }
                        inRun = candidate
                    }
                }
            }
            return (region, coreCount, hasQualifiedCore)
        }

        var openings: [(box: CGRect, seed: Int)] = []
        for index in pixels.indices where eligible(index, threshold: 254, bit: 1) {
            if Task.isCancelled { return needsAdjustment("Đã dừng phân tích PNG") }
            let (region, coreCount, hasQualifiedCore) = flood(index, threshold: 254, bit: 1, inspectCore: true)
            let box = region.bounds
            let touchesEdge = box.minX == 0 || box.minY == 0 || box.maxX == CGFloat(width) || box.maxY == CGFloat(height)
            guard !touchesEdge, hasQualifiedCore else { continue }
            guard coreCount == 1 else {
                return needsAdjustment("Có nhiều vùng lõi nối qua cùng một viền")
            }
            guard !openings.contains(where: { $0.box.intersects(box) }) else {
                return needsAdjustment("Các hình bao ô ảnh chồng lên nhau")
            }
            openings.append((box, index))
            if openings.count > ResourceLimits.maxSlots {
                return result(.tooManyRegions, reason: "Tìm thấy hơn \(ResourceLimits.maxSlots) vùng. Chọn tối đa \(ResourceLimits.maxSlots) ô để dùng.")
            }
        }
        guard !openings.isEmpty else { return needsAdjustment("Không tìm thấy ô ảnh khép kín phù hợp") }

        for (box, seed) in openings {
            _ = flood(seed, threshold: 254, bit: 4, inspectCore: false)
            for row in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX)
                    where pixels[row * width + x] < 255 && visited[row * width + x] & 4 == 0 {
                    return needsAdjustment("Có vùng trong suốt khác nằm trong ô ảnh")
                }
            }
        }

        guard let ordered = orderedBoxes(openings.map(\.box)) else {
            return result(.review, slots: normalized(openings.map(\.box), width: width, height: height),
                          reason: "Kiểm tra thứ tự các ô")
        }
        return result(.ready, slots: normalized(ordered, width: width, height: height))
    }

    static func orderedBoxes(_ boxes: [CGRect]) -> [CGRect]? {
        let sorted = boxes.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
            min(a.maxY, b.maxY) - max(a.minY, b.minY) >= min(a.height, b.height) * 0.5
        }
        var rows: [[CGRect]] = []
        for box in sorted {
            let matches = rows.indices.filter { rows[$0].contains(where: { sameRow(box, $0) }) }
            guard matches.count < 2 else { return nil }
            if let row = matches.first {
                guard rows[row].allSatisfy({ sameRow(box, $0) }) else { return nil }
                rows[row].append(box)
            } else {
                rows.append([box])
            }
        }
        return rows.flatMap { row in
            row.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
        }
    }

    static func normalized(_ boxes: [CGRect], width: Int, height: Int) -> [SlotRect] {
        boxes.map { box in
            SlotRect(x: Double(box.minX) / Double(width), y: Double(box.minY) / Double(height),
                     width: Double(box.width) / Double(width), height: Double(box.height) / Double(height))
        }
    }

    static func result(_ status: PNGOpeningStatus, slots: [SlotRect] = [], reason: String? = nil) -> AutoAlignmentResult {
        AutoAlignmentResult(slots: slots, isAutoAligned: status == .ready, requiresInspection: status != .ready,
                            inspectionReason: reason, blockedSlotIndices: [], pngStatus: status)
    }

    private static func pixelsFromRGBA(_ buffer: UnsafeMutableRawBufferPointer, count: Int) -> [UInt8] {
        var alpha = [UInt8](repeating: 0, count: count)
        for index in 0..<count { alpha[index] = buffer[index * 4 + 3] }
        return alpha
    }

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
        let width = draft.canvasWidth
        let height = draft.canvasHeight
        guard width > 0, height > 0,
              let layer = CompositeRenderer.placeLayer(CIImage(cgImage: overlay),
                  canvasWidth: width, canvasHeight: height, placement: draft.foregroundPlacement) else {
            throw AppError.frameFileCorrupt
        }
        let tileSize = 512
        var blocked: [Int] = []
        for (index, slot) in slots.enumerated() {
            try Task.checkCancellation()
            let mask = MaskBuilder.CanvasSlot(slot: SnapshotSlot(from: slot), width: width, height: height)
            let bounds = mask.bounds.integral.intersection(mask.canvas)
            guard mask.canRender, !bounds.isEmpty else {
                blocked.append(index + 1)
                continue
            }
            var visible = false
            scan: for y in stride(from: Int(bounds.minY), to: Int(bounds.maxY), by: tileSize) {
                for x in stride(from: Int(bounds.minX), to: Int(bounds.maxX), by: tileSize) {
                    try Task.checkCancellation()
                    let tile = CGRect(x: x, y: y, width: min(tileSize, Int(bounds.maxX) - x),
                                      height: min(tileSize, Int(bounds.maxY) - y))
                    let clear = CIImage(color: .clear).cropped(to: tile)
                    let coverage = try tileAlpha(mask.coverage(in: tile), in: tile)
                    let opacity = try tileAlpha(layer.composited(over: clear).cropped(to: tile), in: tile)
                    if coverage.indices.contains(where: { coverage[$0] > 0 && opacity[$0] < 255 }) {
                        visible = true
                        break scan
                    }
                }
            }
            if !visible { blocked.append(index + 1) }
        }
        return blocked
    }

    private static func tileAlpha(_ image: CIImage, in tile: CGRect) throws -> [UInt8] {
        let width = Int(tile.width)
        let height = Int(tile.height)
        guard let bitmap = CIContextHolder.shared.context.createCGImage(image, from: tile) else {
            throw AppError.frameFileCorrupt
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        return try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw AppError.frameFileCorrupt
            }
            context.setBlendMode(.copy)
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            return (0..<(width * height)).map { bytes[$0 * 4 + 3] }
        }
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

/// Uses the original alpha for comparison and leaves the imported artwork intact.
private struct PNGOpeningSweep {
    private struct Region {
        let box: CGRect
        let seed: Int
        let area: Int
        let clearPixels: Int
        let transmission: Int
    }

    private struct Level {
        let threshold: UInt8
        let regions: [Region]

        var boxes: [CGRect] { regions.map(\.box) }

        var hasOverlappingBoxes: Bool {
            for i in regions.indices {
                if regions[..<i].contains(where: { PNGOpeningSweep.area($0.box.intersection(regions[i].box)) > 0 }) {
                    return true
                }
            }
            return false
        }
    }

    let pixels: [UInt8]
    let width: Int
    let height: Int

    private static let thresholds: [UInt8] = [32, 64, 96, 128, 160, 192, 224, 240, 248]
    private static let edgeThreshold: UInt8 = 160

    func detect(strict: AutoAlignmentResult) -> AutoAlignmentResult {
        if strict.pngStatus == .tooManyRegions { return strict }
        var marks = [UInt8](repeating: 0, count: pixels.count)
        // Keep the original low-alpha exterior in bit 0. The remaining bits identify the current pass.
        var levels: [Level] = []
        var hasExterior = false
        for (index, threshold) in Self.thresholds.enumerated() {
            let stamp = UInt8(2 * (index + 1))
            var closed: [Region] = []
            for seed in pixels.indices {
                if seed % width == 0 && Task.isCancelled { return cancelled }
                guard marks[seed] & 254 != stamp, pixels[seed] <= threshold,
                      threshold != Self.edgeThreshold || marks[seed] & 1 == 0 else { continue }
                let region = flood(seed: seed, threshold: threshold, stamp: stamp, marks: &marks)
                if touchesBorder(region.box) {
                    if threshold == Self.edgeThreshold {
                        _ = flood(seed: seed, threshold: threshold, stamp: 32, marks: &marks, markExterior: true)
                        hasExterior = true
                    }
                } else if plausible(region) {
                    closed.append(region)
                    if closed.count > ResourceLimits.maxSlots { return tooMany }
                }
            }
            levels.append(Level(threshold: threshold, regions: closed))
        }

        let stableBands = levels.indices.compactMap { first -> ClosedRange<Int>? in
            guard !levels[first].regions.isEmpty, !levels[first].hasOverlappingBoxes else { return nil }
            var last = first
            while last + 1 < levels.count,
                  !levels[last + 1].hasOverlappingBoxes,
                  matches(levels[first].boxes, levels[last + 1].boxes),
                  matches(levels[last].boxes, levels[last + 1].boxes) {
                last += 1
            }
            return last > first ? first...last : nil
        }
        let bands = stableBands.sorted { ($0.count, $0.upperBound) > ($1.count, $1.upperBound) }
        var visibilityByLevel: [Int: Bool] = [:]
        var choice: (ClosedRange<Int>, Level)?
        for band in bands {
            if Task.isCancelled { return cancelled }
            for index in band.reversed() {
                let isVisible = visibilityByLevel[index] ?? levels[index].regions.allSatisfy(visible)
                visibilityByLevel[index] = isVisible
                if isVisible {
                    choice = (band, levels[index])
                    break
                }
            }
            if choice != nil { break }
        }
        guard !Task.isCancelled else { return cancelled }
        guard let (selectedBand, selected) = choice else {
            return provisional(strict: strict, levels: levels, bands: bands)
        }

        let stableConflict = bands.contains { band in
            guard !band.overlaps(selectedBand) else { return false }
            let other = levels[band.upperBound].boxes
            if band.upperBound < selectedBand.lowerBound {
                // A later stable window set may reveal more slots as their alpha enters the sweep.
                // Its earlier strict subset is evidence for the same layout.
                return !isSubset(other, of: selected.boxes, allowsGrowth: true)
            }
            return !matches(selected.boxes, other)
        }
        var suggestions = selected.boxes
        var additional = false
        // A newly separated window matters even if visible at only one threshold.
        for (index, level) in levels.enumerated() {
            for region in level.regions {
                let stamp = UInt8(48 + 2 * index)
                if independent(region, at: level.threshold, stamp: stamp, from: selected.boxes, marks: &marks) {
                    guard !Task.isCancelled else { return cancelled }
                    if !suggestions.contains(where: { Self.area($0.intersection(region.box)) > 0 }) {
                        suggestions.append(region.box)
                    }
                    additional = true
                }
            }
        }

        let strictBoxes = strict.slots.map(pixelBox)
        let strictDiffers = !strictBoxes.isEmpty && !isSubset(strictBoxes, of: selected.boxes)
        if strictDiffers {
            for box in strictBoxes where selected.boxes.allSatisfy({ Self.area($0.intersection(box)) == 0 }) &&
                !suggestions.contains(where: { Self.area($0.intersection(box)) > 0 }) {
                suggestions.append(box)
            }
        }
        if suggestions.count > ResourceLimits.maxSlots { return tooMany }
        let connectedToEdge = hasExterior && openWindowExists(marks: &marks)
        guard !Task.isCancelled else { return cancelled }
        let ordered = PNGAutoAlignmentService.orderedBoxes(suggestions)
        if connectedToEdge || additional || stableConflict || strictDiffers || ordered == nil {
            let reason: String
            if connectedToEdge { reason = "Có thể có ô ảnh thông ra mép khung" }
            else if additional { reason = "Có thể thiếu ô ảnh" }
            else if ordered == nil { reason = "Kiểm tra thứ tự các ô" }
            else { reason = "Có nhiều bố cục phù hợp. Kiểm tra lại các ô ảnh." }
            return review(ordered ?? suggestions, reason: reason)
        }
        if strict.isAutoAligned && strictBoxes.count == selected.regions.count &&
            strictMatchesVisibility(strictBoxes, selected: selected) {
            return strict
        }
        return PNGAutoAlignmentService.result(.ready, slots: normalized(ordered ?? suggestions))
    }

    private func provisional(strict: AutoAlignmentResult, levels: [Level],
                             bands: [ClosedRange<Int>]) -> AutoAlignmentResult {
        if !strict.slots.isEmpty {
            return PNGAutoAlignmentService.result(.review, slots: strict.slots,
                                                  reason: strict.inspectionReason ?? "Kiểm tra các ô được gợi ý")
        }
        let best = bands.first.map { levels[$0.upperBound] } ??
            levels.reversed().first { !$0.regions.isEmpty && !$0.hasOverlappingBoxes }
        if let best { return review(best.boxes, reason: "Kiểm tra các ô được gợi ý") }
        return PNGAutoAlignmentService.result(.undetermined, reason: "Chọn vị trí đặt ảnh")
    }

    private var cancelled: AutoAlignmentResult {
        PNGAutoAlignmentService.result(.undetermined, reason: "Đã dừng phân tích PNG")
    }

    private var tooMany: AutoAlignmentResult {
        PNGAutoAlignmentService.result(.tooManyRegions,
            reason: "Tìm thấy hơn \(ResourceLimits.maxSlots) vùng. Chọn tối đa \(ResourceLimits.maxSlots) ô để dùng.")
    }

    private func review(_ boxes: [CGRect], reason: String) -> AutoAlignmentResult {
        let ordered = PNGAutoAlignmentService.orderedBoxes(boxes) ??
            boxes.sorted { ($0.midY, $0.midX) < ($1.midY, $1.midX) }
        return PNGAutoAlignmentService.result(.review, slots: normalized(ordered), reason: reason)
    }

    private func normalized(_ boxes: [CGRect]) -> [SlotRect] {
        PNGAutoAlignmentService.normalized(boxes, width: width, height: height)
    }

    private func pixelBox(_ slot: SlotRect) -> CGRect {
        CGRect(x: (slot.x * Double(width)).rounded(), y: (slot.y * Double(height)).rounded(),
               width: (slot.width * Double(width)).rounded(), height: (slot.height * Double(height)).rounded())
    }

    private func plausible(_ region: Region) -> Bool {
        let area = Double(region.area)
        let smallOpening = Double(pixels.count) * 0.0025
        guard region.box.width >= 12, region.box.height >= 12,
              area >= smallOpening, area >= Self.area(region.box) * 0.65 else { return false }
        // A soft border alone cannot make a tiny decoration count as a small photo window.
        return area >= Double(pixels.count) * 0.01 ||
            region.clearPixels == 0 || Double(region.clearPixels) >= smallOpening
    }

    private func touchesBorder(_ box: CGRect) -> Bool {
        box.minX == 0 || box.minY == 0 || box.maxX == Double(width) || box.maxY == Double(height)
    }

    private static func area(_ box: CGRect) -> Double {
        box.isNull ? 0 : box.width * box.height
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = Self.area(a.intersection(b))
        return intersection / (Self.area(a) + Self.area(b) - intersection)
    }

    private func matches(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.count == b.count && isSubset(a, of: b)
    }

    private func isSubset(_ a: [CGRect], of b: [CGRect], allowsGrowth: Bool = false) -> Bool {
        guard !a.isEmpty, a.count <= b.count else { return false }
        var used = Set<Int>()
        for box in a {
            // The lower threshold can contain just the core of an opening. Every core still
            // needs its own destination, so this exception cannot accept two windows merging.
            let matching = b.indices.filter {
                iou(box, b[$0]) >= 0.90 ||
                    (allowsGrowth && Self.area(box.intersection(b[$0])) >= Self.area(box) * 0.95)
            }
            guard matching.count == 1, used.insert(matching[0]).inserted else { return false }
        }
        return true
    }

    private func transmission(in box: CGRect) -> Int {
        var total = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            if Task.isCancelled { break }
            let start = y * width + Int(box.minX)
            let end = y * width + Int(box.maxX)
            for index in start..<end { total += 255 - Int(pixels[index]) }
        }
        return total
    }

    private func centerVisible(in box: CGRect) -> Bool {
        let dx = Int(box.width * 0.20)
        let dy = Int(box.height * 0.20)
        let center = box.insetBy(dx: CGFloat(dx), dy: CGFloat(dy))
        return Double(transmission(in: center)) >= Self.area(center) * 255 * 0.45
    }

    private func visible(_ region: Region) -> Bool {
        guard centerVisible(in: region.box) else { return false }
        return Double(transmission(in: region.box) - region.transmission) <= Self.area(region.box) * 255 * 0.01
    }

    private func strictMatchesVisibility(_ boxes: [CGRect], selected: Level) -> Bool {
        boxes.allSatisfy { box in
            guard let window = selected.regions.first(where: { iou(box, $0.box) >= 0.90 }),
                  centerVisible(in: box) else { return false }
            if box.contains(window.box) {
                return Double(transmission(in: box) - window.transmission) <= Self.area(box) * 255 * 0.01
            }
            // The strict scan used the original alpha to validate this box. Keep its aligned geometry.
            return Double(transmission(in: box) - transmission(in: box.intersection(window.box))) <=
                Self.area(box) * 255 * 0.01
        }
    }

    private func independent(_ region: Region, at threshold: UInt8, stamp: UInt8,
                             from boxes: [CGRect], marks: inout [UInt8]) -> Bool {
        let intersections = boxes.map { $0.intersection(region.box) }.filter { Self.area($0) > 0 }
        let overlap = intersections.reduce(0.0) { $0 + Self.area($1) }
        let limit = Double(region.area) * 0.80
        if Self.area(region.box) - overlap < limit { return false }
        if Double(region.area) - overlap >= limit { return true }

        // The bounding boxes give inconclusive bounds. Revisit exactly this connected component.
        var intersecting = 0
        // Stamps must differ even for multiple candidates reconstructed from the same threshold.
        for y in Int(region.box.minY)..<Int(region.box.maxY) {
            for x in Int(region.box.minX)..<Int(region.box.maxX) {
                let i = y * width + x
                if marks[i] & 254 == stamp { marks[i] &= 1 }
            }
        }
        _ = flood(seed: region.seed, threshold: threshold, stamp: stamp, marks: &marks) { row, left, right in
            for rect in intersections where row >= Int(rect.minY) && row < Int(rect.maxY) {
                intersecting += max(0, min(right + 1, Int(rect.maxX)) - max(left, Int(rect.minX)))
            }
        }
        return Double(region.area - intersecting) >= limit
    }

    private func openWindowExists(marks: inout [UInt8]) -> Bool {
        // Diagnose narrow necks in the true exterior. No eroded pixels are used for a saved opening.
        let stamp: UInt8 = 80
        for y in 1..<(height - 1) {
            if Task.isCancelled { return false }
            for x in 1..<(width - 1) {
                let seed = y * width + x
                guard marks[seed] & 1 != 0, marks[seed] & 254 != stamp, isEroded(seed) else { continue }
                let region = flood(seed: seed, threshold: Self.edgeThreshold, stamp: stamp, marks: &marks, eroded: true)
                guard plausible(region), centerVisible(in: region.box) else { continue }
                // Ignore lobes confined to the narrow decorative outer margin.
                let inset = CGRect(x: Double(width) * 0.06, y: Double(height) * 0.03,
                                   width: Double(width) * 0.88, height: Double(height) * 0.94)
                if Self.area(region.box.intersection(inset)) >= Self.area(region.box) * 0.75 { return true }
            }
        }
        return false
    }

    private func isEroded(_ p: Int) -> Bool {
        let (y, x) = p.quotientAndRemainder(dividingBy: width)
        let threshold = Self.edgeThreshold
        return x > 0 && x + 1 < width && y > 0 && y + 1 < height &&
            pixels[p] <= threshold && pixels[p - 1] <= threshold && pixels[p + 1] <= threshold &&
            pixels[p - width] <= threshold && pixels[p + width] <= threshold
    }

    private func flood(seed: Int, threshold: UInt8, stamp: UInt8, marks: inout [UInt8],
                       eroded: Bool = false, markExterior: Bool = false,
                       visit: ((Int, Int, Int) -> Void)? = nil) -> Region {
        var minX = width, minY = height, maxX = 0, maxY = 0
        var count = 0, clear = 0, transmitted = 0
        var stack = [seed]
        func allowed(_ index: Int, _ mark: UInt8) -> Bool {
            mark & 254 != stamp && pixels[index] <= threshold && (!eroded || isEroded(index))
        }

        while let pixel = stack.popLast() {
            if Task.isCancelled { break }
            guard allowed(pixel, marks[pixel]) else { continue }
            let row = pixel / width
            let start = row * width
            let end = start + width - 1
            var left = pixel, right = pixel
            while left > start && allowed(left - 1, marks[left - 1]) { left -= 1 }
            while right < end && allowed(right + 1, marks[right + 1]) { right += 1 }
            minX = min(minX, left - start)
            maxX = max(maxX, right - start + 1)
            minY = min(minY, row)
            maxY = max(maxY, row + 1)
            count += right - left + 1
            for index in left...right {
                marks[index] = stamp | (markExterior ? 1 : marks[index] & 1)
                let alpha = Int(pixels[index])
                if alpha <= 160 { clear += 1 }
                transmitted += 255 - alpha
            }
            visit?(row, left - start, right - start)
            for nextRow in [row - 1, row + 1] where (0..<height).contains(nextRow) {
                let offset = (nextRow - row) * width
                var inRun = false
                for index in (left + offset)...(right + offset) {
                    let current = allowed(index, marks[index])
                    if current && !inRun { stack.append(index) }
                    inRun = current
                }
            }
        }
        let box = count > 0 ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : .null
        return Region(box: box, seed: seed, area: count, clearPixels: clear, transmission: transmitted)
    }
}
