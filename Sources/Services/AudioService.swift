import Foundation
import AppKit

/// AudioService (§5.6, §17.1): phát sự kiện âm thanh, không điều khiển camera, không dùng microphone.
/// Dùng NSSound hệ thống để tránh tài nguyên bản quyền; tôn trọng volume/mute của macOS.
@MainActor
public final class AudioService: ObservableObject {
    private let settings: SettingsStore
    private let playback: ((String, Float) -> Void)?

    public init(settings: SettingsStore, playback: ((String, Float) -> Void)? = nil) {
        self.settings = settings
        self.playback = playback
    }

    private var sounds: [String: NSSound] = [:]

    public enum Event {
        case countdownTick(last: Bool)   // tick từng giây cuối nếu bật (§5.6)
        case shutter
        case completed
        case warning
        case preview(String)             // Nghe thử trong Cài đặt
    }

    private func play(_ name: String) {
        guard settings.soundEnabled else { return }
        if let playback {
            playback(name, Float(settings.soundVolume) / 100.0)
            return
        }
        #if !PHOTOBOOTH_QA_HOST
        if let s = sounds[name] {
            s.volume = Float(settings.soundVolume) / 100.0
            s.play()
            return
        }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = Float(settings.soundVolume) / 100.0
        sounds[name] = sound
        sound.play()
        #endif
    }

    public func handle(_ event: Event) {
        switch event {
        case .countdownTick(let last):
            if last {
                if settings.soundCountdown { play("Tink") }
            } else if settings.soundCountdown {
                play("Pop")
            }
        case .shutter:
            if settings.soundShutter { play("Submarine") }
        case .completed:
            if settings.soundFinish { play("Glass") }
        case .warning:
            play("Sosumi")
        case .preview(let name):
            play(name)
        }
    }
}
