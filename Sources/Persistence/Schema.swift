import Foundation

/// Schema v1 — DDL chuyển ngữ trực tiếp từ đặc tả §16.2 + §16.3 (asset_references),
/// bổ sung bảng app_state cho seedVersion/clock-marker (§6.4 idempotent seeding).
public enum Schema {
    public static let currentVersion: Int64 = 3

    static let v1Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at_ms INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS categories (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 80),
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            lifecycle TEXT NOT NULL DEFAULT 'active'
                CHECK(lifecycle IN ('active','trashing','trashed','purging'))
        );
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS ux_category_active_name
            ON categories(lower(name)) WHERE lifecycle='active';
        """,
        """
        CREATE TABLE IF NOT EXISTS assets (
            id TEXT PRIMARY KEY,
            sha256 TEXT NOT NULL UNIQUE,
            relative_path TEXT NOT NULL UNIQUE,
            media_type TEXT NOT NULL,
            byte_size INTEGER NOT NULL CHECK(byte_size >= 0),
            width INTEGER,
            height INTEGER,
            created_at_ms INTEGER NOT NULL,
            storage_state TEXT NOT NULL DEFAULT 'available'
                CHECK(storage_state IN ('available','quarantined','deleting'))
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS frames (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
            current_revision_id TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0 CHECK(is_favorite IN (0,1)),
            is_built_in INTEGER NOT NULL DEFAULT 0 CHECK(is_built_in IN (0,1)),
            validation_status TEXT NOT NULL DEFAULT 'unconfigured'
                CHECK(validation_status IN ('unconfigured','ready','invalid')),
            lifecycle TEXT NOT NULL DEFAULT 'active'
                CHECK(lifecycle IN ('active','trashing','trashed','purging')),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS ix_frames_category ON frames(category_id,lifecycle);",
        "CREATE INDEX IF NOT EXISTS ix_frames_updated ON frames(updated_at_ms);",
        """
        CREATE TABLE IF NOT EXISTS frame_revisions (
            id TEXT PRIMARY KEY,
            frame_id TEXT NOT NULL REFERENCES frames(id) ON DELETE CASCADE,
            revision_no INTEGER NOT NULL CHECK(revision_no >= 1),
            canvas_width INTEGER NOT NULL CHECK(canvas_width BETWEEN 256 AND 8192),
            canvas_height INTEGER NOT NULL CHECK(canvas_height BETWEEN 256 AND 8192),
            background_asset_id TEXT REFERENCES assets(id),
            foreground_asset_id TEXT REFERENCES assets(id),
            background_color TEXT NOT NULL DEFAULT '#FFFFFFFF',
            background_placement TEXT NOT NULL DEFAULT 'aspect_fill',
            foreground_placement TEXT NOT NULL DEFAULT 'aspect_fit',
            geometry_version INTEGER NOT NULL DEFAULT 1,
            created_at_ms INTEGER NOT NULL,
            UNIQUE(frame_id,revision_no)
        );
        """,
        "CREATE INDEX IF NOT EXISTS ix_frame_revisions_frame ON frame_revisions(frame_id);",
        """
        CREATE TABLE IF NOT EXISTS frame_slots (
            id TEXT PRIMARY KEY,
            frame_revision_id TEXT NOT NULL REFERENCES frame_revisions(id) ON DELETE CASCADE,
            capture_index INTEGER NOT NULL CHECK(capture_index BETWEEN 1 AND 12),
            x REAL NOT NULL, y REAL NOT NULL,
            width REAL NOT NULL CHECK(width > 0),
            height REAL NOT NULL CHECK(height > 0),
            rotation_degrees REAL NOT NULL DEFAULT 0,
            z_order INTEGER NOT NULL,
            mask_type TEXT NOT NULL CHECK(mask_type IN ('rectangle','rounded_rectangle','ellipse')),
            corner_radius REAL NOT NULL DEFAULT 0 CHECK(corner_radius >= 0),
            default_crop_mode TEXT NOT NULL DEFAULT 'auto_face'
                CHECK(default_crop_mode IN ('fill','fit','auto_face')),
            UNIQUE(frame_revision_id,z_order)
        );
        """,
        "CREATE INDEX IF NOT EXISTS ix_frame_slots_revision ON frame_slots(frame_revision_id,capture_index);",
        """
        CREATE TABLE IF NOT EXISTS presets (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            is_system INTEGER NOT NULL DEFAULT 0 CHECK(is_system IN (0,1)),
            parameters_json TEXT NOT NULL,
            parameter_version INTEGER NOT NULL DEFAULT 1,
            lifecycle TEXT NOT NULL DEFAULT 'active'
                CHECK(lifecycle IN ('active','trashing','trashed','purging')),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS ux_presets_active_name
            ON presets(lower(name)) WHERE lifecycle='active';
        """,
        """
        CREATE TABLE IF NOT EXISTS frame_snapshots (
            id TEXT PRIMARY KEY,
            source_frame_id TEXT,
            source_frame_revision_id TEXT,
            snapshot_json TEXT NOT NULL,
            snapshot_hash TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            status TEXT NOT NULL CHECK(status IN
                ('draft','in_progress','paused','reviewable','completed','trashed','purging')),
            active_frame_snapshot_id TEXT NOT NULL REFERENCES frame_snapshots(id),
            required_capture_count INTEGER NOT NULL CHECK(required_capture_count BETWEEN 1 AND 12),
            current_capture_index INTEGER NOT NULL DEFAULT 1 CHECK(current_capture_index BETWEEN 1 AND 13),
            capture_mode TEXT NOT NULL CHECK(capture_mode IN ('automatic','manual')),
            camera_id TEXT,
            session_defaults_json TEXT NOT NULL,
            revision_no INTEGER NOT NULL DEFAULT 1,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            completed_at_ms INTEGER
        );
        """,
        "CREATE INDEX IF NOT EXISTS ix_sessions_status_updated ON sessions(status,updated_at_ms DESC);",
        """
        CREATE TABLE IF NOT EXISTS session_shots (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            capture_index INTEGER NOT NULL CHECK(capture_index BETWEEN 1 AND 12),
            current_photo_revision_id TEXT,
            UNIQUE(session_id,capture_index)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS photo_revisions (
            id TEXT PRIMARY KEY,
            shot_id TEXT NOT NULL REFERENCES session_shots(id) ON DELETE CASCADE,
            revision_no INTEGER NOT NULL CHECK(revision_no >= 1),
            relative_path TEXT NOT NULL UNIQUE,
            sha256 TEXT NOT NULL,
            width INTEGER NOT NULL CHECK(width > 0),
            height INTEGER NOT NULL CHECK(height > 0),
            orientation INTEGER NOT NULL,
            codec TEXT NOT NULL,
            color_profile TEXT,
            capture_request_id TEXT NOT NULL UNIQUE,
            captured_at_ms INTEGER NOT NULL,
            state TEXT NOT NULL DEFAULT 'available'
                CHECK(state IN ('available','corrupt','quarantined')),
            UNIQUE(shot_id,revision_no)
        );
        """,
        "CREATE INDEX IF NOT EXISTS ix_photo_revisions_shot ON photo_revisions(shot_id,revision_no DESC);",
        """
        CREATE TABLE IF NOT EXISTS photo_adjustments (
            photo_revision_id TEXT PRIMARY KEY REFERENCES photo_revisions(id) ON DELETE CASCADE,
            overrides_json TEXT NOT NULL,
            parameter_version INTEGER NOT NULL DEFAULT 1,
            updated_at_ms INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS slot_placements (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            frame_snapshot_id TEXT NOT NULL REFERENCES frame_snapshots(id),
            snapshot_slot_id TEXT NOT NULL,
            crop_mode TEXT NOT NULL CHECK(crop_mode IN ('fill','fit','auto_face')),
            scale REAL NOT NULL CHECK(scale > 0),
            offset_x REAL NOT NULL,
            offset_y REAL NOT NULL,
            manual_override INTEGER NOT NULL DEFAULT 0 CHECK(manual_override IN (0,1)),
            updated_at_ms INTEGER NOT NULL,
            UNIQUE(session_id,frame_snapshot_id,snapshot_slot_id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS export_records (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            session_revision_no INTEGER NOT NULL,
            format TEXT NOT NULL CHECK(format IN ('jpeg','png')),
            filename TEXT NOT NULL,
            destination_display_path TEXT,
            destination_bookmark_id TEXT,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            quality INTEGER,
            sha256 TEXT,
            status TEXT NOT NULL CHECK(status IN ('preparing','writing','success','failed')),
            created_at_ms INTEGER NOT NULL,
            completed_at_ms INTEGER
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS category_restore_links (
            category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
            frame_id TEXT NOT NULL REFERENCES frames(id) ON DELETE CASCADE,
            detached_at_ms INTEGER NOT NULL,
            PRIMARY KEY(category_id,frame_id)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS trash_items (
            id TEXT PRIMARY KEY,
            root_type TEXT NOT NULL CHECK(root_type IN ('session','frame','category','preset','photo')),
            root_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            deleted_at_ms INTEGER NOT NULL,
            expires_at_ms INTEGER NOT NULL,
            original_parent_id TEXT,
            estimated_bytes INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL CHECK(status IN ('trashed','restoring','purging','purge_failed')),
            last_error TEXT,
            UNIQUE(root_type,root_id)
        );
        """,
        "CREATE INDEX IF NOT EXISTS ix_trash_expiry ON trash_items(status,expires_at_ms);",
        """
        CREATE TABLE IF NOT EXISTS operation_intents (
            id TEXT PRIMARY KEY,
            op_type TEXT NOT NULL,
            root_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            last_error TEXT
        );
        """,
        "CREATE INDEX IF NOT EXISTS ix_intents_recovery ON operation_intents(status,updated_at_ms);",
        """
        CREATE TABLE IF NOT EXISTS app_bookmarks (
            id TEXT PRIMARY KEY,
            purpose TEXT NOT NULL,
            bookmark_blob BLOB NOT NULL,
            display_path TEXT,
            updated_at_ms INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS asset_references (
            asset_id TEXT NOT NULL REFERENCES assets(id),
            owner_type TEXT NOT NULL CHECK(owner_type IN
               ('frame_revision','frame_snapshot','preset','other_internal')),
            owner_id TEXT NOT NULL,
            purpose TEXT NOT NULL,
            PRIMARY KEY(asset_id,owner_type,owner_id,purpose)
        );
        """,
        "CREATE INDEX IF NOT EXISTS ix_asset_ref_owner ON asset_references(owner_type,owner_id);"
    ]

    public static func migrate(_ db: SQLiteDatabase, backupFolder: URL? = nil) throws {
        let now = Time.nowMs()
        try db.run("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at_ms INTEGER NOT NULL
            );
            """)
        let rows = try db.query("SELECT version FROM schema_migrations ORDER BY version")
        let applied = rows.compactMap { row -> Int64? in
            if case .int(let v) = row["version"] ?? .int(0) { return v }
            return nil
        }

        // Kiểm tra phiên bản kho mới hơn app (§3.1.1 — chặn ghi để tránh hỏng dữ liệu)
        if let maxApplied = applied.max(), maxApplied > currentVersion {
            throw AppError.databaseCorrupt(
                "Kho dữ liệu có phiên bản schema v\(maxApplied) mới hơn phiên bản ứng dụng hiện tại (v\(currentVersion)). Vui lòng cập nhật Open Photobooth để mở kho này."
            )
        }

        if applied.isEmpty {
            // Cài đặt schema ban đầu v1 + v2 + v3 hoàn chỉnh (mới hoàn toàn)
            try db.withTransaction { tx in
                for stmt in v1Statements { try tx.run(stmt) }
                try tx.run("INSERT INTO schema_migrations(version, applied_at_ms) VALUES(?, ?)",
                           [.int(1), .int(now)])
                // Áp dụng v2 vào bảng sessions
                try tx.run("ALTER TABLE sessions ADD COLUMN frame_name_at_capture TEXT")
                try tx.run("ALTER TABLE sessions ADD COLUMN countdown_seconds INTEGER NOT NULL DEFAULT 3")
                try tx.run("ALTER TABLE sessions ADD COLUMN intermission_seconds INTEGER NOT NULL DEFAULT 2")
                try tx.run("INSERT INTO schema_migrations(version, applied_at_ms) VALUES(?, ?)",
                           [.int(2), .int(now)])
                try tx.run("INSERT INTO schema_migrations(version, applied_at_ms) VALUES(?, ?)",
                           [.int(3), .int(now)])
            }
            return
        }

        // Migration v1 -> v2 (§3.1.2)
        if !applied.contains(2) {
            // Tạo bản sao an toàn trước migration nếu DB nằm trên đĩa
            if db.databasePath != ":memory:" {
                let dbURL = URL(fileURLWithPath: db.databasePath)
                let backupDir = backupFolder ?? dbURL.deletingLastPathComponent().appendingPathComponent("backups")
                try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let backupURL = backupDir.appendingPathComponent("openphotobooth-pre-migration-v2-\(now).sqlite")
                do {
                    try db.backup(to: backupURL.path)
                    Log.store.info("Đã sao lưu an toàn trước migration v1->v2: \(backupURL.path, privacy: .public)")
                } catch {
                    throw AppError.ioFailure("Không tạo được bản sao lưu an toàn trước migration v1->v2: \(error.localizedDescription)")
                }
            }

            try db.withTransaction { tx in
                // Bổ sung các cột mới v2
                try tx.run("ALTER TABLE sessions ADD COLUMN frame_name_at_capture TEXT")
                try tx.run("ALTER TABLE sessions ADD COLUMN countdown_seconds INTEGER NOT NULL DEFAULT 3")
                try tx.run("ALTER TABLE sessions ADD COLUMN intermission_seconds INTEGER NOT NULL DEFAULT 2")

                // Điền tên khung lúc chụp từ frame_snapshots -> frames
                let sessionRows = try tx.query("SELECT id, active_frame_snapshot_id FROM sessions")
                for sRow in sessionRows {
                    let sID = sRow["id"].stringValue
                    let snapshotID = sRow["active_frame_snapshot_id"].stringValue
                    let snapRows = try tx.query("SELECT source_frame_id FROM frame_snapshots WHERE id=?", [.text(snapshotID)])
                    var resolvedName = ""
                    if let fID = snapRows.first?["source_frame_id"].stringValue, !fID.isEmpty {
                        let fRows = try tx.query("SELECT name FROM frames WHERE id=?", [.text(fID)])
                        if let name = fRows.first?["name"].stringValue, !name.isEmpty {
                            resolvedName = name
                        }
                    }
                    try tx.run("UPDATE sessions SET frame_name_at_capture=? WHERE id=?", [.text(resolvedName), .text(sID)])
                }

                try tx.run("INSERT INTO schema_migrations(version, applied_at_ms) VALUES(?, ?)",
                           [.int(2), .int(now)])
            }
        }

        // Migration v2 -> v3 (§2.3 item 4: mở rộng trash_items.root_type với 'photo')
        if !applied.contains(3) {
            // 1. Tạo bản sao an toàn trước migration v3 nếu DB nằm trên đĩa
            if db.databasePath != ":memory:" {
                let dbURL = URL(fileURLWithPath: db.databasePath)
                let backupDir = backupFolder ?? dbURL.deletingLastPathComponent().appendingPathComponent("backups")
                try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let backupURL = backupDir.appendingPathComponent("openphotobooth-pre-migration-v3-\(now).sqlite")
                do {
                    try db.backup(to: backupURL.path)
                    Log.store.info("Đã sao lưu an toàn trước migration v2->v3: \(backupURL.path, privacy: .public)")
                } catch {
                    throw AppError.ioFailure("Không tạo được bản sao lưu an toàn trước migration v2->v3: \(error.localizedDescription)")
                }
            }

            // Ghi nhận số lượng bản ghi trước migration để đối chiếu
            let preSessions = (try? db.query("SELECT COUNT(*) c FROM sessions").first?["c"]?.intValue) ?? 0
            let prePhotos = (try? db.query("SELECT COUNT(*) c FROM photo_revisions").first?["c"]?.intValue) ?? 0
            let preAdjustments = (try? db.query("SELECT COUNT(*) c FROM photo_adjustments").first?["c"]?.intValue) ?? 0
            let preSnapshots = (try? db.query("SELECT COUNT(*) c FROM frame_snapshots").first?["c"]?.intValue) ?? 0
            let preTrash = (try? db.query("SELECT COUNT(*) c FROM trash_items").first?["c"]?.intValue) ?? 0

            // 2. Thực thi migration trong transaction duy nhất
            try db.withTransaction { tx in
                try tx.run("""
                    CREATE TABLE IF NOT EXISTS trash_items_v3 (
                        id TEXT PRIMARY KEY,
                        root_type TEXT NOT NULL CHECK(root_type IN ('session','frame','category','preset','photo')),
                        root_id TEXT NOT NULL,
                        display_name TEXT NOT NULL,
                        deleted_at_ms INTEGER NOT NULL,
                        expires_at_ms INTEGER NOT NULL,
                        original_parent_id TEXT,
                        estimated_bytes INTEGER NOT NULL DEFAULT 0,
                        status TEXT NOT NULL CHECK(status IN ('trashed','restoring','purging','purge_failed')),
                        last_error TEXT,
                        UNIQUE(root_type,root_id)
                    )
                """)
                try tx.run("""
                    INSERT INTO trash_items_v3(id, root_type, root_id, display_name, deleted_at_ms,
                        expires_at_ms, original_parent_id, estimated_bytes, status, last_error)
                    SELECT id, root_type, root_id, display_name, deleted_at_ms,
                        expires_at_ms, original_parent_id, estimated_bytes, status, last_error
                    FROM trash_items
                """)
                try tx.run("DROP TABLE trash_items")
                try tx.run("ALTER TABLE trash_items_v3 RENAME TO trash_items")
                try tx.run("CREATE INDEX IF NOT EXISTS ix_trash_expiry ON trash_items(status,expires_at_ms)")

                try tx.run("INSERT INTO schema_migrations(version, applied_at_ms) VALUES(?, ?)",
                           [.int(3), .int(now)])
            }

            // 3. Kiểm tra tính toàn vẹn cơ sở dữ liệu và số lượng đối tượng sau migration (§2.3 item 4)
            let integrityRows = try db.query("PRAGMA integrity_check")
            let integrityResult = integrityRows.first?["integrity_check"]?.stringValue ?? ""
            guard integrityResult.lowercased() == "ok" else {
                throw AppError.databaseCorrupt("PRAGMA integrity_check thất bại sau migration v3: \(integrityResult)")
            }

            let postSessions = (try? db.query("SELECT COUNT(*) c FROM sessions").first?["c"]?.intValue) ?? 0
            let postPhotos = (try? db.query("SELECT COUNT(*) c FROM photo_revisions").first?["c"]?.intValue) ?? 0
            let postAdjustments = (try? db.query("SELECT COUNT(*) c FROM photo_adjustments").first?["c"]?.intValue) ?? 0
            let postSnapshots = (try? db.query("SELECT COUNT(*) c FROM frame_snapshots").first?["c"]?.intValue) ?? 0
            let postTrash = (try? db.query("SELECT COUNT(*) c FROM trash_items").first?["c"]?.intValue) ?? 0

            guard postSessions == preSessions,
                  postPhotos == prePhotos,
                  postAdjustments == preAdjustments,
                  postSnapshots == preSnapshots,
                  postTrash == preTrash else {
                throw AppError.databaseCorrupt("Dữ liệu không khớp sau migration v3: sessions \(preSessions)->\(postSessions), photos \(prePhotos)->\(postPhotos), trash \(preTrash)->\(postTrash)")
            }
        }
    }
}
