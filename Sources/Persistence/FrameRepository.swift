import Foundation
import CoreGraphics

/// FrameRepository: Frame/category/revision CRUD + snapshot (§17.1).
/// Views không truy cập trực tiếp; chỉ gọi qua services/ViewModels.
public final class FrameRepository: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let assets: AssetStore
    private let layout: FileLayout
#if DEBUG
    // Set before a QA operation and clear only after it has completed; never used in Release.
    var onDuplicateLockedForTesting: (@Sendable () throws -> Void)?
#endif

    public init(db: SQLiteDatabase, assets: AssetStore, layout: FileLayout) {
        self.db = db; self.assets = assets; self.layout = layout
    }

    static let jsonEncoder = JSONEncoder()
    static let jsonDecoder = JSONDecoder()

    // MARK: - Read

    public func listFrames(includeTrashed: Bool = false) throws -> [Frame] {
        let sql = includeTrashed
            ? "SELECT * FROM frames ORDER BY updated_at_ms DESC"
            : "SELECT * FROM frames WHERE lifecycle='active' ORDER BY updated_at_ms DESC"
        return try db.query(sql).compactMap(Self.frame(from:))
    }

    public func listReadyFrames() throws -> [Frame] {
        try db.query("""
            SELECT * FROM frames
            WHERE lifecycle='active' AND validation_status='ready' AND current_revision_id IS NOT NULL
            ORDER BY updated_at_ms DESC
            """).compactMap(Self.frame(from:))
    }

    public func getFrame(id: String) throws -> Frame? {
        let rows = try db.query("SELECT * FROM frames WHERE id=?", [.text(id)])
        return rows.first.flatMap(Self.frame(from:))
    }

    public func frameCount(in categoryID: String?) throws -> Int {
        let rows: [SQLiteRow]
        if let cid = categoryID {
            rows = try db.query("SELECT COUNT(*) c FROM frames WHERE lifecycle='active' AND category_id=?", [.text(cid)])
        } else {
            rows = try db.query("SELECT COUNT(*) c FROM frames WHERE lifecycle='active' AND category_id IS NULL")
        }
        return Int(rows.first?["c"]?.intValue ?? 0)
    }

    public static func frame(from row: SQLiteRow) -> Frame? {
        // id là TEXT PRIMARY KEY (Schema v1) — phải đọc bằng stringValue, không phải intValue.
        let id = row["id"].stringValue
        guard !id.isEmpty else { return nil }
        return Frame(
            id: id,
            name: row["name"].stringValue,
            categoryID: row["category_id"].stringValue.isEmpty ? nil : row["category_id"].stringValue,
            currentRevisionID: row["current_revision_id"].stringValue.isEmpty ? nil : row["current_revision_id"].stringValue,
            isFavorite: row["is_favorite"].boolValue,
            isBuiltIn: row["is_built_in"].boolValue,
            validationStatus: FrameValidationStatus(rawValue: row["validation_status"].stringValue) ?? .unconfigured,
            lifecycle: FrameLifecycle(rawValue: row["lifecycle"].stringValue) ?? .active,
            createdAtMs: row["created_at_ms"]?.int64Value ?? 0,
            updatedAtMs: row["updated_at_ms"]?.int64Value ?? 0)
    }

    // MARK: - Revision & slots

    public func getRevision(id: String) throws -> FrameRevision? {
        let rows = try db.query("""
            SELECT r.*, m.value AS layer_orientation
            FROM frame_revisions r LEFT JOIN app_state m ON m.key='frame_layer_exif_' || r.id
            WHERE r.id=?
            """, [.text(id)])
        guard let r = rows.first else { return nil }
        var revision = FrameRevision(
            id: r["id"].stringValue, frameID: r["frame_id"].stringValue,
            revisionNo: r["revision_no"]?.intValue ?? 1,
            canvasWidth: r["canvas_width"]?.intValue ?? 1200, canvasHeight: r["canvas_height"]?.intValue ?? 1800,
            backgroundAssetID: r["background_asset_id"].stringValue.isEmpty ? nil : r["background_asset_id"].stringValue,
            foregroundAssetID: r["foreground_asset_id"].stringValue.isEmpty ? nil : r["foreground_asset_id"].stringValue,
            backgroundColorHex: r["background_color"].stringValue,
            backgroundPlacement: PlacementKind(rawValue: r["background_placement"].stringValue) ?? .aspectFill,
            foregroundPlacement: PlacementKind(rawValue: r["foreground_placement"].stringValue) ?? .aspectFit,
            geometryVersion: r["geometry_version"]?.intValue ?? 1,
            createdAtMs: r["created_at_ms"]?.int64Value ?? 0)
        if let metadata = r["layer_orientation"], metadata != .null {
            guard let layers = try? Self.jsonDecoder.decode(LayerOrientations.self, from: Data(metadata.stringValue.utf8)) else {
                throw AppError.invalidState("Dữ liệu hướng ảnh của khung không hợp lệ")
            }
            revision.backgroundImageOrientation = try Self.validatedOrientation(layers.background, assetID: revision.backgroundAssetID)
            revision.foregroundImageOrientation = try Self.validatedOrientation(layers.foreground, assetID: revision.foregroundAssetID)
        }
        return revision
    }

    private struct LayerOrientations: Codable {
        var background: Int?
        var foreground: Int?
    }

    private static func validatedOrientation(_ value: Int?, assetID: String?) throws -> Int? {
        guard let value, value != 1 else { return nil }
        guard (2...8).contains(value), assetID != nil else {
            throw AppError.invalidState("Dữ liệu hướng ảnh của khung không hợp lệ")
        }
        return value
    }

    public func getSlots(revisionID: String) throws -> [FrameSlot] {
        try db.query("SELECT * FROM frame_slots WHERE frame_revision_id=? ORDER BY z_order", [.text(revisionID)]).map { r in
            FrameSlot(id: r["id"].stringValue, frameRevisionID: r["frame_revision_id"].stringValue,
                      captureIndex: r["capture_index"]?.intValue ?? 1,
                      x: r["x"]?.doubleValue ?? 0, y: r["y"]?.doubleValue ?? 0,
                      width: r["width"]?.doubleValue ?? 0.1, height: r["height"]?.doubleValue ?? 0.1,
                      rotationDegrees: r["rotation_degrees"]?.doubleValue ?? 0,
                      zOrder: r["z_order"]?.intValue ?? 0,
                      maskType: MaskType(rawValue: r["mask_type"].stringValue) ?? .rectangle,
                      cornerRadius: r["corner_radius"]?.doubleValue ?? 0,
                      defaultCropMode: CropMode(rawValue: r["default_crop_mode"].stringValue) ?? .autoFace)
        }
    }

    /// Lưu revision mới (bất biến) + slots + cập nhật current_revision_id trong MỘT transaction (§6.5).
    /// BUG-FRM-01: Luôn cấp ID mới cho revision và từng slot để caller không bị đụng UNIQUE constraint.
    /// FK vòng frames.current_revision_id → revision cùng frame được đảm bảo tại đây (§16.2.1).
    public func commitRevision(frameID: String, draft: FrameRevision, slots: [FrameSlot]) throws -> FrameRevision {
        try commitRevision(frameID: frameID, draft: draft, slots: slots, replacing: nil, stagedOwnerID: nil)
    }

    func commitRevision(frameID: String, draft: FrameRevision, slots: [FrameSlot],
                        replacing expectedRevisionID: String?, stagedOwnerID: String?) throws -> FrameRevision {
        try db.withTransaction { tx in
            try writeRevision(frameID: frameID, draft: draft, slots: slots,
                              replacing: expectedRevisionID, stagedOwnerID: stagedOwnerID, tx: tx)
        }
    }

    /// A configured frame must pass the same pixel checks at every write/use boundary.
    static func configuredIssues(draft: FrameRevision, slots: [FrameSlot], foreground: CGImage?) throws -> [ValidationIssue] {
        var issues = FrameValidator.validate(revision: draft, slots: slots)
        guard issues.isEmpty else { return issues }
        if draft.foregroundAssetID != nil {
            guard let foreground else { throw AppError.missingFrameAssets }
            let blocked = try PNGAutoAlignmentService.blockedSlots(overlay: foreground, draft: draft, slots: slots)
            for number in blocked {
                issues.append(ValidationIssue(code: "F-VAL-09", slotID: slots[number - 1].id,
                    message: "Lớp phủ che kín ô \(number). Hãy chỉnh bố cục hoặc làm trong ô ảnh."))
            }
        }
        return issues
    }

    func configuredIssues(draft: FrameRevision, slots: [FrameSlot]) throws -> [ValidationIssue] {
        if let background = draft.backgroundAssetID { _ = try assets.loadVerifiedImage(assetID: background) }
        let foreground = try draft.foregroundAssetID.map {
            try ImageNormalizer.orientedFramePixels(assets.loadVerifiedImage(assetID: $0),
                                                   orientation: draft.foregroundImageOrientation)
        }
        return try Self.configuredIssues(draft: draft, slots: slots, foreground: foreground)
    }

    private func requireConfigured(_ draft: FrameRevision, slots: [FrameSlot]) throws {
        if let issue = try configuredIssues(draft: draft, slots: slots).first {
            throw AppError.invalidState(issue.message)
        }
    }

    /// Does not persist or mark old frames invalid; repair and existing snapshots remain accessible.
    func validatedSnapshotForUse(frameID: String, expectedRevisionID: String? = nil, persist: Bool = false,
                                 parentToken: OperationCoordinator.OperationToken? = nil) throws -> FrameSnapshot {
        let token = try OperationCoordinator.shared.acquire(key: "frame:\(frameID)", reason: "Kiểm tra khung", parentToken: parentToken)
        defer { token.release() }
        guard let frame = try getFrame(id: frameID), frame.lifecycle == .active, frame.validationStatus == .ready,
              let revisionID = frame.currentRevisionID,
              expectedRevisionID == nil || expectedRevisionID == revisionID,
              let draft = try getRevision(id: revisionID) else { throw AppError.frameUnconfigured }
        try requireConfigured(draft, slots: getSlots(revisionID: revisionID))
        return try createSnapshot(frameID: frameID, persist: persist)
    }

    @discardableResult
    func saveConfiguredRevision(frameID: String, expectedRevisionID: String, name: String,
                                draft: FrameRevision, slots: [FrameSlot], stagedOwnerID: String,
                                explicitWhite: Bool, categoryID: String? = nil, categoryName: String? = nil) throws -> FrameRevision {
        let token = try OperationCoordinator.shared.acquire(key: "frame:\(frameID)", reason: "Lưu bố cục khung")
        defer { token.release() }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidState("Tên khung không được để trống") }
        try requireConfigured(draft, slots: slots)
        return try db.withTransaction { tx in
            let revision = try writeRevision(frameID: frameID, draft: draft, slots: slots,
                replacing: expectedRevisionID, stagedOwnerID: stagedOwnerID, tx: tx)
            try tx.run("UPDATE frames SET name=?, validation_status='ready' WHERE id=?", [.text(name), .text(frameID)])
            if let categoryID = try resolveCategory(categoryName, tx: tx) ?? categoryID {
                try tx.run("UPDATE frames SET category_id=? WHERE id=?", [.text(categoryID), .text(frameID)])
            }
            if explicitWhite {
                try tx.run("INSERT OR REPLACE INTO app_state(key,value,updated_at_ms) VALUES(?, '1', ?)", [.text("explicit_white_\(revision.id)"), .int(Time.nowMs())])
            }
            return revision
        }
    }

    private func writeRevision(frameID: String, draft: FrameRevision, slots: [FrameSlot],
                               replacing expectedRevisionID: String? = nil, stagedOwnerID: String?,
                               tx: SQLiteDatabase.TransactionHandle) throws -> FrameRevision {
        if let expectedRevisionID {
            let current = try tx.query("SELECT current_revision_id FROM frames WHERE id=? AND lifecycle='active'",
                                       [.text(frameID)]).first?["current_revision_id"]?.stringValue
            guard current == expectedRevisionID else {
                throw AppError.invalidState("Khung ảnh đã thay đổi khi đang cập nhật")
            }
        }
        let nextNo = try tx.query("SELECT COALESCE(MAX(revision_no),0)+1 n FROM frame_revisions WHERE frame_id=?", [.text(frameID)])
            .first?["n"]?.intValue ?? 1
        let newRevID = IDFactory.new()
        var revision = FrameRevision(id: newRevID, frameID: frameID, revisionNo: nextNo,
                                     canvasWidth: draft.canvasWidth, canvasHeight: draft.canvasHeight,
                                     backgroundAssetID: draft.backgroundAssetID,
                                     foregroundAssetID: draft.foregroundAssetID,
                                     backgroundColorHex: draft.backgroundColorHex,
                                     backgroundPlacement: draft.backgroundPlacement,
                                     foregroundPlacement: draft.foregroundPlacement,
                                     geometryVersion: draft.geometryVersion)
        try tx.run("""
            INSERT INTO frame_revisions(id, frame_id, revision_no, canvas_width, canvas_height,
                background_asset_id, foreground_asset_id, background_color, background_placement,
                foreground_placement, geometry_version, created_at_ms)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(revision.id), .text(frameID), .int(Int64(nextNo)),
                  .int(Int64(revision.canvasWidth)), .int(Int64(revision.canvasHeight)),
                  revision.backgroundAssetID.map { .text($0) } ?? .null,
                  revision.foregroundAssetID.map { .text($0) } ?? .null,
                  .text(revision.backgroundColorHex),
                  .text(revision.backgroundPlacement.rawValue),
                  .text(revision.foregroundPlacement.rawValue),
                  .int(Int64(revision.geometryVersion)), .int(revision.createdAtMs)])
        revision.backgroundImageOrientation = try Self.validatedOrientation(draft.backgroundImageOrientation, assetID: draft.backgroundAssetID)
        revision.foregroundImageOrientation = try Self.validatedOrientation(draft.foregroundImageOrientation, assetID: draft.foregroundAssetID)
        if revision.backgroundImageOrientation != nil || revision.foregroundImageOrientation != nil {
            let metadata = try Self.jsonEncoder.encode(LayerOrientations(background: revision.backgroundImageOrientation,
                                                                         foreground: revision.foregroundImageOrientation))
            try tx.run("INSERT INTO app_state(key,value,updated_at_ms) VALUES(?,?,?)",
                       [.text("frame_layer_exif_\(revision.id)"), .text(String(decoding: metadata, as: UTF8.self)),
                        .int(Time.nowMs())])
        }
        // Xóa slot cũ của revision (nếu có) rồi insert lại với ID mới cho từng slot
        try tx.run("DELETE FROM frame_slots WHERE frame_revision_id=?", [.text(revision.id)])
        for (i, slot) in slots.enumerated() {
            let slotID = IDFactory.new()
            try tx.run("""
                INSERT INTO frame_slots(id, frame_revision_id, capture_index, x, y, width, height,
                    rotation_degrees, z_order, mask_type, corner_radius, default_crop_mode)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(slotID), .text(revision.id), .int(Int64(slot.captureIndex)),
                      .real(slot.x), .real(slot.y), .real(slot.width), .real(slot.height),
                      .real(slot.rotationDegrees), .int(Int64(i)),
                      .text(slot.maskType.rawValue), .real(slot.cornerRadius),
                      .text(slot.defaultCropMode.rawValue)])
        }
        if let stagedOwnerID {
            for (assetID, purpose) in [(revision.backgroundAssetID, "background"),
                                       (revision.foregroundAssetID, "foreground")] {
                guard let assetID else { continue }
                try tx.run("""
                    INSERT OR IGNORE INTO asset_references(asset_id, owner_type, owner_id, purpose)
                    VALUES(?, 'frame_revision', ?, ?)
                    """, [.text(assetID), .text(revision.id), .text(purpose)])
            }
            try tx.run("DELETE FROM asset_references WHERE owner_type='frame_revision' AND owner_id=?",
                       [.text(stagedOwnerID)])
        }
        try tx.run("UPDATE frames SET current_revision_id=?, updated_at_ms=? WHERE id=?",
                   [.text(revision.id), .int(Time.nowMs()), .text(frameID)])
        return revision
    }

    /// Cập nhật validation_status (ready chỉ khi revision pass validator — §16.2.5).
    public func setValidationStatus(frameID: String, status: FrameValidationStatus) throws {
        try db.run("UPDATE frames SET validation_status=?, updated_at_ms=? WHERE id=?",
                   [.text(status.rawValue), .int(Time.nowMs()), .text(frameID)])
    }

    // MARK: - Tạo frame từ ảnh import (§6.2)

    public func createFrame(name: String, imageData: Data, mediaType: String,
                            role: AssetKind, categoryID: String?) throws -> Frame {
        let image = try AssetStore.validatedFrameImport(imageData)
        let ownerRevision = "draft-\(IDFactory.new())"
        let asset = try assets.store(data: imageData, mediaType: mediaType,
                                     purpose: role.rawValue, ownerType: "frame_revision", ownerID: ownerRevision)
        defer { try? assets.removeReferences(ownerType: "frame_revision", ownerID: ownerRevision) }
        return try db.withTransaction { tx in
            let frame = Frame(name: name, categoryID: categoryID)
            try tx.run("""
                INSERT INTO frames(id, name, category_id, current_revision_id, is_favorite, is_built_in,
                    validation_status, lifecycle, created_at_ms, updated_at_ms)
                VALUES(?,?,?,NULL,0,0,'unconfigured','active',?,?)
                """, [.text(frame.id), .text(name), categoryID.map(SQLiteValue.text) ?? .null,
                      .int(frame.createdAtMs), .int(frame.updatedAtMs)])
            var revision = FrameRevision(frameID: frame.id, revisionNo: 1,
                canvasWidth: min(max(image.width, ResourceLimits.canvasMin), ResourceLimits.canvasMax),
                canvasHeight: min(max(image.height, ResourceLimits.canvasMin), ResourceLimits.canvasMax))
            if role == .frameForeground {
                revision.foregroundAssetID = asset.id
                revision.foregroundImageOrientation = image.orientation
                let aspect = Double(image.width) / Double(image.height)
                let canvasAspect = Double(revision.canvasWidth) / Double(revision.canvasHeight)
                revision.foregroundPlacement = abs(aspect - canvasAspect) < 0.01 ? .stretchToCanvas : .aspectFit
            } else {
                revision.backgroundAssetID = asset.id
                revision.backgroundImageOrientation = image.orientation
            }
            _ = try writeRevision(frameID: frame.id, draft: revision, slots: [], stagedOwnerID: ownerRevision, tx: tx)
            return frame
        }
    }

    /// Tạo frame đã cấu hình ô từ ảnh import (§4.1, §4.2): lưu asset, revision, slots và set validation_status='ready'.
    public func createConfiguredFrame(name: String, imageData: Data, mediaType: String,
                                      role: AssetKind, categoryID: String?,
                                      slots: [FrameSlot]) throws -> Frame {
        try createConfiguredFrame(name: name, imageData: imageData, mediaType: mediaType,
                                  role: role, categoryID: categoryID, slots: slots, frameID: IDFactory.new())
    }

    func createConfiguredFrame(name: String, imageData: Data, mediaType: String,
                               role: AssetKind, categoryID: String?, slots: [FrameSlot],
                               retryID: String) throws -> Frame {
        let token = try OperationCoordinator.shared.acquire(keys: ["frame:\(retryID)"], reason: "Lưu khung nhập")
        defer { token.release() }
        if let existing = try getFrame(id: retryID) {
            let category = try categoryID.flatMap { id in
                try db.query("SELECT id FROM categories WHERE id=? AND lifecycle='active'", [.text(id)])
                    .first?["id"].stringValue
            }
            guard existing.lifecycle == .active, existing.validationStatus == .ready,
                  existing.name == name.trimmingCharacters(in: .whitespacesAndNewlines), existing.categoryID == category,
                  let revisionID = existing.currentRevisionID, let revision = try getRevision(id: revisionID),
                  revision.revisionNo == 1, revision.foregroundPlacement == .stretchToCanvas,
                  revision.backgroundPlacement == .aspectFill,
                  let layerID = role == .frameForeground ? revision.foregroundAssetID : revision.backgroundAssetID,
                  role == .frameForeground ? revision.backgroundAssetID == nil : revision.foregroundAssetID == nil,
                  let asset = assets.assetInfo(assetID: layerID), asset.sha256 == Hashing.sha256Hex(imageData),
                  let image = try? AssetStore.validatedFrameImport(imageData),
                  image.width == revision.canvasWidth, image.height == revision.canvasHeight,
                  image.orientation == (role == .frameForeground ? revision.foregroundImageOrientation : revision.backgroundImageOrientation) else {
                throw AppError.invalidState("Bản khung vừa lưu đã thay đổi. Hãy mở lại khung để kiểm tra.")
            }
            let stored = try getSlots(revisionID: revisionID)
            guard stored.count == slots.count, zip(stored, slots).allSatisfy({ lhs, rhs in
                lhs.captureIndex == rhs.captureIndex && lhs.rect == rhs.rect &&
                lhs.rotationDegrees == rhs.rotationDegrees && lhs.maskType == rhs.maskType &&
                lhs.cornerRadius == rhs.cornerRadius && lhs.defaultCropMode == rhs.defaultCropMode
            }) else {
                throw AppError.invalidState("Bố cục của khung vừa lưu đã thay đổi.")
            }
            _ = try assets.loadVerifiedImage(assetID: layerID)
            return existing
        }
        return try createConfiguredFrame(name: name, imageData: imageData, mediaType: mediaType,
                                         role: role, categoryID: categoryID, slots: slots, frameID: retryID)
    }

    private func createConfiguredFrame(name: String, imageData: Data, mediaType: String,
                                       role: AssetKind, categoryID: String?, slots: [FrameSlot],
                                       frameID: String) throws -> Frame {
        let image = try AssetStore.validatedFrameImport(imageData)
        let owner = "draft-\(IDFactory.new())"
        let asset = try assets.store(data: imageData, mediaType: mediaType,
                                     purpose: role.rawValue, ownerType: "frame_revision", ownerID: owner)
        defer { try? assets.removeReferences(ownerType: "frame_revision", ownerID: owner) }
        var draft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: image.width, canvasHeight: image.height,
                                  backgroundAssetID: role == .frameBackground ? asset.id : nil,
                                  foregroundAssetID: role == .frameForeground ? asset.id : nil,
                                  backgroundPlacement: .aspectFill, foregroundPlacement: .stretchToCanvas)
        draft.backgroundImageOrientation = role == .frameBackground ? image.orientation : nil
        draft.foregroundImageOrientation = role == .frameForeground ? image.orientation : nil
        return try createConfiguredFrame(name: name, categoryID: categoryID, draft: draft, slots: slots,
                                         stagedOwnerID: owner, frameID: frameID)
    }

    func createConfiguredFrame(name: String, categoryID: String?, draft: FrameRevision,
                               slots: [FrameSlot], stagedOwnerID: String, explicitWhite: Bool = false,
                               frameID: String = IDFactory.new(),
                               expectedSource: (id: String, revision: String)? = nil, categoryName: String? = nil) throws -> Frame {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let issues = FrameValidator.validate(revision: draft, slots: slots)
        guard !name.isEmpty, issues.isEmpty else {
            throw AppError.invalidState(issues.first?.message ?? "Tên khung không được để trống")
        }
        try requireConfigured(draft, slots: slots)
        let id = try db.withTransaction { tx in
            var intendedCategory = try resolveCategory(categoryName, tx: tx) ?? categoryID
            var newName = name
            if let expectedSource {
                guard let source = try tx.query("""
                    SELECT name, category_id FROM frames
                    WHERE id=? AND current_revision_id=? AND lifecycle='active' AND validation_status='ready'
                    """, [.text(expectedSource.id), .text(expectedSource.revision)]).first else {
                    throw AppError.invalidState("Khung gốc đã thay đổi. Hãy mở lại bản xem thử.")
                }
                intendedCategory = source["category_id"]?.stringValue
                let names = try tx.query("SELECT name FROM frames WHERE lifecycle='active'", [])
                    .map { $0["name"].stringValue }
                newName = Self.uniqueName(base: source["name"].stringValue + " (đã làm trong)", existing: names)
            }
            let category = try intendedCategory.flatMap { id in
                try tx.query("SELECT id FROM categories WHERE id=? AND lifecycle='active'", [.text(id)]).first?["id"]?.stringValue
            }
            let frame = Frame(id: frameID, name: newName, categoryID: category)
            try tx.run("""
                INSERT INTO frames(id, name, category_id, current_revision_id, is_favorite, is_built_in,
                    validation_status, lifecycle, created_at_ms, updated_at_ms)
                VALUES(?,?,?,NULL,0,0,'unconfigured','active',?,?)
                """, [.text(frame.id), .text(newName), category.map(SQLiteValue.text) ?? .null,
                      .int(frame.createdAtMs), .int(frame.updatedAtMs)])
            let revision = try writeRevision(frameID: frame.id, draft: draft, slots: slots,
                                             stagedOwnerID: stagedOwnerID, tx: tx)
            if explicitWhite {
                try tx.run("INSERT INTO app_state(key,value,updated_at_ms) VALUES(?,?,?)",
                           [.text("explicit_white_\(revision.id)"), .text("1"), .int(Time.nowMs())])
            }
            try tx.run("UPDATE frames SET validation_status='ready' WHERE id=?", [.text(frame.id)])
            return frame.id
        }
        guard let frame = try getFrame(id: id) else { throw AppError.notFound("Khung vừa lưu") }
        return frame
    }

    func saveClearSlotCopy(sourceID: String, revisionID: String,
                           copyID: String, png: Data) throws -> Frame {
        guard sourceID != copyID else { throw AppError.invalidState("ID bản sao trùng với khung gốc") }
        let token = try OperationCoordinator.shared.acquire(keys: ["frame:\(sourceID)", "frame:\(copyID)"],
                                                           reason: "Lưu bản khung đã làm trong")
        defer { token.release() }
        let checksum = Hashing.sha256Hex(png)
        if let existing = try getFrame(id: copyID) {
            guard existing.lifecycle == .active, existing.validationStatus == .ready,
                  let current = existing.currentRevisionID,
                  let assetID = try getRevision(id: current)?.foregroundAssetID,
                  assets.assetInfo(assetID: assetID)?.sha256 == checksum else {
                throw AppError.invalidState("Bản khung vừa lưu đã thay đổi")
            }
            _ = try assets.loadVerifiedImage(assetID: assetID)
            return existing
        }
        guard let source = try getFrame(id: sourceID), source.lifecycle == .active,
              source.validationStatus == .ready, source.currentRevisionID == revisionID,
              var draft = try getRevision(id: revisionID), let originalID = draft.foregroundAssetID else {
            throw AppError.invalidState("Khung gốc đã thay đổi. Hãy mở lại bản xem thử.")
        }
        let sourceSnapshot = try createSnapshot(frameID: sourceID, persist: false)
        guard sourceSnapshot.sourceFrameRevisionID == revisionID,
              let original = assets.assetInfo(assetID: originalID), original.sha256 != checksum else {
            throw AppError.invalidState("Khung gốc đã thay đổi hoặc PNG không có thay đổi")
        }
        let (image, mediaType) = try AssetStore.validatedFrameImage(png)
        guard mediaType == "image/png", image.width == draft.canvasWidth, image.height == draft.canvasHeight else {
            throw AppError.invalidState("PNG đã làm trong không khớp với khung")
        }
        if let bg = draft.backgroundAssetID { _ = try assets.loadVerifiedImage(assetID: bg) }
        let slots = try getSlots(revisionID: revisionID)
        let owner = "draft-\(copyID)"
        defer { try? assets.removeReferences(ownerType: "frame_revision", ownerID: owner) }
        let asset = try assets.store(data: png, mediaType: mediaType, purpose: AssetKind.frameForeground.rawValue,
                                     ownerType: "frame_revision", ownerID: owner)
        _ = try assets.loadVerifiedImage(assetID: asset.id)
        draft.foregroundAssetID = asset.id
        draft.foregroundImageOrientation = nil
        return try createConfiguredFrame(name: source.name, categoryID: source.categoryID, draft: draft,
                                         slots: slots, stagedOwnerID: owner,
                                         explicitWhite: sourceSnapshot.explicitWhite == true, frameID: copyID,
                                         expectedSource: (sourceID, revisionID))
    }

    /// Tạo frame trống (không asset) — khung trắng tối giản hợp lệ với background color.
    public func createEmptyFrame(name: String, categoryID: String?, canvasWidth: Int = 1200, canvasHeight: Int = 1800) throws -> Frame {
        let frame = Frame(name: name, categoryID: categoryID)
        try db.run("""
            INSERT INTO frames(id, name, category_id, current_revision_id, is_favorite, is_built_in,
                validation_status, lifecycle, created_at_ms, updated_at_ms)
            VALUES(?,?,?,NULL,0,0,'unconfigured','active',?,?)
            """, [.text(frame.id), .text(name), categoryID.map { .text($0) } ?? .null,
                  .int(frame.createdAtMs), .int(frame.updatedAtMs)])
        let rev = FrameRevision(frameID: frame.id, revisionNo: 1, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        _ = try commitRevision(frameID: frame.id, draft: rev, slots: [])
        return frame
    }

    // MARK: - Metadata actions

    public func renameFrame(id: String, to name: String, expectedRevisionID: String? = nil) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidState("Tên khung không được để trống")
        }
        guard let frame = try getFrame(id: id), frame.lifecycle == .active else {
            throw AppError.notFound("Khung \(id) không tồn tại hoặc không ở trạng thái active")
        }
        try db.withTransaction { tx in
            if let expectedRevisionID {
                let current = try tx.query("SELECT current_revision_id FROM frames WHERE id=? AND lifecycle='active'", [.text(id)]).first?["current_revision_id"].stringValue
                guard current == expectedRevisionID else { throw AppError.invalidState("Khung đã thay đổi. Hãy mở lại bản nháp.") }
            }
            try tx.run("UPDATE frames SET name=?, updated_at_ms=? WHERE id=?", [.text(trimmed), .int(Time.nowMs()), .text(id)])
        }
    }

    public func setFavorite(id: String, _ favorite: Bool) throws {
        try db.run("UPDATE frames SET is_favorite=?, updated_at_ms=? WHERE id=?",
                   [.int(favorite ? 1 : 0), .int(Time.nowMs()), .text(id)])
    }

    /// Gán yêu thích theo lô có giao dịch nguyên tử (§5, FRM-03).
    /// Chỉ cập nhật các khung có cờ false sang true; giữ nguyên updated_at_ms của hàng đã có sao.
    @discardableResult
    public func setFavorites(frameIDs: [String], isFavorite: Bool = true) throws -> Int {
        guard !frameIDs.isEmpty else { return 0 }
        var updatedCount = 0
        try db.withTransaction { tx in
            let sortedIDs = frameIDs.sorted()
            for id in sortedIDs {
                let rows = try tx.query("SELECT id, is_favorite, lifecycle FROM frames WHERE id=?", [.text(id)])
                guard let row = rows.first, row["lifecycle"]?.stringValue == "active" else {
                    throw AppError.notFound("Khung \(id) không tồn tại hoặc không ở trạng thái active")
                }
            }
            let now = Time.nowMs()
            let targetVal: Int64 = isFavorite ? 1 : 0
            for id in sortedIDs {
                let rows = try tx.query("SELECT is_favorite FROM frames WHERE id=?", [.text(id)])
                guard let row = rows.first else { continue }
                let currentFav = (row["is_favorite"]?.int64Value ?? 0) == 1
                if currentFav != isFavorite {
                    try tx.run("UPDATE frames SET is_favorite=?, updated_at_ms=? WHERE id=?",
                               [.int(targetVal), .int(now), .text(id)])
                    updatedCount += 1
                }
            }
        }
        return updatedCount
    }

    public func setCategory(frameID: String, categoryID: String?) throws {
        try setCategory(frameIDs: [frameID], categoryID: categoryID)
    }

    func setCategory(frameIDs: [String], categoryID: String?) throws {
        let ids = Set(frameIDs).sorted()
        guard !ids.isEmpty else { return }
        let keys = ids.map { "frame:\($0)" } + (categoryID.map { ["category:\($0)"] } ?? [])
        let token = try OperationCoordinator.shared.acquire(keys: keys, reason: "Chuyển danh mục khung")
        defer { token.release() }
        try db.withTransaction { tx in
            if let categoryID {
                guard try tx.scalarInt("""
                    SELECT COUNT(*) FROM categories WHERE id=? AND lifecycle='active'
                      AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='category' AND root_id=categories.id)
                    """, [.text(categoryID)]) == 1 else {
                    throw AppError.invalidState("Danh mục không còn hoạt động. Hãy chọn lại danh mục.")
                }
            }
            for id in ids {
                guard try tx.scalarInt("""
                    SELECT COUNT(*) FROM frames WHERE id=? AND lifecycle='active'
                      AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='frame' AND root_id=frames.id)
                    """, [.text(id)]) == 1 else {
                    throw AppError.invalidState("Khung đã thay đổi hoặc đã vào Thùng rác. Hãy chọn lại khung.")
                }
            }
            let now = Time.nowMs()
            for id in ids {
                try tx.run("UPDATE frames SET category_id=?, updated_at_ms=? WHERE id=?",
                           [categoryID.map(SQLiteValue.text) ?? .null, .int(now), .text(id)])
            }
        }
    }

    /// Nhân bản frame: revision/slots mới với ID mới, asset dùng chung bằng reference (§2.3, D2-A07).
    public func duplicateFrame(id: String) throws -> Frame {
        guard let source = try getFrame(id: id), let revisionID = source.currentRevisionID else {
            throw AppError.notFound("frame \(id)")
        }
        let copyID = IDFactory.new()
        let token = try OperationCoordinator.shared.acquire(keys: ["frame:\(id)", "frame:\(copyID)"],
                                                           reason: "Nhân bản khung")
        defer { token.release() }
        guard let source = try getFrame(id: id), source.lifecycle == .active,
              source.currentRevisionID == revisionID else {
            throw AppError.invalidState("Khung gốc đã thay đổi")
        }
#if DEBUG
        try onDuplicateLockedForTesting?()
#endif
        guard let draft = try getRevision(id: revisionID) else { throw AppError.notFound("frame \(id)") }
        let slots = try getSlots(revisionID: revisionID)
        if source.validationStatus == .ready { try requireConfigured(draft, slots: slots) }
        return try db.withTransaction { tx in
            guard let frame = try tx.query("SELECT * FROM frames WHERE id=?", [.text(id)]).first.flatMap(Self.frame(from:)),
                  frame.lifecycle == .active, frame.currentRevisionID == revisionID,
                  frame.validationStatus == source.validationStatus else {
                throw AppError.invalidState("Khung gốc đã thay đổi")
            }
            let names = try tx.query("SELECT name FROM frames WHERE lifecycle='active'").map { $0["name"].stringValue }
            let categoryID = try frame.categoryID.flatMap { categoryID in
                try tx.query("SELECT id FROM categories WHERE id=? AND lifecycle='active'", [.text(categoryID)])
                    .first?["id"].stringValue
            }
            let copy = Frame(id: copyID, name: Self.uniqueName(base: frame.name + " (bản sao)", existing: names),
                             categoryID: categoryID, isBuiltIn: frame.isBuiltIn, validationStatus: frame.validationStatus)
            try tx.run("""
                INSERT INTO frames(id, name, category_id, current_revision_id, is_favorite, is_built_in,
                    validation_status, lifecycle, created_at_ms, updated_at_ms)
                VALUES(?,?,?,NULL,0,?,?,'active',?,?)
                """, [.text(copy.id), .text(copy.name), copy.categoryID.map(SQLiteValue.text) ?? .null,
                      .int(copy.isBuiltIn ? 1 : 0), .text(copy.validationStatus.rawValue),
                      .int(copy.createdAtMs), .int(copy.updatedAtMs)])
            let revision = try writeRevision(frameID: copy.id, draft: draft, slots: slots, stagedOwnerID: nil, tx: tx)
            for (assetID, purpose) in [(revision.backgroundAssetID, "background"), (revision.foregroundAssetID, "foreground")] {
                guard let assetID else { continue }
                try tx.run("""
                    INSERT INTO asset_references(asset_id, owner_type, owner_id, purpose)
                    VALUES(?, 'frame_revision', ?, ?)
                    """, [.text(assetID), .text(revision.id), .text(purpose)])
            }
            try tx.run("""
                INSERT INTO app_state(key,value,updated_at_ms)
                SELECT ?,value,? FROM app_state WHERE key=?
                """, [.text("explicit_white_\(revision.id)"), .int(Time.nowMs()), .text("explicit_white_\(revisionID)")])
            guard let saved = try tx.query("SELECT * FROM frames WHERE id=?", [.text(copy.id)]).first.flatMap(Self.frame(from:)) else {
                throw AppError.notFound("Bản sao khung")
            }
            return saved
        }
    }

    public static func uniqueName(base: String, existing: [String]) -> String {
        let lower = Set(existing.map { $0.lowercased() })
        if !lower.contains(base.lowercased()) { return base }
        var n = 1
        while lower.contains("\(base) (\(n))".lowercased()) { n += 1 }
        return "\(base) (\(n))"
    }

    // MARK: - Snapshot (§6.5)

    /// Tạo FrameSnapshot bất biến từ frame revision + lưu DB + asset references owner frame_snapshot.
    public func createSnapshot(frameID: String, persist: Bool = true) throws -> FrameSnapshot {
        guard let frame = try getFrame(id: frameID), let revID = frame.currentRevisionID,
              let rev = try getRevision(id: revID) else {
            throw AppError.frameUnconfigured
        }
        let explicit = try? db.query("SELECT value FROM app_state WHERE key=?", [.text("explicit_white_\(revID)")]).first?["value"]?.stringValue
        let isExplicitWhite = (explicit == "1" || explicit == "true")
        let slots = try getSlots(revisionID: revID)
        let slotsN = slots.map { SnapshotSlot(from: $0) }
        var snapshot = FrameSnapshot(sourceFrameID: frameID, sourceFrameRevisionID: revID,
                                     canvasWidth: rev.canvasWidth, canvasHeight: rev.canvasHeight,
                                     background: rev.backgroundAssetID.map { SnapshotLayer(assetID: $0, placement: rev.backgroundPlacement, imageOrientation: rev.backgroundImageOrientation) },
                                     foreground: rev.foregroundAssetID.map { SnapshotLayer(assetID: $0, placement: rev.foregroundPlacement, imageOrientation: rev.foregroundImageOrientation) },
                                     backgroundColorHex: rev.backgroundColorHex,
                                     slots: slotsN,
                                     snapshotHash: "",
                                     explicitWhite: isExplicitWhite)
        snapshot.snapshotHash = snapshot.hashForContent()
        guard persist else { return snapshot }
        let data = try Self.jsonEncoder.encode(snapshot)
        do {
            let sql = """
                INSERT INTO frame_snapshots(id, source_frame_id, source_frame_revision_id, snapshot_json, snapshot_hash, created_at_ms)
                VALUES(?,?,?,?,?,?)
                """
            let params: [SQLiteValue] = [
                .text(snapshot.id),
                .text(frameID),
                .text(revID),
                .text(String(data: data, encoding: .utf8) ?? "{}"),
                .text(snapshot.snapshotHash),
                .int(snapshot.createdAtMs)
            ]
            try db.run(sql, params)
            if let bg = snapshot.background?.assetID {
                try assets.addReference(assetID: bg, ownerType: "frame_snapshot", ownerID: snapshot.id, purpose: "background")
            }
            if let fg = snapshot.foreground?.assetID {
                try assets.addReference(assetID: fg, ownerType: "frame_snapshot", ownerID: snapshot.id, purpose: "foreground")
            }
        } catch {
            // Dọn snapshot + refs mồ côi khi addReference fail (asset thiếu bytes)
            try? db.run("DELETE FROM asset_references WHERE owner_type='frame_snapshot' AND owner_id=?", [.text(snapshot.id)])
            try? db.run("DELETE FROM frame_snapshots WHERE id=?", [.text(snapshot.id)])
            throw error
        }
        return snapshot
    }

    public func getSnapshot(id: String) throws -> FrameSnapshot? {
        let rows = try db.query("SELECT * FROM frame_snapshots WHERE id=?", [.text(id)])
        guard let r = rows.first else { return nil }
        guard let data = r["snapshot_json"].stringValue.data(using: .utf8),
              var snapshot = try? Self.jsonDecoder.decode(FrameSnapshot.self, from: data) else {
            Log.store.error("Snapshot JSON không decode được: \(r["id"].stringValue, privacy: .public)")
            return nil
        }
        snapshot.id = r["id"].stringValue
        return snapshot
    }

    private func resolveCategory(_ name: String?, tx: SQLiteDatabase.TransactionHandle) throws -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), (1...80).contains(name.count) else { return nil }
        if let id = try tx.query("SELECT id FROM categories WHERE lifecycle='active' AND lower(name)=lower(?)", [.text(name)]).first?["id"].stringValue {
            return id
        }
        let order = try tx.query("SELECT COALESCE(MAX(sort_order),0)+1 AS n FROM categories WHERE lifecycle='active'").first?["n"].intValue ?? 1
        let category = Category(name: name, sortOrder: order)
        try tx.run("INSERT INTO categories(id,name,sort_order,created_at_ms,updated_at_ms,lifecycle) VALUES(?,?,?,?,?,'active')",
            [.text(category.id), .text(category.name), .int(Int64(order)), .int(category.createdAtMs), .int(category.updatedAtMs)])
        return category.id
    }

    // MARK: - Categories (§6.3)

    public func listCategories() throws -> [Category] {
        try db.query("SELECT * FROM categories WHERE lifecycle='active' ORDER BY sort_order, name").map { r in
            Category(id: r["id"].stringValue, name: r["name"].stringValue,
                     sortOrder: r["sort_order"]?.intValue ?? 0,
                     createdAtMs: r["created_at_ms"]?.int64Value ?? 0,
                     updatedAtMs: r["updated_at_ms"]?.int64Value ?? 0,
                     lifecycle: FrameLifecycle(rawValue: r["lifecycle"].stringValue) ?? .active)
        }
    }

    public func createCategory(name: String) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.count) else {
            throw AppError.invalidState("Tên danh mục phải 1–80 ký tự")
        }
        let lower = try db.query("SELECT COUNT(*) c FROM categories WHERE lifecycle='active' AND lower(name)=lower(?)", [.text(trimmed)])
        if (lower.first?["c"]?.intValue ?? 0) > 0 {
            throw AppError.restoreConflict("Danh mục '\(trimmed)' đã tồn tại")
        }
        let maxOrder = try db.scalarInt("SELECT COALESCE(MAX(sort_order),0) FROM categories WHERE lifecycle='active'")
        let cat = Category(name: trimmed, sortOrder: Int(maxOrder) + 1)
        try db.run("""
            INSERT INTO categories(id, name, sort_order, created_at_ms, updated_at_ms, lifecycle)
            VALUES(?,?,?,?,?,'active')
            """, [.text(cat.id), .text(cat.name), .int(Int64(cat.sortOrder)),
                  .int(cat.createdAtMs), .int(cat.updatedAtMs)])
        return cat
    }

    public func renameCategory(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.count) else { throw AppError.invalidState("Tên danh mục phải 1–80 ký tự") }
        // D2-A06: Bỏ qua chính ID đang sửa khi kiểm trùng tên (COLLATE NOCASE)
        let dup = try db.query("SELECT id FROM categories WHERE name = ? COLLATE NOCASE AND id <> ? AND lifecycle='active'",
                               [.text(trimmed), .text(id)])
        if !dup.isEmpty {
            throw AppError.duplicateName("Tên danh mục '\(trimmed)' đã tồn tại")
        }
        try db.run("UPDATE categories SET name=?, updated_at_ms=? WHERE id=?", [.text(trimmed), .int(Time.nowMs()), .text(id)])
    }

    public func nextSortOrderAfterDeletion() {}

    /// Đánh dấu khung built-in (§6.4 — ẩn/khôi phục được, không xóa tài nguyên bundle).
    public func markBuiltIn(frameID: String) throws {
        try db.run("UPDATE frames SET is_built_in=1 WHERE id=?", [.text(frameID)])
    }
}
