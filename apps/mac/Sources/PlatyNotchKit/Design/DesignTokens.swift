import CoreGraphics
import Foundation

// The design tokens (spec 7, plan Task 1). Every view reads these through the UI's `DS`
// layer; values are checked by `DesignTokensTests.testTokenGoldenTable`.
// Geometry is `CGFloat`; colour components are `Double` (`RGB`).

/// A text style: size, weight and design (SF Pro, Rounded or Mono).
public struct TypeStyle: Equatable, Sendable {
    public enum Weight: Sendable { case regular, medium, semibold }

    public let size: CGFloat
    public let weight: Weight
    public let rounded: Bool
    public let mono: Bool

    public init(size: CGFloat, weight: Weight, rounded: Bool = false, mono: Bool = false) {
        self.size = size; self.weight = weight; self.rounded = rounded; self.mono = mono
    }
}

/// The type scale (spec 7.3). Nothing in the UI goes below `minimum`.
public enum TypeScale {
    /// Hero time, big numbers.
    public static let display = TypeStyle(size: 34, weight: .semibold, rounded: true)
    /// Hero title.
    public static let title = TypeStyle(size: 20, weight: .semibold)
    /// Row titles, nav.
    public static let headline = TypeStyle(size: 15, weight: .semibold)
    /// Default text.
    public static let body = TypeStyle(size: 13, weight: .regular)
    /// Secondary lines; the smallest size anywhere.
    public static let caption = TypeStyle(size: 11, weight: .medium)
    /// Commands, paths.
    public static let mono = TypeStyle(size: 12, weight: .regular, mono: true)

    public static let all: [TypeStyle] = [display, title, headline, body, caption, mono]
    public static let minimum: CGFloat = 11
}

/// The spacing scale (spec 7.4).
public enum Space {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let scale: [CGFloat] = [xs, s, m, l, xl, xxl]
    /// The open panel's inner margin.
    public static let panelMargin: CGFloat = 16
    public static let heroPadding: CGFloat = 20
}

/// The radius scale (spec 7.4): chips inside cards, cards and tiles, the hero.
public enum Radius {
    public static let chip: CGFloat = 6
    public static let card: CGFloat = 12
    public static let hero: CGFloat = 20
    public static let scale: [CGFloat] = [chip, card, hero]

    /// A concentric inner radius: `outer − padding`, never negative.
    public static func inner(outer: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, outer - padding)
    }
}

/// SF Symbol sizes per context (spec 7.5).
public enum IconSize {
    public static let row: CGFloat = 15
    public static let tile: CGFloat = 20
    public static let hero: CGFloat = 28
}

/// The two elevation levels (spec 7.4).
public enum Elevation: CaseIterable, Sendable { case surface, card }

/// Brand colours (spec 7.2).
public enum Brand {
    /// Platy teal: accent, focus rings, selected nav.
    public static let teal = RGB(hex: 0x2FB8A6)
    /// Bill cream: Platy's highlights, idle hero glow.
    public static let cream = RGB(hex: 0xF2E6C9)
    /// Pond blue: Now's idle hero tint.
    public static let pond = RGB(hex: 0x1C3B4A)
}

/// A state colour, always shown with its symbol or word (never colour alone).
/// Light values are darker variants that reach 4.5:1 on the light surface (Ruling 2).
public enum StateTone: String, CaseIterable, Sendable {
    case working, needsYou, error, done, idle

    public func rgb(dark: Bool) -> RGB {
        switch self {
        case .working: RGB(hex: dark ? 0x2FB8A6 : 0x0B6B5F)
        case .needsYou: RGB(hex: dark ? 0xF5A524 : 0x845000)
        case .error: RGB(hex: dark ? 0xF2685B : 0xA3352B)
        case .done: RGB(hex: dark ? 0x4CC38A : 0x17693F)
        case .idle: RGB(hex: dark ? 0x9AA0A6 : 0x585D62)
        }
    }

    /// The SF Symbol that carries the state alongside its colour.
    public var symbol: String {
        switch self {
        case .working: "bolt.fill"
        case .needsYou: "hand.raised.fill"
        case .error: "exclamationmark.triangle.fill"
        case .done: "checkmark"
        case .idle: "moon.fill"
        }
    }

    public var word: String {
        switch self {
        case .working: "Working"
        case .needsYou: "Needs you"
        case .error: "Error"
        case .done: "Done"
        case .idle: "Idle"
        }
    }
}
