import AppKit
import CoreImage

struct ColorParams {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var gamma = 1.0
}

/// Pure image transforms. Each returns a new CGImage or nil on failure.
enum ImageOps {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func rgbSpace(for img: CGImage) -> CGColorSpace {
        if let cs = img.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func context(width: Int, height: Int, like img: CGImage, opaque: Bool = false) -> CGContext? {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: rgbSpace(for: img), bitmapInfo: info)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
    }

    private static func redraw(_ img: CGImage, width: Int, height: Int, _ transform: (CGContext) -> Void) -> CGImage? {
        guard let ctx = context(width: width, height: height, like: img) else { return nil }
        ctx.interpolationQuality = .high
        transform(ctx)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    static func rotate(_ img: CGImage, clockwise: Bool) -> CGImage? {
        redraw(img, width: img.height, height: img.width) { ctx in
            if clockwise {
                ctx.translateBy(x: 0, y: CGFloat(img.width))
                ctx.rotate(by: -.pi / 2)
            } else {
                ctx.translateBy(x: CGFloat(img.height), y: 0)
                ctx.rotate(by: .pi / 2)
            }
        }
    }

    static func flip(_ img: CGImage, horizontal: Bool) -> CGImage? {
        redraw(img, width: img.width, height: img.height) { ctx in
            if horizontal {
                ctx.translateBy(x: CGFloat(img.width), y: 0)
                ctx.scaleBy(x: -1, y: 1)
            } else {
                ctx.translateBy(x: 0, y: CGFloat(img.height))
                ctx.scaleBy(x: 1, y: -1)
            }
        }
    }

    /// `rect` is in pixel coordinates with a top-left origin.
    static func crop(_ img: CGImage, to rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !r.isEmpty else { return nil }
        return img.cropping(to: r)
    }

    static func resize(_ img: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let ctx = context(width: width, height: height, like: img) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Scales down so the longest side is at most `maxSide` (used for fast previews).
    static func downscaled(_ img: CGImage, maxSide: Int) -> CGImage {
        let longest = max(img.width, img.height)
        guard longest > maxSide else { return img }
        let s = Double(maxSide) / Double(longest)
        return resize(img, width: max(1, Int(Double(img.width) * s)), height: max(1, Int(Double(img.height) * s))) ?? img
    }

    /// Composites onto white, for formats without alpha.
    static func flattened(_ img: CGImage) -> CGImage? {
        guard let ctx = context(width: img.width, height: img.height, like: img, opaque: true) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage()
    }

    // MARK: Core Image filters

    private static func filter(_ img: CGImage, _ build: (CIImage) -> CIImage) -> CGImage? {
        let input = CIImage(cgImage: img)
        let output = build(input).cropped(to: input.extent)
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: rgbSpace(for: img))
    }

    static func grayscale(_ img: CGImage) -> CGImage? {
        filter(img) { $0.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]) }
    }

    static func negative(_ img: CGImage) -> CGImage? {
        filter(img) { $0.applyingFilter("CIColorInvert") }
    }

    static func sharpen(_ img: CGImage) -> CGImage? {
        filter(img) { $0.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.6, kCIInputRadiusKey: 1.5]) }
    }

    static func blur(_ img: CGImage) -> CGImage? {
        filter(img) { $0.clampedToExtent().applyingGaussianBlur(sigma: 2) }
    }

    static func autoAdjust(_ img: CGImage) -> CGImage? {
        filter(img) { input in
            var result = input
            for f in input.autoAdjustmentFilters(options: [.redEye: false]) {
                f.setValue(result, forKey: kCIInputImageKey)
                result = f.outputImage ?? result
            }
            return result
        }
    }

    static func colorAdjust(_ img: CGImage, _ p: ColorParams) -> CGImage? {
        filter(img) {
            $0.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: p.brightness,
                kCIInputContrastKey: p.contrast,
                kCIInputSaturationKey: p.saturation,
            ])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / max(p.gamma, 0.01)])
        }
    }
}
