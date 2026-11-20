import ImageIO
import Foundation
import CoreImage
import CoreGraphics

/// ImageNormalizer: chuẩn hóa orientation/flip ở đầu pipeline (§8.4, §4.4).
/// OutputMirror quyết định pixel ảnh nguồn chuẩn hóa; lưu snapshot trong session defaults,
/// không xử lý chồng nhiều lần.
public enum ImageNormalizer {
    /// Apply stored orientation to raw frame pixels. Capture photos use uprightImage.
    static func orientedFrameLayer(_ image: CGImage, orientation: Int?) throws -> CIImage {
        let raw = CIImage(cgImage: image)
        guard let orientation, orientation != 1 else { return raw }
        guard (2...8).contains(orientation) else { throw AppError.frameFileCorrupt }
        let oriented = raw.oriented(forExifOrientation: Int32(orientation))
        return oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX,
                                                            y: -oriented.extent.minY))
    }

    static func orientedFramePixels(_ image: CGImage, orientation: Int?) throws -> CGImage {
        guard let orientation, orientation != 1 else { return image }
        let oriented = try orientedFrameLayer(image, orientation: orientation)
        guard let pixels = CIContextHolder.shared.context.createCGImage(oriented, from: oriented.extent) else {
            throw AppError.frameFileCorrupt
        }
        return pixels
    }

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
        let output = rotated(CIImage(cgImage: image), degrees: degrees)
        let rect = CGRect(origin: .zero, size: CGSize(width: round(output.extent.width), height: round(output.extent.height)))
        return CIContextHolder.shared.context.createCGImage(output, from: rect) ?? image
    }

    static func rotated(_ image: CIImage, degrees: Double) -> CIImage {
        let norm = degrees.truncatingRemainder(dividingBy: 360)
        let positive = norm < 0 ? norm + 360 : norm
        guard positive != 0 else { return image }
        let outCI: CIImage
        if abs(positive - 90) < 0.001 {
            outCI = image.oriented(.right)
        } else if abs(positive - 180) < 0.001 {
            outCI = image.oriented(.down)
        } else if abs(positive - 270) < 0.001 {
            outCI = image.oriented(.left)
        } else {
            let radians = CGFloat(-positive * Double.pi / 180)
            let rotated = image.transformed(by: CGAffineTransform(rotationAngle: radians))
            let ext = rotated.extent
            let aligned = rotated.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
            outCI = aligned
        }
        return outCI
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

    private static let highlightsShadowsKernel: CIColorKernel? = {
        let kernelSource = """
        kernel vec4 highlightsShadows(__sample pixel, float shadows, float highlights) {
            float a = pixel.a;
            if (a == 0.0) { return pixel; }
            vec3 rgb = pixel.rgb / a;
            float Y = clamp(0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b, 0.0, 1.0);
            float tS = clamp((Y - 0.10) / 0.40, 0.0, 1.0);
            float S = 1.0 - (tS * tS * (3.0 - 2.0 * tS));
            float tH = clamp((Y - 0.50) / 0.40, 0.0, 1.0);
            float H = tH * tH * (3.0 - 2.0 * tH);
            float dS = 0.25 * shadows * S * (shadows >= 0.0 ? (1.0 - Y) : Y);
            float dH = 0.25 * highlights * H * (highlights >= 0.0 ? (1.0 - Y) : Y);
            vec3 res = max(rgb + vec3(dS + dH), vec3(0.0));
            return vec4(res * a, a);
        }
        """
        return CIColorKernel(source: kernelSource)
    }()

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
        // Highlights & Shadows: chèn sau Tương phản và trước Bão hòa (§3.2). Bỏ qua ở giá trị 0.
        if abs(color.highlights) > 0.001 || abs(color.shadows) > 0.001 {
            if let k = highlightsShadowsKernel,
               let o = k.apply(extent: image.extent, arguments: [image, Float(color.shadows), Float(color.highlights)]) {
                image = o
            }
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
        // Vibrance: chèn sau Nhiệt độ/Tint và trước Độ nét (§3.2). Bỏ qua ở giá trị 0.
        if abs(color.vibrance) > 0.001 {
            let f = CIFilter(name: "CIVibrance")
            f?.setValue(image, forKey: kCIInputImageKey)
            f?.setValue(color.vibrance * 0.8, forKey: "inputAmount")
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
