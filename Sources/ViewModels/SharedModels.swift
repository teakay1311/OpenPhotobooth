import Foundation
import SwiftUI

/// Toast không nghiêm trọng, tự ẩn (§2.1) — không thay trạng thái lưu thực tế.
public struct ToastMessage: Equatable, Hashable {
    public enum Kind: Equatable, Hashable { case success, info, warning }
    public var text: String
    public var kind: Kind

    public init(text: String, kind: Kind = .success) {
        self.text = text
        self.kind = kind
    }
}

/// Quy định chọn/thiết lập khung trước capture (§2.2 Frame Picker).
public struct FrameCardModel: Identifiable, Equatable {
    public var id: String { frame.id }
    public var frame: Frame
    public var thumbnail: Data?
    public var slotCount: Int

    public init(frame: Frame, thumbnail: Data?, slotCount: Int) {
        self.frame = frame; self.thumbnail = thumbnail; self.slotCount = slotCount
    }
}

public struct SessionCardModel: Identifiable, Equatable, Sendable {
    public var id: String { card.id }
    public var card: SessionRepository.SessionCard
    public var frameName: String
    public var preview: Data?
    public var formattedDate: String

    public init(card: SessionRepository.SessionCard, frameName: String, preview: Data?, formattedDate: String) {
        self.card = card; self.frameName = frameName; self.preview = preview; self.formattedDate = formattedDate
    }
}

/// Nhóm dữ liệu chờ của CaptureViewModel.
public struct CaptureSetup: Equatable {
    public var selectedFrame: Frame?
    public var requiredCount: Int = 0
    public init() {}
}
