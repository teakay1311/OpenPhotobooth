import Foundation

/// TrashService (§12): soft-delete, restore, purge 30×24h. KHÔNG đụng Finder Trash,
/// không đụng file xuất ngoài (I-07), không xóa preset built-in.
/// Purge/Restore/Trash dùng exclusive root lock (§17.3, TRS-09).
public final class TrashService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let layout: FileLayout
    private let trashRepo: TrashRepository
    private let assets: AssetStore
    private let clock: AppClock
    private let lock = NSLock()
    private var inFlightRoots: Set<String> = []

    public init(db: SQLiteDatabase, layout: FileLayout, trashRepo: TrashRepository,
                assets: AssetStore, clock: AppClock = SystemClock.shared) {
        self.db = db; self.layout = layout; self.trashRepo = trashRepo
        self.assets = assets; self.clock = clock
    }

    // MARK: - Root lock

    private func withRootLock<T>(_ rootKey: String, _ body: () throws -> T) throws -> T {
        lock.lock()
        if inFlightRoots.contains(rootKey) {
            lock.unlock()
            throw AppError.invalidState("Đang có thao tác khác trên mục này")
        }
        inFlightRoots.insert(rootKey)
        lock.unlock()
        defer {
            lock.lock(); inFlightRoots.remove(rootKey); lock.unlock()
        }
        return try body()
    }

    // MARK: - Soft delete (§12.3)

    public func trashSession(sessionID: String) throws {
        try withRootLock("session:\(sessionID)") {
            let intent = try trashRepo.createIntent(opType: "trash", rootID: sessionID)
            guard let session = try db.query("SELECT * FROM sessions WHERE id=? AND status<>'trashed'", [.text(sessionID)]).first,
                  let name = session["id"].stringValue.isEmpty ? nil : Self.sessionDisplayName(session) else {
                try trashRepo.updateIntent(id: intent.id, status: .failed, error: "Không tìm thấy phiên")
                throw AppError.notFound("session \(sessionID)")
            }
            let dir = layout.sessionDir(sessionID)
            let bytes = FileLayout.directorySize(dir)
            try trashRepo.updateIntent(id: intent.id, status: .filesStaged)
            // Move uniquely owned files sang Trash staging (same volume)
            if FileManager.default.fileExists(atPath: dir.path) {
                let dest = layout.trashSessionsDir.appendingPathComponent(sessionID, isDirectory: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: dir, to: dest)
            }
            do {
                try db.withTransaction { tx in
                    try tx.run("UPDATE sessions SET status='trashed', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
                    let now = Time.nowMs(clock: clock)
                    try tx.run("""
                        INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms, expires_at_ms,
                            original_parent_id, estimated_bytes, status, last_error)
                        VALUES(?, 'session', ?, ?, ?, ?, NULL, ?, 'trashed', NULL)
                        ON CONFLICT(root_type, root_id) DO UPDATE SET
                            display_name=excluded.display_name, deleted_at_ms=excluded.deleted_at_ms,
                            expires_at_ms=excluded.expires_at_ms, estimated_bytes=excluded.estimated_bytes,
                            status='trashed'
                        """, [.text(IDFactory.new()), .text(sessionID), .text(name),
                              .int(now), .int(TrashPolicy.expiresAt(deletedAtMs: now)), .int(bytes)])
                }
                try trashRepo.updateIntent(id: intent.id, status: .committed)
                EventBus.shared.post(.trashChanged)
                EventBus.shared.post(.sessionChanged(sessionID: sessionID, revision: 0))
            } catch {
                // DB fail sau move → trả file về vị trí cũ (§12.3)
                let dest = layout.trashSessionsDir.appendingPathComponent(sessionID, isDirectory: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.moveItem(at: dest, to: dir)
                }
                try trashRepo.updateIntent(id: intent.id, status: .rollbackRequired, error: error.localizedDescription)
                throw error
            }
        }
    }

    private static func sessionDisplayName(_ row: SQLiteRow) -> String? {
        let created = row["created_at_ms"]?.intValue ?? 0
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "Phiên \(df.string(from: Time.date(ms: Int64(created))))"
    }

    public func trashFrame(frameID: String) throws {
        try withRootLock("frame:\(frameID)") {
            let intent = try trashRepo.createIntent(opType: "trash", rootID: frameID)
            guard let frame = try db.query("SELECT * FROM frames WHERE id=? AND lifecycle='active'", [.text(frameID)]).first else {
                try trashRepo.updateIntent(id: intent.id, status: .failed, error: "Không tìm thấy khung")
                throw AppError.notFound("frame \(frameID)")
            }
            do {
                try db.withTransaction { tx in
                    try tx.run("UPDATE frames SET lifecycle='trashed', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(frameID)])
                    let now = Time.nowMs(clock: clock)
                    let bytes = try tx.query("""
                        SELECT COALESCE(SUM(a.byte_size),0) s FROM frame_revisions r
                        LEFT JOIN assets a ON a.id IN (r.background_asset_id, r.foreground_asset_id)
                        WHERE r.frame_id = ?
                        """, [.text(frameID)]).first?["s"]?.intValue ?? 0
                    try tx.run("""
                        INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms, expires_at_ms,
                            original_parent_id, estimated_bytes, status, last_error)
                        VALUES(?, 'frame', ?, ?, ?, ?, ?, ?, 'trashed', NULL)
                        ON CONFLICT(root_type, root_id) DO UPDATE SET
                            display_name=excluded.display_name, deleted_at_ms=excluded.deleted_at_ms,
                            expires_at_ms=excluded.expires_at_ms, estimated_bytes=excluded.estimated_bytes,
                            status='trashed'
                        """, [.text(IDFactory.new()), .text(frameID),
                              .text(frame["name"].stringValue),
                              .int(now), .int(TrashPolicy.expiresAt(deletedAtMs: now)),
                              frame["category_id"].stringValue.isEmpty ? .null : frame["category_id"],
                              .int(Int64(bytes))])
                }
                try trashRepo.updateIntent(id: intent.id, status: .committed)
                EventBus.shared.post(.trashChanged)
                EventBus.shared.post(.frameLibraryChanged(frameID: frameID))
            } catch {
                try trashRepo.updateIntent(id: intent.id, status: .rollbackRequired, error: error.localizedDescription)
                throw error
            }
        }
    }

    /// Xóa danh mục: frame thành unclassified + lưu mapping để khôi phục (§6.3, §12.4).
    public func trashCategory(categoryID: String) throws {
        try withRootLock("category:\(categoryID)") {
            let intent = try trashRepo.createIntent(opType: "trash", rootID: categoryID)
            guard let cat = try db.query("SELECT * FROM categories WHERE id=? AND lifecycle='active'", [.text(categoryID)]).first else {
                try trashRepo.updateIntent(id: intent.id, status: .failed, error: "Không tìm thấy danh mục")
                throw AppError.notFound("category \(categoryID)")
            }
            do {
                try db.withTransaction { tx in
                    try tx.run("UPDATE categories SET lifecycle='trashed', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(categoryID)])
                    // Không chuyển frame vào Trash (§6.3) — chỉ gỡ category
                    let frames = try tx.query("SELECT id FROM frames WHERE category_id=?", [.text(categoryID)])
                    for f in frames {
                        try tx.run("UPDATE frames SET category_id=NULL, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), f["id"].stringValue])
                        try tx.run("INSERT OR REPLACE INTO category_restore_links(category_id, frame_id, detached_at_ms) VALUES(?,?,?)",
                                   [.text(categoryID), f["id"].stringValue, .int(Time.nowMs())])
                    }
                    let now = Time.nowMs(clock: clock)
                    try tx.run("""
                        INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms, expires_at_ms,
                            original_parent_id, estimated_bytes, status, last_error)
                        VALUES(?, 'category', ?, ?, ?, ?, NULL, 0, 'trashed', NULL)
                        ON CONFLICT(root_type, root_id) DO UPDATE SET
                            display_name=excluded.display_name, deleted_at_ms=excluded.deleted_at_ms,
                            expires_at_ms=excluded.expires_at_ms, status='trashed'
                        """, [.text(IDFactory.new()), .text(categoryID), .text(cat["name"].stringValue),
                              .int(now), .int(TrashPolicy.expiresAt(deletedAtMs: now))])
                }
                try trashRepo.updateIntent(id: intent.id, status: .committed)
                EventBus.shared.post(.trashChanged)
                EventBus.shared.post(.categoryChanged)
                EventBus.shared.post(.frameLibraryChanged(frameID: nil))
            } catch {
                try trashRepo.updateIntent(id: intent.id, status: .rollbackRequired, error: error.localizedDescription)
                throw error
            }
        }
    }

    public func trashPreset(presetID: String) throws {
        try withRootLock("preset:\(presetID)") {
            let preset = try db.query("SELECT * FROM presets WHERE id=? AND lifecycle='active' AND is_system=0", [.text(presetID)]).first
            guard let p = preset else { throw AppError.invalidState("Preset built-in không xóa được (§8.2)") }
            let intent = try trashRepo.createIntent(opType: "trash", rootID: presetID)
            do {
                try db.withTransaction { tx in
                    try tx.run("UPDATE presets SET lifecycle='trashed', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(presetID)])
                    let now = Time.nowMs(clock: clock)
                    try tx.run("""
                        INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms, expires_at_ms,
                            original_parent_id, estimated_bytes, status, last_error)
                        VALUES(?, 'preset', ?, ?, ?, ?, NULL, 0, 'trashed', NULL)
                        ON CONFLICT(root_type, root_id) DO UPDATE SET
                            display_name=excluded.display_name, deleted_at_ms=excluded.deleted_at_ms,
                            expires_at_ms=excluded.expires_at_ms, status='trashed'
                        """, [.text(IDFactory.new()), .text(presetID), .text(p["name"].stringValue),
                              .int(now), .int(TrashPolicy.expiresAt(deletedAtMs: now))])
                }
                try trashRepo.updateIntent(id: intent.id, status: .committed)
                EventBus.shared.post(.trashChanged)
                EventBus.shared.post(.presetChanged)
            } catch {
                try trashRepo.updateIntent(id: intent.id, status: .rollbackRequired, error: error.localizedDescription)
                throw error
            }
        }
    }

    // MARK: - Restore (§12.4)

    public func restore(_ item: TrashItem) throws {
        try withRootLock("\(item.rootType.rawValue):\(item.rootID)") {
            try trashRepo.setStatus(id: item.id, status: .restoring)
            do {
                switch item.rootType {
                case .session: try restoreSession(item)
                case .frame: try restoreFrame(item)
                case .category: try restoreCategory(item)
                case .preset: try restorePreset(item)
                }
                try trashRepo.remove(id: item.id)
                EventBus.shared.post(.trashChanged)
                EventBus.shared.post(.frameLibraryChanged(frameID: item.rootType == .frame ? item.rootID : nil))
                EventBus.shared.post(.categoryChanged)
                EventBus.shared.post(.presetChanged)
                if item.rootType == .session {
                    EventBus.shared.post(.sessionChanged(sessionID: item.rootID, revision: 0))
                }
            } catch {
                try? trashRepo.setStatus(id: item.id, status: .trashed, error: error.localizedDescription)
                throw error
            }
        }
    }

    private func restoreSession(_ item: TrashItem) throws {
        // Move file về Sessions trước, DB sau; thất bại → item ở Trash + thông báo (§12.4)
        let trashed = layout.trashSessionsDir.appendingPathComponent(item.rootID, isDirectory: true)
        let dest = layout.sessionDir(item.rootID)
        if FileManager.default.fileExists(atPath: trashed.path) {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: trashed, to: dest)
        }
        let committed = try db.scalarInt("""
            SELECT COUNT(*) FROM session_shots WHERE session_id=? AND current_photo_revision_id IS NOT NULL
            """, [.text(item.rootID)])
        let required = try db.scalarInt("SELECT required_capture_count FROM sessions WHERE id=?", [.text(item.rootID)])
        // Phiên từng hoàn thành giữ nguyên trạng thái completed (completed_at_ms != 0)
        let completedAt = try db.scalarInt("SELECT COALESCE(completed_at_ms,0) FROM sessions WHERE id=?", [.text(item.rootID)])
        let status: SessionStatus
        if completedAt > 0 {
            status = .completed
        } else {
            status = Int(committed) >= Int(required) ? .reviewable : .paused
        }
        try db.run("UPDATE sessions SET status=?, updated_at_ms=? WHERE id=?", [.text(status.rawValue), .int(Time.nowMs()), .text(item.rootID)])
    }

    private func restoreFrame(_ item: TrashItem) throws {
        try db.withTransaction { tx in
            try tx.run("UPDATE frames SET lifecycle='active', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(item.rootID)])
        }
        // Tên trùng → hậu tố (E-TRS-01) — so với ĐẦY ĐỦ danh sách tên active để không đụng UNIQUE sau khi đổi
        let currentName = try db.query("SELECT name FROM frames WHERE id=?", [.text(item.rootID)]).first?["name"].stringValue ?? item.displayName
        let activeNames = (try? db.query("SELECT name FROM frames WHERE lifecycle='active' AND id<>?", [.text(item.rootID)]))?.map { $0["name"].stringValue } ?? []
        if activeNames.contains(where: { $0.lowercased() == currentName.lowercased() }) {
            try db.run("UPDATE frames SET name=? WHERE id=?", [.text(FrameRepository.uniqueName(base: currentName, existing: activeNames)), .text(item.rootID)])
        }
        // Danh mục cũ không còn active → Chưa phân loại; danh mục còn active thì GIỮ NGUYÊN (§12.4)
        try db.run("""
            UPDATE frames SET category_id=NULL
            WHERE id=? AND (category_id IS NULL OR category_id NOT IN (SELECT id FROM categories WHERE lifecycle='active'))
            """, [.text(item.rootID)])
    }

    private func restoreCategory(_ item: TrashItem) throws {
        try db.withTransaction { tx in
            try tx.run("UPDATE categories SET lifecycle='active', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(item.rootID)])
            // Chỉ gán lại frame còn unclassified VÀ có mapping; không ghi đè category mới (§12.4, FRM-07)
            let links = try tx.query("SELECT frame_id FROM category_restore_links WHERE category_id=?", [.text(item.rootID)])
            for link in links {
                let frameID = link["frame_id"].stringValue
                let rows = try tx.query("SELECT category_id FROM frames WHERE id=?", [.text(frameID)])
                if rows.first?["category_id"].stringValue.isEmpty == true {
                    try tx.run("UPDATE frames SET category_id=? WHERE id=?", [.text(item.rootID), .text(frameID)])
                }
                try tx.run("DELETE FROM category_restore_links WHERE category_id=? AND frame_id=?", [.text(item.rootID), .text(frameID)])
            }
        }
        // Tên trùng → hậu tố — so với đầy đủ danh sách tên active (UNIQUE index trên active name)
        let activeCatNames = (try? db.query("SELECT name FROM categories WHERE lifecycle='active' AND id<>?", [.text(item.rootID)]))?.map { $0["name"].stringValue } ?? []
        if activeCatNames.contains(where: { $0.lowercased() == item.displayName.lowercased() }) {
            try db.run("UPDATE categories SET name=? WHERE id=?", [.text(FrameRepository.uniqueName(base: item.displayName, existing: activeCatNames)), .text(item.rootID)])
        }
    }

    private func restorePreset(_ item: TrashItem) throws {
        try db.run("UPDATE presets SET lifecycle='active', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(item.rootID)])
        // Tên trùng → hậu tố — so với đầy đủ danh sách tên active (UNIQUE index trên active name)
        let activePresetNames = (try? db.query("SELECT name FROM presets WHERE lifecycle='active' AND id<>?", [.text(item.rootID)]))?.map { $0["name"].stringValue } ?? []
        if activePresetNames.contains(where: { $0.lowercased() == item.displayName.lowercased() }) {
            try db.run("UPDATE presets SET name=? WHERE id=?", [.text(FrameRepository.uniqueName(base: item.displayName, existing: activePresetNames)), .text(item.rootID)])
        }
    }

    // MARK: - Purge (§12.5, §12.6)

    /// Purge idempotent. Trả về true nếu xóa thành công.
    @discardableResult
    public func purge(_ item: TrashItem) -> Bool {
        do {
            return try withRootLock("\(item.rootType.rawValue):\(item.rootID)") {
                try trashRepo.setStatus(id: item.id, status: .purging)
                do {
                    switch item.rootType {
                    case .session: try purgeSession(item)
                    case .frame: try purgeFrame(item)
                    case .category: try purgeCategory(item)
                    case .preset: try purgePreset(item)
                    }
                    try trashRepo.remove(id: item.id)
                    EventBus.shared.post(.trashChanged)
                    EventBus.shared.post(.frameLibraryChanged(frameID: item.rootType == .frame ? item.rootID : nil))
                    if item.rootType == .session {
                        EventBus.shared.post(.sessionChanged(sessionID: item.rootID, revision: 0))
                    }
                    return true
                } catch {
                    try? trashRepo.setStatus(id: item.id, status: .purgeFailed, error: error.localizedDescription)
                    Log.trash.error("Purge lỗi \(item.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
        } catch {
            return false
        }
    }

    private func purgeSession(_ item: TrashItem) throws {
        let sessionID = item.rootID
        // Xóa DB (cascade shots/revisions/placements/adjustments/export_records) trong transaction
        try db.withTransaction { tx in
            let snapshotID = try tx.query("SELECT active_frame_snapshot_id FROM sessions WHERE id=?", [.text(sessionID)]).first?["active_frame_snapshot_id"].stringValue
            try tx.run("DELETE FROM sessions WHERE id=?", [.text(sessionID)])
            if let snapID = snapshotID, !snapID.isEmpty {
                try tx.run("DELETE FROM frame_snapshots WHERE id=?", [.text(snapID)])
                try tx.run("DELETE FROM asset_references WHERE owner_type='frame_snapshot' AND owner_id=?", [.text(snapID)])
            }
        }
        // Xóa thư mục session (nếu còn)
        let dir = layout.trashSessionsDir.appendingPathComponent(sessionID, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        let activeDir = layout.sessionDir(sessionID)
        if FileManager.default.fileExists(atPath: activeDir.path) {
            try FileManager.default.removeItem(at: activeDir)
        }
    }

    private func purgeFrame(_ item: TrashItem) throws {
        let frameID = item.rootID
        let revisionIDs = try db.query("SELECT id FROM frame_revisions WHERE frame_id=?", [.text(frameID)]).map { $0["id"].stringValue }
        try db.withTransaction { tx in
            try tx.run("DELETE FROM frames WHERE id=?", [.text(frameID)]) // cascade revisions + slots
            for revID in revisionIDs {
                try tx.run("DELETE FROM asset_references WHERE owner_type='frame_revision' AND owner_id=?", [.text(revID)])
            }
        }
        // Asset bytes chỉ xóa khi không còn refs (kể cả session trashed — TRS-02)
        try assets.collectGarbage()
    }

    private func purgeCategory(_ item: TrashItem) throws {
        try db.withTransaction { tx in
            try tx.run("DELETE FROM categories WHERE id=?", [.text(item.rootID)])
            try tx.run("DELETE FROM category_restore_links WHERE category_id=?", [.text(item.rootID)])
        }
    }

    private func purgePreset(_ item: TrashItem) throws {
        try db.run("DELETE FROM presets WHERE id=?", [.text(item.rootID)])
    }

    /// Dọn sạch (§12.6): per-item kết quả, không hứa toàn bộ thành công.
    public struct PurgeReport: Equatable {
        public var success: Int = 0
        public var failed: Int = 0
        public var failedNames: [String] = []
    }

    public func purgeAll(items: [TrashItem]) -> PurgeReport {
        var report = PurgeReport()
        for item in items {
            if purge(item) { report.success += 1 }
            else {
                report.failed += 1
                report.failedNames.append(item.displayName)
            }
        }
        return report
    }

    public func estimateTrashBytes() -> Int64 {
        (try? trashRepo.totalBytes()) ?? 0
    }
}
