import Foundation

/// An sRGB color as 0…1 components, for contrast checks of the panel's fixed colors.
public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    public init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, 1…21.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let hi = max(a.luminance, b.luminance), lo = min(a.luminance, b.luminance)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// `top` at `alpha` over this color.
    public func under(_ top: RGB, alpha: Double) -> RGB {
        RGB(r: r + (top.r - r) * alpha, g: g + (top.g - g) * alpha, b: b + (top.b - b) * alpha)
    }
}

/// The panel's fixed colours (Quiet Notch spec 5.1): always black, in every system appearance.
public enum PanelPalette {
    /// The open panel, the pill and anything touching the hardware notch.
    public static let panel = RGB(hex: 0x000000)
    /// The pill's surface: the panel's black.
    public static let darkSurface = panel
    /// The approval card: one step up from the panel.
    public static let approvalCard = RGB(hex: 0x111111)
}
