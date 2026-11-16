import Foundation

/// TrashRepository: bản ghi TrashItem + intents + bookmarks (§12).
public final class TrashRepository: @unchecked Sendable {
    private let db: SQLiteDatabase

    public init(db: SQLiteDatabase) { self.db = db }

    // MARK: Trash items

    public func insert(_ item: TrashItem) throws {
        try db.run("""
            INSERT INTO trash_items(id, root_type, root_id, display_name, deleted_at_ms, expires_at_ms,
                original_parent_id, estimated_bytes, status, last_error)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [.text(item.id), .text(item.rootType.rawValue), .text(item.rootID),
                  .text(item.displayName), .int(item.deletedAtMs), .int(item.expiresAtMs),
                  item.originalParentID.map { .text($0) } ?? .null,
                  .int(item.estimatedBytes), .text(item.status.rawValue),
                  item.lastError.map { .text($0) } ?? .null])
    }

    public func list(status: TrashStatus? = nil) throws -> [TrashItem] {
        let sql: String
        let bind: [SQLiteValue]
        if let status {
            sql = "SELECT * FROM trash_items WHERE status=? ORDER BY expires_at_ms"
            bind = [.text(status.rawValue)]
        } else {
            sql = "SELECT * FROM trash_items ORDER BY expires_at_ms"
            bind = []
        }
        return try db.query(sql, bind).map(Self.item(from:))
    }

    public static func item(from row: SQLiteRow) -> TrashItem {
        TrashItem(id: row["id"].stringValue,
                  rootType: TrashRootType(rawValue: row["root_type"].stringValue) ?? .frame,
                  rootID: row["root_id"].stringValue,
                  displayName: row["display_name"].stringValue,
                  deletedAtMs: row["deleted_at_ms"]?.int64Value ?? 0,
                  expiresAtMs: row["expires_at_ms"]?.int64Value ?? 0,
                  originalParentID: row["original_parent_id"].stringValue.isEmpty ? nil : row["original_parent_id"].stringValue,
                  estimatedBytes: row["estimated_bytes"]?.int64Value ?? 0,
                  status: TrashStatus(rawValue: row["status"].stringValue) ?? .trashed,
                  lastError: row["last_error"].stringValue.isEmpty ? nil : row["last_error"].stringValue)
    }

    public func find(rootType: TrashRootType, rootID: String) throws -> TrashItem? {
        let rows = try db.query("SELECT * FROM trash_items WHERE root_type=? AND root_id=?", [.text(rootType.rawValue), .text(rootID)])
        return rows.first.map(Self.item(from:))
    }

    public func getItem(id: String) throws -> TrashItem? {
        let rows = try db.query("SELECT * FROM trash_items WHERE id=?", [.text(id)])
        return rows.first.map(Self.item(from:))
    }

    public func setStatus(id: String, status: TrashStatus, error: String? = nil) throws {
        try db.run("UPDATE trash_items SET status=?, last_error=? WHERE id=?",
                   [.text(status.rawValue), error.map { .text($0) } ?? .null, .text(id)])
    }

    public func remove(id: String) throws {
        try db.run("DELETE FROM trash_items WHERE id=?", [.text(id)])
    }

    public func expired(nowMs: Int64, limit: Int = 20) throws -> [TrashItem] {
        try db.query("""
            SELECT * FROM trash_items WHERE status='trashed' AND expires_at_ms <= ?
            ORDER BY expires_at_ms LIMIT ?
            """, [.int(nowMs), .int(Int64(limit))]).map(Self.item(from:))
    }

    public func totalCount() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM trash_items"))
    }

    public func totalBytes() throws -> Int64 {
        try db.scalarInt("SELECT COALESCE(SUM(estimated_bytes),0) FROM trash_items")
    }

    // MARK: Operation intents (§10.2, §12.3)

    @discardableResult
    public func createIntent(opType: String, rootID: String, payloadJSON: String = "{}") throws -> OperationIntentRecord {
        try db.withTransaction { tx in
            try createIntent(opType: opType, rootID: rootID, payloadJSON: payloadJSON, tx: tx)
        }
    }

    func createIntent(opType: String, rootID: String, payloadJSON: String, tx: SQLiteDatabase.TransactionHandle) throws -> OperationIntentRecord {
        let now = Time.nowMs()
        let intent = OperationIntentRecord(id: IDFactory.new(), opType: opType, rootID: rootID,
                                           payloadJSON: payloadJSON, status: .prepared,
                                           createdAtMs: now, updatedAtMs: now, lastError: nil)
        try tx.run("""
            INSERT INTO operation_intents(id, op_type, root_id, payload_json, status, created_at_ms, updated_at_ms)
            VALUES(?,?,?,?,?,?,?)
            """, [.text(intent.id), .text(opType), .text(rootID), .text(payloadJSON),
                  .text(intent.status.rawValue), .int(now), .int(now)])
        return intent
    }

    public func updateIntent(id: String, status: OperationStatus, error: String? = nil) throws {
        try db.run("UPDATE operation_intents SET status=?, last_error=?, updated_at_ms=? WHERE id=?",
                   [.text(status.rawValue), error.map { .text($0) } ?? .null, .int(Time.nowMs()), .text(id)])
    }

    func finishIntent(id: String, status: OperationStatus, tx: SQLiteDatabase.TransactionHandle) throws {
        try tx.run("UPDATE operation_intents SET status=?, last_error=NULL, updated_at_ms=? WHERE id=?",
                   [.text(status.rawValue), .int(Time.nowMs()), .text(id)])
    }

    public func pendingIntents(opType: String? = nil) throws -> [OperationIntentRecord] {
        let rows: [SQLiteRow]
        if let opType {
            rows = try db.query("SELECT * FROM operation_intents WHERE status IN ('prepared','files_staged','files_promoted','rollback_required') AND op_type=? ORDER BY updated_at_ms", [.text(opType)])
        } else {
            rows = try db.query("SELECT * FROM operation_intents WHERE status IN ('prepared','files_staged','files_promoted','rollback_required') ORDER BY updated_at_ms")
        }
        return rows.map { r in
            OperationIntentRecord(id: r["id"].stringValue, opType: r["op_type"].stringValue,
                                  rootID: r["root_id"].stringValue, payloadJSON: r["payload_json"].stringValue,
                                  status: OperationStatus(rawValue: r["status"].stringValue) ?? .prepared,
                                  createdAtMs: r["created_at_ms"]?.int64Value ?? 0,
                                  updatedAtMs: r["updated_at_ms"]?.int64Value ?? 0,
                                  lastError: r["last_error"].stringValue.isEmpty ? nil : r["last_error"].stringValue)
        }
    }

    public func getIntent(id: String) throws -> OperationIntentRecord? {
        let rows = try db.query("SELECT * FROM operation_intents WHERE id=?", [.text(id)])
        guard let r = rows.first else { return nil }
        return OperationIntentRecord(id: r["id"].stringValue, opType: r["op_type"].stringValue,
                                     rootID: r["root_id"].stringValue, payloadJSON: r["payload_json"].stringValue,
                                     status: OperationStatus(rawValue: r["status"].stringValue) ?? .prepared,
                                     createdAtMs: r["created_at_ms"]?.int64Value ?? 0,
                                     updatedAtMs: r["updated_at_ms"]?.int64Value ?? 0,
                                     lastError: r["last_error"].stringValue.isEmpty ? nil : r["last_error"].stringValue)
    }

    // MARK: Bookmarks (§10.4)

    @discardableResult
    public func saveBookmark(purpose: String, blob: Data, displayPath: String?) throws -> String {
        let id = IDFactory.new()
        try db.run("""
            INSERT INTO app_bookmarks(id, purpose, bookmark_blob, display_path, updated_at_ms)
            VALUES(?,?,?,?,?)
            """, [.text(id), .text(purpose), .blob(blob), displayPath.map { .text($0) } ?? .null, .int(Time.nowMs())])
        return id
    }

    public func bookmark(id: String) throws -> (blob: Data, displayPath: String?)? {
        let rows = try db.query("SELECT bookmark_blob, display_path FROM app_bookmarks WHERE id=?", [.text(id)])
        guard let r = rows.first else { return nil }
        guard case .blob(let data) = r["bookmark_blob"] ?? .blob(Data()) else { return nil }
        return (data, r["display_path"].stringValue.isEmpty ? nil : r["display_path"].stringValue)
    }

    /// Xóa row bookmark mồ côi (đổi thư mục xuất / reset cài đặt — không tích lũy vô hạn).
    public func deleteBookmark(id: String) throws {
        try db.run("DELETE FROM app_bookmarks WHERE id=?", [.text(id)])
    }
}
