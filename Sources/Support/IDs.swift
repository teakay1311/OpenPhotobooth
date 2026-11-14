import Foundation

/// Định danh chuỗi UUID canonical cho mọi entity (§16.1).
public typealias EntityID = String

public enum IDFactory {
    public static func new() -> EntityID { UUID().uuidString.lowercased() }
    public static func isValid(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }
}

/// Thời gian lưu milliseconds UTC (§16.1). Display dùng locale máy.
public enum Time {
    public static func nowMs(_ clock: AppClock = SystemClock.shared) -> Int64 {
        Int64(clock.now().timeIntervalSince1970 * 1000.0)
    }
    public static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000.0) }
}

/// Trash giữ tối đa 30 × 24 giờ (§12.1): expireAt = deletedAt + 2_592_000_000 ms.
public enum TrashPolicy {
    public static let retentionMs: Int64 = 2_592_000_000
    public static func expiresAt(deletedAtMs: Int64) -> Int64 { deletedAtMs + retentionMs }
    /// Làm tròn lên khi hiển thị "Còn ... ngày/giờ" (§2.5).
    public static func remainingText(expiresAtMs: Int64, nowMs: Int64) -> String {
        let delta = expiresAtMs - nowMs
        if delta <= 0 { return "Đang chờ dọn" }
        let days = delta / 86_400_000
        if days >= 1 {
            // Làm tròn LÊN: còn phần dư của ngày thì đếm thêm 1 ngày
            let hasRemainder = delta % 86_400_000 > 0
            return hasRemainder ? "Còn \(days + 1) ngày" : "Còn \(days) ngày"
        }
        let h = (delta + 3_600_000 - 1) / 3_600_000
        return "Còn \(h) giờ"
    }
}

/// Giới hạn tài nguyên khung (§6.1).
public enum ResourceLimits {
    public static let canvasMin: Int = 256
    public static let canvasMax: Int = 8192
    public static let maxMegapixels: Double = 40
    public static let maxAssetBytes: Int = 100 * 1024 * 1024
    public static let maxCaptureIndices: Int = 12
    public static let maxSlots: Int = 24
    public static let maxPackUncompressedBytes: Int = 1_000_000_000
    public static let maxPackEntries: Int = 3000
}
