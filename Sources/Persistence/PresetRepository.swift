import Foundation

/// PresetRepository: thư viện preset (built-in không xóa được, custom soft-delete §8.2).
public final class PresetRepository: @unchecked Sendable {
    private let db: SQLiteDatabase
    public init(db: SQLiteDatabase) { self.db = db }

    public func listPresets(includeTrashed: Bool = false) throws -> [PresetRecord] {
        let sql = includeTrashed
            ? "SELECT * FROM presets ORDER BY is_system DESC, name"
            : "SELECT * FROM presets WHERE lifecycle='active' ORDER BY is_system DESC, name"
        return try db.query(sql).compactMap(Self.preset(from:))
    }

    public func getPreset(id: String) throws -> PresetRecord? {
        let rows = try db.query("SELECT * FROM presets WHERE id=?", [.text(id)])
        return rows.first.flatMap(Self.preset(from:))
    }

    public static func preset(from row: SQLiteRow) -> PresetRecord? {
        guard let data = row["parameters_json"].stringValue.data(using: .utf8),
              let params = try? JSONDecoder().decode(ColorParameterSet.self, from: data) else { return nil }
        return PresetRecord(id: row["id"].stringValue,
                            name: row["name"].stringValue,
                            isSystem: row["is_system"].boolValue,
                            parameters: params,
                            parameterVersion: row["parameter_version"]?.intValue ?? 1,
                            lifecycle: FrameLifecycle(rawValue: row["lifecycle"].stringValue) ?? .active,
                            createdAtMs: row["created_at_ms"]?.int64Value ?? 0,
                            updatedAtMs: row["updated_at_ms"]?.int64Value ?? 0)
    }

    /// Tạo preset user với tên duy nhất trong nhóm active (§8.2).
    public func createPreset(name: String, parameters: ColorParameterSet, isSystem: Bool = false) throws -> PresetRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.invalidState("Tên preset không được rỗng") }
        let dup = try db.scalarInt("SELECT COUNT(*) FROM presets WHERE lifecycle='active' AND lower(name)=lower(?)", [.text(trimmed)])
        if dup > 0 { throw AppError.restoreConflict("Preset '\(trimmed)' đã tồn tại") }
        let rec = PresetRecord(name: trimmed, isSystem: isSystem, parameters: parameters)
        let json = String(data: try JSONEncoder().encode(parameters), encoding: .utf8) ?? "{}"
        try db.run("""
            INSERT INTO presets(id, name, is_system, parameters_json, parameter_version, lifecycle, created_at_ms, updated_at_ms)
            VALUES(?,?,?,?,1,'active',?,?)
            """, [.text(rec.id), .text(rec.name), .int(isSystem ? 1 : 0), .text(json),
                  .int(rec.createdAtMs), .int(rec.updatedAtMs)])
        return rec
    }

    public func renamePreset(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.invalidState("Tên preset không được rỗng") }
        let dup = try db.scalarInt("SELECT COUNT(*) FROM presets WHERE lifecycle='active' AND lower(name)=lower(?) AND id<>?", [.text(trimmed), .text(id)])
        if dup > 0 { throw AppError.restoreConflict("Preset '\(trimmed)' đã tồn tại") }
        try db.run("UPDATE presets SET name=?, updated_at_ms=? WHERE id=?", [.text(trimmed), .int(Time.nowMs()), .text(id)])
    }

    public func duplicatePreset(id: String) throws -> PresetRecord {
        guard let src = try getPreset(id: id) else { throw AppError.notFound("preset \(id)") }
        return try createPreset(name: FrameRepository.uniqueName(base: src.name + " (bản sao)", existing: try listPresets().map(\.name)), parameters: src.parameters)
    }
}
