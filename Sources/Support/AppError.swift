import Foundation

/// Danh mục lỗi chuẩn §18.1 — mỗi lỗi có thông báo tiếng Việt + hành động gợi ý.
public enum AppError: Error, LocalizedError, Equatable {
    // Camera
    case cameraPermissionNotDetermined      // E-CAM-01
    case cameraPermissionDenied             // E-CAM-02
    case noCamera                           // E-CAM-03
    case cameraBusy                         // E-CAM-04
    case continuityDisconnected             // E-CAM-05
    case stillUnsupported                   // E-CAM-06
    case cameraConfigurationFailed(String)  // E-CAM-* phụ
    // Capture
    case duplicateShutterRequest            // E-CAP-01
    case captureTimeout                     // E-CAP-02
    case captureCancelled                   // E-CAP-03 (sleep/wake)
    case frameLockedDuringCapture           // E-CAP-04
    // Frame
    case frameFileCorrupt                   // E-FRM-01
    case frameUnconfigured                  // E-FRM-02
    case invalidSlotGeometry([String])      // E-FRM-03 — mã vấn đề F-VAL
    case missingFrameAssets                 // E-FRM-04
    case unsafeFramePack(String)            // E-FRM-05
    case resourceLimitExceeded(String)
    // Face
    case noFaceFound                        // E-FACE-01
    // Storage
    case diskFull                           // E-STO-01
    case externalFolderPermissionLost       // E-STO-02
    case ioFailure(String)                  // E-STO-03
    // Export
    case exportFailed(String)               // E-EXP-01
    case exportPreviewChanged
    case exportHistoryNotSaved(ExportedFile)
    case exportLocationUnconfirmed
    case exportFolderChanged
    case exportFileExists                   // E-EXP-02
    case notEnoughPhotos(missing: Int)      // thiếu ảnh khi đổi khung / xuất
    // Share
    case shareCancelled                     // E-SHR-01 (không phải lỗi UI)
    // Trash
    case restoreConflict(String)            // E-TRS-01
    case restoreMissingBytes                // E-TRS-02
    case purgeFailed(String)                // E-TRS-03
    case clockChangedAnomaly                // E-TRS-04
    case trashExpired(String)               // E-TRS-05
    // Concurrency / Coordination
    case busy(String)                       // E-COR-01
    // DB
    case databaseCorrupt(String)            // E-DB-01
    case conflict(expected: Int, actual: Int)
    case invalidState(String)
    case notFound(String)
    case duplicateName(String)

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .cameraPermissionNotDetermined: return "Open Photobooth cần quyền camera để chụp ảnh."
        case .cameraPermissionDenied: return "Camera chưa được cho phép."
        case .noCamera: return "Không tìm thấy camera."
        case .cameraBusy: return "Camera đang bận hoặc tạm gián đoạn."
        case .continuityDisconnected: return "Kết nối với camera iPhone đã ngắt."
        case .stillUnsupported: return "Camera chỉ hỗ trợ chụp ở độ phân giải video."
        case .cameraConfigurationFailed(let d): return "Không cấu hình được camera: \(d)"
        case .duplicateShutterRequest: return "Đang có lượt chụp đang xử lý."
        case .captureTimeout: return "Không chụp được ảnh này."
        case .captureCancelled: return "Phiên đã được tạm dừng."
        case .frameLockedDuringCapture: return "Phiên đang giữ khung hiện tại. Bạn có thể đổi khung trong Xem và chỉnh ảnh hoặc chuẩn bị phiên mới."
        case .frameFileCorrupt: return "Không đọc được tệp khung."
        case .frameUnconfigured: return "Khung chưa có vị trí đặt ảnh."
        case .invalidSlotGeometry(let issues): return "Ô ảnh không hợp lệ: \(issues.joined(separator: "; "))"
        case .missingFrameAssets: return "Thiếu tài nguyên của khung."
        case .unsafeFramePack(let reason): return "Gói khung không hợp lệ hoặc không an toàn: \(reason)"
        case .resourceLimitExceeded(let d): return "Quá giới hạn tài nguyên: \(d)"
        case .noFaceFound: return "Không tìm thấy khuôn mặt."
        case .diskFull: return "Không đủ dung lượng để lưu ảnh."
        case .externalFolderPermissionLost: return "Không thể lưu vào thư mục đã chọn."
        case .ioFailure(let d): return "Lỗi đọc/ghi tệp: \(d)"
        case .exportFailed(let d): return "Không thể xuất ảnh. Phiên chụp vẫn an toàn. (\(d))"
        case .exportPreviewChanged: return "Phiên đã thay đổi. Hãy kiểm tra xem trước mới và bấm Xuất lại."
        case .exportHistoryNotSaved(let file): return "Đã lưu \(file.url.lastPathComponent), chưa ghi được lịch sử xuất."
        case .exportLocationUnconfirmed: return "Ảnh đã được ghi nhưng không thể xác nhận vị trí. Hãy kiểm tra thư mục xuất trước khi thử lại."
        case .exportFolderChanged: return "Thư mục xuất đã thay đổi. Hãy chọn lại thư mục."
        case .exportFileExists: return "Tên file đã tồn tại."
        case .notEnoughPhotos(let missing): return "Thiếu \(missing) ảnh — hãy chụp bổ sung."
        case .shareCancelled: return "Đã hủy chia sẻ."
        case .restoreConflict(let name): return "Tên đã tồn tại: \(name)."
        case .restoreMissingBytes: return "Không thể khôi phục đầy đủ."
        case .purgeFailed(let d): return "Có mục chưa xóa được: \(d)"
        case .clockChangedAnomaly: return "Đồng hồ hệ thống thay đổi bất thường — tạm dừng tự dọn rác."
        case .trashExpired(let d): return "Mục đã quá hạn lưu trữ: \(d)"
        case .busy(let d): return "Tài nguyên đang bận: \(d)"
        case .databaseCorrupt(let d): return "Không thể mở thư viện an toàn. (\(d))"
        case .conflict: return "Dữ liệu đã thay đổi ở nơi khác. Vui lòng tải lại và thử lại."
        case .invalidState(let d): return "Trạng thái không hợp lệ: \(d)"
        case .notFound(let d): return "Không tìm thấy: \(d)"
        case .duplicateName(let d): return d
        }
    }

    public var code: String {
        switch self {
        case .cameraPermissionNotDetermined: return "E-CAM-01"
        case .cameraPermissionDenied: return "E-CAM-02"
        case .noCamera: return "E-CAM-03"
        case .cameraBusy: return "E-CAM-04"
        case .continuityDisconnected: return "E-CAM-05"
        case .stillUnsupported: return "E-CAM-06"
        case .cameraConfigurationFailed: return "E-CAM-07"
        case .duplicateShutterRequest: return "E-CAP-01"
        case .captureTimeout: return "E-CAP-02"
        case .captureCancelled: return "E-CAP-03"
        case .frameLockedDuringCapture: return "E-CAP-04"
        case .frameFileCorrupt: return "E-FRM-01"
        case .frameUnconfigured: return "E-FRM-02"
        case .invalidSlotGeometry: return "E-FRM-03"
        case .missingFrameAssets: return "E-FRM-04"
        case .unsafeFramePack: return "E-FRM-05"
        case .resourceLimitExceeded: return "E-FRM-06"
        case .noFaceFound: return "E-FACE-01"
        case .diskFull: return "E-STO-01"
        case .externalFolderPermissionLost: return "E-STO-02"
        case .ioFailure: return "E-STO-03"
        case .exportFailed: return "E-EXP-01"
        case .exportFileExists: return "E-EXP-02"
        case .exportPreviewChanged: return "E-EXP-03"
        case .exportHistoryNotSaved: return "E-EXP-04"
        case .exportLocationUnconfirmed: return "E-EXP-05"
        case .exportFolderChanged: return "E-EXP-06"
        case .notEnoughPhotos: return "E-CAP-05"
        case .shareCancelled: return "E-SHR-01"
        case .restoreConflict: return "E-TRS-01"
        case .restoreMissingBytes: return "E-TRS-02"
        case .purgeFailed: return "E-TRS-03"
        case .clockChangedAnomaly: return "E-TRS-04"
        case .trashExpired: return "E-TRS-05"
        case .busy: return "E-COR-01"
        case .databaseCorrupt: return "E-DB-01"
        case .conflict: return "E-GEN-01"
        case .invalidState: return "E-GEN-02"
        case .notFound: return "E-GEN-03"
        case .duplicateName: return "E-GEN-04"
        }
    }
}

extension String: @retroactive Error {}
