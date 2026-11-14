import Foundation
import CoreImage
import CoreGraphics

/// Làm mịn da cục bộ (§8.5): Vision face → vùng da ước lượng (loại mắt/môi/cạnh)
/// → edge-preserving smoothing (median + blur) → blend theo strength/confidence.
/// Không đổi hình dạng/góc mặt; không blur toàn ảnh; không có mặt → pass-through.
public enum SkinSmoothingFilter {
    /// Trả về ảnh đã làm mịn. `faces` theo hệ normalized top-left của ảnh input.
    public static func apply(_ input: CGImage, faces: [FaceBox], strength: Double) -> CGImage {
        guard strength > 0.001, !faces.isEmpty else { return input }
        let ci = CIImage(cgImage: input)
        guard let out = apply(ciImage: ci, faces: faces, strength: strength) else { return input }
        return CIContextHolder.shared.context.createCGImage(out, from: ci.extent) ?? input
    }

    /// Biến thể CI thuần để ghép pipeline không round-trip (§8.4: smoothing trước preset).
    public static func apply(ciImage input: CIImage, faces: [FaceBox], strength: Double) -> CIImage? {
        let s = strength.clamped(0...1)
        guard s > 0.001, !faces.isEmpty else { return nil }
        let extent = input.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }

        // 1. Vùng da ước lượng: mask trắng = mịn; đen = giữ (mắt, mày, môi, hairline, cạnh)
        guard let mask = buildSkinMask(width: Int(extent.width), height: Int(extent.height), faces: faces) else {
            return nil
        }
        let maskCI = CIImage(cgImage: mask)

        // 2. Smoothing: median (giữ cạnh) + gaussian theo strength
        var smoothed = input
        let median = CIFilter(name: "CIMedianFilter")
        median?.setValue(input, forKey: kCIInputImageKey)
        if let m = median?.outputImage { smoothed = m }

        let baseRadius = max(extent.width, extent.height) / 900.0
        let radius = (1.5 + s * 5.5) * max(1.0, baseRadius)
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(smoothed, forKey: kCIInputImageKey)
        blur?.setValue(radius, forKey: kCIInputRadiusKey)
        if let b = blur?.outputImage { smoothed = b.cropped(to: extent) }

        // 3. Blend theo strength × confidence: nhân độ sáng (grayscale) của mask với strength.
        // CIBlendWithMask trộn theo kênh grayscale của mask — phải scale kênh R (và G/B),
        // KHÔNG zero các kênh RGB (làm mất hình dạng vùng da) và KHÔNG đưa hệ số vào alpha.
        let minConf = faces.map(\.confidence).min() ?? 1
        let effStrength = s * (0.4 + 0.6 * minConf)
        let scaledMask = maskCI.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(effStrength), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(effStrength), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(effStrength), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])

        let blend = CIFilter(name: "CIBlendWithMask")
        blend?.setValue(smoothed, forKey: kCIInputImageKey)
        blend?.setValue(input, forKey: kCIInputBackgroundImageKey)
        blend?.setValue(scaledMask, forKey: kCIInputMaskImageKey)
        guard let out = blend?.outputImage else { return nil }

        return out.cropped(to: extent)
    }

    /// Vẽ mask vùng da trên context cùng kích thước ảnh (y-up như CI).
    /// Mỗi mặt: ellipse mặt (thu nhỏ hairline) − vùng mắt/môi.
    static func buildSkinMask(width: Int, height: Int, faces: [FaceBox]) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Vẽ vùng mịn: union các mặt (tránh double-process overlap §8.5)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for face in faces {
            let fx = CGFloat(face.x) * CGFloat(width)
            let fyTop = CGFloat(face.y) * CGFloat(height)
            let fw = CGFloat(face.width) * CGFloat(width)
            let fh = CGFloat(face.height) * CGFloat(height)
            // CGContext origin bottom-left → đổi y
            let fy = CGFloat(height) - fyTop - fh
            // Ellipse mặt: hạ nhẹ để包含 hàm, giảm trán (hairline)
            let skinRect = CGRect(x: fx + fw * 0.04, y: fy + fh * 0.12, width: fw * 0.92, height: fh * 0.82)
            ctx.fillEllipse(in: skinRect)
        }
        // Trừ vùng mắt + môi
        ctx.setBlendMode(.copy)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for face in faces {
            let fx = CGFloat(face.x) * CGFloat(width)
            let fyTop = CGFloat(face.y) * CGFloat(height)
            let fw = CGFloat(face.width) * CGFloat(width)
            let fh = CGFloat(face.height) * CGFloat(height)
            let fy = CGFloat(height) - fyTop - fh
            let eyeY = fy + fh * 0.55
            let eyeH = fh * 0.13
            ctx.fillEllipse(in: CGRect(x: fx + fw * 0.16, y: eyeY, width: fw * 0.26, height: eyeH))
            ctx.fillEllipse(in: CGRect(x: fx + fw * 0.58, y: eyeY, width: fw * 0.26, height: eyeH))
            ctx.fillEllipse(in: CGRect(x: fx + fw * 0.28, y: fy + fh * 0.14, width: fw * 0.44, height: fh * 0.16))
        }
        return ctx.makeImage()
    }
}
