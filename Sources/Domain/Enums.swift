import Foundation

// MARK: - Enums chuẩn §16.1

public enum FrameValidationStatus: String, Codable, Sendable, CaseIterable {
    case unconfigured, ready, invalid
}

public enum FrameLifecycle: String, Codable, Sendable {
    case active, trashing, trashed, purging
}

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case draft
    case inProgress = "in_progress"
    case paused
    case reviewable
    case completed
    case trashed
    case purging

    public var isIncomplete: Bool { self == .draft || self == .inProgress || self == .paused || self == .reviewable }
    public var isRecoverable: Bool { self == .inProgress || self == .paused }
}

public enum TrashStatus: String, Codable, Sendable {
    case trashed, restoring, purging
    case purgeFailed = "purge_failed"
}

public enum OperationStatus: String, Codable, Sendable {
    case prepared
    case filesStaged = "files_staged"
    case filesPromoted = "files_promoted"
    case committed
    case rollbackRequired = "rollback_required"
    case failed
}

public enum CaptureMode: String, Codable, Sendable, CaseIterable {
    case automatic, manual

    public var label: String { self == .automatic ? "Tự động" : "Thủ công" }
}

public enum MaskType: String, Codable, Sendable, CaseIterable {
    case rectangle
    case roundedRectangle = "rounded_rectangle"
    case ellipse

    public var label: String {
        switch self {
        case .rectangle: return "Chữ nhật"
        case .roundedRectangle: return "Bo góc"
        case .ellipse: return "Ellipse"
        }
    }
}

public enum CropMode: String, Codable, Sendable, CaseIterable {
    case fill, fit
    case autoFace = "auto_face"

    public var label: String {
        switch self {
        case .fill: return "Fill (lấp đầy)"
        case .fit: return "Fit (vừa khung)"
        case .autoFace: return "Auto Face"
        }
    }
}

public enum ExportImageFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png

    public var label: String { self == .jpeg ? "JPG" : "PNG" }
    public var fileExtension: String { self == .jpeg ? "jpg" : "png" }
}

public enum ExportStatus: String, Codable, Sendable {
    case preparing, writing, success, failed
}

public enum AssetKind: String, Codable, Sendable {
    case frameBackground = "frame_background"
    case frameForeground = "frame_foreground"
    case frameThumbnail = "frame_thumbnail"
    case sourcePhoto = "source_photo"
    case renderCache = "render_cache"
    case exportTemp = "export_temp"
}

public enum PhotoRevisionState: String, Codable, Sendable {
    case available, corrupt, quarantined
}

public enum CameraPermissionState: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
}

public enum CameraKind: String, Codable, Sendable {
    case builtIn, usb, continuity, other
}

/// Cách đặt lớp background/foreground vào canvas (§7.2).
public enum PlacementKind: String, Codable, Sendable, CaseIterable {
    case aspectFill = "aspect_fill"
    case aspectFit = "aspect_fit"
    case stretchToCanvas = "stretch"
    case fillCrop = "fill_crop"

    public var label: String {
        switch self {
        case .aspectFill: return "Fill khung (có crop)"
        case .aspectFit: return "Fit + nền trong suốt"
        case .stretchToCanvas: return "Kéo đầy canvas"
        case .fillCrop: return "Fill và crop"
        }
    }
}

public enum TrashRootType: String, Codable, Sendable, CaseIterable {
    case session, frame, category, preset

    public var label: String {
        switch self {
        case .session: return "Phiên"
        case .frame: return "Khung"
        case .category: return "Danh mục"
        case .preset: return "Preset"
        }
    }
}

public enum AppearanceMode: String, Codable, CaseIterable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: return "Theo hệ thống"
        case .light: return "Sáng"
        case .dark: return "Tối"
        }
    }
}

public enum SkinSmoothPreset: String, CaseIterable {
    case off, light, medium, strong
    public var strength: Double {
        switch self {
        case .off: return 0
        case .light: return 0.20
        case .medium: return 0.40
        case .strong: return 0.65
        }
    }
    public var label: String {
        switch self {
        case .off: return "Tắt"
        case .light: return "Nhẹ"
        case .medium: return "Vừa"
        case .strong: return "Mạnh"
        }
    }
}

public enum FullscreenStep: Equatable {
    case welcome
    case selectFrame
    case live
    case review
    case finish
}

public enum ScreenRoute: Hashable {
    case capture
    case frames
    case library
    case trash
    case settings
    case frameEditor(frameID: String?)
    case review(sessionID: String)
}
