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

    public init(db: SQLiteDatabase, layout: FileLayout,
                sessions: SessionRepository, trashRepo: TrashRepository) {
        self.db = db; self.layout = layout
        self.sessions = sessions; self.trashRepo = trashRepo
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
                          codec: String, colorProfile: String?) async throws -> PhotoRevision {
        // Bước 0: kiểm tra dung lượng ghi được trước khi tạo intent (E-STO-01)
        guard Self.isWritable(layout.rootURL) else { throw AppError.diskFull }
        let revisionID = IDFactory.new()
        let ext = codec == "jpeg" ? "jpg" : "png"
        let intendedRel = "Sessions/\(sessionID)/Originals/\(revisionID).\(ext)"
        let tempRel = intendedRel + ".partial"

        // Bước 1: intent trong DB transaction (prepared)
        let payloadObj = SavePhotoIntentPayload(sessionID: sessionID, captureIndex: captureIndex,
                                                requestID: requestID,
                                                intendedRelativePath: intendedRel,
                                                tempRelativePath: tempRel,
                                                sha256: Hashing.sha256Hex(payloadData))
        let payloadJSON = String(data: try JSONEncoder().encode(payloadObj), encoding: .utf8) ?? "{}"
        let intent = try trashRepo.createIntent(opType: "savePhoto", rootID: sessionID, payloadJSON: payloadJSON)

        do {
            // Bước 2: ghi *.partial trong cùng filesystem nội bộ
            let tempURL = try layout.absoluteURL(forRelativePath: tempRel)
            try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payloadData.write(to: tempURL, options: .atomic)
            try trashRepo.updateIntent(id: intent.id, status: .filesStaged)

            // Bước 3: kiểm tra decode tối thiểu + checksum + size > 0
            guard payloadData.count > 0 else { throw AppError.ioFailure("Payload rỗng") }
            guard let src = CGImageSourceCreateWithData(payloadData as CFData, nil),
                  CGImageSourceGetCount(src) > 0 else {
                throw AppError.ioFailure("Ảnh không decode được")
            }
            let actualSHA = Hashing.sha256Hex(fileURL: tempURL) ?? ""
            guard actualSHA == payloadObj.sha256 else { throw AppError.ioFailure("Checksum không khớp") }

            // Bước 4: atomic rename → final (không ghi đè file có sẵn)
            let finalURL = try layout.absoluteURL(forRelativePath: intendedRel)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                throw AppError.ioFailure("File đích đã tồn tại: \(Log.safePath(intendedRel))")
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
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

    static func isWritable(_ url: URL) -> Bool {
        let probe = url.appendingPathComponent(".probe-\(UUID().uuidString)")
        let ok = FileManager.default.createFile(atPath: probe.path, contents: Data("1".utf8))
        try? FileManager.default.removeItem(at: probe)
        return ok
    }
}
