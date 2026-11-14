import Foundation

/// SessionRepository: session/photo revision/snapshot/adjustment DB (§17.1).
/// Mọi thay đổi phiên chạy trong transaction và tăng session.revision_no để phát hiện outdated edit (§17.3).
public final class SessionRepository: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let layout: FileLayout

    public init(db: SQLiteDatabase, layout: FileLayout) {
        self.db = db; self.layout = layout
    }

    static let jsonEncoder = JSONEncoder()
    static let jsonDecoder = JSONDecoder()

    // MARK: - Create

    @discardableResult
    public func createSession(snapshot: FrameSnapshot, mode: CaptureMode, cameraID: String?,
                              defaults: SessionDefaultsSnapshot) throws -> CaptureSessionRecord {
        let session = CaptureSessionRecord(
            status: .inProgress,
            activeFrameSnapshotID: snapshot.id,
            requiredCaptureCount: snapshot.requiredCaptureCount,
            captureMode: mode, cameraID: cameraID, defaults: defaults)
        let defaultsJSON = String(data: try Self.jsonEncoder.encode(defaults), encoding: .utf8) ?? "{}"
        try db.withTransaction { tx in
            try tx.run("""
                INSERT INTO sessions(id, status, active_frame_snapshot_id, required_capture_count,
                    current_capture_index, capture_mode, camera_id, session_defaults_json, revision_no,
                    created_at_ms, updated_at_ms)
                VALUES(?,?,?,?,?,?,?,?,1,?,?)
                """, [.text(session.id), .text(session.status.rawValue), .text(snapshot.id),
                      .int(Int64(session.requiredCaptureCount)), .int(1),
                      .text(mode.rawValue), cameraID.map { .text($0) } ?? .null,
                      .text(defaultsJSON), .int(session.createdAtMs), .int(session.updatedAtMs)])
            // Shots 1..N với index distinct theo snapshot (CAP-02: nhiều slot dùng chung index)
            for index in 1...snapshot.requiredCaptureCount {
                try tx.run("""
                    INSERT INTO session_shots(id, session_id, capture_index, current_photo_revision_id)
                    VALUES(?,?,?,NULL)
                    """, [.text(IDFactory.new()), .text(session.id), .int(Int64(index))])
            }
            // Slot placements mặc định theo slot snapshot (crop mode từ khung)
            // 10 cột: id, session_id, frame_snapshot_id, snapshot_slot_id, crop_mode,
            // scale=1, offset_x=0, offset_y=0, manual_override=0 (literal), updated_at_ms
            for slot in snapshot.slots {
                try tx.run("""
                    INSERT OR IGNORE INTO slot_placements(id, session_id, frame_snapshot_id, snapshot_slot_id,
                        crop_mode, scale, offset_x, offset_y, manual_override, updated_at_ms)
                    VALUES(?,?,?,?,?,1,0,0,0,?)
                    """, [.text(IDFactory.new()), .text(session.id), .text(snapshot.id), .text(slot.id),
                          .text(slot.defaultCropMode.rawValue), .int(Time.nowMs())])
            }
        }
        return session
    }

    // MARK: - Read

    public func getSession(id: String) throws -> CaptureSessionRecord? {
        let rows = try db.query("SELECT * FROM sessions WHERE id=?", [.text(id)])
        return rows.first.flatMap(Self.session(from:))
    }

    public static func session(from row: SQLiteRow) -> CaptureSessionRecord? {
        let id = row["id"].stringValue
        guard !id.isEmpty else { return nil }
        let defaultsJSON = row["session_defaults_json"].stringValue
        let defaults = (defaultsJSON.data(using: .utf8)).flatMap { try? JSONDecoder().decode(SessionDefaultsSnapshot.self, from: $0) }
            ?? SessionDefaultsSnapshot(presetID: "natural", presetName: "Tự nhiên",
                                       presetResolvedParameters: .natural, presetIntensity: 1,
                                       color: .neutral, skinSmooth: 0.25, outputMirror: false)
        return CaptureSessionRecord(
            id: id,
            status: SessionStatus(rawValue: row["status"].stringValue) ?? .paused,
            activeFrameSnapshotID: row["active_frame_snapshot_id"].stringValue,
            requiredCaptureCount: row["required_capture_count"]?.intValue ?? 1,
            currentCaptureIndex: row["current_capture_index"]?.intValue ?? 1,
            captureMode: CaptureMode(rawValue: row["capture_mode"].stringValue) ?? .automatic,
            cameraID: row["camera_id"].stringValue.isEmpty ? nil : row["camera_id"].stringValue,
            defaults: defaults,
            revisionNo: row["revision_no"]?.intValue ?? 1,
            createdAtMs: row["created_at_ms"]?.int64Value ?? 0,
            updatedAtMs: row["updated_at_ms"]?.int64Value ?? 0,
            completedAtMs: row["completed_at_ms"]?.int64Value)
    }

    public struct SessionCard: Identifiable, Equatable {
        public var id: String { session.id }
        public var session: CaptureSessionRecord
        public var committedCount: Int
        public var hasRenderCache: Bool
    }

    public func listSessions(statuses: [SessionStatus]? = nil, searchText: String = "") throws -> [SessionCard] {
        var sql = """
            SELECT s.*, (SELECT COUNT(*) FROM session_shots sh
                         WHERE sh.session_id = s.id AND sh.current_photo_revision_id IS NOT NULL) AS committed
            FROM sessions s
            """
        var conditions: [String] = []
        var bind: [SQLiteValue] = []
        if let statuses, !statuses.isEmpty {
            let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
            conditions.append("s.status IN (\(placeholders))")
            bind += statuses.map { .text($0.rawValue) }
        } else {
            conditions.append("s.status <> 'trashed'") // danh sách thường không hiện trashed
        }
        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY s.updated_at_ms DESC LIMIT 500"
        let rows = try db.query(sql, bind)
        return rows.compactMap { row -> SessionCard? in
            guard let s = Self.session(from: row) else { return nil }
            return SessionCard(session: s, committedCount: row["committed"]?.intValue ?? 0,
                               hasRenderCache: false)
        }
    }

    public func latestRecoverableSession() throws -> CaptureSessionRecord? {
        let rows = try db.query("""
            SELECT * FROM sessions
            WHERE status IN ('draft','in_progress','paused','reviewable')
            ORDER BY updated_at_ms DESC LIMIT 1
            """)
        return rows.first.flatMap(Self.session(from:))
    }

    /// SessionDetail đầy đủ cho Review/Render.
    public func getDetail(sessionID: String) throws -> SessionDetail? {
        guard let session = try getSession(id: sessionID),
              let snapshot = try snapshotLoader(session.activeFrameSnapshotID) else { return nil }
        let shots = try db.query("SELECT * FROM session_shots WHERE session_id=? ORDER BY capture_index", [.text(sessionID)]).map { r in
            SessionShot(id: r["id"].stringValue, sessionID: sessionID,
                        captureIndex: r["capture_index"]?.intValue ?? 1,
                        currentPhotoRevisionID: r["current_photo_revision_id"].stringValue.isEmpty ? nil : r["current_photo_revision_id"].stringValue)
        }
        var revisions: [String: [PhotoRevision]] = [:]
        var currentByShot: [String: PhotoRevision] = [:]
        for shot in shots {
            let revs = try db.query("SELECT * FROM photo_revisions WHERE shot_id=? ORDER BY revision_no", [.text(shot.id)]).map { r in
                PhotoRevision(id: r["id"].stringValue, shotID: r["shot_id"].stringValue,
                              revisionNo: r["revision_no"]?.intValue ?? 1,
                              relativePath: r["relative_path"].stringValue,
                              sha256: r["sha256"].stringValue,
                              width: r["width"]?.intValue ?? 0, height: r["height"]?.intValue ?? 0,
                              orientation: r["orientation"]?.intValue ?? 1,
                              codec: r["codec"].stringValue,
                              colorProfile: r["color_profile"].stringValue.isEmpty ? nil : r["color_profile"].stringValue,
                              captureRequestID: r["capture_request_id"].stringValue,
                              capturedAtMs: r["captured_at_ms"]?.int64Value ?? 0,
                              state: PhotoRevisionState(rawValue: r["state"].stringValue) ?? .available)
            }
            revisions[shot.id] = revs
            if let curID = shot.currentPhotoRevisionID, let cur = revs.first(where: { $0.id == curID }) {
                currentByShot[shot.id] = cur
            }
        }
        // Overrides cho current revision theo captureIndex
        var overrides: [Int: PhotoOverride] = [:]
        for shot in shots {
            guard let cur = currentByShot[shot.id] else { continue }
            if let o = try getOverride(photoRevisionID: cur.id) {
                overrides[shot.captureIndex] = o
            }
        }
        let placements = try db.query("""
            SELECT * FROM slot_placements WHERE session_id=? AND frame_snapshot_id=?
            """, [.text(sessionID), .text(session.activeFrameSnapshotID)]).map { r in
            SlotPlacement(id: r["id"].stringValue, sessionID: sessionID,
                          frameSnapshotID: r["frame_snapshot_id"].stringValue,
                          snapshotSlotID: r["snapshot_slot_id"].stringValue,
                          cropMode: CropMode(rawValue: r["crop_mode"].stringValue) ?? .autoFace,
                          scale: r["scale"]?.doubleValue ?? 1,
                          offsetX: r["offset_x"]?.doubleValue ?? 0,
                          offsetY: r["offset_y"]?.doubleValue ?? 0,
                          manualOverride: r["manual_override"].boolValue,
                          updatedAtMs: r["updated_at_ms"]?.int64Value ?? 0)
        }
        var placementMap: [String: SlotPlacement] = [:]
        for p in placements { placementMap[p.snapshotSlotID] = p }
        return SessionDetail(session: session, snapshot: snapshot, shots: shots,
                             photoRevisions: revisions, overrides: overrides,
                             placements: placementMap)
    }

    private func snapshotLoader(_ id: String) throws -> FrameSnapshot? {
        let rows = try db.query("SELECT * FROM frame_snapshots WHERE id=?", [.text(id)])
        guard let r = rows.first, let data = r["snapshot_json"].stringValue.data(using: .utf8),
              var snap = try? Self.jsonDecoder.decode(FrameSnapshot.self, from: data) else { return nil }
        snap.id = r["id"].stringValue
        return snap
    }

    public func getPhotoRevision(id: String) throws -> PhotoRevision? {
        let rows = try db.query("SELECT * FROM photo_revisions WHERE id=?", [.text(id)])
        return rows.first.flatMap { row in
            PhotoRevision(id: row["id"].stringValue, shotID: row["shot_id"].stringValue,
                          revisionNo: row["revision_no"]?.intValue ?? 1,
                          relativePath: row["relative_path"].stringValue,
                          sha256: row["sha256"].stringValue,
                          width: row["width"]?.intValue ?? 0, height: row["height"]?.intValue ?? 0,
                          orientation: row["orientation"]?.intValue ?? 1,
                          codec: row["codec"].stringValue,
                          colorProfile: row["color_profile"].stringValue.isEmpty ? nil : row["color_profile"].stringValue,
                          captureRequestID: row["capture_request_id"].stringValue,
                          capturedAtMs: row["captured_at_ms"]?.int64Value ?? 0,
                          state: PhotoRevisionState(rawValue: row["state"].stringValue) ?? .available)
        }
    }

    public func listRevisions(shotID: String) throws -> [PhotoRevision] {
        try db.query("SELECT * FROM photo_revisions WHERE shot_id=? ORDER BY revision_no", [.text(shotID)]).compactMap { row in
            PhotoRevision(id: row["id"].stringValue, shotID: shotID,
                          revisionNo: row["revision_no"]?.intValue ?? 1,
                          relativePath: row["relative_path"].stringValue,
                          sha256: row["sha256"].stringValue,
                          width: row["width"]?.intValue ?? 0, height: row["height"]?.intValue ?? 0,
                          orientation: row["orientation"]?.intValue ?? 1,
                          codec: row["codec"].stringValue,
                          colorProfile: nil,
                          captureRequestID: row["capture_request_id"].stringValue,
                          capturedAtMs: row["captured_at_ms"]?.int64Value ?? 0,
                          state: PhotoRevisionState(rawValue: row["state"].stringValue) ?? .available)
        }
    }

    public func fileURL(for revision: PhotoRevision) throws -> URL {
        try layout.absoluteURL(forRelativePath: revision.relativePath)
    }

    // MARK: - Commit photo ( SafetySave gọi sau khi file ghi xong, §10.2 )

    /// Commit một ảnh đã ghi an toàn. Idempotent theo captureRequestID (E-CAP-01, §17.3).
    public func commitPhoto(sessionID: String, captureIndex: Int, requestID: String,
                            relativePath: String, sha256: String, width: Int, height: Int,
                            orientation: Int, codec: String, colorProfile: String?) throws -> PhotoRevision {
        try db.withTransaction { tx in
            // Idempotency: requestID đã commit thì trả về revision hiện có
            let rows = try tx.query("SELECT * FROM photo_revisions WHERE capture_request_id=?", [.text(requestID)])
            if let r = rows.first {
                // Trả về revision đã tồn tại — đọc color_profile thật từ DB, không hardcoded nil.
                let storedProfile = r["color_profile"].stringValue
                return PhotoRevision(id: r["id"].stringValue, shotID: r["shot_id"].stringValue,
                                     revisionNo: r["revision_no"]?.intValue ?? 1,
                                     relativePath: r["relative_path"].stringValue,
                                     sha256: r["sha256"].stringValue,
                                     width: r["width"]?.intValue ?? 0, height: r["height"]?.intValue ?? 0,
                                     orientation: r["orientation"]?.intValue ?? 1,
                                     codec: r["codec"].stringValue,
                                     colorProfile: storedProfile.isEmpty ? nil : storedProfile,
                                     captureRequestID: requestID,
                                     capturedAtMs: r["captured_at_ms"]?.int64Value ?? 0)
            }
            let sessionRows = try tx.query("SELECT status, required_capture_count, revision_no FROM sessions WHERE id=?", [.text(sessionID)])
            guard let sRow = sessionRows.first else { throw AppError.notFound("session \(sessionID)") }
            let required = sRow["required_capture_count"]?.intValue ?? 1

            // Shot theo captureIndex
            let shotRows = try tx.query("SELECT id FROM session_shots WHERE session_id=? AND capture_index=?", [.text(sessionID), .int(Int64(captureIndex))])
            let shotID: String
            if let existing = shotRows.first {
                shotID = existing["id"].stringValue
            } else {
                shotID = IDFactory.new()
                try tx.run("INSERT INTO session_shots(id, session_id, capture_index, current_photo_revision_id) VALUES(?,?,?,NULL)",
                           [.text(shotID), .text(sessionID), .int(Int64(captureIndex))])
            }
            let nextNo = try tx.query("SELECT COALESCE(MAX(revision_no),0)+1 n FROM photo_revisions WHERE shot_id=?", [.text(shotID)]).first?["n"]?.intValue ?? 1
            let rev = PhotoRevision(shotID: shotID, revisionNo: nextNo, relativePath: relativePath,
                                    sha256: sha256, width: width, height: height,
                                    orientation: orientation, codec: codec, colorProfile: colorProfile,
                                    captureRequestID: requestID)
            try tx.run("""
                INSERT INTO photo_revisions(id, shot_id, revision_no, relative_path, sha256, width, height,
                    orientation, codec, color_profile, capture_request_id, captured_at_ms, state)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,'available')
                """, [.text(rev.id), .text(shotID), .int(Int64(nextNo)), .text(relativePath), .text(sha256),
                      .int(Int64(width)), .int(Int64(height)), .int(Int64(orientation)), .text(codec),
                      colorProfile.map { .text($0) } ?? .null, .text(requestID), .int(rev.capturedAtMs)])
            // Atomic switch con trỏ current (§3.3, §5.5)
            try tx.run("UPDATE session_shots SET current_photo_revision_id=? WHERE id=?", [.text(rev.id), .text(shotID)])
            // Update index phiên: next chưa chụp (giới hạn required để hiện đủ N)
            let newStatus = SessionStatus(rawValue: sRow["status"].stringValue) ?? .inProgress
            if newStatus == .inProgress {
                let nextIndex = min(captureIndex + 1, required)
                try tx.run("UPDATE sessions SET current_capture_index=?, updated_at_ms=?, revision_no=revision_no+1 WHERE id=?",
                           [.int(Int64(nextIndex)), .int(Time.nowMs()), .text(sessionID)])
            } else {
                try tx.run("UPDATE sessions SET updated_at_ms=?, revision_no=revision_no+1 WHERE id=?",
                           [.int(Time.nowMs()), .text(sessionID)])
            }
            return rev
        }
    }

    /// Chuyển con trỏ current của shot (Undo retake §5.5 — không xóa revision).
    public func switchCurrentRevision(shotID: String, toRevisionID: String, sessionID: String) throws {
        try db.withTransaction { tx in
            let belongs = try tx.query("SELECT COUNT(*) c FROM photo_revisions WHERE id=? AND shot_id=?", [.text(toRevisionID), .text(shotID)])
            guard (belongs.first?["c"]?.intValue ?? 0) > 0 else {
                throw AppError.invalidState("Revision không thuộc shot này (§16.2.2)")
            }
            try tx.run("UPDATE session_shots SET current_photo_revision_id=? WHERE id=?", [.text(toRevisionID), .text(shotID)])
            try tx.run("UPDATE sessions SET updated_at_ms=?, revision_no=revision_no+1 WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
        }
    }

    // MARK: - Status & revision bump

    public func setStatus(sessionID: String, status: SessionStatus) throws {
        if status == .completed {
            try db.run("UPDATE sessions SET status=?, completed_at_ms=?, updated_at_ms=? WHERE id=?",
                       [.text(status.rawValue), .int(Time.nowMs()), .int(Time.nowMs()), .text(sessionID)])
        } else {
            try db.run("UPDATE sessions SET status=?, updated_at_ms=? WHERE id=?",
                       [.text(status.rawValue), .int(Time.nowMs()), .text(sessionID)])
        }
    }

    public func bumpRevision(sessionID: String) throws -> Int {
        try db.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
        return Int(try db.scalarInt("SELECT revision_no FROM sessions WHERE id=?", [.text(sessionID)]))
    }

    /// Sau crash: mọi session `in_progress` chuyển thành `paused` (§5.1 — transient không resume nguyên trạng).
    public func convertTransientToPaused() throws {
        try db.run("UPDATE sessions SET status='paused', updated_at_ms=? WHERE status='in_progress'", [.int(Time.nowMs())])
    }

    public func touch(sessionID: String) throws {
        try db.run("UPDATE sessions SET updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
    }

    // MARK: - Overrides (§8.3, §9.2)

    public func getOverride(photoRevisionID: String) throws -> PhotoOverride? {
        let rows = try db.query("SELECT overrides_json FROM photo_adjustments WHERE photo_revision_id=?", [.text(photoRevisionID)])
        guard let r = rows.first, let data = r["overrides_json"].stringValue.data(using: .utf8) else { return nil }
        return try? Self.jsonDecoder.decode(PhotoOverride.self, from: data)
    }

    /// Cập nhật override của một photo revision (partial). Bump session revision.
    public func setOverride(sessionID: String, photoRevisionID: String, override: PhotoOverride) throws {
        let json = String(data: try Self.jsonEncoder.encode(override), encoding: .utf8) ?? "{}"
        try db.withTransaction { tx in
            let exists = try tx.query("SELECT COUNT(*) c FROM photo_adjustments WHERE photo_revision_id=?", [.text(photoRevisionID)])
            if (exists.first?["c"]?.intValue ?? 0) > 0 {
                try tx.run("UPDATE photo_adjustments SET overrides_json=?, parameter_version=1, updated_at_ms=? WHERE photo_revision_id=?",
                           [.text(json), .int(Time.nowMs()), .text(photoRevisionID)])
            } else {
                try tx.run("INSERT INTO photo_adjustments(photo_revision_id, overrides_json, parameter_version, updated_at_ms) VALUES(?,?,1,?)",
                           [.text(photoRevisionID), .text(json), .int(Time.nowMs())])
            }
            try tx.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
        }
    }

    /// Áp dụng màu cho tất cả: override snapshot cho mọi ảnh current (§8.3, một transaction).
    public func applyColorToAll(sessionID: String, color: ColorOverrides?, skinSmooth: Double?,
                                presetID: String?, presetParameters: ColorParameterSet?, presetIntensity: Double?) throws {
        try db.withTransaction { tx in
            let rows = try tx.query("""
                SELECT pr.id, sh.capture_index FROM photo_revisions pr
                JOIN session_shots sh ON sh.id = pr.shot_id
                JOIN sessions s ON s.id = sh.session_id
                WHERE sh.session_id = ? AND sh.current_photo_revision_id = pr.id
                """, [.text(sessionID)])
            for row in rows {
                let revID = row["id"].stringValue
                let existing = try tx.query("SELECT overrides_json FROM photo_adjustments WHERE photo_revision_id=?", [.text(revID)])
                var o = PhotoOverride()
                if let data = existing.first?["overrides_json"].stringValue.data(using: .utf8),
                   let decoded = try? Self.jsonDecoder.decode(PhotoOverride.self, from: data) {
                    o = decoded
                }
                o.color = color ?? o.color
                if let ss = skinSmooth { o.skinSmooth = ss }
                if let pid = presetID {
                    o.presetID = pid
                    o.presetParameters = presetParameters
                    o.presetIntensity = presetIntensity
                }
                let json = String(data: try Self.jsonEncoder.encode(o), encoding: .utf8) ?? "{}"
                let up = try tx.query("SELECT COUNT(*) c FROM photo_adjustments WHERE photo_revision_id=?", [.text(revID)])
                if (up.first?["c"]?.intValue ?? 0) > 0 {
                    try tx.run("UPDATE photo_adjustments SET overrides_json=?, updated_at_ms=? WHERE photo_revision_id=?", [.text(json), .int(Time.nowMs()), .text(revID)])
                } else {
                    try tx.run("INSERT INTO photo_adjustments(photo_revision_id, overrides_json, parameter_version, updated_at_ms) VALUES(?,?,1,?)", [.text(revID), .text(json), .int(Time.nowMs())])
                }
            }
            try tx.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
        }
    }

    /// Reset overrides của một ảnh (về SessionDefault §9.3).
    public func clearOverride(sessionID: String, photoRevisionID: String) throws {
        try db.run("DELETE FROM photo_adjustments WHERE photo_revision_id=?", [.text(photoRevisionID)])
        try bumpRevision(sessionID: sessionID)
    }

    // MARK: - Placements (§9.2)

    public func setPlacement(sessionID: String, snapshotSlotID: String, placement: PhotoPlacement,
                             cropMode: CropMode, manualOverride: Bool) throws {
        try db.withTransaction { tx in
            let rows = try tx.query("SELECT id FROM slot_placements WHERE session_id=? AND snapshot_slot_id=? AND frame_snapshot_id=(SELECT active_frame_snapshot_id FROM sessions WHERE id=?)", [.text(sessionID), .text(snapshotSlotID), .text(sessionID)])
            if let r = rows.first {
                try tx.run("""
                    UPDATE slot_placements SET crop_mode=?, scale=?, offset_x=?, offset_y=?, manual_override=?, updated_at_ms=?
                    WHERE id=?
                    """, [.text(cropMode.rawValue), .real(placement.scale), .real(placement.offsetX),
                          .real(placement.offsetY), .int(manualOverride ? 1 : 0), .int(Time.nowMs()), .text(r["id"].stringValue)])
            } else {
                let snapID = try tx.query("SELECT active_frame_snapshot_id FROM sessions WHERE id=?", [.text(sessionID)]).first?["active_frame_snapshot_id"].stringValue ?? ""
                try tx.run("""
                    INSERT INTO slot_placements(id, session_id, frame_snapshot_id, snapshot_slot_id, crop_mode, scale, offset_x, offset_y, manual_override, updated_at_ms)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    """, [.text(IDFactory.new()), .text(sessionID), .text(snapID), .text(snapshotSlotID),
                          .text(cropMode.rawValue), .real(placement.scale), .real(placement.offsetX),
                          .real(placement.offsetY), .int(manualOverride ? 1 : 0), .int(Time.nowMs())])
            }
            try tx.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
        }
    }

    /// Đổi khung ở Review (§3.6): snapshot mới + mapping + reset placements theo snapshot mới (transaction).
    public func changeFrame(sessionID: String, newSnapshot: FrameSnapshot) throws {
        // Bảo vệ: snapshot 0 ô ảnh (khung hỏng/nhập tay) — tránh vừa sai dữ liệu vừa crash vòng `1...count`.
        guard newSnapshot.requiredCaptureCount >= 1 else { throw AppError.frameUnconfigured }
        try db.withTransaction { tx in
            try tx.run("UPDATE sessions SET active_frame_snapshot_id=?, required_capture_count=?, revision_no=revision_no+1, updated_at_ms=? WHERE id=?",
                       [.text(newSnapshot.id), .int(Int64(newSnapshot.requiredCaptureCount)), .int(Time.nowMs()), .text(sessionID)])
            // Thêm shot cho index mới nếu N_new > cũ (§3.4.3)
            for index in 1...newSnapshot.requiredCaptureCount {
                try tx.run("INSERT OR IGNORE INTO session_shots(id, session_id, capture_index, current_photo_revision_id) VALUES(?,?,?,NULL)",
                           [.text(IDFactory.new()), .text(sessionID), .int(Int64(index))])
            }
            // Xóa placements của snapshot cũ — không để orphan sau nhiều lần đổi khung (§3.4).
            try tx.run("DELETE FROM slot_placements WHERE session_id=? AND frame_snapshot_id<>?",
                       [.text(sessionID), .text(newSnapshot.id)])
            // Reset SlotPlacement theo snapshot mới (giữ PhotoAdjustment — §3.4.5)
            // 10 cột, 6 placeholder: scale=1, offset=0, manual=0 là literal (không còn lệch bind).
            for slot in newSnapshot.slots {
                try tx.run("""
                    INSERT OR REPLACE INTO slot_placements(id, session_id, frame_snapshot_id, snapshot_slot_id, crop_mode, scale, offset_x, offset_y, manual_override, updated_at_ms)
                    VALUES(?,?,?,?,?,1,0,0,0,?)
                    """, [.text(IDFactory.new()), .text(sessionID), .text(newSnapshot.id), .text(slot.id),
                          .text(slot.defaultCropMode.rawValue), .int(Time.nowMs())])
            }
        }
    }

    // MARK: - Export records (§11)

    @discardableResult
    public func insertExportRecord(_ record: ExportRecordModel) throws -> ExportRecordModel {
        try db.run("""
            INSERT INTO export_records(id, session_id, session_revision_no, format, filename,
                destination_display_path, destination_bookmark_id, width, height, quality, sha256, status, created_at_ms, completed_at_ms)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(record.id), .text(record.sessionID), .int(Int64(record.sessionRevisionNo)),
                  .text(record.format.rawValue), .text(record.filename),
                  record.destinationDisplayPath.map { .text($0) } ?? .null,
                  record.destinationBookmarkID.map { .text($0) } ?? .null,
                  .int(Int64(record.width)), .int(Int64(record.height)),
                  record.quality.map { .int(Int64($0)) } ?? .null,
                  record.sha256.map { .text($0) } ?? .null,
                  .text(record.status.rawValue), .int(record.createdAtMs),
                  record.completedAtMs.map { .int($0) } ?? .null])
        return record
    }

    public func updateExportRecord(id: String, status: ExportStatus, displayPath: String?, bookmarkID: String?, sha256: String?) throws {
        try db.run("""
            UPDATE export_records SET status=?, destination_display_path=COALESCE(?, destination_display_path),
                destination_bookmark_id=COALESCE(?, destination_bookmark_id), sha256=COALESCE(?, sha256),
                completed_at_ms=?
            WHERE id=?
            """, [.text(status.rawValue), displayPath.map { .text($0) } ?? .null,
                  bookmarkID.map { .text($0) } ?? .null, sha256.map { .text($0) } ?? .null,
                  status == .success ? .int(Time.nowMs()) : .null, .text(id)])
    }

    public func listExportRecords(sessionID: String) throws -> [ExportRecordModel] {
        try db.query("SELECT * FROM export_records WHERE session_id=? ORDER BY created_at_ms DESC", [.text(sessionID)]).compactMap { r in
            ExportRecordModel(id: r["id"].stringValue, sessionID: sessionID,
                              sessionRevisionNo: r["session_revision_no"]?.intValue ?? 1,
                              format: ExportImageFormat(rawValue: r["format"].stringValue) ?? .jpeg,
                              filename: r["filename"].stringValue,
                              destinationDisplayPath: r["destination_display_path"].stringValue.isEmpty ? nil : r["destination_display_path"].stringValue,
                              destinationBookmarkID: r["destination_bookmark_id"].stringValue.isEmpty ? nil : r["destination_bookmark_id"].stringValue,
                              width: r["width"]?.intValue ?? 0, height: r["height"]?.intValue ?? 0,
                              quality: r["quality"]?.intValue, sha256: r["sha256"].stringValue.isEmpty ? nil : r["sha256"].stringValue,
                              status: ExportStatus(rawValue: r["status"].stringValue) ?? .failed,
                              createdAtMs: r["created_at_ms"]?.int64Value ?? 0,
                              completedAtMs: r["completed_at_ms"]?.int64Value)
        }
    }
}

