import ImageIO
import Foundation
import CoreImage
import CoreGraphics

/// ImageNormalizer: chuẩn hóa orientation/flip ở đầu pipeline (§8.4, §4.4).
/// OutputMirror quyết định pixel ảnh nguồn chuẩn hóa; lưu snapshot trong session defaults,
/// không xử lý chồng nhiều lần.
public enum ImageNormalizer {
    /// Decode ảnh upright theo EXIF orientation (ImageIO transform).
    public static func uprightImage(data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h)
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    public static func uprightImage(url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return uprightImage(data: data)
    }

    /// Flip ngang khi session bật OutputMirror (baked một lần duy nhất).
    public static func applyOutputMirror(_ image: CGImage, mirrored: Bool) -> CGImage {
        guard mirrored else { return image }
        let ci = CIImage(cgImage: image).oriented(.upMirrored)
        return CIContextHolder.shared.context.createCGImage(ci, from: ci.extent) ?? image
    }

    /// Áp dụng photo rotation (PhotoOverride.photoRotation, độ clockwise).
    public static func rotate(_ image: CGImage, degrees: Double) -> CGImage {
        guard degrees.truncatingRemainder(dividingBy: 360) != 0 else { return image }
        let ci = CIImage(cgImage: image)
        let radians = CGFloat(-degrees * Double.pi / 180) // screen-clockwise
        let center = CGPoint(x: ci.extent.midX, y: ci.extent.midY)
        var t = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)
        let rotated = ci.transformed(by: t).cropped(to: ci.extent.insetBy(dx: -ci.extent.width, dy: -ci.extent.height))
        let fitted = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX + (ci.extent.width - rotated.extent.width) / 2,
                                                               y: -rotated.extent.minY + (ci.extent.height - rotated.extent.height) / 2))
        _ = t
        t = .identity
        return CIContextHolder.shared.context.createCGImage(fitted, from: CGRect(x: 0, y: 0, width: ci.extent.width, height: ci.extent.height)) ?? image
    }
}

// MARK: - Pipeline màu §8.4

public enum ColorMappingVersion { public static let current = 1 }

public enum ImageColorPipeline {
    /// Áp preset + intensity blend + basic adjustments (thứ tự pipeline xác định §8.3/§8.4).
    public static func applyColor(_ input: CIImage, resolved: ResolvedPhotoParams) -> CIImage {
        var image = input
        // 1. Preset base (kết quả preset)
        let presetResult = applyParameters(image, parameters: resolved.presetParameters)
        // 2. Intensity blend giữa preset result và input đã chuẩn hóa (§8.3)
        if resolved.presetIntensity < 0.999 && resolved.presetIntensity > 0.001 {
            let dissolve = CIFilter(name: "CIDissolveTransition")
            dissolve?.setValue(image, forKey: kCIInputImageKey)
            dissolve?.setValue(presetResult, forKey: "inputTargetImage")
            dissolve?.setValue(resolved.presetIntensity, forKey: "inputTime")
            if let out = dissolve?.outputImage {
                image = out.cropped(to: input.extent)
            } else {
                image = presetResult
            }
        } else if resolved.presetIntensity >= 0.999 {
            image = presetResult
        }
        // 3. Basic adjustments (slider tự do) sau blend
        image = applyAdjustments(image, color: resolved.color)
        return image
    }

    static func applyParameters(_ input: CIImage, parameters: ColorParameterSet) -> CIImage {
        applyAdjustments(input, color: parameters)
    }

    static func applyAdjustments(_ input: CIImage, color: ColorParameterSet) -> CIImage {
        var image = input
        // Exposure: -1..1 → EV -1.5..1.5
        if abs(color.exposure) > 0.001 {
            let f = CIFilter(name: "CIExposureAdjust")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(color.exposure * 1.5, forKey: kCIInputEVKey)
            if let o = f?.outputImage { image = o }
        }
        // Contrast: -1..1 → 0.5..1.5
        if abs(color.contrast) > 0.001 {
            let f = CIFilter(name: "CIColorControls")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(1.0 + color.contrast * 0.5, forKey: kCIInputContrastKey)
            if let o = f?.outputImage { image = o }
        }
        // Saturation: -1..1 → 0..2 (Đen trắng dùng -1)
        if abs(color.saturation) > 0.001 {
            let f = CIFilter(name: "CIColorControls")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(1.0 + color.saturation, forKey: kCIInputSaturationKey)
            if let o = f?.outputImage { image = o }
        }
        // Temperature/Tint — CITemperatureAndTint nhận CIVector cho inputNeutral và inputTargetNeutral
        if abs(color.temperature) > 0.001 || abs(color.tint) > 0.001 {
            let f = CIFilter(name: "CITemperatureAndTint")
            f?.setValue(image, forKey: kCIInputImageKey)
            // Neutral gốc (6500, 0); target = (6500 - temp*2000, tint*100).
            f?.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            let targetTemp = 6500.0 - color.temperature * 2000.0
            let targetTint = color.tint * 100.0
            f?.setValue(CIVector(x: targetTemp, y: targetTint), forKey: "inputTargetNeutral")
            if let o = f?.outputImage { image = o.cropped(to: input.extent) }
        }
        // Sharpness: unsharp mask nhẹ, tránh halo (§8.4)
        if color.sharpness > 0.01 {
            let f = CIFilter(name: "CIUnsharpMask")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(color.sharpness * 0.7, forKey: kCIInputIntensityKey)
            f?.setValue(1.6, forKey: kCIInputRadiusKey)
            if let o = f?.outputImage { image = o.cropped(to: input.extent) }
        }
        return image
    }
}
