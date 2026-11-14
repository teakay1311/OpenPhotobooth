import XCTest
@testable import OpenPhotobooth

final class OpenPhotoboothTests: XCTestCase {
    func testGeometryCalculations() {
        let rect = RectN(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(rect.isFinite)
        XCTAssertTrue(rect.isPositive)
        let pixel = rect.pixelRect(canvasWidth: 1000, canvasHeight: 1000)
        XCTAssertEqual(pixel.origin.x, 100)
        XCTAssertEqual(pixel.origin.y, 100)
        XCTAssertEqual(pixel.size.width, 800)
        XCTAssertEqual(pixel.size.height, 800)
        XCTAssertTrue(FrameGeometry.isSlotInsideCanvas(rect, rotationDegrees: 0, canvasWidth: 1000, canvasHeight: 1000))
    }

    func testIDFactoryAndTime() {
        let id1 = IDFactory.new()
        let id2 = IDFactory.new()
        XCTAssertNotEqual(id1, id2)
        XCTAssertTrue(IDFactory.isValid(id1))
        
        let now = Time.nowMs()
        XCTAssertGreaterThan(now, 0)
        let expires = TrashPolicy.expiresAt(deletedAtMs: now)
        XCTAssertEqual(expires, now + TrashPolicy.retentionMs)
        let remaining = TrashPolicy.remainingText(expiresAtMs: expires, nowMs: now)
        XCTAssertTrue(remaining.contains("30 ngày"))
    }

    func testSQLiteDatabaseInMemory() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        let integrity = db.integrityCheck()
        XCTAssertNil(integrity) // nil means "ok"
        let fk = db.foreignKeyCheck()
        XCTAssertTrue(fk.isEmpty)
    }

    func testSchemaMigrationV1toV2() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try Schema.migrate(db)
        
        // Verify schema version is 2
        let rows = try db.query("SELECT MAX(version) as mv FROM schema_migrations")
        let maxVersion = rows.first?["mv"]?.int64Value
        XCTAssertEqual(maxVersion, 2)
        
        // Check columns in sessions table
        let tableInfo = try db.query("PRAGMA table_info(sessions)")
        let colNames = tableInfo.map { $0["name"].stringValue }
        XCTAssertTrue(colNames.contains("frame_name_at_capture"))
        XCTAssertTrue(colNames.contains("countdown_seconds"))
        XCTAssertTrue(colNames.contains("intermission_seconds"))
    }

    func testOperationCoordinatorLocks() throws {
        let coord = OperationCoordinator()
        let sessionID = "sess-test-123"
        
        // Acquire lock
        let token = try coord.acquire(key: "session:\(sessionID)", reason: "Chụp ảnh")
        XCTAssertTrue(coord.isSessionBusy(sessionID).busy)
        
        // Acquire conflicting lock should fail
        XCTAssertThrowsError(try coord.acquire(key: "session:\(sessionID)", reason: "Xóa rác")) { error in
            guard let appErr = error as? AppError, case .busy = appErr else {
                XCTFail("Expected AppError.busy, got \(error)")
                return
            }
        }
        
        // Release lock
        token.release()
        XCTAssertFalse(coord.isSessionBusy(sessionID).busy)
        
        // Can re-acquire after release
        let token2 = try coord.acquire(key: "session:\(sessionID)", reason: "Đổi khung")
        XCTAssertTrue(coord.isSessionBusy(sessionID).busy)
        token2.release()
    }

    func testExportFilenameSanitization() {
        let dirty = "My/Photo:Booth\\Awesome*Name?"
        let clean = ExportService.sanitizedFilenameBase(dirty)
        XCTAssertFalse(clean.contains("/"))
        XCTAssertFalse(clean.contains(":"))
        XCTAssertFalse(clean.contains("\\"))
        XCTAssertFalse(clean.contains("*"))
        XCTAssertFalse(clean.contains("?"))
    }

    func testTrashRetentionCalculation() {
        let now = Time.nowMs()
        let deletedAt = now - (TrashPolicy.retentionMs + 10_000)
        let isExpired = now >= deletedAt + TrashPolicy.retentionMs
        XCTAssertTrue(isExpired)
    }

    func testMagicBytesValidation() {
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertTrue(FramesViewModel.validateMagicBytes(pngHeader))
        
        let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertTrue(FramesViewModel.validateMagicBytes(jpegHeader))
        
        let invalidData = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertFalse(FramesViewModel.validateMagicBytes(invalidData))
    }
}
