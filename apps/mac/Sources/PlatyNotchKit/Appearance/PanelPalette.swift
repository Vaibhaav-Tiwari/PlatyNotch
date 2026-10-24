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

/// The panel's fixed colors per scheme (the views build their `Color`s from these).
public enum PanelPalette {
    public static let darkSurface = RGB(hex: 0x000000)
    /// The light theme's surface (macOS's light window background).
    public static let lightSurface = RGB(hex: 0xECECEC)
    /// Warning text ("Contains hidden characters") in the dark scheme: systemOrange.
    public static let warningDark = RGB(hex: 0xFF9F0A)
    /// In the light scheme: a darker orange that reaches 4.5:1 on the surface and a card.
    public static let warningLight = RGB(hex: 0x8F4000)
    /// The Allow button's tint in the light scheme (systemGreen text on its own tinted
    /// fill is under 2:1 there); dark keeps systemGreen.
    public static let allowLight = RGB(hex: 0x0B521F)
    public static let systemGreenLight = RGB(hex: 0x34C759)
    /// A bordered button's tinted fill: at most this much of its tint over the card.
    public static let tintedFill = 0.2
    /// Cards draw this much black (light) or white (dark) over the surface at most.
    public static let cardOverlay = 0.08
}
