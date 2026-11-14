import Foundation

// MARK: - Mô hình màu §8, §16.4

/// Thang nội bộ versioned: exposure/contrast/saturation/temperature/tint ∈ -1..1, sharpness ∈ 0..1.
/// KHÔNG lưu thang UI -100..100 vào JSON xử lý thấp.
public struct ColorParameterSet: Codable, Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var temperature: Double
    public var tint: Double
    public var sharpness: Double

    public init(exposure: Double = 0, contrast: Double = 0, saturation: Double = 0,
                temperature: Double = 0, tint: Double = 0, sharpness: Double = 0) {
        self.exposure = exposure.clamped(-1...1)
        self.contrast = contrast.clamped(-1...1)
        self.saturation = saturation.clamped(-1...1)
        self.temperature = temperature.clamped(-1...1)
        self.tint = tint.clamped(-1...1)
        self.sharpness = sharpness.clamped(0...1)
    }

    public static let neutral = ColorParameterSet()

    public static let natural = ColorParameterSet()
    public static let bright = ColorParameterSet(exposure: 0.22, contrast: 0.15, saturation: 0.14, temperature: 0.04, tint: 0, sharpness: 0.18)
    public static let warm = ColorParameterSet(exposure: 0.06, contrast: 0.08, saturation: 0.10, temperature: 0.32, tint: 0.05, sharpness: 0.10)
    public static let cool = ColorParameterSet(exposure: 0.05, contrast: 0.10, saturation: 0.06, temperature: -0.30, tint: -0.04, sharpness: 0.12)
    public static let vintage = ColorParameterSet(exposure: -0.04, contrast: -0.10, saturation: -0.18, temperature: 0.24, tint: 0.12, sharpness: 0.05)
    public static let film = ColorParameterSet(exposure: 0.02, contrast: 0.20, saturation: -0.08, temperature: 0.10, tint: -0.03, sharpness: 0.22)
    public static let blackWhite = ColorParameterSet(exposure: 0.03, contrast: 0.24, saturation: -1.0, temperature: 0, tint: 0, sharpness: 0.15)
    public static let soft = ColorParameterSet(exposure: 0.10, contrast: -0.12, saturation: 0.05, temperature: 0.08, tint: 0.03, sharpness: 0)
}

extension Comparable {
    func clamped(_ range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Override một phần: nil = kế thừa; giá trị hiện diện là override thật (kể cả 0) (§8.3).
public struct ColorOverrides: Codable, Equatable, Sendable {
    public var exposure: Double?
    public var contrast: Double?
    public var saturation: Double?
    public var temperature: Double?
    public var tint: Double?
    public var sharpness: Double?

    public init(exposure: Double? = nil, contrast: Double? = nil, saturation: Double? = nil,
                temperature: Double? = nil, tint: Double? = nil, sharpness: Double? = nil) {
        self.exposure = exposure; self.contrast = contrast; self.saturation = saturation
        self.temperature = temperature; self.tint = tint; self.sharpness = sharpness
    }

    public var isEmpty: Bool {
        self == ColorOverrides()
    }
}

/// PhotoOverride là map một phần trên CaptureIndex + currentPhotoRevision (§8.3).
public struct PhotoOverride: Codable, Equatable, Sendable {
    public var presetID: String?
    public var presetParameters: ColorParameterSet?
    public var presetIntensity: Double?
    public var color: ColorOverrides?
    public var skinSmooth: Double?
    public var photoRotation: Double?

    public init(presetID: String? = nil, presetParameters: ColorParameterSet? = nil,
                presetIntensity: Double? = nil, color: ColorOverrides? = nil,
                skinSmooth: Double? = nil, photoRotation: Double? = nil) {
        self.presetID = presetID
        self.presetParameters = presetParameters
        self.presetIntensity = presetIntensity
        self.color = color
        self.skinSmooth = skinSmooth
        self.photoRotation = photoRotation
    }

    public var isEmpty: Bool { self == PhotoOverride() }
}

/// Snapshot mặc định của phiên: freeze AppDefault tại thời điểm tạo phiên (§8.3).
/// JSON khớp §16.4.
public struct SessionDefaultsSnapshot: Codable, Equatable, Sendable {
    public var parameterVersion: Int
    public var presetID: String?
    public var presetName: String?
    public var presetResolvedParameters: ColorParameterSet
    public var presetIntensity: Double
    public var color: ColorParameterSet
    public var skinSmooth: Double
    public var outputMirror: Bool

    public init(parameterVersion: Int = 1, presetID: String?, presetName: String?,
                presetResolvedParameters: ColorParameterSet, presetIntensity: Double,
                color: ColorParameterSet, skinSmooth: Double, outputMirror: Bool) {
        self.parameterVersion = parameterVersion
        self.presetID = presetID
        self.presetName = presetName
        self.presetResolvedParameters = presetResolvedParameters
        self.presetIntensity = presetIntensity.clamped(0...1)
        self.color = color
        self.skinSmooth = skinSmooth.clamped(0...1)
        self.outputMirror = outputMirror
    }
}

/// Kết quả đã merge: AppDefaultAtCreation → SessionDefault → PhotoOverride, theo từng thuộc tính (§8.3).
public struct ResolvedPhotoParams: Equatable, Sendable {
    public var presetID: String?
    public var presetParameters: ColorParameterSet
    public var presetIntensity: Double
    public var color: ColorParameterSet
    public var skinSmooth: Double
    public var photoRotation: Double

    public static func resolve(defaults: SessionDefaultsSnapshot, override: PhotoOverride?) -> ResolvedPhotoParams {
        guard let o = override else {
            return ResolvedPhotoParams(presetID: defaults.presetID,
                                       presetParameters: defaults.presetResolvedParameters,
                                       presetIntensity: defaults.presetIntensity,
                                       color: defaults.color,
                                       skinSmooth: defaults.skinSmooth,
                                       photoRotation: 0)
        }
        let c = o.color
        let mergedColor = ColorParameterSet(
            exposure: c?.exposure ?? defaults.color.exposure,
            contrast: c?.contrast ?? defaults.color.contrast,
            saturation: c?.saturation ?? defaults.color.saturation,
            temperature: c?.temperature ?? defaults.color.temperature,
            tint: c?.tint ?? defaults.color.tint,
            sharpness: c?.sharpness ?? defaults.color.sharpness)
        return ResolvedPhotoParams(
            presetID: o.presetID ?? defaults.presetID,
            presetParameters: o.presetParameters ?? defaults.presetResolvedParameters,
            presetIntensity: o.presetIntensity ?? defaults.presetIntensity,
            color: mergedColor,
            skinSmooth: o.skinSmooth ?? defaults.skinSmooth,
            photoRotation: o.photoRotation ?? 0)
    }
}

// MARK: - 8 preset built-in (§8.2) — ID nội bộ giữ ổn định

public struct BuiltinPreset {
    public let id: String
    public let nameVN: String
    public let parameters: ColorParameterSet

    public static let all: [BuiltinPreset] = [
        BuiltinPreset(id: "natural", nameVN: "Tự nhiên", parameters: .natural),
        BuiltinPreset(id: "bright", nameVN: "Tươi sáng", parameters: .bright),
        BuiltinPreset(id: "warm", nameVN: "Ấm", parameters: .warm),
        BuiltinPreset(id: "cool", nameVN: "Lạnh", parameters: .cool),
        BuiltinPreset(id: "vintage", nameVN: "Hoài cổ", parameters: .vintage),
        BuiltinPreset(id: "film", nameVN: "Phim", parameters: .film),
        BuiltinPreset(id: "blackwhite", nameVN: "Đen trắng", parameters: .blackWhite),
        BuiltinPreset(id: "soft", nameVN: "Dịu nhẹ", parameters: .soft)
    ]

    public static func byID(_ id: String) -> BuiltinPreset? {
        all.first { $0.id == id }
    }
}
