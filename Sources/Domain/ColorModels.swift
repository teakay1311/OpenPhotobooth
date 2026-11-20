import Foundation

// MARK: - Mô hình màu §8, §16.4

extension Double {
    func safeColorClamped(_ range: ClosedRange<Double>) -> Double {
        guard self.isFinite else { return 0 }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Thang nội bộ versioned: exposure/contrast/highlights/shadows/saturation/temperature/tint/vibrance ∈ -1..1, sharpness ∈ 0..1.
/// KHÔNG lưu thang UI -100..100 vào JSON xử lý thấp.
public struct ColorParameterSet: Codable, Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var saturation: Double
    public var temperature: Double
    public var tint: Double
    public var vibrance: Double
    public var sharpness: Double

    public init(exposure: Double = 0, contrast: Double = 0,
                highlights: Double = 0, shadows: Double = 0,
                saturation: Double = 0, temperature: Double = 0,
                tint: Double = 0, vibrance: Double = 0,
                sharpness: Double = 0) {
        self.exposure = exposure.safeColorClamped(-1...1)
        self.contrast = contrast.safeColorClamped(-1...1)
        self.highlights = highlights.safeColorClamped(-1...1)
        self.shadows = shadows.safeColorClamped(-1...1)
        self.saturation = saturation.safeColorClamped(-1...1)
        self.temperature = temperature.safeColorClamped(-1...1)
        self.tint = tint.safeColorClamped(-1...1)
        self.vibrance = vibrance.safeColorClamped(-1...1)
        self.sharpness = sharpness.safeColorClamped(0...1)
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, saturation, temperature, tint, vibrance, sharpness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let exp = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0.0
        let con = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0.0
        let high = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0.0
        let shad = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0.0
        let sat = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0.0
        let temp = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.0
        let tnt = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0.0
        let vib = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0.0
        let sharp = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0.0
        self.init(exposure: exp, contrast: con, highlights: high, shadows: shad,
                  saturation: sat, temperature: temp, tint: tnt, vibrance: vib, sharpness: sharp)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(tint, forKey: .tint)
        try c.encode(vibrance, forKey: .vibrance)
        try c.encode(sharpness, forKey: .sharpness)
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
    public var highlights: Double?
    public var shadows: Double?
    public var saturation: Double?
    public var temperature: Double?
    public var tint: Double?
    public var vibrance: Double?
    public var sharpness: Double?

    public init(exposure: Double? = nil, contrast: Double? = nil,
                highlights: Double? = nil, shadows: Double? = nil,
                saturation: Double? = nil, temperature: Double? = nil,
                tint: Double? = nil, vibrance: Double? = nil,
                sharpness: Double? = nil) {
        self.exposure = exposure?.safeColorClamped(-1...1)
        self.contrast = contrast?.safeColorClamped(-1...1)
        self.highlights = highlights?.safeColorClamped(-1...1)
        self.shadows = shadows?.safeColorClamped(-1...1)
        self.saturation = saturation?.safeColorClamped(-1...1)
        self.temperature = temperature?.safeColorClamped(-1...1)
        self.tint = tint?.safeColorClamped(-1...1)
        self.vibrance = vibrance?.safeColorClamped(-1...1)
        self.sharpness = sharpness?.safeColorClamped(0...1)
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, saturation, temperature, tint, vibrance, sharpness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.exposure = try c.decodeIfPresent(Double.self, forKey: .exposure)?.safeColorClamped(-1...1)
        self.contrast = try c.decodeIfPresent(Double.self, forKey: .contrast)?.safeColorClamped(-1...1)
        self.highlights = try c.decodeIfPresent(Double.self, forKey: .highlights)?.safeColorClamped(-1...1)
        self.shadows = try c.decodeIfPresent(Double.self, forKey: .shadows)?.safeColorClamped(-1...1)
        self.saturation = try c.decodeIfPresent(Double.self, forKey: .saturation)?.safeColorClamped(-1...1)
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)?.safeColorClamped(-1...1)
        self.tint = try c.decodeIfPresent(Double.self, forKey: .tint)?.safeColorClamped(-1...1)
        self.vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance)?.safeColorClamped(-1...1)
        self.sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness)?.safeColorClamped(0...1)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(exposure, forKey: .exposure)
        try c.encodeIfPresent(contrast, forKey: .contrast)
        try c.encodeIfPresent(highlights, forKey: .highlights)
        try c.encodeIfPresent(shadows, forKey: .shadows)
        try c.encodeIfPresent(saturation, forKey: .saturation)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(tint, forKey: .tint)
        try c.encodeIfPresent(vibrance, forKey: .vibrance)
        try c.encodeIfPresent(sharpness, forKey: .sharpness)
    }

    public var isEmpty: Bool {
        exposure == nil && contrast == nil && highlights == nil && shadows == nil &&
        saturation == nil && temperature == nil && tint == nil && vibrance == nil && sharpness == nil
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
    public var explicitNoPreset: Bool?

    public init(presetID: String? = nil, presetParameters: ColorParameterSet? = nil,
                presetIntensity: Double? = nil, color: ColorOverrides? = nil,
                skinSmooth: Double? = nil, photoRotation: Double? = nil,
                explicitNoPreset: Bool? = nil) {
        self.presetID = presetID
        self.presetParameters = presetParameters
        self.presetIntensity = presetIntensity
        self.color = color
        self.skinSmooth = skinSmooth
        self.photoRotation = photoRotation
        self.explicitNoPreset = explicitNoPreset
    }

    private enum CodingKeys: String, CodingKey {
        case presetID, presetParameters, presetIntensity, color, skinSmooth, photoRotation, explicitNoPreset
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(presetID, forKey: .presetID)
        try values.encodeIfPresent(presetParameters, forKey: .presetParameters)
        try values.encodeIfPresent(presetIntensity, forKey: .presetIntensity)
        try values.encodeIfPresent(color, forKey: .color)
        try values.encodeIfPresent(photoRotation, forKey: .photoRotation)
        try values.encodeIfPresent(explicitNoPreset, forKey: .explicitNoPreset)
    }

    public var isEmpty: Bool {
        presetID == nil && presetParameters == nil && presetIntensity == nil
            && (color?.isEmpty ?? true) && photoRotation == nil && explicitNoPreset == nil
    }
}

/// Bộ chỉnh màu được sao chép trong bộ nhớ ứng dụng (§4.1).
public struct CopiedColorAdjustments: Codable, Equatable, Sendable {
    public let presetID: String?
    public let presetParameters: ColorParameterSet
    public let presetIntensity: Double
    public let isExplicitNoPreset: Bool
    public let color: ColorParameterSet

    public init(presetID: String?, presetParameters: ColorParameterSet, presetIntensity: Double, isExplicitNoPreset: Bool, color: ColorParameterSet) {
        self.presetID = presetID
        self.presetParameters = presetParameters
        self.presetIntensity = presetIntensity
        self.isExplicitNoPreset = isExplicitNoPreset
        self.color = color
    }
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
    public var rotation: Int?
    public var smartFace: Bool?
    public var autoFacePlacementVersion: Int? = nil
    public var plannedCaptureCount: Int? = nil
    public var appliedFrameName: String? = nil
    public var selectionCaptureCount: Int? = nil
    public var selectedCaptureOrder: [Int]? = nil

    public init(parameterVersion: Int = 1, presetID: String?, presetName: String?,
                presetResolvedParameters: ColorParameterSet, presetIntensity: Double,
                color: ColorParameterSet, skinSmooth: Double, outputMirror: Bool,
                rotation: Int? = 0, smartFace: Bool? = true) {
        self.parameterVersion = parameterVersion
        self.presetID = presetID
        self.presetName = presetName
        self.presetResolvedParameters = presetResolvedParameters
        self.presetIntensity = presetIntensity.clamped(0...1)
        self.color = color
        self.skinSmooth = skinSmooth.clamped(0...1)
        self.outputMirror = outputMirror
        self.rotation = rotation
        self.smartFace = smartFace
    }

    private enum CodingKeys: String, CodingKey {
        case parameterVersion, presetID, presetName, presetResolvedParameters
        case presetIntensity, color, skinSmooth, outputMirror, rotation, smartFace
        case selectionCaptureCount, selectedCaptureOrder, plannedCaptureCount, appliedFrameName, autoFacePlacementVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parameterVersion = try c.decodeIfPresent(Int.self, forKey: .parameterVersion) ?? 1
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        presetName = try c.decodeIfPresent(String.self, forKey: .presetName)
        presetResolvedParameters = try c.decodeIfPresent(ColorParameterSet.self, forKey: .presetResolvedParameters) ?? .neutral
        presetIntensity = (try c.decodeIfPresent(Double.self, forKey: .presetIntensity) ?? 1.0).clamped(0...1)
        color = try c.decodeIfPresent(ColorParameterSet.self, forKey: .color) ?? .neutral
        skinSmooth = (try c.decodeIfPresent(Double.self, forKey: .skinSmooth) ?? 0.0).clamped(0...1)
        outputMirror = try c.decodeIfPresent(Bool.self, forKey: .outputMirror) ?? false
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        smartFace = try c.decodeIfPresent(Bool.self, forKey: .smartFace) ?? true
        autoFacePlacementVersion = try c.decodeIfPresent(Int.self, forKey: .autoFacePlacementVersion)
        plannedCaptureCount = try c.decodeIfPresent(Int.self, forKey: .plannedCaptureCount)
        appliedFrameName = try c.decodeIfPresent(String.self, forKey: .appliedFrameName)
        selectionCaptureCount = try c.decodeIfPresent(Int.self, forKey: .selectionCaptureCount)
        selectedCaptureOrder = try c.decodeIfPresent([Int].self, forKey: .selectedCaptureOrder)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(parameterVersion, forKey: .parameterVersion)
        try values.encodeIfPresent(presetID, forKey: .presetID)
        try values.encodeIfPresent(presetName, forKey: .presetName)
        try values.encode(presetResolvedParameters, forKey: .presetResolvedParameters)
        try values.encode(presetIntensity, forKey: .presetIntensity)
        try values.encode(color, forKey: .color)
        try values.encode(outputMirror, forKey: .outputMirror)
        try values.encodeIfPresent(rotation, forKey: .rotation)
        try values.encodeIfPresent(smartFace, forKey: .smartFace)
        try values.encodeIfPresent(autoFacePlacementVersion, forKey: .autoFacePlacementVersion)
        try values.encodeIfPresent(plannedCaptureCount, forKey: .plannedCaptureCount)
        try values.encodeIfPresent(appliedFrameName, forKey: .appliedFrameName)
        try values.encodeIfPresent(selectionCaptureCount, forKey: .selectionCaptureCount)
        try values.encodeIfPresent(selectedCaptureOrder, forKey: .selectedCaptureOrder)
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
        let baseRotation = Double(defaults.rotation ?? 0)
        guard let o = override else {
            return ResolvedPhotoParams(presetID: defaults.presetID,
                                       presetParameters: defaults.presetResolvedParameters,
                                       presetIntensity: defaults.presetIntensity,
                                       color: defaults.color,
                                       skinSmooth: defaults.skinSmooth,
                                       photoRotation: baseRotation)
        }
        let isExplicitNone = o.explicitNoPreset == true
        let resolvedPresetID = isExplicitNone ? nil : (o.presetID ?? defaults.presetID)
        let resolvedPresetParams = isExplicitNone ? .neutral : (o.presetParameters ?? defaults.presetResolvedParameters)
        let resolvedIntensity = isExplicitNone ? 0.0 : (o.presetIntensity ?? defaults.presetIntensity)

        let c = o.color
        let mergedColor = ColorParameterSet(
            exposure: c?.exposure ?? defaults.color.exposure,
            contrast: c?.contrast ?? defaults.color.contrast,
            highlights: c?.highlights ?? defaults.color.highlights,
            shadows: c?.shadows ?? defaults.color.shadows,
            saturation: c?.saturation ?? defaults.color.saturation,
            temperature: c?.temperature ?? defaults.color.temperature,
            tint: c?.tint ?? defaults.color.tint,
            vibrance: c?.vibrance ?? defaults.color.vibrance,
            sharpness: c?.sharpness ?? defaults.color.sharpness)
        return ResolvedPhotoParams(
            presetID: resolvedPresetID,
            presetParameters: resolvedPresetParams,
            presetIntensity: resolvedIntensity,
            color: mergedColor,
            skinSmooth: o.skinSmooth ?? defaults.skinSmooth,
            photoRotation: o.photoRotation ?? baseRotation)
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
