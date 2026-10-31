import CoreGraphics
import Foundation

/// The colour behind the artwork glow: the image drawn at 16×16, near-black and near-white
/// pixels ignored (backgrounds, text), the rest averaged. Run off the main thread, once per
/// artwork change.
public enum DominantColor {
    public static let sampleSize = 16
    /// A pixel whose brightest channel is below this is near-black.
    public static let blackCutoff = 0.1
    /// A pixel whose darkest channel is above this is near-white.
    public static let whiteCutoff = 0.9
    /// For an image with no readable pixels.
    public static let fallback: (r: Double, g: Double, b: Double) = (0.55, 0.55, 0.6)

    public static func of(cgImage: CGImage) -> (r: Double, g: Double, b: Double) {
        let n = sampleSize
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return drawn ? of(pixels: pixels) : fallback
    }

    /// `pixels` is RGBA, 8 bits per channel, alpha premultiplied. Mostly transparent pixels
    /// are skipped; if every pixel is near-black or near-white, all of them are averaged.
    public static func of(pixels: [UInt8]) -> (r: Double, g: Double, b: Double) {
        var kept = (r: 0.0, g: 0.0, b: 0.0, n: 0)
        var all = (r: 0.0, g: 0.0, b: 0.0, n: 0)
        var i = 0
        while i + 3 < pixels.count {
            let a = Double(pixels[i + 3]) / 255
            defer { i += 4 }
            guard a >= 0.5 else { continue }
            let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
            all = (all.r + r, all.g + g, all.b + b, all.n + 1)
            let hi = max(r, g, b), lo = min(r, g, b)
            if hi < blackCutoff || lo > whiteCutoff { continue }
            kept = (kept.r + r, kept.g + g, kept.b + b, kept.n + 1)
        }
        let use = kept.n > 0 ? kept : all
        guard use.n > 0 else { return fallback }
        let n = Double(use.n)
        return (min(use.r / n, 1), min(use.g / n, 1), min(use.b / n, 1))
    }
}

extension RGB {
    /// A `DominantColor` result.
    public init(_ c: (r: Double, g: Double, b: Double)) {
        self.init(r: c.r, g: c.g, b: c.b)
    }

    /// No hue to glow with: near-black, near-white or grey (channels within 0.08).
    public var isMonochrome: Bool {
        let hi = max(r, g, b), lo = min(r, g, b)
        return hi < DominantColor.blackCutoff || lo > DominantColor.whiteCutoff || hi - lo < 0.08
    }
}
