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
}
