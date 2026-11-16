import Foundation
import CoreGraphics

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
                assets: PackFrameAssets(background: bgRef, foreground: fgRef),
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
        for frame in manifest.frames {
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
        let existingFrames = try frames.listFrames()
        var existingHashes: Set<String> = []
        for frameID in existingFrames.map(\.id) {
            if let snap = try? createContentHash(frameID: frameID) {
                existingHashes.insert(snap)
            }
        }
        for packFrame in result.manifest.frames {
            var thumbData: Data? = nil
            var assetCount = 0
            for ref in [packFrame.assets.background, packFrame.assets.foreground].compactMap({ $0 }) {
                let sha = ref.replacingOccurrences(of: "sha256:", with: "")
                if let data = extracted.first(where: { $0.key.contains(sha) })?.value {
                    thumbData = data
                    assetCount += 1
                }
            }
            let contentHash = Self.packContentHash(packFrame: packFrame)
            let isDup = existingHashes.contains(contentHash)
            packEntries.append(PackEntry(frame: packFrame, thumbnailData: thumbData,
                                         assetCount: assetCount, isDuplicate: isDup,
                                         existingFrameID: nil))
        }
        result = PackValidationResult(manifest: result.manifest, entries: packEntries,
                                      warnings: result.warnings)
        return result
    }

    private func verifiedAssets(data: Data, manifest: PackManifest) throws -> [String: Data] {
        let entries = try ZipArchive.read(data: data)
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
                _ = try AssetStore.validatedFrameImage(d)
            }
            extracted[entry.name] = d
        }
        return extracted
    }

    static func packContentHash(packFrame: PackFrame) -> String {
        var material = "\(packFrame.canvas.width)x\(packFrame.canvas.height)|\(packFrame.backgroundColor ?? "#FFFFFFFF")"
        material += "|\(packFrame.assets.background ?? "-")|\(packFrame.assets.foreground ?? "-")"
        for s in packFrame.slots.sorted(by: { $0.zOrder < $1.zOrder }) {
            material += "|\(s.captureIndex),\(s.x),\(s.y),\(s.width),\(s.height),\(s.rotationDegrees ?? 0),\(s.zOrder),\(s.mask ?? "rectangle")"
        }
        return Hashing.sha256Hex(Data(material.utf8))
    }

    func createContentHash(frameID: String) throws -> String? {
        guard let frame = try frames.getFrame(id: frameID),
              let revID = frame.currentRevisionID,
              let rev = try frames.getRevision(id: revID) else { return nil }
        let slots = try frames.getSlots(revisionID: revID)
        let bg = rev.backgroundAssetID.flatMap { assets.assetInfo(assetID: $0)?.sha256 } ?? "-"
        let fg = rev.foregroundAssetID.flatMap { assets.assetInfo(assetID: $0)?.sha256 } ?? "-"
        var material = "\(rev.canvasWidth)x\(rev.canvasHeight)|\(rev.backgroundColorHex)"
        material += "|\(bg)|\(fg)"
        for s in slots.sorted(by: { $0.zOrder < $1.zOrder }) {
            material += "|\(s.captureIndex),\(s.x),\(s.y),\(s.width),\(s.height),\(s.rotationDegrees),\(s.zOrder),\(s.maskType.rawValue)"
        }
        return Hashing.sha256Hex(Data(material.utf8))
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
        let extracted = try verifiedAssets(data: data, manifest: validated.manifest)
        var statuses: [String: PackItemStatus] = [:]
        let existingNames = try frames.listFrames().map(\.name)
        for choice in choices {
            guard choice.selected else {
                statuses[choice.packFrameID] = .unselected
                continue
            }
            guard let packFrame = result.manifest.frames.first(where: { $0.frameId == choice.packFrameID }) else {
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
                                                forceNewID: true, existingNames: existingNames,
                                                onEnteredWriteZone: { didEnterWriteZone = true })
                    statuses[choice.packFrameID] = .imported(frameID: newID)
                case .replace:
                    let id = try importFrame(packFrame: packFrame, extracted: extracted,
                                             forceNewID: false, existingNames: existingNames,
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
                             forceNewID: Bool, existingNames: [String],
                             onEnteredWriteZone: () -> Void) throws -> String {
        let ownerKey = "pack-\(packFrame.frameId)-\(forceNewID ? "copy" : "replace")-\(IDFactory.new())"
        onEnteredWriteZone()
        do {
            // Tải asset
            var bgAsset: AssetStore.StoredAsset?
            var fgAsset: AssetStore.StoredAsset?
            if let bgRef = packFrame.assets.background {
                let sha = bgRef.replacingOccurrences(of: "sha256:", with: "")
                if let data = extracted.first(where: { $0.key.contains(sha) })?.value {
                    let isJpeg = data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
                    let mediaType = isJpeg ? "image/jpeg" : "image/png"
                    bgAsset = try assets.store(data: data, mediaType: mediaType, purpose: AssetKind.frameBackground.rawValue,
                                               ownerType: "frame_revision", ownerID: ownerKey)
                }
            }
            if let fgRef = packFrame.assets.foreground {
                let sha = fgRef.replacingOccurrences(of: "sha256:", with: "")
                if let data = extracted.first(where: { $0.key.contains(sha) })?.value {
                    let isJpeg = data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
                    let mediaType = isJpeg ? "image/jpeg" : "image/png"
                    fgAsset = try assets.store(data: data, mediaType: mediaType, purpose: AssetKind.frameForeground.rawValue,
                                               ownerType: "frame_revision", ownerID: ownerKey)
                }
            }
            // Category display name → tạo nếu chưa có (không fail cả pack nếu category lỗi)
            var categoryID: String? = nil
            if let catName = packFrame.category, !catName.isEmpty {
                categoryID = try? frames.createCategory(name: catName).id
                if categoryID == nil, let all = try? frames.listCategories() {
                    categoryID = all.first { $0.name.lowercased() == catName.lowercased() }?.id
                }
            }

            if !forceNewID, let existing = try frames.listFrames().first(where: {
                $0.name.lowercased() == packFrame.name.lowercased()
            }), let _ = existing.currentRevisionID {
                // Thay thế: tạo revision mới trên frame được chọn (PACK-05), session cũ giữ snapshot
                var rev = FrameRevision(frameID: existing.id, revisionNo: 1,
                                        canvasWidth: packFrame.canvas.width, canvasHeight: packFrame.canvas.height,
                                        backgroundAssetID: bgAsset?.id, foregroundAssetID: fgAsset?.id,
                                        backgroundColorHex: packFrame.backgroundColor ?? "#FFFFFFFF",
                                        backgroundPlacement: PlacementKind(rawValue: packFrame.backgroundPlacement ?? "") ?? .aspectFill,
                                        foregroundPlacement: PlacementKind(rawValue: packFrame.foregroundPlacement ?? "") ?? .aspectFit)
                _ = rev.revisionNo
                let slots = packFrame.slots.map { s in
                    FrameSlot(id: IDFactory.new(), frameRevisionID: rev.id,
                              captureIndex: s.captureIndex, x: s.x, y: s.y, width: s.width, height: s.height,
                              rotationDegrees: s.rotationDegrees ?? 0, zOrder: s.zOrder,
                              maskType: MaskType(rawValue: s.mask ?? "") ?? .rectangle,
                              cornerRadius: s.cornerRadius ?? 0,
                              defaultCropMode: CropMode(rawValue: s.cropMode ?? "") ?? .autoFace)
                }
                let committed = try frames.commitRevision(frameID: existing.id, draft: rev, slots: slots)
                // Trạng thái theo validator thật (F-VAL) — không set .ready mù (§7.5)
                let issues = FrameValidator.validate(canvasWidth: rev.canvasWidth, canvasHeight: rev.canvasHeight,
                                                     slots: slots, hasBackground: bgAsset != nil,
                                                     hasForeground: fgAsset != nil,
                                                     backgroundColorHex: rev.backgroundColorHex)
                try frames.setValidationStatus(frameID: existing.id, status: issues.isEmpty ? .ready : .invalid)
                // Chuyển owner references từ key tạm sang revision thật (tránh orphan).
                try assets.moveReferences(ownerType: "frame_revision", fromOwnerID: ownerKey, toOwnerID: committed.id)
                if packFrame.explicitWhite == true {
                    try? db.run("INSERT OR REPLACE INTO app_state(key, value) VALUES(?, '1')", [.text("explicit_white_\(committed.id)")])
                }
                if let cid = categoryID { try frames.setCategory(frameID: existing.id, categoryID: cid) }
                return existing.id
            }

            // Bản sao: frame mới + ID mới (PACK-04)
            let name = FrameRepository.uniqueName(base: packFrame.name, existing: existingNames)
            let newFrame = try frames.createEmptyFrame(name: name, categoryID: categoryID,
                                                       canvasWidth: packFrame.canvas.width,
                                                       canvasHeight: packFrame.canvas.height)
            var rev = FrameRevision(frameID: newFrame.id, revisionNo: 1,
                                    canvasWidth: packFrame.canvas.width, canvasHeight: packFrame.canvas.height,
                                    backgroundAssetID: bgAsset?.id, foregroundAssetID: fgAsset?.id,
                                    backgroundColorHex: packFrame.backgroundColor ?? "#FFFFFFFF",
                                    backgroundPlacement: PlacementKind(rawValue: packFrame.backgroundPlacement ?? "") ?? .aspectFill,
                                    foregroundPlacement: PlacementKind(rawValue: packFrame.foregroundPlacement ?? "") ?? .aspectFit)
            _ = rev.revisionNo
            let slots = packFrame.slots.map { s in
                FrameSlot(id: IDFactory.new(), frameRevisionID: rev.id,
                          captureIndex: s.captureIndex, x: s.x, y: s.y, width: s.width, height: s.height,
                          rotationDegrees: s.rotationDegrees ?? 0, zOrder: s.zOrder,
                          maskType: MaskType(rawValue: s.mask ?? "") ?? .rectangle,
                          cornerRadius: s.cornerRadius ?? 0,
                          defaultCropMode: CropMode(rawValue: s.cropMode ?? "") ?? .autoFace)
            }
            let committed = try frames.commitRevision(frameID: newFrame.id, draft: rev, slots: slots)
            // Trạng thái theo validator thật (F-VAL) — không set .ready mù (§7.5)
            let issues = FrameValidator.validate(canvasWidth: rev.canvasWidth, canvasHeight: rev.canvasHeight,
                                                 slots: slots, hasBackground: bgAsset != nil,
                                                 hasForeground: fgAsset != nil,
                                                 backgroundColorHex: rev.backgroundColorHex)
            try frames.setValidationStatus(frameID: newFrame.id, status: issues.isEmpty ? .ready : .invalid)
            // Chuyển owner references từ key tạm sang revision thật
            try assets.moveReferences(ownerType: "frame_revision", fromOwnerID: ownerKey, toOwnerID: committed.id)
            if packFrame.explicitWhite == true {
                try? db.run("INSERT OR REPLACE INTO app_state(key, value) VALUES(?, '1')", [.text("explicit_white_\(committed.id)")])
            }
            return newFrame.id
        } catch {
            try? assets.removeReferences(ownerType: "frame_revision", ownerID: ownerKey)
            throw error
        }
    }
}
