import Foundation
import CoreGraphics
import ImageIO

/// SafetySaveService — bắt buộc, không có nút tắt (§10.1).
/// Phương án ghi ảnh + DB không nguyên tử: write-ahead intent + staging + reconciliation (§10.2).
public final class SafetySaveService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let layout: FileLayout
    private let sessions: SessionRepository
    private let trashRepo: TrashRepository
    private let coordinator: OperationCoordinator

    public init(db: SQLiteDatabase, layout: FileLayout,
                sessions: SessionRepository, trashRepo: TrashRepository,
                coordinator: OperationCoordinator = OperationCoordinator.shared) {
        self.db = db; self.layout = layout
        self.sessions = sessions; self.trashRepo = trashRepo
        self.coordinator = coordinator
    }

    struct SavePhotoIntentPayload: Codable {
        var sessionID: String
        var captureIndex: Int
        var requestID: String
        var intendedRelativePath: String
        var tempRelativePath: String
        var sha256: String
    }

    /// Ghi ảnh gốc an toàn theo 7 bước §10.2. Trả về PhotoRevision đã commit.
    public func savePhoto(sessionID: String, captureIndex: Int,
                          payloadData: Data, requestID: String,
                          width: Int, height: Int, orientation: Int,
                          codec: String, colorProfile: String?,
                          parentToken: OperationCoordinator.OperationToken? = nil) async throws -> PhotoRevision {
        // L7: Tái sử dụng OperationCoordinator với khóa nguyên tử session:<id>
        let opToken = try coordinator.acquire(key: "session:\(sessionID)", reason: "SafetySave: saving photo", parentToken: parentToken)
        defer { opToken.release() }

        // L7: Dưới khóa, tải phiên theo ID. Phiên mất, .trashed hoặc .purging bị từ chối trước intent, tệp tạm hoặc tài nguyên đích.
        guard try sessions.activeSession(id: sessionID) != nil else {
            throw AppError.invalidState("Phiên chụp không còn hoạt động")
        }

        let sha = Hashing.sha256Hex(payloadData)
        let committed = try db.query("""
            SELECT pr.id, pr.sha256, sh.session_id, sh.capture_index
            FROM photo_revisions pr JOIN session_shots sh ON sh.id = pr.shot_id
            WHERE pr.capture_request_id=?
            """, [.text(requestID)]).first
        if let row = committed {
            guard row["session_id"].stringValue == sessionID,
                  row["capture_index"]?.intValue == captureIndex,
                  row["sha256"].stringValue == sha,
                  let revision = try sessions.getPhotoRevision(id: row["id"].stringValue),
                  Hashing.sha256Hex(fileURL: try sessions.fileURL(for: revision)) == sha else {
                throw AppError.ioFailure("Không xác minh được ảnh đã lưu của lượt này")
            }
            if let prior = try photoIntent(sessionID: sessionID, requestID: requestID) {
                try trashRepo.updateIntent(id: prior.id, status: .committed)
            }
            return revision
        }

        let intent: OperationIntentRecord
        let payloadObj: SavePhotoIntentPayload
        if let prior = try photoIntent(sessionID: sessionID, requestID: requestID) {
            let saved = try JSONDecoder().decode(SavePhotoIntentPayload.self, from: Data(prior.payloadJSON.utf8))
            guard saved.sessionID == sessionID, saved.captureIndex == captureIndex, saved.sha256 == sha else {
                throw AppError.ioFailure("Yêu cầu ghi ảnh không khớp lượt đang chờ")
            }
            intent = prior
            payloadObj = saved
        } else {
            guard Self.isWritable(layout.rootURL) else { throw AppError.diskFull }
            let ext = codec == "jpeg" ? "jpg" : "png"
            let relative = "Sessions/\(sessionID)/Originals/\(IDFactory.new()).\(ext)"
            payloadObj = SavePhotoIntentPayload(sessionID: sessionID, captureIndex: captureIndex,
                                                requestID: requestID, intendedRelativePath: relative,
                                                tempRelativePath: relative + ".partial", sha256: sha)
            let payloadJSON = String(decoding: try JSONEncoder().encode(payloadObj), as: UTF8.self)
            intent = try trashRepo.createIntent(opType: "savePhoto", rootID: sessionID, payloadJSON: payloadJSON)
        }
        let intendedRel = payloadObj.intendedRelativePath

        do {
            guard !payloadData.isEmpty, let src = CGImageSourceCreateWithData(payloadData as CFData, nil),
                  CGImageSourceGetCount(src) > 0 else { throw AppError.ioFailure("Ảnh không decode được") }
            let finalURL = try layout.absoluteURL(forRelativePath: intendedRel)
            if FileManager.default.fileExists(atPath: finalURL.path),
               Hashing.sha256Hex(fileURL: finalURL) != sha {
                // Chỉ làm lại file của intent chưa commit. Giữ bản lỗi để Recovery có thể đối chiếu.
                let quarantine = layout.quarantineDir.appendingPathComponent(
                    "\(IDFactory.new())-\(finalURL.lastPathComponent)")
                try FileManager.default.moveItem(at: finalURL, to: quarantine)
            }
            if !FileManager.default.fileExists(atPath: finalURL.path) {
                guard Self.isWritable(layout.rootURL) else { throw AppError.diskFull }
                let tempURL = try layout.absoluteURL(forRelativePath: payloadObj.tempRelativePath)
                try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try payloadData.write(to: tempURL, options: .atomic)
                try trashRepo.updateIntent(id: intent.id, status: .filesStaged)
                guard Hashing.sha256Hex(fileURL: tempURL) == sha else {
                    throw AppError.ioFailure("Checksum không khớp")
                }
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
            }
            guard Hashing.sha256Hex(fileURL: finalURL) == sha else {
                throw AppError.ioFailure("Ảnh đã ghi không khớp checksum")
            }
            try trashRepo.updateIntent(id: intent.id, status: .filesPromoted)

            // Bước 5: SQLite transaction tạo revision + pointer + index (idempotent theo requestID)
            let revision = try sessions.commitPhoto(
                sessionID: sessionID, captureIndex: captureIndex, requestID: requestID,
                relativePath: intendedRel, sha256: payloadObj.sha256,
                width: width, height: height, orientation: orientation,
                codec: codec, colorProfile: colorProfile)
            try trashRepo.updateIntent(id: intent.id, status: .committed)

            // Bước 6/7: publish event ở caller; dọn intent cũ để background
            Log.store.info("Shot committed: session=\(sessionID.prefix(8)) index=\(captureIndex) rev=\(revision.revisionNo)")
            return revision
        } catch {
            // Không tăng index; intent về rollback_required để Recovery xử lý (STO-01)
            try? trashRepo.updateIntent(id: intent.id, status: .rollbackRequired, error: error.localizedDescription)
            throw error
        }
    }

    private func photoIntent(sessionID: String, requestID: String) throws -> OperationIntentRecord? {
        let row = try db.query("""
            SELECT id FROM operation_intents
            WHERE op_type='savePhoto' AND root_id=?
              AND json_extract(CASE WHEN json_valid(payload_json) THEN payload_json ELSE '{}' END, '$.requestID')=?
            ORDER BY created_at_ms LIMIT 1
            """, [.text(sessionID), .text(requestID)]).first
        guard let row else { return nil }
        return try trashRepo.getIntent(id: row["id"].stringValue)
    }

    static func isWritable(_ url: URL) -> Bool {
        let probe = url.appendingPathComponent(".probe-\(UUID().uuidString)")
        let ok = FileManager.default.createFile(atPath: probe.path, contents: Data("1".utf8))
        try? FileManager.default.removeItem(at: probe)
        return ok
    }
}
