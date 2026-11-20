import Foundation
import CoreGraphics
import CoreImage

/// FramePackService (§13): xuất/nhập `.photoframepack` — manifest schemaVersion 1,
/// packFormatVersion 1; verify trước preview; không giải nén vào thư viện đang hoạt động.
public final class FramePackService: @unchecked Sendable {
    private let frames: FrameRepository
    private let assets: AssetStore
    private let layout: FileLayout
    private let db: SQLiteDatabase

    public init(frames: FrameRepository, assets: AssetStore, layout: FileLayout, db: SQLiteDatabase) {
        self.frames = frames; self.assets = assets; self.layout = layout; self.db = db
    }

    // MARK: - Export (§13.3)

    public struct BuildPackResult: Sendable {
        public let data: Data
        public let packedFramesCount: Int
        public let skippedDraftCount: Int
        public let skippedReasons: [String]
    }

    public func preparePack(name: String, frameIDs: [String], includeCategories: Bool = true) throws -> BuildPackResult {
        var seen = Set<String>()
        var uniqueIDs: [String] = []
        for id in frameIDs {
            if !seen.contains(id) {
                seen.insert(id)
                uniqueIDs.append(id)
            }
        }

        var packFrames: [PackFrame] = []
        var fileMap: [String: Data] = [:]  // relPath -> bytes
        var files: [PackFileEntry] = []
        var skippedReasons: [String] = []
        var skippedDraftCount = 0
        let categories = (try? frames.listCategories()) ?? []

        for frameID in uniqueIDs {
            guard let frame = try frames.getFrame(id: frameID), frame.lifecycle == .active else {
                throw AppError.notFound("Khung \(frameID) không tồn tại hoặc đã bị xóa")
            }
            guard let revID = frame.currentRevisionID,
                  let rev = try frames.getRevision(id: revID) else {
                throw AppError.invalidState("Khung '\(frame.name)' thiếu revision hiện hành")
            }
            let slots = try frames.getSlots(revisionID: revID)

            // Nháp 0 ô: bỏ qua có báo số lượng và lý do (A1)
            if slots.isEmpty {
                skippedDraftCount += 1
                skippedReasons.append("Bỏ qua bản nháp '\(frame.name)' do chưa có ô ảnh")
                continue
            }

            // Khung cũ vượt 12 ô
            if slots.count > 12 {
                throw AppError.invalidState("Khung '\(frame.name)' có \(slots.count) ô (vượt giới hạn tối đa 12 ô)")
            }

            // Trùng index hoặc hình học không hợp lệ
            var seenIndices = Set<Int>()
            for s in slots {
                if seenIndices.contains(s.captureIndex) {
                    throw AppError.invalidState("Khung '\(frame.name)' có chỉ số ô ảnh trùng lặp (\(s.captureIndex))")
                }
                seenIndices.insert(s.captureIndex)
                guard s.x.isFinite, s.y.isFinite, s.width.isFinite, s.height.isFinite,
                      s.width > 0, s.height > 0 else {
                    throw AppError.invalidState("Khung '\(frame.name)' có hình học ô ảnh không hợp lệ")
                }
            }

            var bgRef: String? = nil
            var fgRef: String? = nil
            if let bgID = rev.backgroundAssetID {
                guard let info = assets.assetInfo(assetID: bgID),
                      let data = try? assets.loadData(assetID: bgID) else {
                    throw AppError.missingFrameAssets
                }
                let ext = (data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) ? "jpg" : "png"
                let path = "assets/\(info.sha256).\(ext)"
                bgRef = "sha256:\(info.sha256)"
                if fileMap[path] == nil {
                    fileMap[path] = data
                    files.append(PackFileEntry(path: path, sha256: info.sha256, size: data.count))
                }
            }
            if let fgID = rev.foregroundAssetID {
                guard let info = assets.assetInfo(assetID: fgID),
                      let data = try? assets.loadData(assetID: fgID) else {
                    throw AppError.missingFrameAssets
                }
                let ext = (data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) ? "jpg" : "png"
                let path = "assets/\(info.sha256).\(ext)"
                fgRef = "sha256:\(info.sha256)"
                if fileMap[path] == nil {
                    fileMap[path] = data
                    files.append(PackFileEntry(path: path, sha256: info.sha256, size: data.count))
                }
            }
            let categoryName = frame.categoryID.flatMap { cid in categories.first { $0.id == cid }?.name }
            let explicitWhite = (try? db.query("SELECT value FROM app_state WHERE key=?", [.text("explicit_white_\(revID)")]).first?["value"]?.stringValue) == "1"
            packFrames.append(PackFrame(
                frameId: frame.id, name: frame.name,
                category: includeCategories ? categoryName : nil,
                canvas: PackCanvas(width: rev.canvasWidth, height: rev.canvasHeight),
                slots: slots.map { s in
                    PackSlot(id: s.id, captureIndex: s.captureIndex, x: s.x, y: s.y,
                             width: s.width, height: s.height, rotationDegrees: s.rotationDegrees,
                             zOrder: s.zOrder, mask: s.maskType.rawValue, cornerRadius: s.cornerRadius,
                             cropMode: s.defaultCropMode.rawValue)
                },
                assets: PackFrameAssets(background: bgRef, foreground: fgRef,
                    backgroundImageOrientation: rev.backgroundImageOrientation,
                    foregroundImageOrientation: rev.foregroundImageOrientation),
                backgroundColor: rev.backgroundColorHex,
                backgroundPlacement: rev.backgroundPlacement.rawValue,
                foregroundPlacement: rev.foregroundPlacement.rawValue,
                explicitWhite: explicitWhite ? true : nil))
        }

        guard !packFrames.isEmpty else {
            throw AppError.invalidState("Không có khung hợp lệ nào để đóng gói (tất cả là bản nháp 0 ô hoặc danh sách rỗng)")
        }

        let manifest = PackManifest(schemaVersion: 1, packFormatVersion: 1,
                                    packId: IDFactory.new(), name: name,
                                    createdAt: ISO8601DateFormatter().string(from: Date()),
                                    frames: packFrames, files: files)
        let manifestData = try JSONEncoder().encode(manifest)
        var entries: [ZipArchive.Entry] = [ZipArchive.Entry(name: "manifest.json", data: manifestData)]
        for (path, data) in fileMap.sorted(by: { $0.key < $1.key }) {
            entries.append(ZipArchive.Entry(name: path, data: data))
        }
        let zipData = ZipArchive.archive(entries: entries)
        // Verify archive trước khi save (§13.3)
        _ = try Self.validate(data: zipData)
        return BuildPackResult(data: zipData, packedFramesCount: packFrames.count,
                               skippedDraftCount: skippedDraftCount, skippedReasons: skippedReasons)
    }

    public func buildPack(name: String, frameIDs: [String], includeCategories: Bool = true) throws -> Data {
        try preparePack(name: name, frameIDs: frameIDs, includeCategories: includeCategories).data
    }

    // MARK: - Validation (§13.2)

    public static func validate(data: Data) throws -> PackValidationResult {
        let entries = try ZipArchive.read(data: data)
        guard let manifestEntry = entries.first(where: { $0.name == "manifest.json" }) else {
            throw AppError.unsafeFramePack("Thiếu manifest.json")
        }
        let manifestData = try ZipArchive.extract(data: data, entry: manifestEntry,
                                                  maxUncompressedBytes: 10_000_000)
        guard let manifest = try? JSONDecoder().decode(PackManifest.self, from: manifestData) else {
            throw AppError.unsafeFramePack("manifest.json không hợp lệ")
        }
        guard manifest.schemaVersion == 1, manifest.packFormatVersion == 1 else {
            throw AppError.unsafeFramePack("schemaVersion/packFormatVersion không hỗ trợ")
        }
        guard manifest.frames.count <= 300 else {
            throw AppError.unsafeFramePack("Quá nhiều khung trong gói")
        }
        var warnings: [String] = []
        // Validate slot geometry + range/finite (không tin manifest chỉ vì JSON hợp lệ §13.1)
        var frameIDs: Set<String> = []
        for frame in manifest.frames {
            guard !frame.frameId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  frameIDs.insert(frame.frameId).inserted else {
                throw AppError.unsafeFramePack("ID khung bị trống hoặc trùng trong manifest")
            }
            for (reference, orientation) in [(frame.assets.background, frame.assets.backgroundImageOrientation),
                                             (frame.assets.foreground, frame.assets.foregroundImageOrientation)] {
                if let orientation, !(1...8).contains(orientation) || (orientation != 1 && reference == nil) {
                    throw AppError.unsafeFramePack("Hướng ảnh không hợp lệ trong khung '\(frame.name)'")
                }
            }
            // F-VAL-02: ít nhất 1 ô ảnh — không cho khung 0 slot vào thư viện
            guard !frame.slots.isEmpty else {
                throw AppError.unsafeFramePack("Khung '\(frame.name)' không có ô ảnh")
            }
            guard frame.slots.count <= 12 else {
                throw AppError.unsafeFramePack("Khung '\(frame.name)' có \(frame.slots.count) ô (vượt giới hạn tối đa 12 ô)")
            }
            guard (ResourceLimits.canvasMin...ResourceLimits.canvasMax).contains(frame.canvas.width),
                  (ResourceLimits.canvasMin...ResourceLimits.canvasMax).contains(frame.canvas.height),
                  Double(frame.canvas.width) * Double(frame.canvas.height) <= ResourceLimits.maxMegapixels * 1_000_000 else {
                throw AppError.unsafeFramePack("Khung '\(frame.name)' canvas vượt giới hạn")
            }
            var indices: Set<Int> = []
            for slot in frame.slots {
                guard slot.captureIndex >= 1, slot.captureIndex <= 12 else {
                    throw AppError.unsafeFramePack("Khung '\(frame.name)' captureIndex ngoài phạm vi (1...12)")
                }
                guard slot.x.isFinite, slot.y.isFinite, slot.width.isFinite, slot.height.isFinite,
                      slot.width > 0, slot.height > 0 else {
                    throw AppError.unsafeFramePack("Khung '\(frame.name)' có slot không hợp lệ")
                }
                indices.insert(slot.captureIndex)
            }
            guard indices.count == frame.slots.count else {
                throw AppError.unsafeFramePack("Khung '\(frame.name)' có chỉ số ô ảnh trùng lặp")
            }
            if let maxIdx = indices.max(), indices != Set(1...maxIdx) {
                warnings.append("Khung '\(frame.name)' thiếu lượt chụp liên tục")
            }
        }
        // Files: path an toàn + trỏ đúng assets/<sha>.<ext>
        let entryNames = entries.map(\.name)
        guard Set(entryNames).count == entryNames.count else {
            throw AppError.unsafeFramePack("Gói chứa entry trùng tên")
        }
        let entryNameSet = Set(entryNames)
        for declared in manifest.files {
            guard entryNameSet.contains(declared.path) else {
                throw AppError.unsafeFramePack("Gói thiếu tệp đã khai báo: \(declared.path)")
            }
        }
        let declaredShas = Set(manifest.files.map(\.sha256))
        for frame in manifest.frames {
            if let bg = frame.assets.background {
                let sha = bg.replacingOccurrences(of: "sha256:", with: "")
                guard declaredShas.contains(sha) else {
                    throw AppError.unsafeFramePack("Khung '\(frame.name)' tham chiếu nền không có trong gói")
                }
            }
            if let fg = frame.assets.foreground {
                let sha = fg.replacingOccurrences(of: "sha256:", with: "")
                guard declaredShas.contains(sha) else {
                    throw AppError.unsafeFramePack("Khung '\(frame.name)' tham chiếu lớp phủ không có trong gói")
                }
            }
        }

        let validPaths = Set(manifest.files.map(\.path))
        for entry in entries where entry.name != "manifest.json" {
            guard !entry.name.contains(".."), !entry.name.hasPrefix("/"), !entry.name.contains("\0") else {
                throw AppError.unsafeFramePack("Đường dẫn không an toàn: \(entry.name)")
            }
            guard validPaths.contains(entry.name) else {
                warnings.append("Entry lạ trong gói: \(entry.name)")
                continue
            }
            let sha = (entry.name as NSString).lastPathComponent.split(separator: ".").first.map(String.init) ?? ""
            let expected = manifest.files.first { $0.path == entry.name }?.sha256 ?? ""
            if !sha.isEmpty, !expected.isEmpty, sha != expected {
                throw AppError.unsafeFramePack("Tên file asset lệch sha256: \(entry.name)")
            }
        }
        return PackValidationResult(manifest: manifest, entries: [], warnings: warnings)
    }

    /// Xác minh toàn pack vào staging (không đụng thư viện) rồi build preview (§13.2, §2.10).
    public func loadPack(data: Data) throws -> PackValidationResult {
        var result = try Self.validate(data: data)
        let extracted = try verifiedAssets(data: data, manifest: result.manifest)
        // Thumbnail + duplicate detection
        var packEntries: [PackEntry] = []
        let replacements = try replacementOptions(for: result.manifest.frames)
        for packFrame in result.manifest.frames {
            var thumbData: Data? = nil
            var assetCount = 0
            for (reference, orientation) in [(packFrame.assets.background, packFrame.assets.backgroundImageOrientation),
                                             (packFrame.assets.foreground, packFrame.assets.foregroundImageOrientation)] {
                guard let ref = reference else { continue }
                let sha = ref.replacingOccurrences(of: "sha256:", with: "")
                if let data = extracted.first(where: { $0.key.contains(sha) })?.value {
                    if let orientation, orientation != 1 {
                        let image = try AssetStore.validatedFrameImage(data).image
                        var oriented = try ImageNormalizer.orientedFrameLayer(image, orientation: orientation)
                        let scale = min(1, 240 / max(oriented.extent.width, oriented.extent.height))
                        oriented = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                        thumbData = CIContextHolder.shared.context.pngRepresentation(
                            of: oriented, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    } else {
                        thumbData = data
                    }
                    assetCount += 1
                }
            }
            let option = replacements[packFrame.frameId]
            packEntries.append(PackEntry(frame: packFrame, thumbnailData: thumbData,
                                         assetCount: assetCount, isDuplicate: option?.isDuplicate == true,
                                         replacementTarget: option?.target,
                                         replacementUnavailableReason: option?.reason))
        }
        result = PackValidationResult(manifest: result.manifest, entries: packEntries,
                                      warnings: result.warnings)
        return result
    }

    private func verifiedAssets(data: Data, manifest: PackManifest) throws -> [String: Data] {
        let entries = try ZipArchive.read(data: data)
        let orientedSHAs = Set(manifest.frames.flatMap { frame in
            [(frame.assets.background, frame.assets.backgroundImageOrientation),
             (frame.assets.foreground, frame.assets.foregroundImageOrientation)].compactMap { reference, orientation in
                guard let orientation, orientation != 1 else { return nil as String? }
                return reference?.replacingOccurrences(of: "sha256:", with: "")
            }
        })
        var extracted: [String: Data] = [:]
        var totalUncompressed = 0
        for entry in entries {
            if entry.name == "manifest.json" { continue }
            let d = try ZipArchive.extract(data: data, entry: entry,
                                           maxUncompressedBytes: ResourceLimits.maxAssetBytes)
            totalUncompressed += d.count
            guard totalUncompressed <= ResourceLimits.maxPackUncompressedBytes else {
                throw AppError.unsafeFramePack("Tổng dung lượng gói vượt 1GB")
            }
            // Kiểm tra checksum manifest
            if let declared = manifest.files.first(where: { $0.path == entry.name }) {
                let actual = Hashing.sha256Hex(d)
                guard actual == declared.sha256, declared.size == d.count else {
                    throw AppError.unsafeFramePack("Checksum không khớp: \(entry.name)")
                }
                let image = try AssetStore.validatedFrameImage(d)
                if orientedSHAs.contains(actual), image.mediaType != "image/jpeg" {
                    throw AppError.unsafeFramePack("Hướng EXIF chỉ áp dụng cho lớp JPEG")
                }
            }
            extracted[entry.name] = d
        }
        return extracted
    }

    static func packContentHash(packFrame f: PackFrame) -> String {
        struct Layer: Encodable { let sha: String; let placement: String; let orientation: Int? }
        struct Slot: Encodable {
            let index: Int; let geometry: [Double]; let mask: String; let crop: String
        }
        struct Content: Encodable {
            let width: Int; let height: Int; let color: [Double]; let explicitWhite: Bool
            let background: Layer?; let foreground: Layer?; let slots: [Slot]
        }
        func layer(_ ref: String?, _ placement: String?, _ fallback: PlacementKind, _ orientation: Int?) -> Layer? {
            ref.map { Layer(sha: $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : $0.lowercased(),
                            placement: (PlacementKind(rawValue: placement ?? "") ?? fallback).rawValue,
                            orientation: orientation == 1 ? nil : orientation) }
        }
        let color = ColorHex.toCGColor(f.backgroundColor ?? "#FFFFFFFF")
            .converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components ?? [1,1,1,1]
        let slots = f.slots.enumerated().sorted {
            ($0.element.zOrder, $0.offset) < ($1.element.zOrder, $1.offset)
        }.map { _, s in
            Slot(index: s.captureIndex,
                 geometry: [s.x,s.y,s.width,s.height,s.rotationDegrees ?? 0,s.cornerRadius ?? 0].map { $0 == 0 ? 0 : $0 },
                 mask: (MaskType(rawValue: s.mask ?? "") ?? .rectangle).rawValue,
                 crop: (CropMode(rawValue: s.cropMode ?? "") ?? .autoFace).rawValue)
        }
        let content = Content(width: f.canvas.width, height: f.canvas.height,
            color: color.map(Double.init), explicitWhite: f.explicitWhite ?? false,
            background: layer(f.assets.background, f.backgroundPlacement, .aspectFill, f.assets.backgroundImageOrientation),
            foreground: layer(f.assets.foreground, f.foregroundPlacement, .aspectFit, f.assets.foregroundImageOrientation), slots: slots)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(content) else { return "" }
        return Hashing.sha256Hex(data)
    }

    private func contentHash(frame: Frame, revision rev: FrameRevision) throws -> String? {
        let revID = rev.id
        let slots = try frames.getSlots(revisionID: revID)
        let explicit = try db.query("SELECT value FROM app_state WHERE key=?", [.text("explicit_white_\(revID)")]).first?["value"].stringValue
        let background = rev.backgroundAssetID.flatMap { assets.assetInfo(assetID: $0)?.sha256 }
        let foreground = rev.foregroundAssetID.flatMap { assets.assetInfo(assetID: $0)?.sha256 }
        guard (rev.backgroundAssetID == nil || background != nil),
              (rev.foregroundAssetID == nil || foreground != nil) else { return nil }
        return Self.packContentHash(packFrame: PackFrame(frameId: frame.id, name: frame.name, category: nil,
            canvas: PackCanvas(width: rev.canvasWidth, height: rev.canvasHeight),
            slots: slots.map { PackSlot(id: $0.id, captureIndex: $0.captureIndex, x: $0.x, y: $0.y,
                width: $0.width, height: $0.height, rotationDegrees: $0.rotationDegrees, zOrder: $0.zOrder,
                mask: $0.maskType.rawValue, cornerRadius: $0.cornerRadius, cropMode: $0.defaultCropMode.rawValue) },
            assets: PackFrameAssets(background: background, foreground: foreground,
                                    backgroundImageOrientation: rev.backgroundImageOrientation,
                                    foregroundImageOrientation: rev.foregroundImageOrientation),
            backgroundColor: rev.backgroundColorHex, backgroundPlacement: rev.backgroundPlacement.rawValue,
            foregroundPlacement: rev.foregroundPlacement.rawValue, explicitWhite: explicit == "1" || explicit == "true"))
    }

    private struct ReplacementOption {
        let target: PackReplacementTarget?
        let reason: String?
        let isDuplicate: Bool
    }

    private func replacementOptions(for incoming: [PackFrame]) throws -> [String: ReplacementOption] {
        guard !incoming.isEmpty else { return [:] }
        let library = try frames.listFrames(includeTrashed: true)
        let knownIDs = Set(library.map(\.id))
        var active: [String: PackReplacementTarget] = [:]
        var hashes: [String: [PackReplacementTarget]] = [:]
        for frame in library where frame.lifecycle == .active {
            guard let revisionID = frame.currentRevisionID, let rev = try frames.getRevision(id: revisionID),
                  rev.frameID == frame.id else { continue }
            let target = PackReplacementTarget(id: frame.id, revisionID: revisionID, name: frame.name)
            active[frame.id] = target
            if let hash = try contentHash(frame: frame, revision: rev), !hash.isEmpty {
                hashes[hash, default: []].append(target)
            }
        }
        return Dictionary(uniqueKeysWithValues: incoming.map { frame in
            let matches = hashes[Self.packContentHash(packFrame: frame)] ?? []
            let target = knownIDs.contains(frame.frameId) ? active[frame.frameId] : (matches.count == 1 ? matches.first : nil)
            let reason: String?
            if target != nil { reason = nil }
            else if knownIDs.contains(frame.frameId) { reason = "Khung gốc không còn khả dụng để thay thế." }
            else if matches.count > 1 { reason = "Nhiều khung có cùng nội dung. Hãy chọn Bản sao hoặc Bỏ qua." }
            else { reason = "Không tìm thấy khung đích. Hãy chọn Bản sao hoặc Bỏ qua." }
            return (frame.frameId, ReplacementOption(target: target, reason: reason, isDuplicate: !matches.isEmpty))
        })
    }

    // MARK: - Import (§13.2, PACK-01..05)

    public enum PackItemStatus: Equatable, Sendable {
        case imported(frameID: String)
        case replaced(frameID: String)
        case skipped
        case unselected
        case failedBeforeWrite(String)
        case partiallyWritten(String)

        public var isSuccess: Bool {
            switch self {
            case .imported, .replaced, .skipped, .unselected: return true
            default: return false
            }
        }

        public var message: String {
            switch self {
            case .imported(let id): return id
            case .replaced(let id): return id
            case .skipped: return "Bỏ qua"
            case .unselected: return "Đã bỏ chọn"
            case .failedBeforeWrite(let r): return "Thất bại trước khi ghi: \(r)"
            case .partiallyWritten(let r): return "Có thể đã ghi một phần: \(r)"
            }
        }
    }

    public struct ImportChoice: Equatable, Sendable {
        public var packFrameID: String
        public var policy: PackDuplicatePolicy
        public var selected: Bool

        public init(packFrameID: String, policy: PackDuplicatePolicy, selected: Bool) {
            self.packFrameID = packFrameID
            self.policy = policy
            self.selected = selected
        }
    }

    /// Nhập theo lựa chọn từng khung; per-frame transaction; kết quả từng item (§13.2).
    public func applyImport(result: PackValidationResult,
                            choices: [ImportChoice],
                            data: Data) throws -> [String: Result<String, String>] {
        let detailed = try applyImportDetailed(result: result, choices: choices, data: data)
        var outcomes: [String: Result<String, String>] = [:]
        for (id, status) in detailed {
            switch status {
            case .imported(let frameID), .replaced(let frameID):
                outcomes[id] = .success(frameID)
            case .skipped:
                outcomes[id] = .success("Bỏ qua")
            case .unselected:
                outcomes[id] = .success("Đã bỏ chọn")
            case .failedBeforeWrite(let err):
                outcomes[id] = .failure("Thất bại trước khi ghi: \(err)")
            case .partiallyWritten(let err):
                outcomes[id] = .failure("Có thể đã ghi một phần: \(err)")
            }
        }
        return outcomes
    }

    /// Nhập chi tiết phân loại kết quả từng mục theo mốc ghi dữ liệu (§13.2, FRM-01).
    public func applyImportDetailed(result: PackValidationResult,
                                    choices: [ImportChoice],
                                    data: Data) throws -> [String: PackItemStatus] {
        let validated = try Self.validate(data: data)
        guard validated.manifest == result.manifest else {
            throw AppError.unsafeFramePack("Gói khung đã thay đổi sau khi xem trước")
        }
        let framesByID = Dictionary(uniqueKeysWithValues: validated.manifest.frames.map { ($0.frameId, $0) })
        var choiceIDs: Set<String> = []
        guard choices.allSatisfy({ framesByID[$0.packFrameID] != nil && choiceIDs.insert($0.packFrameID).inserted }) else {
            throw AppError.unsafeFramePack("Lựa chọn chứa ID khung trùng hoặc không có trong manifest")
        }
        let extracted = try verifiedAssets(data: data, manifest: validated.manifest)
        var statuses: [String: PackItemStatus] = [:]
        let replaceIDs = Set(choices.filter { $0.selected && $0.policy == .replace }.map(\.packFrameID))
        let replacements: [String: ReplacementOption]
        if result.entries.isEmpty {
            // The format-only API has no preview. Resolve targets once before any row writes.
            replacements = try replacementOptions(for: validated.manifest.frames.filter { replaceIDs.contains($0.frameId) })
        } else {
            replacements = result.entries.reduce(into: [:]) { options, entry in
                guard replaceIDs.contains(entry.id) else { return }
                options[entry.id] = ReplacementOption(target: entry.replacementTarget,
                    reason: entry.replacementUnavailableReason, isDuplicate: entry.isDuplicate)
            }
        }
        let targetCounts = Dictionary(grouping: replacements.values.compactMap(\.target), by: \.id).mapValues(\.count)
        for choice in choices {
            guard choice.selected else {
                statuses[choice.packFrameID] = .unselected
                continue
            }
            guard let packFrame = framesByID[choice.packFrameID] else {
                statuses[choice.packFrameID] = .failedBeforeWrite("Không tìm thấy khung trong manifest")
                continue
            }
            if choice.policy == .skip {
                statuses[choice.packFrameID] = .skipped
                continue
            }
            var didEnterWriteZone = false
            do {
                switch choice.policy {
                case .skip:
                    statuses[choice.packFrameID] = .skipped
                case .copy:
                    let newID = try importFrame(packFrame: packFrame, extracted: extracted,
                                                target: nil,
                                                onEnteredWriteZone: { didEnterWriteZone = true })
                    statuses[choice.packFrameID] = .imported(frameID: newID)
                case .replace:
                    guard let target = replacements[choice.packFrameID]?.target else {
                        throw AppError.invalidState(replacements[choice.packFrameID]?.reason ?? "Không tìm thấy khung đích trong bản xem trước.")
                    }
                    guard targetCounts[target.id] == 1 else {
                        throw AppError.invalidState("Nhiều mục đang chọn thay thế cùng một khung.")
                    }
                    let id = try importFrame(packFrame: packFrame, extracted: extracted,
                                             target: target,
                                             onEnteredWriteZone: { didEnterWriteZone = true })
                    statuses[choice.packFrameID] = .replaced(frameID: id)
                }
            } catch {
                if didEnterWriteZone {
                    statuses[choice.packFrameID] = .partiallyWritten(error.localizedDescription)
                } else {
                    statuses[choice.packFrameID] = .failedBeforeWrite(error.localizedDescription)
                }
            }
        }
        EventBus.shared.post(.frameLibraryChanged(frameID: nil))
        EventBus.shared.post(.categoryChanged)
        return statuses
    }

    private func importFrame(packFrame: PackFrame, extracted: [String: Data],
                             target: PackReplacementTarget?,
                             onEnteredWriteZone: () -> Void) throws -> String {
        func bytes(_ reference: String?) throws -> Data? {
            guard let reference else { return nil }
            let sha = reference.replacingOccurrences(of: "sha256:", with: "")
            guard let data = extracted.first(where: {
                ($0.key as NSString).lastPathComponent.split(separator: ".").first.map(String.init) == sha
            })?.value else { throw AppError.missingFrameAssets }
            return data
        }
        let background = try bytes(packFrame.assets.background)
        let foreground = try bytes(packFrame.assets.foreground)
        var draft = FrameRevision(frameID: "", revisionNo: 1,
            canvasWidth: packFrame.canvas.width, canvasHeight: packFrame.canvas.height,
            backgroundAssetID: packFrame.assets.background, foregroundAssetID: packFrame.assets.foreground,
            backgroundColorHex: packFrame.backgroundColor ?? "#FFFFFFFF",
            backgroundPlacement: PlacementKind(rawValue: packFrame.backgroundPlacement ?? "") ?? .aspectFill,
            foregroundPlacement: PlacementKind(rawValue: packFrame.foregroundPlacement ?? "") ?? .aspectFit)
        let slots = packFrame.slots.enumerated().sorted {
            ($0.element.zOrder, $0.offset) < ($1.element.zOrder, $1.offset)
        }.map { _, s in
            FrameSlot(captureIndex: s.captureIndex, x: s.x, y: s.y, width: s.width, height: s.height,
                rotationDegrees: s.rotationDegrees ?? 0, zOrder: s.zOrder,
                maskType: MaskType(rawValue: s.mask ?? "") ?? .rectangle, cornerRadius: s.cornerRadius ?? 0,
                defaultCropMode: CropMode(rawValue: s.cropMode ?? "") ?? .autoFace)
        }
        draft.backgroundImageOrientation = packFrame.assets.backgroundImageOrientation
        draft.foregroundImageOrientation = packFrame.assets.foregroundImageOrientation
        let overlay = try foreground.map {
            try ImageNormalizer.orientedFramePixels(AssetStore.validatedFrameImage($0).image,
                                                   orientation: draft.foregroundImageOrientation)
        }
        if let issue = try FrameRepository.configuredIssues(draft: draft, slots: slots, foreground: overlay).first {
            throw AppError.invalidState(issue.message)
        }
        let token = try target.map {
            try OperationCoordinator.shared.acquire(key: "frame:\($0.id)", reason: "Thay thế khung từ Frame Pack")
        }
        defer { token?.release() }
        if let target {
            guard let current = try frames.getFrame(id: target.id), current.lifecycle == .active,
                  current.currentRevisionID == target.revisionID else {
                throw AppError.invalidState("Khung đích đã thay đổi. Hãy mở lại gói để xem trước.")
            }
        }
        let ownerKey = "pack-\(IDFactory.new())"
        onEnteredWriteZone()
        do {
            for (data, role) in [(background, AssetKind.frameBackground), (foreground, AssetKind.frameForeground)] {
                guard let data else { continue }
                let media = try AssetStore.validatedFrameImage(data).mediaType
                let asset = try assets.store(data: data, mediaType: media, purpose: role.rawValue,
                    ownerType: "frame_revision", ownerID: ownerKey)
                if role == .frameBackground { draft.backgroundAssetID = asset.id }
                else { draft.foregroundAssetID = asset.id }
            }
            if let target {
                _ = try frames.saveConfiguredRevision(frameID: target.id, expectedRevisionID: target.revisionID,
                    name: nil, draft: draft, slots: slots, stagedOwnerID: ownerKey,
                    explicitWhite: packFrame.explicitWhite == true, categoryName: packFrame.category, parentToken: token)
                return target.id
            }
            let name = FrameRepository.uniqueName(base: packFrame.name, existing: try frames.listFrames().map(\.name))
            return try frames.createConfiguredFrame(name: name, categoryID: nil, draft: draft, slots: slots,
                stagedOwnerID: ownerKey, explicitWhite: packFrame.explicitWhite == true,
                categoryName: packFrame.category).id
        } catch let importError {
            // On success the revision transaction already transferred and removed these references.
            do { try assets.removeReferences(ownerType: "frame_revision", ownerID: ownerKey) }
            catch let cleanupError {
                throw AppError.ioFailure("\(importError.localizedDescription) Không dọn được tham chiếu tạm: \(cleanupError.localizedDescription)")
            }
            throw importError
        }
    }
}
