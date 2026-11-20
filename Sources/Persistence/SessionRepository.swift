import CoreGraphics
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
                              defaults: SessionDefaultsSnapshot,
                              frameNameAtCapture: String? = nil,
                              countdownSeconds: Int = 3,
                              intermissionSeconds: Int = 2) throws -> CaptureSessionRecord {
        let planned = defaults.plannedCaptureCount
        if let planned {
            guard (1...ResourceLimits.maxCaptureIndices).contains(planned),
                  defaults.selectedCaptureOrder == nil, snapshot.slots.isEmpty,
                  snapshot.sourceFrameID == nil, snapshot.background == nil, snapshot.foreground == nil else {
                throw AppError.invalidState("Cấu hình phiên chụp chưa hợp lệ")
            }
        } else if snapshot.requiredCaptureCount == 0 {
            throw AppError.frameUnconfigured
        }
        if let count = defaults.selectionCaptureCount,
           count < snapshot.requiredCaptureCount || count > ResourceLimits.maxCaptureIndices {
            throw AppError.invalidState("Số lượt chụp phải đủ để điền khung ảnh")
        }
        let session = CaptureSessionRecord(
            status: .inProgress,
            activeFrameSnapshotID: snapshot.id,
            requiredCaptureCount: planned ?? snapshot.requiredCaptureCount,
            captureMode: mode, cameraID: cameraID, defaults: defaults,
            frameNameAtCapture: frameNameAtCapture,
            countdownSeconds: countdownSeconds,
            intermissionSeconds: intermissionSeconds)
        let defaultsJSON = String(data: try Self.jsonEncoder.encode(defaults), encoding: .utf8) ?? "{}"
        try db.withTransaction { tx in
            if planned != nil { try Self.storeSnapshot(snapshot, tx: tx) }
            try tx.run("""
                INSERT INTO sessions(id, status, active_frame_snapshot_id, required_capture_count,
                    current_capture_index, capture_mode, camera_id, session_defaults_json, revision_no,
                    created_at_ms, updated_at_ms, frame_name_at_capture, countdown_seconds, intermission_seconds)
                VALUES(?,?,?,?,?,?,?,?,1,?,?,?,?,?)
                """, [.text(session.id), .text(session.status.rawValue), .text(snapshot.id),
                      .int(Int64(session.requiredCaptureCount)), .int(1),
                      .text(mode.rawValue), cameraID.map { .text($0) } ?? .null,
                      .text(defaultsJSON), .int(session.createdAtMs), .int(session.updatedAtMs),
                      frameNameAtCapture.map { .text($0) } ?? .null,
                      .int(Int64(countdownSeconds)), .int(Int64(intermissionSeconds))])
            // Shots 1..N với index distinct theo snapshot (CAP-02: nhiều slot dùng chung index)
            for index in session.captureIndices(in: snapshot).sorted() {
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
                                       color: .neutral, skinSmooth: 0, outputMirror: false)
        let rawFrameName = row["frame_name_at_capture"].stringValue
        let frameNameAtCapture: String? = rawFrameName.isEmpty ? nil : rawFrameName
        let countdownSeconds = row["countdown_seconds"]?.intValue ?? 3
        let intermissionSeconds = row["intermission_seconds"]?.intValue ?? 2
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
            completedAtMs: row["completed_at_ms"]?.int64Value,
            frameNameAtCapture: frameNameAtCapture,
            countdownSeconds: countdownSeconds,
            intermissionSeconds: intermissionSeconds)
    }

    public struct SessionCard: Identifiable, Equatable, Sendable {
        public var id: String { session.id }
        public var session: CaptureSessionRecord
        public var committedCount: Int
        public var totalCapturedCount: Int = 0
        public var hasRenderCache: Bool
        var sourceFrameName: String? = nil
    }

    public func listSessions(statuses: [SessionStatus]? = nil, searchText: String = "") throws -> [SessionCard] {
        let defaultsJSON = "(CASE WHEN json_valid(s.session_defaults_json) THEN s.session_defaults_json ELSE '{}' END)"
        let selectionCount = "json_extract(\(defaultsJSON), '$.selectionCaptureCount')"
        let planned = "json_extract(\(defaultsJSON), '$.plannedCaptureCount')"
        let awaitsFrame = "\(planned) IS NOT NULL AND json_extract(\(defaultsJSON), '$.selectedCaptureOrder') IS NULL"
        let pendingSelection = "\(selectionCount) BETWEEN 1 AND \(ResourceLimits.maxCaptureIndices) AND json_extract(\(defaultsJSON), '$.selectedCaptureOrder') IS NULL"
        let committedExpr = """
            (SELECT COUNT(DISTINCT sh.capture_index) FROM session_shots sh
             JOIN photo_revisions pr ON pr.id = sh.current_photo_revision_id
             JOIN frame_snapshots fs ON fs.id = s.active_frame_snapshot_id
             WHERE sh.session_id = s.id AND pr.state = 'available'
               AND CASE WHEN \(awaitsFrame) THEN sh.capture_index BETWEEN 1 AND \(planned)
                        WHEN \(pendingSelection) THEN sh.capture_index BETWEEN 1 AND \(selectionCount)
                        ELSE sh.capture_index IN (
                            SELECT json_extract(value, '$.captureIndex')
                            FROM json_each(
                                CASE WHEN json_valid(fs.snapshot_json)
                                     THEN json_extract(fs.snapshot_json, '$.slots')
                                     ELSE '[]' END
                            )
                        ) END)
            """
        let effectiveStatusExpr = "CASE WHEN s.status = 'completed' AND \(committedExpr) < s.required_capture_count THEN 'paused' ELSE s.status END"

        var sql = """
            SELECT s.*, f.name AS source_frame_name, \(committedExpr) AS committed,
              (SELECT COUNT(*) FROM session_shots sh JOIN photo_revisions pr ON pr.id=sh.current_photo_revision_id
               WHERE sh.session_id=s.id AND pr.state='available') AS total_captured
            FROM sessions s
            LEFT JOIN frame_snapshots sf ON sf.id = s.active_frame_snapshot_id
            LEFT JOIN frames f ON f.id = sf.source_frame_id
            """
        var conditions: [String] = []
        var bind: [SQLiteValue] = []
        if let statuses, !statuses.isEmpty {
            let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
            conditions.append("\(effectiveStatusExpr) IN (\(placeholders))")
            bind += statuses.map { .text($0.rawValue) }
        } else {
            conditions.append("s.status NOT IN ('trashed', 'purging')") // danh sách thường không hiện trashed / purging
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            let pattern = "%\(trimmedSearch)%"
            conditions.append("(COALESCE(json_extract(\(defaultsJSON), '$.appliedFrameName'), s.frame_name_at_capture) LIKE ? OR s.id LIKE ? OR datetime(s.created_at_ms / 1000, 'unixepoch', 'localtime') LIKE ?)")
            bind += [.text(pattern), .text(pattern), .text(pattern)]
        }

        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY s.updated_at_ms DESC, s.id ASC"
        let rows = try db.query(sql, bind)
        return rows.compactMap { row -> SessionCard? in
            guard var s = Self.session(from: row) else { return nil }
            let committed = row["committed"]?.intValue ?? 0
            // Trạng thái hiệu lực cho hồ sơ cũ lệch dữ liệu (DATA-02 / §5.4):
            // Nếu phiên lưu .completed nhưng committed < required, hiệu lực thực tế là .paused
            if s.status == .completed && committed < s.requiredCaptureCount {
                s.status = .paused
                s.completedAtMs = nil
            }
            return SessionCard(session: s, committedCount: committed,
                               totalCapturedCount: row["total_captured"]?.intValue ?? committed,
                               hasRenderCache: false, sourceFrameName: row["source_frame_name"] == .null ? nil : row["source_frame_name"].stringValue)
        }
    }

    public func latestRecoverableSession() throws -> CaptureSessionRecord? {
        let rows = try db.query("""
            SELECT * FROM sessions
            WHERE status IN ('draft','in_progress','paused','reviewable') AND NOT \(Self.hasRootTrashItem)
              AND NOT \(Self.hasUnresolvedCaptureCancellation)
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

    static func loadSnapshot(_ id: String, tx: SQLiteDatabase.TransactionHandle) throws -> FrameSnapshot {
        let row = try tx.query("SELECT snapshot_json FROM frame_snapshots WHERE id=?", [.text(id)]).first
        guard let json = row?["snapshot_json"]?.stringValue else { throw AppError.notFound("Snapshot khung") }
        return try jsonDecoder.decode(FrameSnapshot.self, from: Data(json.utf8))
    }

    static func availableCaptureIndices(sessionID: String, tx: SQLiteDatabase.TransactionHandle) throws -> Set<Int> {
        let rows = try tx.query("""
            SELECT sh.capture_index FROM session_shots sh
            JOIN photo_revisions pr ON pr.id=sh.current_photo_revision_id AND pr.shot_id=sh.id
            WHERE sh.session_id=? AND pr.state='available'
              AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='photo' AND root_id=pr.id)
            """, [.text(sessionID)])
        return Set(rows.compactMap { $0["capture_index"]?.intValue })
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
            guard try tx.scalarInt("SELECT COUNT(*) FROM sessions WHERE id=? AND NOT \(Self.hasRootTrashItem)", [.text(sessionID)]) == 1 else {
                throw AppError.invalidState("Phiên không còn hoạt động")
            }
            // Idempotency: requestID đã commit thì trả về revision hiện có
            let rows = try tx.query("""
                SELECT pr.*, sh.session_id, sh.capture_index, s.status AS session_status
                FROM photo_revisions pr JOIN session_shots sh ON sh.id=pr.shot_id
                JOIN sessions s ON s.id=sh.session_id WHERE pr.capture_request_id=?
                """, [.text(requestID)])
            if let r = rows.first {
                guard r["session_id"].stringValue == sessionID,
                      r["capture_index"]?.intValue == captureIndex,
                      !["trashed", "purging"].contains(r["session_status"].stringValue) else {
                    throw AppError.invalidState("Yêu cầu lưu ảnh không khớp phiên hoặc lượt chụp")
                }
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
            let sessionRows = try tx.query("SELECT * FROM sessions WHERE id=?", [.text(sessionID)])
            guard let sRow = sessionRows.first, let session = Self.session(from: sRow) else {
                throw AppError.notFound("session \(sessionID)")
            }
            if sRow["status"]?.stringValue == "trashed" || sRow["status"]?.stringValue == "purging" {
                throw AppError.invalidState("Phiên chụp đã bị đưa vào Thùng rác")
            }
            if let snapID = sRow["active_frame_snapshot_id"]?.stringValue, !snapID.isEmpty {
                let snapRows = try tx.query("SELECT snapshot_json FROM frame_snapshots WHERE id=?", [.text(snapID)])
                if let json = snapRows.first?["snapshot_json"]?.stringValue,
                   let snapData = json.data(using: .utf8),
                   let snap = try? JSONDecoder().decode(FrameSnapshot.self, from: snapData) {
                    if !session.captureIndices(in: snap).contains(captureIndex) {
                        throw AppError.invalidState("Lượt chụp \(captureIndex) không thuộc khung ảnh hiện hành")
                    }
                }
            }
            let required = session.captureCount

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
            let belongs = try tx.query("""
                SELECT COUNT(*) c FROM photo_revisions pr
                JOIN session_shots sh ON sh.id=pr.shot_id
                JOIN sessions s ON s.id=sh.session_id
                WHERE pr.id=? AND sh.id=? AND s.id=? AND pr.state='available'
                  AND s.status NOT IN ('trashed','purging')
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='session' AND root_id=s.id)
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='photo' AND root_id=pr.id)
                """, [.text(toRevisionID), .text(shotID), .text(sessionID)])
            guard (belongs.first?["c"]?.intValue ?? 0) > 0 else {
                throw AppError.invalidState("Revision không thuộc shot này (§16.2.2)")
            }
            try tx.run("UPDATE session_shots SET current_photo_revision_id=? WHERE id=?", [.text(toRevisionID), .text(shotID)])
            try tx.run("UPDATE sessions SET updated_at_ms=?, revision_no=revision_no+1 WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
        }
    }

    // MARK: - Status & revision bump

    private static let hasRootTrashItem = """
        EXISTS (SELECT 1 FROM trash_items WHERE root_type='session' AND root_id=sessions.id)
        """

    private static let hasUnresolvedCaptureCancellation = """
        EXISTS (
            SELECT 1 FROM operation_intents WHERE root_id=sessions.id AND op_type='trash'
              AND status IN ('prepared','files_staged','files_promoted','rollback_required')
              AND json_extract(CASE WHEN json_valid(payload_json) THEN payload_json ELSE '{}' END,
                               '$.captureCancellation')=1
        )
        """

    func activeSession(id: String) throws -> CaptureSessionRecord? {
        guard let row = try db.query("""
            SELECT *, \(Self.hasUnresolvedCaptureCancellation) AS cancellation_needs_recovery
            FROM sessions WHERE id=? AND status NOT IN ('trashed','purging')
              AND NOT \(Self.hasRootTrashItem)
            """, [.text(id)]).first else { return nil }
        guard row["cancellation_needs_recovery"]?.intValue != 1 else {
            throw AppError.invalidState("Cần mở lại ứng dụng để phục hồi vị trí tệp của phiên chụp")
        }
        return Self.session(from: row)
    }

    func activeCaptureDetail(sessionID: String) throws -> SessionDetail? {
        guard try activeSession(id: sessionID) != nil else { return nil }
        return try getDetail(sessionID: sessionID)
    }

    public func setStatus(sessionID: String, status: SessionStatus) throws {
        let now = Time.nowMs()
        try db.withTransaction { tx in
            guard try tx.scalarInt("""
                SELECT COUNT(*) FROM sessions WHERE id=? AND status NOT IN ('trashed','purging')
                  AND NOT \(Self.hasRootTrashItem)
                """, [.text(sessionID)]) == 1, status != .trashed, status != .purging else {
                throw AppError.invalidState("Phiên không còn hoạt động")
            }
            if status == .completed {
                try tx.run("UPDATE sessions SET status=?, completed_at_ms=?, updated_at_ms=? WHERE id=?",
                           [.text(status.rawValue), .int(now), .int(now), .text(sessionID)])
            } else {
                try tx.run("UPDATE sessions SET status=?, updated_at_ms=? WHERE id=?",
                           [.text(status.rawValue), .int(now), .text(sessionID)])
            }
        }
    }

    public func bumpRevision(sessionID: String) throws -> Int {
        try db.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
        return Int(try db.scalarInt("SELECT revision_no FROM sessions WHERE id=?", [.text(sessionID)]))
    }

    /// Sau crash: mọi session `in_progress` chuyển thành `paused` (§5.1 — transient không resume nguyên trạng).
    public func convertTransientToPaused() throws {
        try db.run("UPDATE sessions SET status='paused', updated_at_ms=? WHERE status='in_progress' AND NOT \(Self.hasRootTrashItem)", [.int(Time.nowMs())])
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
        let token = try OperationCoordinator.shared.acquire(key: "session:\(sessionID)", reason: "Chỉnh ảnh")
        defer { token.release() }
        let json = String(data: try Self.jsonEncoder.encode(override), encoding: .utf8) ?? "{}"
        try db.withTransaction { tx in
            let revCheck = try tx.query("""
                SELECT sh.current_photo_revision_id, s.status FROM photo_revisions pr
                JOIN session_shots sh ON sh.id = pr.shot_id
                JOIN sessions s ON s.id = sh.session_id
                WHERE pr.id = ? AND s.id = ? AND pr.state='available'
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='session' AND root_id=s.id)
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='photo' AND root_id=pr.id)
                """, [.text(photoRevisionID), .text(sessionID)])
            guard let row = revCheck.first else {
                throw AppError.notFound("Không tìm thấy ảnh của phiên")
            }
            if row["status"]?.stringValue == "trashed" || row["status"]?.stringValue == "purging" {
                throw AppError.invalidState("Phiên chụp đã bị đưa vào Thùng rác")
            }
            guard row["current_photo_revision_id"]?.stringValue == photoRevisionID else {
                throw AppError.invalidState("Phiên bản ảnh đã thay đổi. Hãy chọn lại ảnh hiện hành.")
            }
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
    @discardableResult
    public func applyColorToAll(sessionID: String, color: ColorOverrides?,
                                presetID: String?, presetParameters: ColorParameterSet?, presetIntensity: Double?,
                                explicitNoPreset: Bool? = nil) throws -> (before: [String: PhotoOverride?], after: [String: PhotoOverride]) {
        let token = try OperationCoordinator.shared.acquire(key: "session:\(sessionID)", reason: "Chỉnh ảnh")
        defer { token.release() }
        let result = try db.withTransaction { tx -> (before: [String: PhotoOverride?], after: [String: PhotoOverride]) in
            let rows = try tx.query("""
                SELECT pr.id, sh.capture_index FROM photo_revisions pr
                JOIN session_shots sh ON sh.id = pr.shot_id
                JOIN sessions s ON s.id = sh.session_id
                WHERE sh.session_id = ? AND sh.current_photo_revision_id = pr.id AND pr.state='available'
                  AND s.status NOT IN ('trashed','purging')
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='session' AND root_id=s.id)
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='photo' AND root_id=pr.id)
                  AND CASE WHEN json_type(CASE WHEN json_valid(s.session_defaults_json)
                                         THEN s.session_defaults_json ELSE '{}' END, '$.selectedCaptureOrder') = 'array'
                           THEN sh.capture_index IN (
                               SELECT value FROM json_each(s.session_defaults_json, '$.selectedCaptureOrder')
                           )
                           ELSE 1 END
                """, [.text(sessionID)])
            var before: [String: PhotoOverride?] = [:]
            var after: [String: PhotoOverride] = [:]
            for row in rows {
                let revID = row["id"].stringValue
                let existing = try tx.query("SELECT overrides_json FROM photo_adjustments WHERE photo_revision_id=?", [.text(revID)])
                var old: PhotoOverride?
                var o = PhotoOverride()
                if let data = existing.first?["overrides_json"].stringValue.data(using: .utf8),
                   let decoded = try? Self.jsonDecoder.decode(PhotoOverride.self, from: data) {
                    old = decoded
                    o = decoded
                }
                before.updateValue(old, forKey: revID)
                o.color = color ?? o.color
                if explicitNoPreset == true {
                    o.explicitNoPreset = true
                    o.presetID = nil
                    o.presetParameters = .neutral
                    o.presetIntensity = 0.0
                } else if let pid = presetID {
                    o.explicitNoPreset = nil
                    o.presetID = pid
                    o.presetParameters = presetParameters
                    o.presetIntensity = presetIntensity
                }
                after[revID] = o
                let json = String(data: try Self.jsonEncoder.encode(o), encoding: .utf8) ?? "{}"
                let up = try tx.query("SELECT COUNT(*) c FROM photo_adjustments WHERE photo_revision_id=?", [.text(revID)])
                if (up.first?["c"]?.intValue ?? 0) > 0 {
                    try tx.run("UPDATE photo_adjustments SET overrides_json=?, updated_at_ms=? WHERE photo_revision_id=?", [.text(json), .int(Time.nowMs()), .text(revID)])
                } else {
                    try tx.run("INSERT INTO photo_adjustments(photo_revision_id, overrides_json, parameter_version, updated_at_ms) VALUES(?,?,1,?)", [.text(revID), .text(json), .int(Time.nowMs())])
                }
            }
            if !after.isEmpty {
                try tx.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
            }
            return (before, after)
        }
        if !result.after.isEmpty { EventBus.shared.post(.sessionChanged(sessionID: sessionID, revision: 0)) }
        return result
    }

    /// Áp dụng preset cho cả phiên (§3.2): cập nhật tất cả ảnh hiện hành còn khả dụng (kể cả ảnh dự phòng) trong 1 giao dịch.
    public func applyPresetToSession(sessionID: String,
                                     presetID: String,
                                     presetParameters: ColorParameterSet) throws -> (before: [String: PhotoOverride?], after: [String: PhotoOverride]) {
        let token = try OperationCoordinator.shared.acquire(key: "session:\(sessionID)", reason: "Áp dụng preset")
        defer { token.release() }
        return try db.withTransaction { tx in
            let sessRows = try tx.query("SELECT status, session_defaults_json FROM sessions WHERE id=? AND NOT \(Self.hasRootTrashItem)", [.text(sessionID)])
            guard let sessRow = sessRows.first else {
                throw AppError.notFound("Không tìm thấy phiên chụp")
            }
            let status = sessRow["status"]?.stringValue ?? ""
            if status == "trashed" || status == "purging" {
                throw AppError.invalidState("Phiên chụp đã bị đưa vào Thùng rác")
            }
            var defaultIntensity: Double = 1.0
            var defaultPresetID: String? = nil
            if let defJson = sessRow["session_defaults_json"]?.stringValue.data(using: .utf8),
               let decoded = try? Self.jsonDecoder.decode(SessionDefaultsSnapshot.self, from: defJson) {
                defaultIntensity = decoded.presetIntensity
                defaultPresetID = decoded.presetID
            }

            let rows = try tx.query("""
                SELECT pr.id, sh.capture_index FROM photo_revisions pr
                JOIN session_shots sh ON sh.id = pr.shot_id
                WHERE sh.session_id = ? AND sh.current_photo_revision_id = pr.id AND pr.state = 'available'
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='photo' AND root_id=pr.id)
                """, [.text(sessionID)])

            var before: [String: PhotoOverride?] = [:]
            var after: [String: PhotoOverride] = [:]

            for row in rows {
                let revID = row["id"].stringValue
                let existing = try tx.query("SELECT overrides_json FROM photo_adjustments WHERE photo_revision_id=?", [.text(revID)])
                var oldOverride: PhotoOverride? = nil
                var o = PhotoOverride()
                if let data = existing.first?["overrides_json"].stringValue.data(using: .utf8),
                   let decoded = try? Self.jsonDecoder.decode(PhotoOverride.self, from: data) {
                    oldOverride = decoded
                    o = decoded
                }
                before.updateValue(oldOverride, forKey: revID)

                let wasOff = (o.explicitNoPreset == true) || (o.presetID == nil && defaultPresetID == nil)
                let intensity: Double
                if wasOff {
                    intensity = defaultIntensity
                } else if let curIntensity = o.presetIntensity, abs(curIntensity) < 0.0001 {
                    intensity = 0.0
                } else {
                    intensity = o.presetIntensity ?? defaultIntensity
                }

                o.explicitNoPreset = nil
                o.presetID = presetID
                o.presetParameters = presetParameters
                o.presetIntensity = intensity

                after[revID] = o

                let json = String(data: try Self.jsonEncoder.encode(o), encoding: .utf8) ?? "{}"
                let up = try tx.query("SELECT COUNT(*) c FROM photo_adjustments WHERE photo_revision_id=?", [.text(revID)])
                if (up.first?["c"]?.intValue ?? 0) > 0 {
                    try tx.run("UPDATE photo_adjustments SET overrides_json=?, updated_at_ms=? WHERE photo_revision_id=?",
                               [.text(json), .int(Time.nowMs()), .text(revID)])
                } else {
                    try tx.run("INSERT INTO photo_adjustments(photo_revision_id, overrides_json, parameter_version, updated_at_ms) VALUES(?,?,1,?)",
                               [.text(revID), .text(json), .int(Time.nowMs())])
                }
            }

            try tx.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?",
                       [.int(Time.nowMs()), .text(sessionID)])
            return (before: before, after: after)
        }
    }

    func restorePresetOverrides(sessionID: String, overrides: [String: PhotoOverride?]) throws {
        let token = try OperationCoordinator.shared.acquire(key: "session:\(sessionID)", reason: "Chỉnh ảnh")
        defer { token.release() }
        guard !overrides.isEmpty else { return }
        try db.withTransaction { tx in
            let rows = try tx.query("""
                SELECT pr.id FROM photo_revisions pr
                JOIN session_shots sh ON sh.current_photo_revision_id=pr.id AND sh.id=pr.shot_id
                JOIN sessions s ON s.id=sh.session_id
                WHERE s.id=? AND s.status NOT IN ('trashed','purging')
                  AND pr.state='available'
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='session' AND root_id=s.id)
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='photo' AND root_id=pr.id)
                """, [.text(sessionID)])
            let current = Set(rows.map { $0["id"].stringValue })
            guard Set(overrides.keys).isSubset(of: current) else {
                throw AppError.invalidState("Phiên bản ảnh đã thay đổi hoặc vào Thùng rác. Không thể áp dụng lịch sử.")
            }
            let now = Time.nowMs()
            for (id, override) in overrides {
                if let override, !override.isEmpty {
                    let json = String(decoding: try Self.jsonEncoder.encode(override), as: UTF8.self)
                    try tx.run("""
                        INSERT INTO photo_adjustments(photo_revision_id, overrides_json, parameter_version, updated_at_ms)
                        VALUES(?,?,1,?) ON CONFLICT(photo_revision_id) DO UPDATE SET
                            overrides_json=excluded.overrides_json, updated_at_ms=excluded.updated_at_ms
                        """, [.text(id), .text(json), .int(now)])
                } else {
                    try tx.run("DELETE FROM photo_adjustments WHERE photo_revision_id=?", [.text(id)])
                }
            }
            try tx.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?", [.int(now), .text(sessionID)])
        }
        EventBus.shared.post(.sessionChanged(sessionID: sessionID, revision: 0))
    }

    /// Reset overrides của một ảnh (về SessionDefault §9.3).
    public func clearOverride(sessionID: String, photoRevisionID: String) throws {
        let token = try OperationCoordinator.shared.acquire(key: "session:\(sessionID)", reason: "Chỉnh ảnh")
        defer { token.release() }
        try db.withTransaction { tx in
            let revCheck = try tx.query("""
                SELECT sh.current_photo_revision_id, s.status FROM photo_revisions pr
                JOIN session_shots sh ON sh.id = pr.shot_id
                JOIN sessions s ON s.id = sh.session_id
                WHERE pr.id = ? AND s.id = ? AND pr.state='available'
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='session' AND root_id=s.id)
                  AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='photo' AND root_id=pr.id)
                """, [.text(photoRevisionID), .text(sessionID)])
            guard let row = revCheck.first else {
                throw AppError.notFound("Không tìm thấy ảnh của phiên")
            }
            if row["status"]?.stringValue == "trashed" || row["status"]?.stringValue == "purging" {
                throw AppError.invalidState("Phiên chụp đã bị đưa vào Thùng rác")
            }
            guard row["current_photo_revision_id"]?.stringValue == photoRevisionID else {
                throw AppError.invalidState("Phiên bản ảnh đã thay đổi. Hãy chọn lại ảnh hiện hành.")
            }
            try tx.run("DELETE FROM photo_adjustments WHERE photo_revision_id=?", [.text(photoRevisionID)])
            try tx.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
        }
    }

    /// Xóa một hoặc nhiều ảnh khỏi phiên và chuyển vào Thùng rác trong một transaction duy nhất (§2.2).
    @discardableResult
    public func trashPhotos(sessionID: String, pairs: [(shotID: String, photoRevisionID: String)]) throws -> [TrashItem] {
        guard !pairs.isEmpty else { return [] }
        let lockToken = try OperationCoordinator.shared.acquire(key: "session:\(sessionID)", reason: "trashPhotos")
        defer { lockToken.release() }

        var createdItems: [TrashItem] = []
        try db.withTransaction { tx in
            let sessionRows = try tx.query("SELECT * FROM sessions WHERE id=? AND NOT \(Self.hasRootTrashItem)", [.text(sessionID)])
            guard let sRow = sessionRows.first, let session = Self.session(from: sRow) else {
                throw AppError.notFound("Phiên chụp \(sessionID)")
            }
            if session.status == .trashed || session.status == .purging {
                throw AppError.invalidState("Phiên chụp đã bị đưa vào Thùng rác")
            }

            // 1. Kiểm tra toàn bộ danh sách cặp (shotID, photoRevisionID)
            for pair in pairs {
                let shotRows = try tx.query("""
                    SELECT sh.current_photo_revision_id, sh.capture_index FROM session_shots sh
                    JOIN photo_revisions pr ON pr.id=sh.current_photo_revision_id AND pr.shot_id=sh.id
                    WHERE sh.id=? AND sh.session_id=? AND pr.state='available'
                      AND NOT EXISTS (SELECT 1 FROM trash_items WHERE root_type='photo' AND root_id=pr.id)
                    """, [.text(pair.shotID), .text(sessionID)])
                guard let shotRow = shotRows.first,
                      shotRow["current_photo_revision_id"]?.stringValue == pair.photoRevisionID else {
                    throw AppError.invalidState("Phiên bản ảnh đã thay đổi hoặc đang có thao tác xung đột. Hãy chọn lại ảnh hiện hành.")
                }
            }

            // 2. Tạo TrashItem và bỏ current_photo_revision_id của các lượt
            let now = Time.nowMs()
            let expiresAt = TrashPolicy.expiresAt(deletedAtMs: now)
            for pair in pairs {
                let revRows = try tx.query("SELECT relative_path, capture_request_id FROM photo_revisions WHERE id=?", [.text(pair.photoRevisionID)])
                guard let revRow = revRows.first else {
                    throw AppError.notFound("Phiên bản ảnh \(pair.photoRevisionID)")
                }
                let relPath = revRow["relative_path"].stringValue
                var byteSize: Int64 = 0
                if let fileURL = try? layout.absoluteURL(forRelativePath: relPath),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                    byteSize = (attrs[.size] as? Int64) ?? 0
                }

                let shotIndex = (try? tx.query("SELECT capture_index FROM session_shots WHERE id=?", [.text(pair.shotID)]).first?["capture_index"]?.intValue) ?? 1
                let shortSession = String(sessionID.prefix(8))
                let displayName = "Ảnh lượt \(shotIndex) (Phiên \(shortSession))"

                let item = TrashItem(
                    id: IDFactory.new(),
                    rootType: .photo,
                    rootID: pair.photoRevisionID,
                    displayName: displayName,
                    deletedAtMs: now,
                    expiresAtMs: expiresAt,
                    originalParentID: sessionID,
                    estimatedBytes: byteSize,
                    status: .trashed
                )

                try tx.run("""
                    INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms,
                        expires_at_ms, original_parent_id, estimated_bytes, status, last_error)
                    VALUES(?,?,?,?,?,?,?,?,?,NULL)
                    """, [.text(item.id), .text(item.rootType.rawValue), .text(item.rootID),
                          .text(item.displayName), .int(item.deletedAtMs), .int(item.expiresAtMs),
                          .text(sessionID), .int(item.estimatedBytes), .text(item.status.rawValue)])

                try tx.run("UPDATE session_shots SET current_photo_revision_id=NULL WHERE id=?", [.text(pair.shotID)])
                createdItems.append(item)
            }

            // 3. Tính lại các lượt thiếu và cập nhật trạng thái phiên
            let snapshot = try Self.loadSnapshot(session.activeFrameSnapshotID, tx: tx)
            let missingIndices = session.captureIndices(in: snapshot)
                .subtracting(try Self.availableCaptureIndices(sessionID: sessionID, tx: tx))

            if !missingIndices.isEmpty {
                // Thiếu lượt bắt buộc: chuyển sang chờ chụp tiếp, bỏ mốc hoàn thành, đặt lượt tiếp theo
                let nextIdx = missingIndices.sorted().first ?? 1
                try tx.run("""
                    UPDATE sessions SET status='paused', completed_at_ms=NULL, current_capture_index=?,
                        revision_no=revision_no+1, updated_at_ms=?
                    WHERE id=?
                    """, [.int(Int64(nextIdx)), .int(now), .text(sessionID)])
            } else {
                // Chỉ xóa ảnh dự phòng hoặc khung vẫn đủ ảnh: giữ trạng thái hoàn thành/reviewable
                try tx.run("""
                    UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?
                    """, [.int(now), .text(sessionID)])
            }
        }

        EventBus.shared.post(.sessionChanged(sessionID: sessionID, revision: 0))
        EventBus.shared.post(.trashChanged)
        return createdItems
    }

    // MARK: - Placements (§9.2)

    public func setPlacement(sessionID: String, snapshotSlotID: String, placement: PhotoPlacement,
                             cropMode: CropMode, manualOverride: Bool,
                             expectedSnapshotID: String? = nil, expectedPhotoRevisionID: String? = nil,
                             parentToken: OperationCoordinator.OperationToken? = nil) throws {
        let token = try OperationCoordinator.shared.acquire(key: "session:\(sessionID)", reason: "Chỉnh vị trí", parentToken: parentToken)
        defer { token.release() }
        let revision = try db.withTransaction { tx in
            let row = try tx.query("""
                SELECT active_frame_snapshot_id FROM sessions WHERE id=?
                AND status NOT IN ('trashed','purging') AND NOT \(Self.hasRootTrashItem)
                """, [.text(sessionID)]).first
            guard let snapshotID = row?["active_frame_snapshot_id"]?.stringValue,
                  expectedSnapshotID == nil || expectedSnapshotID == snapshotID,
                  let slot = try Self.loadSnapshot(snapshotID, tx: tx).slots.first(where: { $0.id == snapshotSlotID }) else {
                throw AppError.invalidState("Ô hoặc khung của phiên đã thay đổi")
            }
            if let expectedPhotoRevisionID {
                let shot = try tx.query("""
                    SELECT current_photo_revision_id FROM session_shots WHERE session_id=? AND capture_index=?
                    """, [.text(sessionID), .int(Int64(slot.captureIndex))]).first
                guard shot?["current_photo_revision_id"]?.stringValue == expectedPhotoRevisionID else {
                    throw AppError.invalidState("Phiên bản ảnh của ô đã thay đổi")
                }
            }
            let rows = try tx.query("SELECT id FROM slot_placements WHERE session_id=? AND snapshot_slot_id=? AND frame_snapshot_id=(SELECT active_frame_snapshot_id FROM sessions WHERE id=?)", [.text(sessionID), .text(snapshotSlotID), .text(sessionID)])
            if let r = rows.first {
                try tx.run("""
                    UPDATE slot_placements SET crop_mode=?, scale=?, offset_x=?, offset_y=?, manual_override=?, updated_at_ms=?
                    WHERE id=?
                    """, [.text(cropMode.rawValue), .real(placement.scale), .real(placement.offsetX),
                          .real(placement.offsetY), .int(manualOverride ? 1 : 0), .int(Time.nowMs()), .text(r["id"].stringValue)])
            } else {
                try tx.run("""
                    INSERT INTO slot_placements(id, session_id, frame_snapshot_id, snapshot_slot_id, crop_mode, scale, offset_x, offset_y, manual_override, updated_at_ms)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    """, [.text(IDFactory.new()), .text(sessionID), .text(snapshotID), .text(snapshotSlotID),
                          .text(cropMode.rawValue), .real(placement.scale), .real(placement.offsetX),
                          .real(placement.offsetY), .int(manualOverride ? 1 : 0), .int(Time.nowMs())])
            }
            try tx.run("UPDATE sessions SET revision_no=revision_no+1, updated_at_ms=? WHERE id=?", [.int(Time.nowMs()), .text(sessionID)])
            return try tx.scalarInt("SELECT revision_no FROM sessions WHERE id=?", [.text(sessionID)])
        }
        EventBus.shared.post(.sessionChanged(sessionID: sessionID, revision: Int(revision)))
    }

    /// Đổi khung ở Review (§3.6): snapshot mới + mapping + reset placements theo snapshot mới (transaction, D2-A08, DATA-01, DATA-02).
    public func changeFrame(sessionID: String, newSnapshot: FrameSnapshot,
                            frames: FrameRepository? = nil, expectedSessionRevision: Int? = nil) throws {
        guard let frameID = newSnapshot.sourceFrameID, let revision = newSnapshot.sourceFrameRevisionID else {
            try replaceFrame(sessionID: sessionID, proposedSnapshot: newSnapshot, selection: nil, expectedRevision: expectedSessionRevision)
            return
        }
        let repository = frames ?? FrameRepository(db: db, assets: AssetStore(db: db, layout: layout), layout: layout)
        let token = try OperationCoordinator.shared.acquireFrameAndSession(frameID: frameID, sessionID: sessionID, reason: "Đổi khung")
        defer { token.release() }
        _ = try repository.validatedSnapshotForUse(frameID: frameID, expectedRevisionID: revision, parentToken: token)
        try replaceFrame(sessionID: sessionID, proposedSnapshot: newSnapshot, selection: nil, expectedRevision: expectedSessionRevision, parentToken: token)
    }

    public func confirmPhotoSelection(sessionID: String, order: [Int]) throws {
        try replaceFrame(sessionID: sessionID, proposedSnapshot: nil, selection: order)
    }

    func verifiedPhotoImage(_ revision: PhotoRevision) throws -> CGImage {
        let data = try Data(contentsOf: fileURL(for: revision))
        guard revision.sha256.isEmpty || Hashing.sha256Hex(data) == revision.sha256,
              let image = ImageNormalizer.uprightImage(data: data) else {
            throw AppError.ioFailure("Tệp ảnh không đọc được hoặc không khớp checksum")
        }
        return image
    }

    func verifiedCaptureDetail(sessionID: String) throws -> SessionDetail? {
        guard var detail = try activeCaptureDetail(sessionID: sessionID) else { return nil }
        for shot in detail.shots {
            guard let current = shot.currentPhotoRevisionID,
                  let index = detail.photoRevisions[shot.id]?.firstIndex(where: { $0.id == current }),
                  let revision = detail.photoRevisions[shot.id]?[index],
                  revision.state == .available,
                  (try? verifiedPhotoImage(revision)) == nil else { continue }
            detail.photoRevisions[shot.id]?[index].state = .corrupt
        }
        return detail
    }

    func applyCaptureFrame(sessionID: String, expectedRevision: Int, frameID: String,
                           frameRevisionID: String, orderedPhotoIDs: [String],
                           frames: FrameRepository, assets: AssetStore) throws {
        let token = try OperationCoordinator.shared.acquireFrameAndSession(
            frameID: frameID, sessionID: sessionID, reason: "Áp dụng khung")
        defer { token.release() }
        guard let detail = try verifiedCaptureDetail(sessionID: sessionID),
              detail.session.defaults.plannedCaptureCount != nil,
              let frame = try frames.getFrame(id: frameID),
              frame.lifecycle == .active, frame.validationStatus == .ready,
              frame.currentRevisionID == frameRevisionID else {
            throw AppError.invalidState("Phiên hoặc khung đã thay đổi")
        }
        let current = detail.currentRevisions(includeUnassigned: true).filter { $0.value.state == .available }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.value.id, $0.key) })
        let order = orderedPhotoIDs.compactMap { byID[$0] }
        guard order.count == orderedPhotoIDs.count, Set(order).count == order.count else {
            throw AppError.invalidState("Ảnh đã chọn không còn khả dụng")
        }
        if detail.snapshot.sourceFrameID == frameID,
           detail.snapshot.sourceFrameRevisionID == frameRevisionID,
           detail.session.defaults.selectedCaptureOrder == order { return }
        guard detail.session.revisionNo == expectedRevision,
              !detail.session.awaitsFrame || detail.missingIndices.isEmpty else {
            throw AppError.invalidState("Phiên đã thay đổi. Hãy kiểm tra lại ảnh trước khi xác nhận.")
        }
        let snapshot = try frames.validatedSnapshotForUse(frameID: frameID, expectedRevisionID: frameRevisionID, parentToken: token)
        guard snapshot.sourceFrameRevisionID == frameRevisionID else {
            throw AppError.invalidState("Khung ảnh đã thay đổi")
        }
        for layer in [snapshot.background, snapshot.foreground].compactMap({ $0 }) {
            _ = try assets.loadVerifiedImage(assetID: layer.assetID)
        }
        try replaceFrame(sessionID: sessionID, proposedSnapshot: snapshot, selection: order,
                         captureFirst: (expectedRevision, frame.name), parentToken: token)
    }

    private func replaceFrame(sessionID: String, proposedSnapshot: FrameSnapshot?, selection: [Int]?,
                              captureFirst: (revision: Int, frameName: String)? = nil, expectedRevision: Int? = nil,
                              parentToken: OperationCoordinator.OperationToken? = nil) throws {
        let lockToken = try OperationCoordinator.shared.acquire(key: "session:\(sessionID)", reason: "changeFrame",
                                                                parentToken: parentToken)
        defer { lockToken.release() }

        try db.withTransaction { tx in
            let rows = try tx.query("SELECT * FROM sessions WHERE id=? AND status NOT IN ('trashed','purging') AND NOT \(Self.hasRootTrashItem)", [.text(sessionID)])
            guard let row = rows.first, var session = Self.session(from: row) else {
                throw AppError.notFound("session \(sessionID)")
            }
            guard expectedRevision == nil || expectedRevision == session.revisionNo else {
                throw AppError.invalidState("Phiên đã thay đổi. Hãy mở lại bộ chọn khung.")
            }
            let committedRows = try tx.query("""
                SELECT sh.capture_index FROM session_shots sh
                JOIN photo_revisions pr ON pr.id = sh.current_photo_revision_id
                WHERE sh.session_id=? AND pr.state='available'
                """, [.text(sessionID)])
            let committedIndices = Set(committedRows.compactMap { $0["capture_index"]?.intValue })
            let previousSnapshot = try Self.loadSnapshot(session.activeFrameSnapshotID, tx: tx)
            let newSnapshot: FrameSnapshot
            if let captureFirst {
                guard session.defaults.plannedCaptureCount != nil,
                      session.revisionNo == captureFirst.revision,
                      let proposedSnapshot, proposedSnapshot.requiredCaptureCount > 0,
                      let selection, Set(selection).isSubset(of: committedIndices) else {
                    throw AppError.invalidState("Phiên hoặc ảnh đã thay đổi")
                }
                newSnapshot = try proposedSnapshot.assigningPhotos(in: selection)
                session.defaults.selectedCaptureOrder = selection
                session.defaults.appliedFrameName = captureFirst.frameName
            } else if let selection {
                guard let count = session.pendingSelectionCount,
                      session.status == .reviewable || session.status == .paused,
                      Set(1...count).isSubset(of: committedIndices),
                      Set(selection).isSubset(of: Set(1...count)),
                      let data = try tx.query("SELECT snapshot_json FROM frame_snapshots WHERE id=?",
                                              [.text(session.activeFrameSnapshotID)]).first?["snapshot_json"]?.stringValue.data(using: .utf8),
                      let snapshot = try? Self.jsonDecoder.decode(FrameSnapshot.self, from: data) else {
                    throw AppError.invalidState("Phiên chưa có đủ ảnh để xác nhận")
                }
                newSnapshot = try snapshot.assigningPhotos(in: selection)
                session.defaults.selectedCaptureOrder = selection
            } else {
                guard session.defaults.plannedCaptureCount == nil,
                      let proposedSnapshot, proposedSnapshot.requiredCaptureCount > 0 else {
                    throw AppError.frameUnconfigured
                }
                if let count = session.defaults.selectionCaptureCount {
                    guard proposedSnapshot.requiredCaptureCount <= count else {
                        throw AppError.invalidState("Khung này cần nhiều ảnh hơn số lượt đã đặt cho phiên")
                    }
                    if let order = session.defaults.selectedCaptureOrder,
                       order.count == proposedSnapshot.requiredCaptureCount {
                        newSnapshot = try proposedSnapshot.assigningPhotos(in: order)
                    } else {
                        newSnapshot = proposedSnapshot
                        session.defaults.selectedCaptureOrder = nil
                    }
                } else {
                    newSnapshot = proposedSnapshot
                }
            }

            try Self.storeSnapshot(newSnapshot, tx: tx)

            let oldSnapshotID = session.activeFrameSnapshotID
            let requiredIndices = session.captureIndices(in: newSnapshot)

            // Thêm shot cho index mới theo tập index thật của snapshot (§5 / DATA-02)
            for index in requiredIndices {
                try tx.run("INSERT OR IGNORE INTO session_shots(id, session_id, capture_index, current_photo_revision_id) VALUES(?,?,?,NULL)",
                           [.text(IDFactory.new()), .text(sessionID), .int(Int64(index))])
            }

            let missingIndices = requiredIndices.subtracting(committedIndices)

            let newStatus: SessionStatus
            let newCompletedAtMs: Int64?
            let nextIndex: Int
            if !missingIndices.isEmpty {
                newStatus = .paused
                newCompletedAtMs = nil
                nextIndex = missingIndices.min() ?? 1
            } else {
                if session.status == .completed && session.pendingSelectionCount == nil {
                    newStatus = .completed
                    newCompletedAtMs = session.completedAtMs ?? Time.nowMs()
                } else {
                    newStatus = .reviewable
                    newCompletedAtMs = nil
                }
                nextIndex = requiredIndices.max() ?? 1
            }

            if let proposedSnapshot, proposedSnapshot.sourceFrameID != previousSnapshot.sourceFrameID ||
                proposedSnapshot.sourceFrameRevisionID != previousSnapshot.sourceFrameRevisionID {
                session.defaults.autoFacePlacementVersion = 1
            }
            let defaultsJSON = String(decoding: try Self.jsonEncoder.encode(session.defaults), as: UTF8.self)
            try tx.run("""
                UPDATE sessions
                SET active_frame_snapshot_id=?, required_capture_count=?, current_capture_index=?,
                    status=?, completed_at_ms=?, revision_no=revision_no+1, updated_at_ms=?, session_defaults_json=?
                WHERE id=?
                """, [.text(newSnapshot.id), .int(Int64(newSnapshot.requiredCaptureCount)),
                      .int(Int64(nextIndex)), .text(newStatus.rawValue),
                      newCompletedAtMs.map { .int($0) } ?? .null,
                      .int(Time.nowMs()), .text(defaultsJSON), .text(sessionID)])

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
            if oldSnapshotID != newSnapshot.id {
                try Self.removeUnusedSnapshot(oldSnapshotID, tx: tx)
            }
        }
        EventBus.shared.post(.sessionChanged(sessionID: sessionID, revision: 0))
    }

    private static func storeSnapshot(_ snapshot: FrameSnapshot, tx: SQLiteDatabase.TransactionHandle) throws {
        if (try tx.scalarInt("SELECT COUNT(*) FROM frame_snapshots WHERE id=?", [.text(snapshot.id)])) == 0 {
            let data = try Self.jsonEncoder.encode(snapshot)
            try tx.run("""
                INSERT INTO frame_snapshots(id, source_frame_id, source_frame_revision_id, snapshot_json, snapshot_hash, created_at_ms)
                VALUES(?,?,?,?,?,?)
                """, [.text(snapshot.id), snapshot.sourceFrameID.map { .text($0) } ?? .null,
                      snapshot.sourceFrameRevisionID.map { .text($0) } ?? .null,
                      .text(String(data: data, encoding: .utf8) ?? "{}"),
                      .text(snapshot.snapshotHash),
                      .int(snapshot.createdAtMs)])
            if let bg = snapshot.background?.assetID {
                try tx.run("INSERT OR IGNORE INTO asset_references(asset_id, owner_type, owner_id, purpose) VALUES(?,?,?,?)",
                           [.text(bg), .text("frame_snapshot"), .text(snapshot.id), .text("background")])
            }
            if let fg = snapshot.foreground?.assetID {
                try tx.run("INSERT OR IGNORE INTO asset_references(asset_id, owner_type, owner_id, purpose) VALUES(?,?,?,?)",
                           [.text(fg), .text("frame_snapshot"), .text(snapshot.id), .text("foreground")])
            }
        }
    }

    private static func removeUnusedSnapshot(_ id: String, tx: SQLiteDatabase.TransactionHandle) throws {
        let sessionCount = try tx.scalarInt("SELECT COUNT(*) FROM sessions WHERE active_frame_snapshot_id=?", [.text(id)])
        let placementCount = try tx.scalarInt("SELECT COUNT(*) FROM slot_placements WHERE frame_snapshot_id=?", [.text(id)])
        guard sessionCount == 0, placementCount == 0 else { return }
        try tx.run("DELETE FROM asset_references WHERE owner_type='frame_snapshot' AND owner_id=?", [.text(id)])
        try tx.run("DELETE FROM frame_snapshots WHERE id=?", [.text(id)])
    }

    /// Repairs only the old selection writer that persisted an order but left the source frame's mapping unchanged.
    @discardableResult
    func repairLegacyFrameAssignments(using frames: FrameRepository) throws -> (updated: Int, unresolved: [String]) {
        let rows = try db.query("""
            SELECT * FROM sessions WHERE status NOT IN ('trashed','purging')
              AND NOT \(Self.hasRootTrashItem)
              AND json_valid(session_defaults_json)
              AND json_extract(session_defaults_json, '$.plannedCaptureCount') IS NULL
              AND json_type(session_defaults_json, '$.selectedCaptureOrder')='array'
            """)
        var updated = 0
        var unresolved: [String] = []
        var backedUp = false
        for row in rows {
            guard let session = Self.session(from: row), let order = session.defaults.selectedCaptureOrder else { continue }
            guard let snapshot = try snapshotLoader(session.activeFrameSnapshotID) else {
                unresolved.append(session.id)
                continue
            }
            // The affected writer never changed the source revision's slot IDs or geometry.
            guard let count = session.defaults.selectionCaptureCount,
                  (1...ResourceLimits.maxCaptureIndices).contains(count),
                  Set(order).count == order.count, order.allSatisfy({ (1...count).contains($0) }),
                  let sourceID = snapshot.sourceFrameRevisionID else {
                unresolved.append(session.id)
                continue
            }
            let canonical = try frames.getSlots(revisionID: sourceID).map(SnapshotSlot.init(from:))
            var original = snapshot
            original.slots = canonical
            guard !canonical.isEmpty, let expected = try? original.assigningPhotos(in: order) else {
                unresolved.append(session.id)
                continue
            }
            let slots = snapshot.slots.sorted { $0.id < $1.id }
            if slots == expected.slots.sorted(by: { $0.id < $1.id }) { continue }
            guard slots == canonical.sorted(by: { $0.id < $1.id }) else {
                unresolved.append(session.id)
                continue
            }
            let token = try OperationCoordinator.shared.acquire(key: "session:\(session.id)", reason: "repair frame assignment")
            defer { token.release() }
            if !backedUp, db.databasePath != ":memory:" {
                let backups = layout.rootURL.appendingPathComponent("backups", isDirectory: true)
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                try db.backup(to: backups.appendingPathComponent("pre-frame-assignment-\(IDFactory.new()).sqlite").path)
                backedUp = true
            }
            let applied = try db.withTransaction { tx in
                let current = try tx.query("SELECT revision_no FROM sessions WHERE id=? AND active_frame_snapshot_id=? AND status NOT IN ('trashed','purging')", [.text(session.id), .text(snapshot.id)]).first
                guard current?["revision_no"]?.intValue == session.revisionNo else { return false }
                let missing = expected.requiredIndices.subtracting(try Self.availableCaptureIndices(sessionID: session.id, tx: tx))
                try Self.storeSnapshot(expected, tx: tx)
                try tx.run("UPDATE slot_placements SET frame_snapshot_id=? WHERE session_id=? AND frame_snapshot_id=?",
                           [.text(expected.id), .text(session.id), .text(snapshot.id)])
                let next = missing.min() ?? expected.maxCaptureIndex
                let status = missing.isEmpty ? (session.status == .completed ? SessionStatus.completed : .reviewable) : .paused
                try tx.run("""
                    UPDATE sessions SET active_frame_snapshot_id=?, current_capture_index=?, status=?,
                        completed_at_ms=?, revision_no=revision_no+1, updated_at_ms=? WHERE id=?
                    """, [.text(expected.id), .int(Int64(next)), .text(status.rawValue),
                          status == .completed ? session.completedAtMs.map { .int($0) } ?? .null : .null,
                          .int(Time.nowMs()), .text(session.id)])
                try Self.removeUnusedSnapshot(snapshot.id, tx: tx)
                return true
            }
            if applied {
                updated += 1
                EventBus.shared.post(.sessionChanged(sessionID: session.id, revision: 0))
            } else {
                unresolved.append(session.id)
            }
        }
        return (updated, unresolved)
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

