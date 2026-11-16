import Foundation
import CoreGraphics

/// FrameRepository: Frame/category/revision CRUD + snapshot (§17.1).
/// Views không truy cập trực tiếp; chỉ gọi qua services/ViewModels.
public final class FrameRepository: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let assets: AssetStore
    private let layout: FileLayout

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
        let rows = try db.query("SELECT * FROM frame_revisions WHERE id=?", [.text(id)])
        guard let r = rows.first else { return nil }
        return FrameRevision(
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
        let revision = FrameRevision(id: newRevID, frameID: frameID, revisionNo: nextNo,
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
        guard let image = CGImage.createFrom(data: imageData) else { throw AppError.frameFileCorrupt }
        let ownerRevision = "draft-\(IDFactory.new())"
        let asset = try assets.store(data: imageData, mediaType: mediaType,
                                     purpose: role.rawValue, ownerType: "frame_revision", ownerID: ownerRevision)
        do {
            let frame = Frame(name: name, categoryID: categoryID)
            try db.run("""
                INSERT INTO frames(id, name, category_id, current_revision_id, is_favorite, is_built_in,
                    validation_status, lifecycle, created_at_ms, updated_at_ms)
                VALUES(?,?,?,NULL,0,0,'unconfigured','active',?,?)
                """, [.text(frame.id), .text(name),
                      categoryID.map { .text($0) } ?? .null,
                      .int(frame.createdAtMs), .int(frame.updatedAtMs)])
            // Revision 1 chứa asset với owner là revision thật
            var rev = FrameRevision(frameID: frame.id, revisionNo: 1,
                                    canvasWidth: max(image.width, ResourceLimits.canvasMin),
                                    canvasHeight: max(image.height, ResourceLimits.canvasMin))
            rev.canvasWidth = min(max(image.width, 256), 8192)
            rev.canvasHeight = min(max(image.height, 256), 8192)
            if role == .frameForeground {
                rev.foregroundAssetID = asset.id
                rev.foregroundPlacement = (abs(Double(image.width) / Double(max(image.height,1)) - Double(rev.canvasWidth) / Double(max(rev.canvasHeight,1))) < 0.01) ? .stretchToCanvas : .aspectFit
            } else {
                rev.backgroundAssetID = asset.id
                rev.backgroundPlacement = .aspectFill
            }
            let committed = try commitRevision(frameID: frame.id, draft: rev, slots: [])
            // Chuyển owner reference từ draft sang revision thật
            try db.run("UPDATE asset_references SET owner_id=? WHERE owner_type='frame_revision' AND owner_id=?",
                       [.text(committed.id), .text(ownerRevision)])
            return frame
        } catch {
            // Không để lại asset_references mồ côi owner draft-* khi bước sau fail (rò rỉ storage qua GC)
            try? assets.removeReferences(ownerType: "frame_revision", ownerID: ownerRevision)
            throw error
        }
    }

    /// Tạo frame đã cấu hình ô từ ảnh import (§4.1, §4.2): lưu asset, revision, slots và set validation_status='ready'.
    public func createConfiguredFrame(name: String, imageData: Data, mediaType: String,
                                      role: AssetKind, categoryID: String?,
                                      slots: [FrameSlot]) throws -> Frame {
        guard let image = CGImage.createFrom(data: imageData) else { throw AppError.frameFileCorrupt }
        let owner = "draft-\(IDFactory.new())"
        let asset = try assets.store(data: imageData, mediaType: mediaType,
                                     purpose: role.rawValue, ownerType: "frame_revision", ownerID: owner)
        defer { try? assets.removeReferences(ownerType: "frame_revision", ownerID: owner) }
        let draft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: image.width, canvasHeight: image.height,
                                  backgroundAssetID: role == .frameBackground ? asset.id : nil,
                                  foregroundAssetID: role == .frameForeground ? asset.id : nil,
                                  backgroundPlacement: .aspectFill, foregroundPlacement: .stretchToCanvas)
        return try createConfiguredFrame(name: name, categoryID: categoryID, draft: draft, slots: slots,
                                         stagedOwnerID: owner)
    }

    func createConfiguredFrame(name: String, categoryID: String?, draft: FrameRevision,
                               slots: [FrameSlot], stagedOwnerID: String, explicitWhite: Bool = false) throws -> Frame {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let issues = FrameValidator.validate(revision: draft, slots: slots)
        guard !name.isEmpty, issues.isEmpty else {
            throw AppError.invalidState(issues.first?.message ?? "Tên khung không được để trống")
        }
        if let foregroundID = draft.foregroundAssetID {
            let overlay = try assets.loadImage(assetID: foregroundID)
            let blocked = try PNGAutoAlignmentService.blockedSlots(overlay: overlay, draft: draft, slots: slots)
            guard blocked.isEmpty else {
                throw AppError.invalidState("Lớp phủ che kín ô \(blocked.map(String.init).joined(separator: ", "))")
            }
        }
        let id = try db.withTransaction { tx in
            let category = try categoryID.flatMap { id in
                try tx.query("SELECT id FROM categories WHERE id=? AND lifecycle='active'", [.text(id)]).first?["id"]?.stringValue
            }
            let frame = Frame(name: name, categoryID: category)
            try tx.run("""
                INSERT INTO frames(id, name, category_id, current_revision_id, is_favorite, is_built_in,
                    validation_status, lifecycle, created_at_ms, updated_at_ms)
                VALUES(?,?,?,NULL,0,0,'unconfigured','active',?,?)
                """, [.text(frame.id), .text(name), category.map(SQLiteValue.text) ?? .null,
                      .int(frame.createdAtMs), .int(frame.updatedAtMs)])
            let revision = try writeRevision(frameID: frame.id, draft: draft, slots: slots,
                                             stagedOwnerID: stagedOwnerID, tx: tx)
            if explicitWhite {
                try tx.run("INSERT INTO app_state(key,value) VALUES(?,?)",
                           [.text("explicit_white_\(revision.id)"), .text("1")])
            }
            try tx.run("UPDATE frames SET validation_status='ready' WHERE id=?", [.text(frame.id)])
            return frame.id
        }
        guard let frame = try getFrame(id: id) else { throw AppError.notFound("Khung vừa lưu") }
        return frame
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

    public func renameFrame(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidState("Tên khung không được để trống")
        }
        guard let frame = try getFrame(id: id), frame.lifecycle == .active else {
            throw AppError.notFound("Khung \(id) không tồn tại hoặc không ở trạng thái active")
        }
        try db.run("UPDATE frames SET name=?, updated_at_ms=? WHERE id=?", [.text(trimmed), .int(Time.nowMs()), .text(id)])
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
        try db.run("UPDATE frames SET category_id=?, updated_at_ms=? WHERE id=?",
                   [categoryID.map { .text($0) } ?? .null, .int(Time.nowMs()), .text(frameID)])
    }

    /// Nhân bản frame: revision/slots mới với ID mới, asset dùng chung bằng reference (§2.3, D2-A07).
    public func duplicateFrame(id: String) throws -> Frame {
        guard let frame = try getFrame(id: id), let revID = frame.currentRevisionID,
              let rev = try getRevision(id: revID) else {
            throw AppError.notFound("frame \(id)")
        }
        let slots = try getSlots(revisionID: revID)
        let newRevID = IDFactory.new()
        var draft = rev
        draft.id = newRevID
        var newSlots = slots
        for i in newSlots.indices { newSlots[i].id = IDFactory.new() }
        let newName = Self.uniqueName(base: frame.name + " (bản sao)", existing: try listFrames().map(\.name))
        let copy = Frame(name: newName, categoryID: frame.categoryID)
        var committedRev: FrameRevision? = nil
        do {
            try db.run("""
                INSERT INTO frames(id, name, category_id, current_revision_id, is_favorite, is_built_in,
                    validation_status, lifecycle, created_at_ms, updated_at_ms)
                VALUES(?,?,?,?,?,?,'unconfigured','active',?,?)
                """, [.text(copy.id), .text(newName), frame.categoryID.map { .text($0) } ?? .null,
                      .null, .int(0), .int(frame.isBuiltIn ? 1 : 0),
                      .int(copy.createdAtMs), .int(copy.updatedAtMs)])
            let committed = try commitRevision(frameID: copy.id, draft: draft, slots: newSlots)
            committedRev = committed
            // D2-A07: Trỏ asset references sang ID revision THẬT đã được cấp trong giao dịch commitRevision
            if let bg = rev.backgroundAssetID {
                try assets.addReference(assetID: bg, ownerType: "frame_revision", ownerID: committed.id, purpose: "background")
            }
            if let fg = rev.foregroundAssetID {
                try assets.addReference(assetID: fg, ownerType: "frame_revision", ownerID: committed.id, purpose: "foreground")
            }
            // D2-A09: Sao chép explicit white metadata sang revision mới
            if let explicit = try? db.query("SELECT value FROM app_state WHERE key=?", [.text("explicit_white_\(revID)")]).first?["value"]?.stringValue {
                try? db.run("INSERT OR REPLACE INTO app_state(key, value) VALUES(?, ?)", [.text("explicit_white_\(committed.id)"), .text(explicit)])
            }
            return (try? getFrame(id: copy.id)) ?? copy
        } catch {
            if let committed = committedRev {
                try? assets.removeReferences(ownerType: "frame_revision", ownerID: committed.id)
            }
            try? db.run("DELETE FROM frame_slots WHERE frame_revision_id IN (SELECT id FROM frame_revisions WHERE frame_id=?)", [.text(copy.id)])
            try? db.run("DELETE FROM frame_revisions WHERE frame_id=?", [.text(copy.id)])
            try? db.run("DELETE FROM frames WHERE id=?", [.text(copy.id)])
            throw error
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
                                     background: rev.backgroundAssetID.map { SnapshotLayer(assetID: $0, placement: rev.backgroundPlacement) },
                                     foreground: rev.foregroundAssetID.map { SnapshotLayer(assetID: $0, placement: rev.foregroundPlacement) },
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
