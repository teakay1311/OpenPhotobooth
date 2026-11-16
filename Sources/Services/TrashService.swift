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

    private let coordinator: OperationCoordinator

    public init(db: SQLiteDatabase, layout: FileLayout, trashRepo: TrashRepository,
                assets: AssetStore, clock: AppClock = SystemClock.shared,
                coordinator: OperationCoordinator = OperationCoordinator.shared) {
        self.db = db; self.layout = layout; self.trashRepo = trashRepo
        self.assets = assets; self.clock = clock
        self.coordinator = coordinator
    }

    // MARK: - Root lock

    private func withRootLock<T>(_ rootKey: String, _ body: () throws -> T) throws -> T {
        // Đồng bộ với OperationCoordinator cho các thao tác phiên / tài nguyên (DATA-01)
        let opToken = try coordinator.acquire(key: rootKey, reason: "TrashService: \(rootKey)")
        defer { opToken.release() }

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

    private func operationKey(for item: TrashItem) throws -> String {
        if item.rootType == .photo {
            guard let sessionID = item.originalParentID, !sessionID.isEmpty else {
                throw AppError.invalidState("Ảnh trong Thùng rác thiếu phiên cha")
            }
            return "session:\(sessionID)"
        }
        return "\(item.rootType.rawValue):\(item.rootID)"
    }

    // MARK: - Soft delete (§12.3)

    public func trashSession(sessionID: String) throws {
        try withRootLock("session:\(sessionID)") {
            guard let session = try db.query("SELECT * FROM sessions WHERE id=? AND status NOT IN ('trashed','purging')", [.text(sessionID)]).first,
                  let name = Self.sessionDisplayName(session),
                  try trashRepo.find(rootType: .session, rootID: sessionID) == nil else {
                throw AppError.invalidState("Phiên không còn đủ điều kiện chuyển vào Thùng rác")
            }
            let busyPhoto = try db.query("""
                SELECT id FROM trash_items WHERE root_type='photo' AND original_parent_id=?
                  AND status IN ('purging','restoring') LIMIT 1
                """, [.text(sessionID)]).first
            guard busyPhoto == nil else {
                throw AppError.invalidState("Phiên có ảnh đang chờ hoàn tất thao tác trong Thùng rác")
            }
            let paths = try sessionPaths(sessionID)
            guard !paths.inTrash else { throw AppError.invalidState("Đường dẫn Thùng rác của phiên đã tồn tại") }
            let bytes = FileLayout.directorySize(paths.active)
            let now = Time.nowMs(clock)
            let itemID = IDFactory.new()
            let journal = Journal(itemID: itemID, rootType: .session, previousStatus: nil)
            let intent = try trashRepo.createIntent(opType: "trash", rootID: sessionID, payloadJSON: try journal.json())
            var moved = false
            do {
                if paths.inActive {
                    try FileManager.default.moveItem(at: paths.active, to: paths.trash)
                    moved = true
                }
                try db.withTransaction { tx in
                    try tx.run("UPDATE sessions SET status='trashed', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
                    try tx.run("""
                        INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms, expires_at_ms,
                            original_parent_id, estimated_bytes, status, last_error)
                        VALUES(?, 'session', ?, ?, ?, ?, NULL, ?, 'trashed', NULL)
                        """, [.text(itemID), .text(sessionID), .text(name),
                              .int(now), .int(TrashPolicy.expiresAt(deletedAtMs: now)), .int(bytes)])
                    try trashRepo.finishIntent(id: intent.id, status: .committed, tx: tx)
                }
            } catch {
                try recordRollback(intent, error: error) {
                    if moved { try FileManager.default.moveItem(at: paths.trash, to: paths.active) }
                }
                throw error
            }
            EventBus.shared.post(.trashChanged)
            EventBus.shared.post(.sessionChanged(sessionID: sessionID, revision: 0))
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
            guard let frame = try db.query("SELECT * FROM frames WHERE id=? AND lifecycle='active'", [.text(frameID)]).first else {
                throw AppError.notFound("frame \(frameID)")
            }
            let itemID = IDFactory.new()
            let journal = Journal(itemID: itemID, rootType: .frame, previousStatus: nil)
            let payload = try journal.json()
            try db.withTransaction { tx in
                let intent = try trashRepo.createIntent(opType: "trash", rootID: frameID, payloadJSON: payload, tx: tx)
                try tx.run("UPDATE frames SET lifecycle='trashed', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(frameID)])
                let now = Time.nowMs(clock)
                let bytes = try tx.query("""
                    SELECT COALESCE(SUM(a.byte_size),0) s FROM frame_revisions r
                    LEFT JOIN assets a ON a.id IN (r.background_asset_id, r.foreground_asset_id)
                    WHERE r.frame_id = ?
                    """, [.text(frameID)]).first?["s"]?.intValue ?? 0
                try tx.run("""
                    INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms, expires_at_ms,
                        original_parent_id, estimated_bytes, status, last_error)
                    VALUES(?, 'frame', ?, ?, ?, ?, ?, ?, 'trashed', NULL)
                    """, [.text(itemID), .text(frameID),
                          .text(frame["name"].stringValue),
                          .int(now), .int(TrashPolicy.expiresAt(deletedAtMs: now)),
                          frame["category_id"].stringValue.isEmpty ? .null : (frame["category_id"] ?? .null),
                          .int(Int64(bytes))])
                try trashRepo.finishIntent(id: intent.id, status: .committed, tx: tx)
            }
            EventBus.shared.post(.trashChanged)
            EventBus.shared.post(.frameLibraryChanged(frameID: frameID))
        }
    }

    /// Xóa danh mục: frame thành unclassified + lưu mapping để khôi phục (§6.3, §12.4).
    public func trashCategory(categoryID: String) throws {
        try withRootLock("category:\(categoryID)") {
            guard let cat = try db.query("SELECT * FROM categories WHERE id=? AND lifecycle='active'", [.text(categoryID)]).first else {
                throw AppError.notFound("category \(categoryID)")
            }
            let itemID = IDFactory.new()
            let journal = Journal(itemID: itemID, rootType: .category, previousStatus: nil)
            let payload = try journal.json()
            try db.withTransaction { tx in
                let intent = try trashRepo.createIntent(opType: "trash", rootID: categoryID, payloadJSON: payload, tx: tx)
                try tx.run("UPDATE categories SET lifecycle='trashed', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(categoryID)])
                // Không chuyển frame vào Trash (§6.3) — chỉ gỡ category
                let frames = try tx.query("SELECT id FROM frames WHERE category_id=?", [.text(categoryID)])
                for f in frames {
                    try tx.run("UPDATE frames SET category_id=NULL, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(f["id"].stringValue)])
                    try tx.run("INSERT OR REPLACE INTO category_restore_links(category_id, frame_id, detached_at_ms) VALUES(?,?,?)",
                               [.text(categoryID), .text(f["id"].stringValue), .int(Time.nowMs())])
                }
                let now = Time.nowMs(clock)
                try tx.run("""
                    INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms, expires_at_ms,
                        original_parent_id, estimated_bytes, status, last_error)
                    VALUES(?, 'category', ?, ?, ?, ?, NULL, 0, 'trashed', NULL)
                    """, [.text(itemID), .text(categoryID), .text(cat["name"].stringValue),
                          .int(now), .int(TrashPolicy.expiresAt(deletedAtMs: now))])
                try trashRepo.finishIntent(id: intent.id, status: .committed, tx: tx)
            }
            EventBus.shared.post(.trashChanged)
            EventBus.shared.post(.categoryChanged)
            EventBus.shared.post(.frameLibraryChanged(frameID: nil))
        }
    }

    public func trashPreset(presetID: String) throws {
        try withRootLock("preset:\(presetID)") {
            let preset = try db.query("SELECT * FROM presets WHERE id=? AND lifecycle='active' AND is_system=0", [.text(presetID)]).first
            guard let p = preset else { throw AppError.invalidState("Preset built-in không xóa được (§8.2)") }
            let itemID = IDFactory.new()
            let journal = Journal(itemID: itemID, rootType: .preset, previousStatus: nil)
            let payload = try journal.json()
            try db.withTransaction { tx in
                let intent = try trashRepo.createIntent(opType: "trash", rootID: presetID, payloadJSON: payload, tx: tx)
                try tx.run("UPDATE presets SET lifecycle='trashed', updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(presetID)])
                let now = Time.nowMs(clock)
                try tx.run("""
                    INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms, expires_at_ms,
                        original_parent_id, estimated_bytes, status, last_error)
                    VALUES(?, 'preset', ?, ?, ?, ?, NULL, 0, 'trashed', NULL)
                    """, [.text(itemID), .text(presetID), .text(p["name"].stringValue),
                          .int(now), .int(TrashPolicy.expiresAt(deletedAtMs: now))])
                try trashRepo.finishIntent(id: intent.id, status: .committed, tx: tx)
            }
            EventBus.shared.post(.trashChanged)
            EventBus.shared.post(.presetChanged)
        }
    }

    // MARK: - Restore (§12.4)

    public enum ItemOperationResult: Equatable {
        case processed
        case skipped(reason: String)
        case failed(reason: String)
    }

    public func restore(_ item: TrashItem) throws {
        try withRootLock(try operationKey(for: item)) {
            let fresh = try currentItem(item)
            guard Time.nowMs(clock) < TrashPolicy.expiresAt(deletedAtMs: fresh.deletedAtMs) else {
                throw AppError.trashExpired("Mục đã quá hạn 30 ngày trong Thùng rác")
            }
            let paths = fresh.rootType == .session ? try sessionPaths(fresh.rootID) : nil
            let detail = fresh.rootType == .session
                ? try SessionRepository(db: db, layout: layout).getDetail(sessionID: fresh.rootID) : nil
            if let paths {
                guard let detail else { throw AppError.notFound("Phiên chụp \(fresh.rootID)") }
                for layer in [detail.snapshot.background, detail.snapshot.foreground].compactMap({ $0 }) {
                    guard (try? assets.loadVerifiedImage(assetID: layer.assetID)) != nil else {
                        throw AppError.missingFrameAssets
                    }
                }
                guard !paths.inActive else { throw AppError.invalidState("Phiên có dữ liệu ở vị trí đang hoạt động") }
                try validateSessionFiles(fresh.rootID, at: paths.inTrash ? paths.trash : nil, currentOnly: true)
            }
            let restoredPhoto = fresh.rootType == .photo ? try photoLocation(fresh) : nil
            if let restoredPhoto {
                guard !restoredPhoto.parentInTrash else {
                    throw AppError.invalidState("Không thể khôi phục ảnh khi phiên cha đang ở trong Thùng rác")
                }
                guard restoredPhoto.currentRevisionID == nil else {
                    throw AppError.invalidState("Lượt chụp đã có ảnh bù")
                }
                try verifyPhotoFile(restoredPhoto)
            }
            let intent = try begin(fresh, op: "restore", status: .restoring)
            var moved = false
            do {
                if let paths, paths.inTrash {
                    try FileManager.default.moveItem(at: paths.trash, to: paths.active)
                    moved = true
                }
                try db.withTransaction { tx in
                    switch fresh.rootType {
                    case .session:
                        guard let detail else { throw AppError.notFound("Phiên chụp \(fresh.rootID)") }
                        try restoreSession(detail, tx: tx)
                    case .frame: try restoreFrame(fresh, tx: tx)
                    case .category: try restoreCategory(fresh, tx: tx)
                    case .preset: try restorePreset(fresh, tx: tx)
                    case .photo:
                        guard let restoredPhoto else { throw AppError.restoreMissingBytes }
                        try complete(fresh, intent: intent, tx: tx)
                        try restorePhoto(fresh, photo: restoredPhoto, tx: tx)
                        return
                    }
                    try complete(fresh, intent: intent, tx: tx)
                }
            } catch {
                try recordRollback(intent, item: fresh, error: error) {
                    if moved, let paths { try FileManager.default.moveItem(at: paths.active, to: paths.trash) }
                }
                throw error
            }
            publishChange(fresh)
            EventBus.shared.post(.categoryChanged)
            EventBus.shared.post(.presetChanged)
        }
    }

    public func restoreResult(_ item: TrashItem) -> ItemOperationResult {
        do {
            try restore(item)
            return .processed
        } catch let err as AppError {
            switch err {
            case .trashExpired:
                return .skipped(reason: "Mục đã quá hạn 30 ngày trong Thùng rác")
            case .invalidState(let reason):
                return .skipped(reason: reason)
            case .notFound(let reason):
                return .skipped(reason: reason)
            default:
                return .failed(reason: err.message)
            }
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private func restoreSession(_ detail: SessionDetail, tx: SQLiteDatabase.TransactionHandle) throws {
        let completedAt = detail.session.completedAtMs ?? 0
        let status: SessionStatus
        let newCompletedAt: SQLiteValue
        if detail.hasEnoughPhotos && completedAt > 0 {
            status = .completed
            newCompletedAt = .int(completedAt)
        } else {
            status = detail.missingIndices.isEmpty ? .reviewable : .paused
            newCompletedAt = .null
        }
        try tx.run("UPDATE sessions SET status=?, completed_at_ms=?, updated_at_ms=? WHERE id=?",
                   [.text(status.rawValue), newCompletedAt, .int(Time.nowMs()), .text(detail.session.id)])
    }

    private func restoreFrame(_ item: TrashItem, tx: SQLiteDatabase.TransactionHandle) throws {
        // D2-A05: Xử lý tên trùng TRƯỚC KHI chuyển active để không đụng UNIQUE constraint
        let currentName = try tx.query("SELECT name FROM frames WHERE id=?", [.text(item.rootID)]).first?["name"].stringValue ?? item.displayName
        let activeNames = try tx.query("SELECT name FROM frames WHERE lifecycle='active' AND id<>?", [.text(item.rootID)]).map { $0["name"].stringValue }
        let finalName: String
        if activeNames.contains(where: { $0.caseInsensitiveCompare(currentName) == .orderedSame }) {
            finalName = FrameRepository.uniqueName(base: currentName, existing: activeNames)
        } else {
            finalName = currentName
        }
        try tx.run("UPDATE frames SET name=?, lifecycle='active', updated_at_ms=? WHERE id=?",
                   [.text(finalName), .int(Time.nowMs()), .text(item.rootID)])

        // Danh mục cũ không còn active → Chưa phân loại; danh mục còn active thì GIỮ NGUYÊN (§12.4)
        try tx.run("""
            UPDATE frames SET category_id=NULL
            WHERE id=? AND (category_id IS NULL OR category_id NOT IN (SELECT id FROM categories WHERE lifecycle='active'))
            """, [.text(item.rootID)])
    }

    private func restoreCategory(_ item: TrashItem, tx: SQLiteDatabase.TransactionHandle) throws {
        // D2-A05: Xử lý tên trùng TRƯỚC KHI chuyển active
        let currentName = try tx.query("SELECT name FROM categories WHERE id=?", [.text(item.rootID)]).first?["name"].stringValue ?? item.displayName
        let activeCatNames = try tx.query("SELECT name FROM categories WHERE lifecycle='active' AND id<>?", [.text(item.rootID)]).map { $0["name"].stringValue }
        let finalName: String
        if activeCatNames.contains(where: { $0.caseInsensitiveCompare(currentName) == .orderedSame }) {
            finalName = FrameRepository.uniqueName(base: currentName, existing: activeCatNames)
        } else {
            finalName = currentName
        }
        try tx.run("UPDATE categories SET name=?, lifecycle='active', updated_at_ms=? WHERE id=?",
                   [.text(finalName), .int(Time.nowMs()), .text(item.rootID)])

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

    private func restorePreset(_ item: TrashItem, tx: SQLiteDatabase.TransactionHandle) throws {
        // D2-A05: Xử lý tên trùng TRƯỚC KHI chuyển active
        let currentName = try tx.query("SELECT name FROM presets WHERE id=?", [.text(item.rootID)]).first?["name"].stringValue ?? item.displayName
        let activePresetNames = try tx.query("SELECT name FROM presets WHERE lifecycle='active' AND id<>?", [.text(item.rootID)]).map { $0["name"].stringValue }
        let finalName: String
        if activePresetNames.contains(where: { $0.caseInsensitiveCompare(currentName) == .orderedSame }) {
            finalName = FrameRepository.uniqueName(base: currentName, existing: activePresetNames)
        } else {
            finalName = currentName
        }
        try tx.run("UPDATE presets SET name=?, lifecycle='active', updated_at_ms=? WHERE id=?",
                   [.text(finalName), .int(Time.nowMs()), .text(item.rootID)])
    }

    private func restorePhoto(_ item: TrashItem, photo: PhotoLocation, tx: SQLiteDatabase.TransactionHandle) throws {
        guard let parentID = item.originalParentID, !parentID.isEmpty else {
            throw AppError.notFound("Không tìm thấy phiên của ảnh")
        }
        let sessionRows = try tx.query("SELECT * FROM sessions WHERE id=?", [.text(parentID)])
        guard let sRow = sessionRows.first, let session = SessionRepository.session(from: sRow) else {
            throw AppError.notFound("Phiên chụp \(parentID)")
        }
        if session.status == .trashed || session.status == .purging {
            throw AppError.invalidState("Không thể khôi phục ảnh khi phiên cha đang ở trong Thùng rác")
        }

        let shot = try tx.query("SELECT id FROM session_shots WHERE id=? AND session_id=? AND current_photo_revision_id IS NULL",
                                [.text(photo.shotID), .text(parentID)]).first
        guard shot != nil else {
            throw AppError.invalidState("Lượt chụp đã có ảnh bù, không thể khôi phục ảnh cũ vào ô này.")
        }
        try tx.run("UPDATE session_shots SET current_photo_revision_id=? WHERE id=?", [.text(item.rootID), .text(photo.shotID)])

        let snapshot = try SessionRepository.loadSnapshot(session.activeFrameSnapshotID, tx: tx)
        let missing = session.captureIndices(in: snapshot)
            .subtracting(try SessionRepository.availableCaptureIndices(sessionID: parentID, tx: tx))
        let newStatus: SessionStatus = missing.isEmpty
            ? (session.status == .completed ? .completed : .reviewable)
            : .paused

        try tx.run("""
            UPDATE sessions SET status=?, current_capture_index=?, completed_at_ms=?,
                revision_no=revision_no+1, updated_at_ms=? WHERE id=?
            """, [.text(newStatus.rawValue), .int(Int64(missing.min() ?? session.captureCount)),
                  newStatus == .completed ? session.completedAtMs.map { .int($0) } ?? .null : .null,
                  .int(Time.nowMs()), .text(parentID)])
    }

    // MARK: - Purge (§12.5, §12.6, §3.3)

    public func purgeResult(_ item: TrashItem) -> ItemOperationResult {
        purgeResult(item, onlyExpired: false)
    }

    private func purgeResult(_ item: TrashItem, onlyExpired: Bool) -> ItemOperationResult {
        do {
            return try withRootLock(try operationKey(for: item)) {
                let fresh = try currentItem(item)
                if onlyExpired, fresh.status != .trashed || fresh.expiresAtMs > Time.nowMs(clock) {
                    return .skipped(reason: "Mục chưa đủ điều kiện tự động dọn")
                }
                let paths = try purgePaths(fresh, allowMissing: fresh.status == .purgeFailed)
                var photoPath: String?
                if fresh.rootType == .photo {
                    let photo = try photoLocation(fresh)
                    guard !photo.parentInTrash else {
                        return .skipped(reason: "Tạm dừng dọn riêng ảnh con khi phiên cha đang ở trong Thùng rác")
                    }
                    try verifyPhotoFile(photo)
                    photoPath = photo.relativePath
                }
                let intent = try begin(fresh, op: "purge", status: .purging, photoPath: photoPath)
                return runPurge(fresh, intent: intent, paths: paths)
            }
        } catch AppError.invalidState(let reason) {
            return .skipped(reason: reason)
        } catch {
            return .skipped(reason: error.localizedDescription)
        }
    }

    @discardableResult
    public func purge(_ item: TrashItem) -> Bool {
        purgeResult(item) == .processed
    }

    private func runPurge(_ item: TrashItem, intent: OperationIntentRecord, paths: SessionPaths?) -> ItemOperationResult {
        var removedPhotoFile = false
        do {
            if item.rootType == .photo {
                let photo = try photoLocation(item)
                guard !photo.parentInTrash, photo.currentRevisionID != item.rootID,
                      Self.decodeJournal(intent)?.photoPath == photo.relativePath else {
                    throw AppError.invalidState("Không xác minh được ý định dọn ảnh")
                }
                if try fileValues(photo.url) != nil {
                    try verifyPhotoFile(photo)
                    try FileManager.default.removeItem(at: photo.url)
                }
                removedPhotoFile = true
            }
            if let paths, paths.inTrash {
                try FileManager.default.removeItem(at: paths.trash)
            }
            try db.withTransaction { tx in
                switch item.rootType {
                case .session: try purgeSession(item, tx: tx)
                case .frame: try purgeFrame(item, tx: tx)
                case .category: try purgeCategory(item, tx: tx)
                case .preset: try tx.run("DELETE FROM presets WHERE id=?", [.text(item.rootID)])
                case .photo: try purgePhoto(item, tx: tx)
                }
                try complete(item, intent: intent, tx: tx)
            }
        } catch {
            // The prepared intent remains replayable once the file has been removed.
            if removedPhotoFile { return .failed(reason: error.localizedDescription) }
            do {
                try db.withTransaction { tx in
                    try tx.run("UPDATE trash_items SET status='purge_failed', last_error=? WHERE id=?",
                               [.text(error.localizedDescription), .text(item.id)])
                    try trashRepo.finishIntent(id: intent.id, status: .failed, tx: tx)
                }
            } catch {
                Log.trash.error("Không thể ghi trạng thái dọn rác: \(error.localizedDescription, privacy: .private)")
            }
            publishChange(item)
            return .failed(reason: error.localizedDescription)
        }
        if item.rootType == .session || item.rootType == .frame {
            do { _ = try assets.collectGarbage() }
            catch { Log.trash.error("Không thể dọn tài nguyên: \(error.localizedDescription, privacy: .private)") }
        }
        publishChange(item)
        return .processed
    }

    private func purgeSession(_ item: TrashItem, tx: SQLiteDatabase.TransactionHandle) throws {
        // Dọn các mục rác ảnh con thuộc phiên này (§2.3 item 3)
        let childPhotos = try tx.query("SELECT id, root_id FROM trash_items WHERE root_type='photo' AND original_parent_id=?", [.text(item.rootID)])
        for child in childPhotos {
            let photoRevID = child["root_id"].stringValue
            let itemID = child["id"].stringValue
            try tx.run("""
                UPDATE operation_intents SET status='committed', updated_at_ms=?, last_error=NULL
                WHERE root_id=? AND op_type IN ('purge','restore')
                  AND status IN ('prepared','files_staged','files_promoted','rollback_required')
                  AND json_extract(CASE WHEN json_valid(payload_json) THEN payload_json ELSE '{}' END, '$.itemID')=?
                """, [.int(Time.nowMs(clock)), .text(photoRevID), .text(itemID)])
            try tx.run("DELETE FROM photo_adjustments WHERE photo_revision_id=?", [.text(photoRevID)])
            try tx.run("DELETE FROM photo_revisions WHERE id=?", [.text(photoRevID)])
            try tx.run("DELETE FROM trash_items WHERE id=?", [.text(itemID)])
        }

        let snapshotID = try tx.query("SELECT active_frame_snapshot_id FROM sessions WHERE id=?", [.text(item.rootID)]).first?["active_frame_snapshot_id"].stringValue
        try tx.run("DELETE FROM sessions WHERE id=?", [.text(item.rootID)])
        if let snapshotID, !snapshotID.isEmpty {
            let references = try tx.scalarInt("SELECT COUNT(*) FROM sessions WHERE active_frame_snapshot_id=?", [.text(snapshotID)])
            if references == 0 {
                try tx.run("DELETE FROM frame_snapshots WHERE id=?", [.text(snapshotID)])
                try tx.run("DELETE FROM asset_references WHERE owner_type='frame_snapshot' AND owner_id=?", [.text(snapshotID)])
            }
        }
    }

    private func purgePhoto(_ item: TrashItem, tx: SQLiteDatabase.TransactionHandle) throws {
        try tx.run("DELETE FROM photo_revisions WHERE id=?", [.text(item.rootID)])
    }

    private struct PhotoLocation {
        let shotID: String
        let currentRevisionID: String?
        let parentInTrash: Bool
        let relativePath: String
        let sha256: String
        let url: URL
    }

    private func photoLocation(_ item: TrashItem) throws -> PhotoLocation {
        guard let sessionID = item.originalParentID,
              let row = try db.query("""
                  SELECT pr.shot_id, pr.relative_path, pr.sha256, sh.current_photo_revision_id, s.status
                  FROM photo_revisions pr JOIN session_shots sh ON sh.id=pr.shot_id
                  JOIN sessions s ON s.id=sh.session_id
                  WHERE pr.id=? AND s.id=? AND pr.state='available'
                  """, [.text(item.rootID), .text(sessionID)]).first else {
            throw AppError.notFound("Phiên bản ảnh trong Thùng rác")
        }
        let paths = try sessionPaths(sessionID)
        let relative = row["relative_path"].stringValue
        let prefix = "Sessions/\(sessionID)/Originals/"
        guard relative.hasPrefix(prefix), FileLayout.isValidRelativePath(relative) else {
            throw AppError.invalidState("Đường dẫn ảnh không thuộc phiên")
        }
        let status = row["status"].stringValue
        let inTrash = status == "trashed" || status == "purging"
        guard inTrash ? paths.inTrash : !paths.inTrash else {
            throw AppError.invalidState("Vị trí dữ liệu phiên không khớp trạng thái")
        }
        let directory = inTrash ? paths.trash : paths.active
        let suffix = String(relative.dropFirst("Sessions/\(sessionID)/".count))
        let url = directory.appendingPathComponent(suffix)
        let expected = directory.resolvingSymlinksInPath().appendingPathComponent(suffix)
        guard url.resolvingSymlinksInPath().path == expected.path else {
            throw AppError.invalidState("Đường dẫn ảnh đi qua liên kết tượng trưng")
        }
        let currentRevisionID = row["current_photo_revision_id"].stringValue
        return PhotoLocation(shotID: row["shot_id"].stringValue,
                             currentRevisionID: currentRevisionID.isEmpty ? nil : currentRevisionID,
                             parentInTrash: inTrash, relativePath: relative,
                             sha256: row["sha256"].stringValue, url: url)
    }

    private func verifyPhotoFile(_ photo: PhotoLocation) throws {
        guard let values = try fileValues(photo.url) else { throw AppError.restoreMissingBytes }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Hashing.sha256Hex(fileURL: photo.url) == photo.sha256 else {
            throw AppError.ioFailure("Không xác minh được tệp ảnh nguồn")
        }
    }

    private func purgeFrame(_ item: TrashItem, tx: SQLiteDatabase.TransactionHandle) throws {
        let frameID = item.rootID
        let revisionIDs = try tx.query("SELECT id FROM frame_revisions WHERE frame_id=?", [.text(frameID)]).map { $0["id"].stringValue }
        try tx.run("DELETE FROM frames WHERE id=?", [.text(frameID)]) // cascade revisions + slots
        for revID in revisionIDs {
            try tx.run("DELETE FROM asset_references WHERE owner_type='frame_revision' AND owner_id=?", [.text(revID)])
        }
    }

    private func purgeCategory(_ item: TrashItem, tx: SQLiteDatabase.TransactionHandle) throws {
        try tx.run("DELETE FROM categories WHERE id=?", [.text(item.rootID)])
        try tx.run("DELETE FROM category_restore_links WHERE category_id=?", [.text(item.rootID)])
    }

    private struct Journal: Codable {
        let itemID: String
        let rootType: TrashRootType
        let previousStatus: TrashStatus?
        var photoPath: String? = nil

        func json() throws -> String {
            String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        }
    }

    private struct SessionPaths {
        let active: URL
        let trash: URL
        let inActive: Bool
        let inTrash: Bool
    }

    private func sessionPaths(_ id: String) throws -> SessionPaths {
        guard FileLayout.isValidRelativePath(id), !id.contains("/") else {
            throw AppError.invalidState("ID phiên không hợp lệ")
        }
        let active = layout.sessionDir(id)
        let trash = layout.trashSessionsDir.appendingPathComponent(id, isDirectory: true)
        let inActive = try isSessionDirectory(active)
        let inTrash = try isSessionDirectory(trash)
        guard !inActive || !inTrash else {
            throw AppError.invalidState("Phiên có dữ liệu ở cả hai vị trí")
        }
        return SessionPaths(active: active, trash: trash, inActive: inActive, inTrash: inTrash)
    }

    private func isSessionDirectory(_ url: URL) throws -> Bool {
        guard let values = try fileValues(url) else { return false }
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path == layout.rootURL.resolvingSymlinksInPath()
                .appendingPathComponent(String(url.path.dropFirst(layout.rootURL.path.count + 1))).path else {
            throw AppError.invalidState("Đường dẫn nội bộ của phiên không hợp lệ")
        }
        return true
    }

    private func fileValues(_ url: URL) throws -> URLResourceValues? {
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
    }

    private func validateSessionFiles(_ id: String, at directory: URL?, allowMissing: Bool = false, currentOnly: Bool = false) throws {
        let rows = try db.query("""
            SELECT r.relative_path, r.sha256 FROM photo_revisions r
            JOIN session_shots s ON s.id=r.shot_id
            WHERE s.session_id=? AND r.state='available' AND (?=0 OR s.current_photo_revision_id=r.id)
            """, [.text(id), .int(currentOnly ? 1 : 0)])
        let prefix = "Sessions/\(id)/"
        for row in rows {
            let path = row["relative_path"].stringValue
            guard path.hasPrefix(prefix), FileLayout.isValidRelativePath(path) else {
                throw AppError.invalidState("Đường dẫn ảnh không thuộc phiên")
            }
            let suffix = String(path.dropFirst(prefix.count))
            guard !suffix.isEmpty else { throw AppError.restoreMissingBytes }
            guard let directory else {
                if allowMissing { continue }
                throw AppError.restoreMissingBytes
            }
            let url = directory.appendingPathComponent(suffix)
            let expected = directory.resolvingSymlinksInPath().appendingPathComponent(suffix)
            guard url.resolvingSymlinksInPath().path == expected.path else {
                throw AppError.invalidState("Đường dẫn ảnh không thuộc thư mục phiên")
            }
            guard let values = try fileValues(url) else {
                if allowMissing { continue }
                throw AppError.restoreMissingBytes
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Hashing.sha256Hex(fileURL: url) == row["sha256"].stringValue else {
                throw AppError.ioFailure("Không xác minh được ảnh đã lưu của phiên")
            }
        }
    }

    private func rootStatus(_ type: TrashRootType, _ id: String) throws -> String? {
        let sql: String
        switch type {
        case .session: sql = "SELECT status AS state FROM sessions WHERE id=?"
        case .frame: sql = "SELECT lifecycle AS state FROM frames WHERE id=?"
        case .category: sql = "SELECT lifecycle AS state FROM categories WHERE id=?"
        case .preset: sql = "SELECT lifecycle AS state FROM presets WHERE id=?"
        case .photo:
            let rows = try db.query("SELECT current_photo_revision_id FROM session_shots ss JOIN photo_revisions pr ON pr.shot_id = ss.id WHERE pr.id=?", [.text(id)])
            if let row = rows.first {
                let currentRev = row["current_photo_revision_id"]?.stringValue
                return (currentRev == id) ? "active" : "trashed"
            }
            return "trashed"
        }
        return try db.query(sql, [.text(id)]).first?["state"].stringValue
    }

    private func currentItem(_ item: TrashItem) throws -> TrashItem {
        guard let fresh = try trashRepo.find(rootType: item.rootType, rootID: item.rootID) else {
            throw AppError.invalidState("Mục không còn tồn tại trong Thùng rác")
        }
        guard fresh.id == item.id else {
            throw AppError.invalidState("Mục đã được thay thế bằng bản ghi rác mới")
        }
        guard fresh.status == .trashed || fresh.status == .purgeFailed,
              let state = try rootStatus(fresh.rootType, fresh.rootID),
              state == "trashed" || state == "purging" else {
            throw AppError.invalidState("Mục không đủ điều kiện thao tác (\(fresh.status.rawValue))")
        }
        return fresh
    }

    private func purgePaths(_ item: TrashItem, allowMissing: Bool) throws -> SessionPaths? {
        guard item.rootType == .session else { return nil }
        let paths = try sessionPaths(item.rootID)
        guard !paths.inActive else { throw AppError.invalidState("Phiên có dữ liệu ở vị trí đang hoạt động") }
        try validateSessionFiles(item.rootID, at: paths.inTrash ? paths.trash : nil, allowMissing: allowMissing)
        return paths
    }

    private func begin(_ item: TrashItem, op: String, status: TrashStatus, photoPath: String? = nil) throws -> OperationIntentRecord {
        let payload = try Journal(itemID: item.id, rootType: item.rootType, previousStatus: item.status, photoPath: photoPath).json()
        return try db.withTransaction { tx in
            let intent = try trashRepo.createIntent(opType: op, rootID: item.rootID, payloadJSON: payload, tx: tx)
            try tx.run("UPDATE trash_items SET status=?, last_error=NULL WHERE id=?",
                       [.text(status.rawValue), .text(item.id)])
            return intent
        }
    }

    private func complete(_ item: TrashItem, intent: OperationIntentRecord, tx: SQLiteDatabase.TransactionHandle) throws {
        try tx.run("DELETE FROM trash_items WHERE id=?", [.text(item.id)])
        try trashRepo.finishIntent(id: intent.id, status: .committed, tx: tx)
    }

    private func recordRollback(_ intent: OperationIntentRecord, item: TrashItem? = nil, error: Error, rollback: () throws -> Void) throws {
        do {
            try rollback()
        } catch let rollbackError {
            try? trashRepo.updateIntent(id: intent.id, status: .rollbackRequired, error: rollbackError.localizedDescription)
            throw rollbackError
        }
        try db.withTransaction { tx in
            if let item {
                try tx.run("UPDATE trash_items SET status=?, last_error=? WHERE id=?",
                           [.text(item.status.rawValue), .text(error.localizedDescription), .text(item.id)])
            }
            try trashRepo.finishIntent(id: intent.id, status: .failed, tx: tx)
        }
    }

    private func publishChange(_ item: TrashItem) {
        EventBus.shared.post(.trashChanged)
        EventBus.shared.post(.frameLibraryChanged(frameID: item.rootType == .frame ? item.rootID : nil))
        if item.rootType == .session {
            EventBus.shared.post(.sessionChanged(sessionID: item.rootID, revision: 0))
        } else if item.rootType == .photo, let parent = item.originalParentID {
            EventBus.shared.post(.sessionChanged(sessionID: parent, revision: 0))
        }
    }

    struct RecoveryResult {
        var issues: [String] = []
        var excludedSessions: Set<String> = []
    }

    func recoverOperations() throws -> RecoveryResult {
        var report = RecoveryResult()
        let items = try trashRepo.list()
        let intents = try trashRepo.pendingIntents().filter { ["trash", "restore", "purge"].contains($0.opType) }
        var handledIntents: Set<String> = []
        for item in items {
            let related = intents.filter { intent in
                guard intent.rootID == item.rootID else { return false }
                if let journal = Self.decodeJournal(intent) {
                    return journal.itemID == item.id && journal.rootType == item.rootType
                }
                return intent.opType == "trash" && intent.payloadJSON == "{}"
            }
            handledIntents.formUnion(related.map(\.id))
            do {
                try withRootLock(try operationKey(for: item)) {
                    guard let fresh = try trashRepo.getItem(id: item.id), fresh.rootID == item.rootID,
                          fresh.rootType == item.rootType else { return }
                    try recoverItem(fresh, intents: related)
                }
                if item.rootType == .session, try trashRepo.getItem(id: item.id) != nil {
                    report.excludedSessions.insert(item.rootID)
                }
            } catch {
                report.issues.append("\(item.rootID.prefix(8)): \(error.localizedDescription)")
                if item.rootType == .session { report.excludedSessions.insert(item.rootID) }
            }
        }

        for intent in intents where !handledIntents.contains(intent.id) {
            do {
                let journal = Self.decodeJournal(intent)
                if intent.opType == "trash", journal?.rootType == .session || intent.payloadJSON == "{}" {
                    if let journal, let newer = try trashRepo.find(rootType: journal.rootType, rootID: intent.rootID),
                       newer.id != journal.itemID {
                        try trashRepo.updateIntent(id: intent.id, status: .failed, error: "Mục trong Thùng rác đã thay đổi")
                        continue
                    }
                    try withRootLock("session:\(intent.rootID)") { try recoverUncommittedTrash(intent) }
                } else {
                    // A different item for this root invalidates an older restore/purge authorization.
                    guard let journal,
                          try trashRepo.find(rootType: journal.rootType, rootID: intent.rootID) != nil else {
                        throw AppError.invalidState("Không xác định được mục của thao tác đang chờ")
                    }
                    try trashRepo.updateIntent(id: intent.id, status: .failed, error: "Mục trong Thùng rác đã thay đổi")
                }
            } catch {
                report.issues.append("\(intent.rootID.prefix(8)): \(error.localizedDescription)")
                if Self.decodeJournal(intent)?.rootType == .session || intent.opType == "trash" {
                    report.excludedSessions.insert(intent.rootID)
                }
            }
        }
        return report
    }

    private static func decodeJournal(_ intent: OperationIntentRecord) -> Journal? {
        try? JSONDecoder().decode(Journal.self, from: Data(intent.payloadJSON.utf8))
    }

    private func recoverUncommittedTrash(_ intent: OperationIntentRecord) throws {
        let id = intent.rootID
        let state = try rootStatus(.session, id)
        let paths = try sessionPaths(id)
        if state == nil && !paths.inActive && !paths.inTrash && intent.payloadJSON == "{}" {
            // Legacy non-session soft deletes did not store the root type.
            let states = try [TrashRootType.frame, .category, .preset].compactMap { try rootStatus($0, id) }
            guard states.count == 1, let state = states.first else {
                throw AppError.invalidState("Không xác định được đối tượng của thao tác xóa")
            }
            try trashRepo.updateIntent(id: intent.id, status: state == "trashed" ? .committed : .failed)
            return
        }
        guard let state, state != "trashed", state != "purging",
              try trashRepo.find(rootType: .session, rootID: id) == nil else {
            throw AppError.invalidState("Không xác định được vị trí an toàn của phiên")
        }
        try validateSessionFiles(id, at: paths.inTrash ? paths.trash : (paths.inActive ? paths.active : nil))
        if paths.inTrash {
            try FileManager.default.moveItem(at: paths.trash, to: paths.active)
        }
        try trashRepo.updateIntent(id: intent.id, status: .failed, error: "Đã hoàn tác chuyển phiên vào Thùng rác")
    }

    private func recoverItem(_ item: TrashItem, intents: [OperationIntentRecord]) throws {
        let state = try rootStatus(item.rootType, item.rootID)
        let paths = item.rootType == .session ? try sessionPaths(item.rootID) : nil
        let rootIsTrashed = state == "trashed" || state == "purging"
        let restore = intents.last { $0.opType == "restore" }
        let purge = intents.last { $0.opType == "purge" }
        let trash = intents.filter { $0.opType == "trash" }

        if state == nil, item.status == .purging, let purge,
           paths?.inActive != true, paths?.inTrash != true {
            try db.withTransaction { tx in try complete(item, intent: purge, tx: tx) }
            return
        }
        if item.status == .restoring, state != nil, !rootIsTrashed {
            if let paths {
                guard !paths.inTrash else { throw AppError.invalidState("Phiên đã khôi phục nhưng tệp vẫn ở Thùng rác") }
                try validateSessionFiles(item.rootID, at: paths.inActive ? paths.active : nil)
            }
            try db.withTransaction { tx in
                try tx.run("DELETE FROM trash_items WHERE id=?", [.text(item.id)])
                if let restore { try trashRepo.finishIntent(id: restore.id, status: .committed, tx: tx) }
            }
            publishChange(item)
            return
        }
        guard rootIsTrashed else { throw AppError.invalidState("Mục rác và trạng thái đối tượng không khớp") }
        if item.status == .purging {
            if item.rootType == .photo {
                let photo = try photoLocation(item)
                if photo.parentInTrash || purge.flatMap(Self.decodeJournal)?.photoPath == nil {
                    // The original implementation marked a child before deferring its purge.
                    try verifyPhotoFile(photo)
                    let previous = purge.flatMap(Self.decodeJournal)?.previousStatus ?? .trashed
                    try db.withTransaction { tx in
                        try tx.run("UPDATE trash_items SET status=?, last_error=NULL WHERE id=?",
                                   [.text(previous.rawValue), .text(item.id)])
                        if let purge { try trashRepo.finishIntent(id: purge.id, status: .failed, tx: tx) }
                    }
                    publishChange(item)
                    return
                }
            }
            guard paths?.inActive != true else { throw AppError.invalidState("Phiên đang dọn có tệp ở vị trí hoạt động") }
            if let purge {
                let checkedPaths = try purgePaths(item, allowMissing: true)
                if case .failed(let reason) = runPurge(item, intent: purge, paths: checkedPaths) {
                    throw AppError.purgeFailed(reason)
                }
            } else {
                try trashRepo.setStatus(id: item.id, status: .purgeFailed,
                                        error: "Lần dọn trước bị gián đoạn. Hãy xác nhận thử lại.")
                publishChange(item)
            }
            return
        }

        // A pending restore may already have moved the original files. The live row
        // still being trashed means its SQLite transaction never committed.
        let repairPlacement = paths?.inActive == true
        if let paths, repairPlacement || item.status == .restoring || !trash.isEmpty || !paths.inTrash {
            try validateSessionFiles(item.rootID, at: paths.inActive ? paths.active : (paths.inTrash ? paths.trash : nil),
                                     allowMissing: item.status == .purgeFailed && !paths.inActive)
            if repairPlacement { try FileManager.default.moveItem(at: paths.active, to: paths.trash) }
        }
        guard item.status == .restoring || !trash.isEmpty || repairPlacement else { return }
        try db.withTransaction { tx in
            if item.status == .restoring {
                let prior = restore.flatMap(Self.decodeJournal)?.previousStatus
                let status: TrashStatus = prior == .purgeFailed ? .purgeFailed : .trashed
                try tx.run("UPDATE trash_items SET status=?, last_error=NULL WHERE id=?", [.text(status.rawValue), .text(item.id)])
                if let restore { try trashRepo.finishIntent(id: restore.id, status: .failed, tx: tx) }
            }
            for intent in trash { try trashRepo.finishIntent(id: intent.id, status: .committed, tx: tx) }
        }
        publishChange(item)
    }

    /// Dọn sạch (§12.6, §3.3): per-item kết quả Đã xử lý / Bỏ qua / Lỗi.
    public struct PurgeReport: Equatable {
        public var success: Int = 0
        public var skipped: Int = 0
        public var failed: Int = 0
        public var failedNames: [String] = []
        public var skippedReasons: [String] = []

        public init(success: Int = 0, skipped: Int = 0, failed: Int = 0, failedNames: [String] = [], skippedReasons: [String] = []) {
            self.success = success
            self.skipped = skipped
            self.failed = failed
            self.failedNames = failedNames
            self.skippedReasons = skippedReasons
        }
    }

    public func purgeAll(items: [TrashItem]) -> PurgeReport {
        purgeAll(items: items, onlyExpired: false)
    }

    func purgeAll(items: [TrashItem], onlyExpired: Bool) -> PurgeReport {
        var report = PurgeReport()
        for item in items {
            switch purgeResult(item, onlyExpired: onlyExpired) {
            case .processed:
                report.success += 1
            case .skipped(let reason):
                report.skipped += 1
                report.skippedReasons.append("\(item.displayName): \(reason)")
            case .failed(let reason):
                report.failed += 1
                report.failedNames.append(item.displayName)
                report.skippedReasons.append("\(item.displayName): \(reason)")
            }
        }
        return report
    }

    public func estimateTrashBytes() -> Int64 {
        (try? trashRepo.totalBytes()) ?? 0
    }
}
