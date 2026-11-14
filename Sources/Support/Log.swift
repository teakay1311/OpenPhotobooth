import Foundation
import os

/// Ghi log kỹ thuật — KHÔNG chứa bytes ảnh, thumbnail hay tọa độ khuôn mặt gắn danh tính (§18.3).
public enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "vn.openphotobooth.app"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let camera = Logger(subsystem: subsystem, category: "camera")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let trash = Logger(subsystem: subsystem, category: "trash")
    public static let render = Logger(subsystem: subsystem, category: "render")
    public static let export = Logger(subsystem: subsystem, category: "export")
    public static let recovery = Logger(subsystem: subsystem, category: "recovery")
    public static let pack = Logger(subsystem: subsystem, category: "pack")

    /// Rút gọn đường dẫn nội bộ để log không lộ cấu trúc đầy đủ.
    public static func safePath(_ path: String) -> String {
        guard path.count > 60 else { return path }
        return "…" + path.suffix(48)
    }
}
