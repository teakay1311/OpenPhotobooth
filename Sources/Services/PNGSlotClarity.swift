import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum PNGSlotClarity {
    enum Status: String, Sendable {
        case cleared = "Đã làm trong"
        case alreadyClear = "Đã trong sẵn"
        case needsReview = "Cần xem lại"
        case detailKept = "Đã xác nhận chi tiết cần giữ"
        case previewApproved = "Đã duyệt theo bản xem trước"
    }

    struct Issue: Sendable {
        let bounds: CGRect
        let location: String
        let canRetry: Bool
        var pixels: [Range<Int>] = []
    }

    struct SlotResult: Identifiable, Sendable {
        let id: String
        let number: Int
        let bounds: CGRect
        let status: Status
        let issues: [Issue]
    }

    struct Approval: Equatable, Sendable {
        let source: String
        let geometry: [Double]
        let mask: MaskType
        let placement: PlacementKind
        let pixels: Data
        let warnings: Set<Warning>
    }

    struct Warning: Hashable, Sendable {
        let bounds: [Double]
        let pixels: [Range<Int>]
    }

    typealias Approvals = [String: Approval]

    struct Result: Sendable {
        let data: Data
        let slots: [SlotResult]
        let hasChanges: Bool
        var signatures: Approvals = [:]

        var complete: Bool { !slots.isEmpty && slots.allSatisfy { $0.status != .needsReview } }
        var canSave: Bool { complete && hasChanges }

        func retained(_ approvals: Approvals) -> Approvals {
            approvals.filter { signatures[$0.key] == $0.value }
        }

        func pending(_ approvals: Approvals) -> [SlotResult] {
            let valid = retained(approvals)
            return slots.filter { $0.status == .needsReview && valid[$0.id] == nil }
        }

        func approving(_ approvals: Approvals, slotID: String? = nil) -> Approvals {
            var reviewed = retained(approvals)
            for slot in pending(reviewed) where slotID == nil || slot.id == slotID {
                reviewed[slot.id] = signatures[slot.id]
            }
            return reviewed
        }

        func displayedSlots(_ approvals: Approvals) -> [SlotResult] {
            let valid = retained(approvals)
            return slots.map { slot in
                guard slot.status == .needsReview, valid[slot.id] != nil else { return slot }
                return SlotResult(id: slot.id, number: slot.number, bounds: slot.bounds,
                                  status: .previewApproved, issues: [])
            }
        }
    }

    struct ReviewState: Sendable {
        var edits: [Edit] = []
        var approvals: Approvals = [:]
    }

    struct Edit: Sendable {
        enum Action: Sendable { case clear, keep }
        let slotID: String
        let bounds: CGRect
        let action: Action
        var pixels: [Range<Int>] = []
    }

    static func prepare(data: Data, snapshot: FrameSnapshot,
                        progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> Result {
        let source = try Source(data: data, snapshot: snapshot)
        var edited = source.bytes
        var outcomes: [SlotResult] = []
        for (index, region) in source.regions.enumerated() {
            try Task.checkCancellation()
            progress(index + 1, source.regions.count)
            let window = try source.window(for: region)
            if source.writable { try applyAutomatic(window, original: source.bytes, edited: &edited) }
            let after = try scan(window, pixels: edited, original: source.bytes)
            outcomes.append(outcome(region, number: index + 1, scan: after))
        }
        if !source.writable {
            let pending = outcomes.filter { $0.status == .needsReview }.map { String($0.number) }
            if !pending.isEmpty {
                throw AppError.invalidState("Ô \(pending.joined(separator: ", ")) cần chỉnh lớp phủ. Hãy xuất lại tệp dưới dạng PNG tĩnh sRGB RGBA 8 bit để chỉnh an toàn.")
            }
        }
        return try source.result(bytes: edited, outcomes: outcomes, snapshot: snapshot)
    }

    static func refine(data: Data, snapshot: FrameSnapshot, automatic: Result, edits: [Edit]) throws -> Result {
        guard !edits.isEmpty else { return automatic }
        let source = try Source(data: data, snapshot: snapshot)
        guard source.writable else {
            throw AppError.invalidState("Hãy xuất lại tệp dưới dạng PNG tĩnh sRGB RGBA 8 bit để chỉnh an toàn.")
        }
        var bytes = try Source(data: automatic.data, snapshot: snapshot).bytes
        // Rebuild from the immutable automatic result. Keep always takes precedence, including overlaps.
        var kept = [UInt8](repeating: 0, count: source.image.width * source.image.height)
        for edit in edits where edit.action == .clear {
            try source.apply(edit, bytes: &bytes, kept: &kept)
        }
        for edit in edits where edit.action == .keep {
            try source.apply(edit, bytes: &bytes, kept: &kept)
        }
        let outcomes = try source.regions.enumerated().map { index, region in
            let window = try source.window(for: region)
            return outcome(region, number: index + 1,
                           scan: try scan(window, pixels: bytes, original: source.bytes, kept: kept))
        }
        return try source.result(bytes: bytes, outcomes: outcomes, snapshot: snapshot)
    }

    private static func outcome(_ region: Region, number: Int, scan: Scan) -> SlotResult {
        let status: Status
        if !scan.issues.isEmpty { status = .needsReview }
        else if scan.hasKeptPixels { status = .detailKept }
        else { status = scan.changed ? .cleared : .alreadyClear }
        let issues = scan.issues.map {
            Issue(bounds: $0.bounds.applying(region.assetToCanvas), location: $0.location,
                  canRetry: $0.canRetry, pixels: $0.pixels)
        }
        return SlotResult(id: region.id, number: number, bounds: region.canvasBounds, status: status, issues: issues)
    }

    private struct Source {
        let data: Data
        let image: CGImage
        let bytes: Data
        let regions: [Region]
        let writable: Bool

        init(data: Data, snapshot: FrameSnapshot) throws {
            guard let decoded = try staticPNG(data), let foreground = snapshot.foreground,
                  snapshot.canvasWidth > 0, snapshot.canvasHeight > 0 else {
                throw AppError.invalidState("Không thể đọc lớp phủ. Hãy chọn PNG tĩnh.")
            }
            let image = decoded.image
            let slots = snapshot.slots.sorted { ($0.zOrder, $0.captureIndex, $0.id) < ($1.zOrder, $1.captureIndex, $1.id) }
            guard !slots.isEmpty, slots.allSatisfy({ $0.rect.isFinite && $0.rect.isPositive && $0.rotationDegrees.isFinite }) else {
                throw AppError.frameUnconfigured
            }
            self.data = data
            self.image = image
            if decoded.standardOrientation, let raw = writableBytes(image) {
                bytes = raw
                writable = true
            } else {
                bytes = try analysisBytes(image)
                writable = false
            }
            let sx = Double(snapshot.canvasWidth) / Double(image.width)
            let sy = Double(snapshot.canvasHeight) / Double(image.height)
            let transform: CGAffineTransform
            if foreground.placement == .stretchToCanvas {
                transform = CGAffineTransform(scaleX: sx, y: sy)
            } else {
                let scale = foreground.placement == .aspectFit ? min(sx, sy) : max(sx, sy)
                transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                    tx: (Double(snapshot.canvasWidth) - scale * Double(image.width)) / 2,
                    ty: (Double(snapshot.canvasHeight) - scale * Double(image.height)) / 2)
            }
            regions = slots.map {
                Region(slot: $0, width: snapshot.canvasWidth, height: snapshot.canvasHeight, assetToCanvas: transform)
            }
        }

        func window(for region: Region) throws -> Window {
            let others = regions.filter { $0.id != region.id && $0.bounds.intersects(region.bounds) }
            return try Window(region: region, canvasWidth: image.width, canvasHeight: image.height, neighbors: others)
        }

        func apply(_ edit: Edit, bytes output: inout Data, kept: inout [UInt8]) throws {
            guard let region = regions.first(where: { $0.id == edit.slotID }), !edit.bounds.isNull,
                  !edit.bounds.isInfinite, edit.bounds.width > 0, edit.bounds.height > 0 else { return }
            let editBounds = edit.bounds.applying(region.assetToCanvas.inverted())
            let box = editBounds.intersection(region.bounds)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !box.isEmpty else { return }
            // Keep a snapshot of the original bytes without evaluating Data subscripts per pixel.
            try bytes.withUnsafeBytes { original in
                try output.withUnsafeMutableBytes { updated in
                    let old = original.bindMemory(to: UInt8.self)
                    let new = updated.bindMemory(to: UInt8.self)
                    if !edit.pixels.isEmpty {
                        for run in edit.pixels {
                            try Task.checkCancellation()
                            for n in run where n >= 0 && n < kept.count {
                                let point = CGPoint(x: Double(n % image.width) + 0.5, y: Double(n / image.width) + 0.5)
                                guard region.depth(at: point) > 0 else { continue }
                                let a = n * 4 + 3
                                if edit.action == .keep {
                                    if old[a] != 0 { kept[n] = 1 }
                                    new[a] = old[a]
                                } else {
                                    new[a] = 0
                                }
                            }
                        }
                        return
                    }
                    for y in Int(floor(box.minY))..<Int(ceil(box.maxY)) {
                        try Task.checkCancellation()
                        for x in Int(floor(box.minX))..<Int(ceil(box.maxX)) {
                            let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                            guard editBounds.contains(point), region.depth(at: point) > 0 else { continue }
                            let n = y * image.width + x
                            let a = n * 4 + 3
                            if edit.action == .keep {
                                if old[a] != 0 { kept[n] = 1 }
                                new[a] = old[a]
                            } else {
                                let edge = min(point.x - editBounds.minX, editBounds.maxX - point.x,
                                               point.y - editBounds.minY, editBounds.maxY - point.y)
                                let feather = min(3, min(editBounds.width, editBounds.height) / 4)
                                let alpha = UInt8((Double(old[a]) * (1 - smooth(edge / feather))).rounded())
                                new[a] = min(new[a], alpha)
                            }
                        }
                    }
                }
            }
        }

        func result(bytes edited: Data, outcomes: [SlotResult], snapshot: FrameSnapshot) throws -> Result {
            let signatures = try approvalSignatures(edited, outcomes: outcomes, snapshot: snapshot)
            guard edited != bytes else {
                return Result(data: data, slots: outcomes, hasChanges: false, signatures: signatures)
            }
            try Task.checkCancellation()
            guard let space = image.colorSpace, let provider = CGDataProvider(data: edited as CFData),
                  let output = CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                                       bitsPerPixel: 32, bytesPerRow: image.bytesPerRow, space: space,
                                       bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
                                       shouldInterpolate: false, intent: image.renderingIntent) else {
                throw AppError.frameFileCorrupt
            }
            let png = try ExportService.encode(cg: output, format: .png, quality: 100)
            guard let decoded = try staticPNG(png), decoded.standardOrientation,
                  decoded.image.width == image.width, decoded.image.height == image.height,
                  let colorSpace = decoded.image.colorSpace, CFEqual(space, colorSpace),
                  writableBytes(decoded.image) == edited else {
                throw AppError.invalidState("Không thể lưu PNG mà vẫn giữ nguyên các chi tiết được bảo vệ")
            }
            return Result(data: png, slots: outcomes, hasChanges: true, signatures: signatures)
        }

        private func approvalSignatures(_ edited: Data, outcomes: [SlotResult],
                                        snapshot: FrameSnapshot) throws -> Approvals {
            let pending = outcomes.filter { $0.status == .needsReview }
            guard !pending.isEmpty, let placement = snapshot.foreground?.placement else { return [:] }
            let source = Hashing.sha256Hex(data)
            var result: Approvals = [:]
            for outcome in pending {
                guard let region = regions.first(where: { $0.id == outcome.id }),
                      let slot = snapshot.slots.first(where: { $0.id == outcome.id }) else { continue }
                let w = try Window(region: region, canvasWidth: image.width, canvasHeight: image.height, neighbors: [])
                var hasher = SHA256()
                try edited.withUnsafeBytes { raw in
                    for y in 0..<w.height {
                        try Task.checkCancellation()
                        let offset = y * w.width
                        var x = 0
                        while x < w.width {
                            guard w.depth[offset + x] > 0 else { x += 1; continue }
                            let first = w.pixel(offset + x) * 4
                            let start = x
                            repeat { x += 1 } while x < w.width && w.depth[offset + x] > 0
                            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[first..<(first + (x - start) * 4)]))
                        }
                    }
                }
                result[outcome.id] = Approval(source: source,
                    geometry: [Double(snapshot.canvasWidth), Double(snapshot.canvasHeight), slot.x, slot.y,
                               slot.width, slot.height, slot.rotationDegrees, slot.cornerRadius],
                    mask: slot.maskType, placement: placement, pixels: Data(hasher.finalize()),
                    warnings: Set(outcome.issues.map {
                        Warning(bounds: [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height], pixels: $0.pixels)
                    }))
            }
            return result
        }
    }

    private static func staticPNG(_ data: Data) throws -> (image: CGImage, standardOrientation: Bool)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let standardOrientation = (properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        return (try AssetStore.validatedFrameImage(data).image, standardOrientation)
    }

    private static func writableBytes(_ image: CGImage) -> Data? {
        guard image.colorSpace?.name == CGColorSpace.sRGB, image.bitsPerComponent == 8,
              image.bitsPerPixel == 32, image.bitmapInfo == CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
              image.bytesPerRow == image.width * 4,
              let data = image.dataProvider?.data as Data?,
              data.count == image.bytesPerRow * image.height else { return nil }
        return data
    }

    // This raster is only for analysis. Non-writable PNGs keep their original bytes.
    private static func analysisBytes(_ image: CGImage) throws -> Data {
        var data = Data(count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw AppError.frameFileCorrupt
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            for p in stride(from: 0, to: bytes.count, by: 4) {
                if p.isMultiple(of: 16_384) { try Task.checkCancellation() }
                let alpha = Int(bytes[p + 3])
                guard alpha > 0, alpha < 255 else { continue }
                for ch in p..<(p + 3) {
                    bytes[ch] = UInt8(min(255, (Int(bytes[ch]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        return data
    }

    private struct Region {
        let id: String
        let rect: CGRect
        let bounds: CGRect
        let canvasBounds: CGRect
        let assetToCanvas: CGAffineTransform
        let type: MaskType
        let radius: Double
        let cosine: Double
        let sine: Double

        init(slot: SnapshotSlot, width: Int, height: Int, assetToCanvas: CGAffineTransform) {
            id = slot.id
            rect = slot.rect.pixelRect(canvasWidth: width, canvasHeight: height)
            canvasBounds = FrameGeometry.rotatedBounds(of: rect, degrees: slot.rotationDegrees)
            bounds = canvasBounds.applying(assetToCanvas.inverted())
            self.assetToCanvas = assetToCanvas
            type = slot.maskType
            radius = min(min(rect.width, rect.height) / 2,
                         max(0.5, SlotGeometry.cornerRadiusPixels(slot.cornerRadius, slotPixel: rect,
                                                                canvasWidth: width, canvasHeight: height)))
            let angle = slot.rotationDegrees * .pi / 180
            cosine = cos(angle)
            sine = sin(angle)
        }

        func local(_ point: CGPoint) -> CGPoint {
            let point = point.applying(assetToCanvas)
            let dx = point.x - rect.midX
            let dy = point.y - rect.midY
            return CGPoint(x: (cosine * dx + sine * dy) / rect.width,
                           y: (-sine * dx + cosine * dy) / rect.height)
        }

        func depth(at point: CGPoint) -> Double {
            let uv = local(point)
            let x = abs(uv.x), y = abs(uv.y)
            let rectangular = 0.5 - max(x, y)
            switch type {
            case .rectangle:
                return rectangular
            case .ellipse:
                return 0.5 - hypot(x, y)
            case .roundedRectangle:
                let rx = radius / rect.width, ry = radius / rect.height
                let cornerX = max(0, x - (0.5 - rx))
                let cornerY = max(0, y - (0.5 - ry))
                let cornerDepth = (1 - hypot(cornerX / rx, cornerY / ry)) * max(rx, ry)
                return min(rectangular, cornerDepth)
            }
        }

        func edge(at point: CGPoint) -> (side: Int, position: Double) {
            let uv = local(point)
            if type != .rectangle {
                // Each quarter turn represents one arc of the boundary.
                let quarter = (atan2(uv.y, uv.x) + .pi * 2.25) / (.pi / 2)
                let sector = Int(quarter)
                return ([1, 3, 0, 2][sector % 4], quarter - Double(sector))
            }
            // Keep image rows in top-left coordinates, including for the rotated slot.
            if abs(uv.x) > abs(uv.y) { return (uv.x < 0 ? 0 : 1, uv.y + 0.5) }
            return (uv.y < 0 ? 2 : 3, uv.x + 0.5)
        }
    }

    private struct Window {
        let region: Region
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let canvasWidth: Int
        let depth: [UInt16]
        let shared: [Bool]
        let area: Int

        init(region: Region, canvasWidth: Int, canvasHeight: Int, neighbors: [Region]) throws {
            self.region = region
            self.canvasWidth = canvasWidth
            // Safe pixels just outside the mask supply feather context, but have depth zero and are never edited.
            let box = region.bounds.insetBy(dx: -3, dy: -3)
                .intersection(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
            if box.isEmpty {
                self.x = 0; self.y = 0
                width = 0; height = 0
                depth = []; shared = []; area = 0
                return
            }
            let x = Int(floor(box.minX)), y = Int(floor(box.minY))
            let w = Int(ceil(box.maxX)) - x, h = Int(ceil(box.maxY)) - y
            self.x = x
            self.y = y
            width = w
            height = h
            var depth = [UInt16](repeating: 0, count: w * h)
            var shared = neighbors.isEmpty ? [] : [Bool](repeating: false, count: w * h)
            var area = 0
            for row in 0..<h {
                try Task.checkCancellation()
                for column in 0..<w {
                    let p = CGPoint(x: Double(x + column) + 0.5, y: Double(y + row) + 0.5)
                    let d = region.depth(at: p)
                    guard d > 0 else { continue }
                    let i = row * w + column
                    depth[i] = UInt16(max(1, Int((d * 10_000).rounded(.down))))
                    area += 1
                    if !neighbors.isEmpty { shared[i] = neighbors.contains { $0.depth(at: p) > 0 } }
                }
            }
            self.area = area
            self.depth = depth
            self.shared = shared
        }

        func pixel(_ i: Int) -> Int { (y + i / width) * canvasWidth + x + i % width }
        func point(_ i: Int) -> CGPoint { CGPoint(x: Double(x + i % width) + 0.5, y: Double(y + i / width) + 0.5) }
        func isShared(_ i: Int) -> Bool { !shared.isEmpty && shared[i] }

        func walk(from start: Int, category: UInt8, marks: inout [UInt8], visited: UInt8,
                  connected: (Int, Int) -> Bool = { _, _ in true }) throws -> [Int32] {
            marks[start] = visited
            var queue = [Int32(start)]
            var read = 0
            func visit(_ i: Int, from: Int) {
                guard marks[i] == category, connected(from, i) else { return }
                marks[i] = visited
                queue.append(Int32(i))
            }
            while read < queue.count {
                if read.isMultiple(of: 4096) { try Task.checkCancellation() }
                let i = Int(queue[read])
                read += 1
                if i % width > 0 { visit(i - 1, from: i) }
                if i % width + 1 < width { visit(i + 1, from: i) }
                if i >= width { visit(i - width, from: i) }
                if i + width < depth.count { visit(i + width, from: i) }
            }
            return queue
        }
    }

    private static func colorWeight(_ pixels: UnsafeBufferPointer<UInt8>, _ p: Int, depth: UInt16) -> Double {
        let alpha = pixels[p + 3]
        if alpha <= 8 || (alpha <= 24 && depth >= 1000) { return 1 }
        guard alpha <= 208 else { return 0 }
        let low = min(pixels[p], pixels[p + 1], pixels[p + 2])
        let high = max(pixels[p], pixels[p + 1], pixels[p + 2])
        return min(1, max(0, Double(Int(low) - 192) / 28)) *
               min(1, max(0, Double(48 - Int(high - low)) / 24))
    }

    private static func smooth(_ input: Double) -> Double {
        let t = min(1, max(0, input))
        return t * t * (3 - 2 * t)
    }

    private static func applyAutomatic(_ w: Window, original: Data, edited: inout Data) throws {
        try original.withUnsafeBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self)
            var marks = [UInt8](repeating: 0, count: w.depth.count)
            var coreCount = 0
            var paleCore = 0
            for i in w.depth.indices {
                if i.isMultiple(of: 4096) { try Task.checkCancellation() }
                let depth = w.depth[i]
                if depth >= 2000 { coreCount += 1 }
                guard depth > 200, !w.isShared(i) else { continue }
                let p = w.pixel(i) * 4
                let low = min(pixels[p], pixels[p + 1], pixels[p + 2])
                let high = max(pixels[p], pixels[p + 1], pixels[p + 2])
                // Clear pixels are not bridges between unrelated pale details.
                guard (9...208).contains(pixels[p + 3]), low > 192, high - low < 48 else { continue }
                marks[i] = 1
                if depth >= 2000 { paleCore += 1 }
            }
            guard coreCount > 0, paleCore * 5 >= coreCount * 3 else { return }

            // Use the original alpha to separate abrupt transitions into decorations.
            // A qualifying component must itself cover the core and reach all quadrants.
            var selected: [Int32] = []
            for i in marks.indices where marks[i] == 1 && w.depth[i] >= 2000 {
                let component = try w.walk(from: i, category: 1, marks: &marks, visited: 2) { from, to in
                    abs(Int(pixels[w.pixel(from) * 4 + 3]) - Int(pixels[w.pixel(to) * 4 + 3])) <= 24
                }
                var count = 0, quadrants = 0
                for (index, n) in component.enumerated() {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    let i = Int(n)
                    guard w.depth[i] >= 2000 else { continue }
                    count += 1
                    let local = w.region.local(w.point(i))
                    quadrants |= 1 << ((local.x < 0 ? 0 : 1) + (local.y < 0 ? 0 : 2))
                }
                if count * 5 >= coreCount * 3 && quadrants == 15 {
                    selected = component
                    break
                }
            }
            guard !selected.isEmpty else { return }
            // Leave a short transition inside the proven component. No seed or
            // neighboring pixel outside this component can authorize an edit.
            marks = [UInt8](repeating: 0, count: w.depth.count)
            for n in selected { marks[Int(n)] = 1 }
            for level: UInt8 in 1...3 {
                for (index, n) in selected.enumerated() {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    let i = Int(n), width = w.width
                    guard marks[i] == level, i % width > 0, i % width + 1 < width,
                          i >= width, i + width < marks.count else { continue }
                    if marks[i - width - 1] >= level && marks[i - width] >= level &&
                       marks[i - width + 1] >= level && marks[i - 1] >= level && marks[i + 1] >= level &&
                       marks[i + width - 1] >= level && marks[i + width] >= level && marks[i + width + 1] >= level {
                        marks[i] = level + 1
                    }
                }
            }
            try edited.withUnsafeMutableBytes { target in
                let output = target.bindMemory(to: UInt8.self)
                for (index, n) in selected.enumerated() {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    let i = Int(n), p = w.pixel(i) * 4
                    let depth = w.depth[i]
                    let edge = w.region.edge(at: w.point(i))
                    let extent = edge.side < 2 ? w.region.rect.width : w.region.rect.height
                    let transition = max(0, 50 - 10_000 / extent)
                    let border = transition > 0 ? smooth((Double(depth) - 200) / transition) : 1
                    // The protected border supplies the transition at the slot edge.
                    // Keep the component feather where it meets other artwork inside the slot.
                    let borderFeatherEnd = max(400, 200 + 40_000 / extent)
                    let feather = Double(depth) < borderFeatherEnd ? 1 : Double(marks[i] - 1) / 3
                    output[p + 3] = UInt8((Double(pixels[p + 3]) * (1 - feather * border)).rounded())
                }
            }
        }
    }

    private struct Scan {
        var issues: [Issue] = []
        var changed = false
        var hasKeptPixels = false
    }

    private struct EdgeBin {
        var count = 0
        var covered = 0
        var tintBounds = CGRect.null
        var detailBounds = CGRect.null
        var tintPixels: [Int32] = []
        var detailPixels: [Int32] = []
    }

    private static func scan(_ w: Window, pixels data: Data, original: Data? = nil,
                             kept: [UInt8] = []) throws -> Scan {
        var scan = Scan()
        guard w.area > 0 else {
            if w.depth.isEmpty { return scan }
            scan.issues.append(Issue(bounds: w.region.bounds, location: "Ô quá nhỏ để phân tích", canRetry: false))
            return scan
        }
        var marks = [UInt8](repeating: 0, count: w.depth.count)
        var coreCount = 0, coreAbove = 0
        var coreBounds = CGRect.null
        // ponytail: two local edge bands reuse the same four-side scan; no separate detector.
        var bins = [EdgeBin](repeating: EdgeBin(), count: 160)
        try data.withUnsafeBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self)
            func collect(_ originalBytes: UnsafeBufferPointer<UInt8>?) throws {
                for i in w.depth.indices {
                    if i.isMultiple(of: 4096) { try Task.checkCancellation() }
                    let d = w.depth[i]
                    guard d > 0 else { continue }
                    let pixel = w.pixel(i), p = pixel * 4, a = pixels[p + 3]
                    if let originalBytes, a != originalBytes[p + 3] { scan.changed = true }
                    if !kept.isEmpty && kept[pixel] != 0 { scan.hasKeptPixels = true; continue }
                    let tint = a >= 26 && colorWeight(pixels, p, depth: d) > 0
                    if d >= 2000 {
                        coreCount += 1
                        if a > 8 {
                            coreAbove += 1
                            coreBounds = coreBounds.union(pixelRect(w.point(i)))
                        }
                    }
                    if d <= 200, a >= 26, a < 255 {
                        marks[i] = 4
                    } else if d >= 400, a >= 26 {
                        marks[i] = tint ? 1 : 2
                    } else if d > 200, d < 400 {
                        let point = w.point(i)
                        let edge = w.region.edge(at: point)
                        let band = d < 300 ? 0 : 1
                        let bin = band * 80 + edge.side * 20 + max(0, min(19, Int(edge.position * 20)))
                        bins[bin].count += 1
                        if a >= 26 {
                            bins[bin].covered += 1
                            if tint {
                                bins[bin].tintBounds = bins[bin].tintBounds.union(pixelRect(point))
                                bins[bin].tintPixels.append(Int32(i))
                            } else {
                                bins[bin].detailBounds = bins[bin].detailBounds.union(pixelRect(point))
                                bins[bin].detailPixels.append(Int32(i))
                            }
                        }
                    }
                }
            }
            if let original {
                try original.withUnsafeBytes { try collect($0.bindMemory(to: UInt8.self)) }
            } else {
                try collect(nil)
            }
        }
        for i in marks.indices where marks[i] == 1 || marks[i] == 2 {
            let category = marks[i]
            let group = try w.walk(from: i, category: category, marks: &marks, visited: 3)
            let nearWhite = category == 1
            guard Double(group.count) >= Double(w.area) * (nearWhite ? 0.025 : 0.05) else { continue }
            var bounds = CGRect.null
            var localMin = CGPoint(x: 1, y: 1), localMax = CGPoint(x: -1, y: -1)
            for n in group {
                let p = w.point(Int(n))
                bounds = bounds.union(pixelRect(p))
                let uv = w.region.local(p)
                localMin.x = min(localMin.x, uv.x); localMin.y = min(localMin.y, uv.y)
                localMax.x = max(localMax.x, uv.x); localMax.y = max(localMax.y, uv.y)
            }
            guard max(localMax.x - localMin.x, localMax.y - localMin.y) >= (nearWhite ? 0.20 : 0.25) else { continue }
            scan.issues.append(Issue(bounds: bounds, location: "Còn lớp phủ trong ô", canRetry: nearWhite,
                                     pixels: pixelRuns(group, in: w)))
        }
        if coreAbove * 2 > coreCount && !scan.issues.contains(where: { $0.bounds.intersects(coreBounds) }) {
            let core = try data.withUnsafeBytes { buffer in
                let pixels = buffer.bindMemory(to: UInt8.self)
                var result: [Int32] = []
                for i in w.depth.indices where w.depth[i] >= 2000 {
                    if i.isMultiple(of: 4096) { try Task.checkCancellation() }
                    let n = w.pixel(i)
                    if (kept.isEmpty || kept[n] == 0), pixels[n * 4 + 3] > 8 { result.append(Int32(i)) }
                }
                return result
            }
            scan.issues.append(Issue(bounds: coreBounds, location: "Cần kiểm tra giữa ô", canRetry: true,
                                     pixels: pixelRuns(core, in: w)))
        }
        let names = ["trái", "phải", "trên", "dưới"]
        try data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for i in marks.indices where marks[i] == 4 {
                let group = try w.walk(from: i, category: 4, marks: &marks, visited: 5)
                var start = Array(repeating: 1.0, count: 4)
                var end = Array(repeating: 0.0, count: 4)
                var contactStart = start, contactEnd = end
                var bounds = CGRect.null
                for (index, n) in group.enumerated() {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    let i = Int(n), pixel = w.pixel(i), p = pixel * 4
                    let point = w.point(i)
                    let edge = w.region.edge(at: point)
                    start[edge.side] = min(start[edge.side], edge.position)
                    end[edge.side] = max(end[edge.side], edge.position)
                    bounds = bounds.union(pixelRect(point))
                    // A similar strip outside the slot is evidence of a continuous rim.
                    let xi = pixel % w.canvasWidth, yi = pixel / w.canvasWidth
                    let contact = [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { dx, dy in
                        let x = xi + dx, y = yi + dy
                        guard x >= 0, x < w.canvasWidth, y >= 0, y < bytes.count / (w.canvasWidth * 4),
                              w.region.depth(at: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) <= 0 else { return false }
                        let q = (y * w.canvasWidth + x) * 4
                        return (0..<4).allSatisfy { abs(Int(bytes[p + $0]) - Int(bytes[q + $0])) <= 24 }
                    }
                    if contact {
                        contactStart[edge.side] = min(contactStart[edge.side], edge.position)
                        contactEnd[edge.side] = max(contactEnd[edge.side], edge.position)
                    }
                }
                let suspicious = (0..<4).first { side in
                    let width = side < 2 ? w.region.rect.height : w.region.rect.width
                    let span = end[side] - start[side]
                    return span + 1 / max(1, width) >= 0.2 &&
                        contactEnd[side] - contactStart[side] < span * 0.75
                }
                if let side = suspicious {
                    scan.issues.append(Issue(bounds: bounds, location: "Cần kiểm tra sát mép \(names[side])",
                                             canRetry: false, pixels: pixelRuns(group, in: w)))
                }
            }
        }
        for band in 0..<2 {
            for side in 0..<4 {
                let sideOffset = band * 80 + side * 20
                var flagged = [Bool](repeating: false, count: 20)
                for start in 0...16 {
                    let offset = sideOffset + start
                    let span = bins[offset..<(offset + 4)]
                    let total = span.reduce(0) { $0 + $1.count }
                    let covered = span.reduce(0) { $0 + $1.covered }
                    guard total > 0, covered * 2 >= total, span.allSatisfy({ $0.covered > 0 }) else { continue }
                    for index in start..<(start + 4) { flagged[index] = true }
                }
                let location = "Cần kiểm tra mép \(names[side])"
                for retryable in [true, false] {
                    var extent = CGRect.null
                    var regionPixels: [Int32] = []
                    for index in 0...20 {
                        if index < 20, flagged[index] {
                            let bin = bins[sideOffset + index]
                            let section = retryable ? bin.tintBounds : bin.detailBounds
                            if !section.isNull {
                                extent = extent.union(section)
                                regionPixels += retryable ? bin.tintPixels : bin.detailPixels
                                continue
                            }
                        }
                        if !extent.isNull {
                            scan.issues.append(Issue(bounds: extent, location: location, canRetry: retryable,
                                                     pixels: pixelRuns(regionPixels, in: w)))
                            extent = .null
                            regionPixels.removeAll(keepingCapacity: true)
                        }
                    }
                }
            }
        }
        return scan
    }

    private static func pixelRuns(_ group: [Int32], in w: Window) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for pixel in group.map({ w.pixel(Int($0)) }).sorted() {
            if let last = runs.last, pixel <= last.upperBound {
                if pixel == last.upperBound { runs[runs.count - 1] = last.lowerBound..<(pixel + 1) }
            } else {
                runs.append(pixel..<(pixel + 1))
            }
        }
        return runs
    }

    private static func pixelRect(_ point: CGPoint) -> CGRect {
        CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1)
    }
}
