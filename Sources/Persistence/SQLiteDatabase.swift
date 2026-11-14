import Foundation
import SQLite3

public enum SQLiteValue: Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var sqliteDescription: String {
        switch self {
        case .null: return "NULL"
        case .int(let v): return "INT \(v)"
        case .real(let v): return "REAL \(v)"
        case .text(let v): return "TEXT \(v)"
        case .blob(let d): return "BLOB \(d.count)"
        }
    }
}

public typealias SQLiteRow = [String: SQLiteValue]

/// Truy cập an toàn trên giá trị Optional của subscript dictionary.
/// Cho phép `row["x"].stringValue` (key thiếu → "") song song với `row["x"]?.intValue ?? 0`.
extension Optional where Wrapped == SQLiteValue {
    public var stringValue: String { self?.stringValue ?? "" }
    public var intValue: Int? { self?.intValue }
    public var int64Value: Int64? { self?.int64Value }
    public var doubleValue: Double? { self?.doubleValue }
    public var boolValue: Bool { self?.boolValue ?? false }
}

/// Wrapper SQLite3 thread-an toàn: một connection, queue serial, WAL + foreign_keys (§16.2).
/// Transaction dùng `withTransaction` — thân gọi qua TransactionHandle, không deadlock.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue: DispatchQueue
    private let path: String
    private var inTransactionDepth = 0

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, isReadOnly: Bool = false) throws {
        self.path = path
        self.queue = DispatchQueue(label: "vn.openphotobooth.sqlite", qos: .userInitiated)
        var db: OpaquePointer?
        let flags = isReadOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let d = db { sqlite3_close(d) }
            throw AppError.databaseCorrupt(msg)
        }
        handle = opened
        _ = exec("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            _ = exec("PRAGMA journal_mode = WAL")
            _ = exec("PRAGMA synchronous = NORMAL")
        }
        _ = exec("PRAGMA busy_timeout = 5000")
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    public var databasePath: String { path }

    /// Sao lưu trực tuyến nhất quán (WAL-safe backup) qua SQLite Backup API (§3.1).
    public func backup(to destinationPath: String) throws {
        try queue.sync {
            guard let src = handle else { throw AppError.databaseCorrupt("connection closed") }
            var destDb: OpaquePointer?
            let rc = sqlite3_open(destinationPath, &destDb)
            guard rc == SQLITE_OK, let dest = destDb else {
                if let d = destDb { sqlite3_close(d) }
                throw AppError.ioFailure("Không tạo được file sao lưu SQLite: rc=\(rc)")
            }
            defer { sqlite3_close(dest) }
            guard let backupHandle = sqlite3_backup_init(dest, "main", src, "main") else {
                let msg = String(cString: sqlite3_errmsg(dest))
                throw AppError.ioFailure("sqlite3_backup_init thất bại: \(msg)")
            }
            let stepRc = sqlite3_backup_step(backupHandle, -1)
            let finishRc = sqlite3_backup_finish(backupHandle)
            guard (stepRc == SQLITE_DONE || stepRc == SQLITE_OK) && finishRc == SQLITE_OK else {
                throw AppError.ioFailure("Sao lưu SQLite thất bại: step=\(stepRc), finish=\(finishRc)")
            }
        }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let h = handle else { return false }
        return sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK
    }

    public func integrityCheck() -> String? {
        queue.sync {
            guard let rows = try? self._query("PRAGMA integrity_check", []) else { return nil }
            if let first = rows.first, case .text(let v) = first["integrity_check"] ?? .text("") {
                return v == "ok" ? nil : v
            }
            return nil
        }
    }

    public func foreignKeyCheck() -> [String] {
        queue.sync {
            let rows = (try? self._query("PRAGMA foreign_key_check", [])) ?? []
            return rows.map { row in
                (row["table"].flatMap { if case .text(let t) = $0 { return t } else { return nil } } ?? "?") + ":violation"
            }
        }
    }

    // MARK: public API

    public func run(_ sql: String, _ bind: [SQLiteValue] = []) throws {
        try queue.sync { try _run(sql, bind) }
    }

    public func query(_ sql: String, _ bind: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try queue.sync { try _query(sql, bind) }
    }

    public func scalarInt(_ sql: String, _ bind: [SQLiteValue] = []) throws -> Int64 {
        let rows = try query(sql, bind)
        if let f = rows.first?.values.first {
            switch f {
            case .int(let v): return v
            case .real(let v): return Int64(v)
            case .text(let v): return Int64(v) ?? 0
            default: return 0
            }
        }
        return 0
    }

    public func lastInsertRowID() -> Int64 {
        queue.sync { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    }

    public func withTransaction<T>(_ body: (TransactionHandle) throws -> T) throws -> T {
        try queue.sync {
            guard let h = handle else { throw AppError.databaseCorrupt("connection closed") }
            try _runRaw("BEGIN IMMEDIATE")
            inTransactionDepth += 1
            do {
                let value = try body(TransactionHandle(db: h))
                try _runRaw("COMMIT")
                inTransactionDepth -= 1
                return value
            } catch {
                try? _runRaw("ROLLBACK")
                inTransactionDepth -= 1
                throw error
            }
        }
    }

    public struct TransactionHandle {
        fileprivate let db: OpaquePointer
        public func run(_ sql: String, _ bind: [SQLiteValue] = []) throws {
            try SQLiteDatabase.execute(on: db, sql, bind)
        }
        public func query(_ sql: String, _ bind: [SQLiteValue] = []) throws -> [SQLiteRow] {
            try SQLiteDatabase.select(on: db, sql, bind)
        }
    }

    // MARK: internals

    private func _run(_ sql: String, _ bind: [SQLiteValue]) throws {
        guard let h = handle else { throw AppError.databaseCorrupt("connection closed") }
        try SQLiteDatabase.execute(on: h, sql, bind)
    }

    private func _query(_ sql: String, _ bind: [SQLiteValue]) throws -> [SQLiteRow] {
        guard let h = handle else { throw AppError.databaseCorrupt("connection closed") }
        return try SQLiteDatabase.select(on: h, sql, bind)
    }

    private func _runRaw(_ sql: String) throws {
        guard let h = handle else { throw AppError.databaseCorrupt("connection closed") }
        guard sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK else {
            throw AppError.ioFailure("SQL error: \(String(cString: sqlite3_errmsg(h)))")
        }
    }

    fileprivate static func execute(on h: OpaquePointer, _ sql: String, _ bind: [SQLiteValue]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw AppError.ioFailure("Prepare failed: \(String(cString: sqlite3_errmsg(h))) — \(sql.prefix(80))")
        }
        defer { sqlite3_finalize(s) }
        try assertBindCount(s, bind: bind, sql: sql)
        try bindValues(s, bind)
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw AppError.ioFailure("SQL error: \(String(cString: sqlite3_errmsg(h))) — \(sql.prefix(80))")
        }
    }

    fileprivate static func select(on h: OpaquePointer, _ sql: String, _ bind: [SQLiteValue]) throws -> [SQLiteRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw AppError.ioFailure("Prepare failed: \(String(cString: sqlite3_errmsg(h))) — \(sql.prefix(80))")
        }
        defer { sqlite3_finalize(s) }
        try assertBindCount(s, bind: bind, sql: sql)
        try bindValues(s, bind)
        var rows: [SQLiteRow] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW {
                let count = sqlite3_column_count(s)
                var row: SQLiteRow = [:]
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(s, i))
                    switch sqlite3_column_type(s, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(s, i))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(s, i))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(s, i)))
                    case SQLITE_BLOB:
                        if let ptr = sqlite3_column_blob(s, i) {
                            row[name] = .blob(Data(bytes: ptr, count: Int(sqlite3_column_bytes(s, i))))
                        } else {
                            row[name] = .blob(Data())
                        }
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw AppError.ioFailure("SQL error: \(String(cString: sqlite3_errmsg(h)))")
            }
        }
        return rows
    }

    /// Chống cả lớp lỗi đếm bind lệch: số giá trị bind phải bằng số placeholder của statement
    /// (vi phạm NOT NULL/CHECK do thiếu bind sẽ bị phát hiện tại đây thay vì hỏng dữ liệu âm thầm).
    private static func assertBindCount(_ s: OpaquePointer, bind: [SQLiteValue], sql: String) throws {
        let expected = Int(sqlite3_bind_parameter_count(s))
        guard expected == bind.count else {
            throw AppError.ioFailure("Bind count mismatch (got \(bind.count), expected \(expected)) — \(sql.prefix(80))")
        }
    }

    private static func bindValues(_ s: OpaquePointer, _ values: [SQLiteValue]) throws {
        for (idx, v) in values.enumerated() {
            let i = Int32(idx + 1)
            switch v {
            case .null: sqlite3_bind_null(s, i)
            case .int(let n): sqlite3_bind_int64(s, i, n)
            case .real(let d): sqlite3_bind_double(s, i, d)
            case .text(let t): sqlite3_bind_text(s, i, t, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                if d.isEmpty { sqlite3_bind_zeroblob(s, i, 0) }
                else { d.withUnsafeBytes { p in sqlite3_bind_blob(s, i, p.baseAddress, Int32(d.count), SQLITE_TRANSIENT) } }
            }
        }
    }
}
