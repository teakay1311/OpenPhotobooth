import Foundation
import ImageIO

/// RecoveryService (§10.3, §5.7): reconcile intents/files/DB sau launch.
/// KHÔNG tự dọn file ảnh nguồn khi chưa phân loại; KHÔNG tự chụp sau launch (I-10).
public final class RecoveryService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let layout: FileLayout
    private let sessions: SessionRepository
    private let trashRepo: TrashRepository
    private let clock: AppClock
    private let trashService: TrashService

    public init(db: SQLiteDatabase, layout: FileLayout, sessions: SessionRepository,
                trashRepo: TrashRepository, clock: AppClock = SystemClock.shared,
                trashService: TrashService? = nil) {
        self.db = db; self.layout = layout; self.sessions = sessions
        self.trashRepo = trashRepo; self.clock = clock
        self.trashService = trashService ?? TrashService(db: db, layout: layout, trashRepo: trashRepo,
                                                         assets: AssetStore(db: db, layout: layout), clock: clock)
    }

    public struct Report: Equatable {
        public var committedIntents: Int = 0
        public var quarantinedFiles: Int = 0
        public var orphanedFiles: Int = 0
        public var recoverableSessions: Int = 0
        public var issues: [String] = []

        public var hasProblems: Bool { !issues.isEmpty || quarantinedFiles > 0 || orphanedFiles > 0 }
    }

    public func runOnLaunch() async -> Report {
        var report = Report()
        do {
            let trash = try trashService.recoverOperations()
            report = await reconcileIntents(excluding: trash.excludedSessions)
            report.issues += trash.issues
            await quarantineStrayPartials(into: &report, excluding: trash.excludedSessions)
            await scanOrphanFiles(into: &report, excluding: trash.excludedSessions)
        } catch {
            report.issues.append("Không thể xác minh vị trí dữ liệu Thùng rác: \(error.localizedDescription)")
        }
        await checkDatabase(into: &report)
        await countRecoverableSessions(into: &report)
        Log.recovery.info("Recovery: intents=\(report.committedIntents) quarantine=\(report.quarantinedFiles) orphan=\(report.orphanedFiles) sessions=\(report.recoverableSessions)")
        return report
    }

    /// Intent `prepared/files_staged/files_promoted` của savePhoto:
    /// - final file tồn tại + checksum khớp → hoàn tất commit (idempotent theo requestID)
    /// - chỉ có .partial → quarantine, không đánh dấu ảnh hoàn tất
    func reconcileIntents(excluding sessionsToSkip: Set<String> = []) async -> Report {
        var report = Report()
        guard let intents = try? trashRepo.pendingIntents(opType: "savePhoto") else { return report }
        for intent in intents where !sessionsToSkip.contains(intent.rootID) {
            guard let data = intent.payloadJSON.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(SafetySaveService.SavePhotoIntentPayload.self, from: data) else {
                try? trashRepo.updateIntent(id: intent.id, status: .failed, error: "Payload không đọc được")
                continue
            }
            let finalURL = (try? layout.absoluteURL(forRelativePath: payload.intendedRelativePath))
            let tempURL = try? layout.absoluteURL(forRelativePath: payload.tempRelativePath)
            // DB commit trước khi file tồn tại là không hợp lệ (§10.2): nếu DB đã có revision
            // với requestID này → intent đã commit; đảm bảo file khớp.
            let captureFirst = (try? sessions.getSession(id: payload.sessionID))?.defaults.plannedCaptureCount != nil
            let existing = (try? db.query("""
                SELECT pr.id, pr.relative_path, pr.sha256, sh.session_id, sh.capture_index
                FROM photo_revisions pr JOIN session_shots sh ON sh.id=pr.shot_id
                WHERE pr.capture_request_id=?
                """, [.text(payload.requestID)])) ?? []
            if let row = existing.first {
                if captureFirst {
                    do {
                        guard intent.rootID == payload.sessionID,
                              row["session_id"].stringValue == payload.sessionID,
                              row["capture_index"]?.intValue == payload.captureIndex,
                              row["sha256"].stringValue == payload.sha256,
                              let revision = try sessions.getPhotoRevision(id: row["id"].stringValue) else {
                            throw AppError.invalidState("Thông tin ảnh đã ghi không khớp lượt chụp")
                        }
                        _ = try sessions.verifiedPhotoImage(revision)
                        try trashRepo.updateIntent(id: intent.id, status: .committed)
                        report.committedIntents += 1
                    } catch {
                        let message = "Không xác minh được ảnh đã ghi của lượt \(payload.captureIndex)"
                        report.issues.append(message)
                        try? trashRepo.updateIntent(id: intent.id, status: .failed, error: message)
                    }
                    continue
                }
                // Đã commit trước crash: kiểm tra file tồn tại
                let rel = row["relative_path"].stringValue
                if let url = try? layout.absoluteURL(forRelativePath: rel),
                   FileManager.default.fileExists(atPath: url.path) {
                    try? trashRepo.updateIntent(id: intent.id, status: .committed)
                    report.committedIntents += 1
                } else {
                    report.issues.append("Ảnh đã ghi DB nhưng file thiếu: \(Log.safePath(rel))")
                    try? trashRepo.updateIntent(id: intent.id, status: .rollbackRequired, error: "File thiếu sau commit")
                }
                continue
            }
            if let fURL = finalURL, FileManager.default.fileExists(atPath: fURL.path) {
                // File hoàn chỉnh chưa commit → hợp thức hóa nếu checksum khớp, không xóa (§10.2)
                let sha = Hashing.sha256Hex(fileURL: fURL) ?? ""
                if sha == payload.sha256 {
                    do {
                        // Schema v1: width/height NOT NULL CHECK(width > 0)/(height > 0) — phải decode thật.
                        // Tránh fallback (width=0, height=0) vi phạm CHECK.
                        let fileData = try Data(contentsOf: fURL)
                        let (decodedW, decodedH) = AssetStore.imageDimensions(of: fileData)
                        if captureFirst && (decodedW == nil || decodedH == nil ||
                                            ImageNormalizer.uprightImage(data: fileData) == nil) {
                            quarantine(url: fURL, report: &report, reason: "Không giải mã được ảnh đã ghi")
                            try trashRepo.updateIntent(id: intent.id, status: .failed, error: "Ảnh không giải mã được")
                            continue
                        }
                        let width = decodedW ?? 1
                        let height = decodedH ?? 1
                        // Đọc EXIF orientation để giữ orientation gốc (nếu có).
                        let orientation: Int = {
                            guard let src = CGImageSourceCreateWithData(fileData as CFData, nil),
                                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 1 }
                            return props[kCGImagePropertyOrientation] as? Int ?? 1
                        }()
                        _ = try sessions.commitPhoto(
                            sessionID: payload.sessionID, captureIndex: payload.captureIndex,
                            requestID: payload.requestID,
                            relativePath: payload.intendedRelativePath, sha256: payload.sha256,
                            width: width, height: height, orientation: orientation,
                            codec: payload.intendedRelativePath.hasSuffix(".png") ? "png" : "jpeg",
                            colorProfile: nil)
                        try trashRepo.updateIntent(id: intent.id, status: .committed)
                        report.committedIntents += 1
                        Log.recovery.info("Recovery: hợp thức hóa shot đã ghi file (\(payload.requestID.prefix(8), privacy: .public))")
                    } catch {
                        report.issues.append("Không hợp thức hóa được intent \(intent.id.prefix(8)): \(error.localizedDescription)")
                    }
                } else {
                    quarantine(url: fURL, report: &report, reason: "Checksum lệch với intent")
                    try? trashRepo.updateIntent(id: intent.id, status: .failed, error: "Checksum lệch")
                }
                continue
            }
            // Chỉ có .partial → quarantine
            if let tURL = tempURL, FileManager.default.fileExists(atPath: tURL.path) {
                quarantine(url: tURL, report: &report, reason: ".partial sau crash")
            }
            try? trashRepo.updateIntent(id: intent.id, status: .failed, error: "Không đủ dữ liệu để hoàn tất")
        }
        return report
    }

    /// .partial không có intent → quarantine (không xóa âm thầm).
    func quarantineStrayPartials(into report: inout Report, excluding sessionsToSkip: Set<String>) async {
        let fm = FileManager.default
        guard let sessionDirs = try? fm.contentsOfDirectory(at: layout.sessionsDir, includingPropertiesForKeys: nil) else { return }
        for sessionDir in sessionDirs where !sessionsToSkip.contains(sessionDir.lastPathComponent) {
            let originals = sessionDir.appendingPathComponent("Originals")
            guard let files = try? fm.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "partial" {
                quarantine(url: file, report: &report, reason: ".partial không có intent")
            }
        }
    }

    /// File orphan: có trong thư mục session nhưng không có record DB.
    /// Không xóa hàng loạt tự động (§10.3) — chuyển quarantine và báo cáo.
    func scanOrphanFiles(into report: inout Report, excluding sessionsToSkip: Set<String>) async {
        let fm = FileManager.default
        guard let sessionDirs = try? fm.contentsOfDirectory(at: layout.sessionsDir, includingPropertiesForKeys: nil) else { return }
        for sessionDir in sessionDirs where !sessionsToSkip.contains(sessionDir.lastPathComponent) {
            let sessionID = sessionDir.lastPathComponent
            let originals = sessionDir.appendingPathComponent("Originals")
            guard let files = try? fm.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let name = file.lastPathComponent
                if name.hasSuffix(".partial") { continue }
                let rows = (try? db.query("SELECT COUNT(*) c FROM photo_revisions WHERE relative_path LIKE ?", [.text("%/\(sessionID)/Originals/\(name)")])) ?? []
                let count = rows.first?["c"]?.intValue ?? 1
                if count == 0 {
                    quarantine(url: file, report: &report, reason: "File orphan không có record DB")
                    report.orphanedFiles += 1
                }
            }
        }
    }

    private func quarantine(url: URL, report: inout Report, reason: String) {
        let dest = layout.quarantineDir.appendingPathComponent("\(Int(Time.nowMs()))-\(url.lastPathComponent)")
        do {
            try FileManager.default.createDirectory(at: layout.quarantineDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: dest)
            report.quarantinedFiles += 1
            Log.recovery.warning("Quarantine: \(Log.safePath(url.path), privacy: .public) — \(reason, privacy: .public)")
        } catch {
            report.issues.append("Không quarantine được \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func checkDatabase(into report: inout Report) async {
        do {
            if let problem = try db.integrityCheck() {
                report.issues.append("integrity_check: \(problem)")
            }
        } catch {
            report.issues.append("Không chạy được integrity_check: \(error.localizedDescription)")
        }
        do {
            let violations = try db.foreignKeyCheck()
            if !violations.isEmpty {
                report.issues.append("foreign_key_check: \(violations.count) vi phạm")
            }
        } catch {
            report.issues.append("Không chạy được foreign_key_check: \(error.localizedDescription)")
        }
    }

    func countRecoverableSessions(into report: inout Report) async {
        let rows = (try? db.query("SELECT COUNT(*) c FROM sessions WHERE status IN ('draft','in_progress','paused')")) ?? []
        report.recoverableSessions = rows.first?["c"]?.intValue ?? 0
        // Crash khi state transient → khôi phục dạng paused (§5.1), kiểm tra ảnh cuối đã ghi hoàn toàn
        _ = try? sessions.convertTransientToPaused()
    }
}
