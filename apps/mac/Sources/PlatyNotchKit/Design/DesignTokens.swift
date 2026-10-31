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

/// The type scale (Quiet Notch spec 5.2): SF Pro 13 body, 12 secondary, 11 captions, one
/// 13 pt semibold title per block, SF Mono 12. Nothing in the panel goes above `maximum` or
/// below `minimum`.
public enum TypeScale {
    /// The one title per block (a project, a track).
    public static let title = TypeStyle(size: 13, weight: .semibold)
    /// Default text.
    public static let body = TypeStyle(size: 13, weight: .regular)
    /// Secondary lines, the header, chips and buttons.
    public static let secondary = TypeStyle(size: 12, weight: .regular)
    /// Captions and labels; the smallest size anywhere.
    public static let caption = TypeStyle(size: 11, weight: .regular)
    /// Commands, numbers and usage.
    public static let mono = TypeStyle(size: 12, weight: .regular, mono: true)
    /// The play / pause symbol: the largest thing in the panel.
    public static let glyph = TypeStyle(size: 15, weight: .semibold)

    public static let all: [TypeStyle] = [title, body, secondary, caption, mono, glyph]
    public static let maximum: CGFloat = 15
    public static let minimum: CGFloat = 11
}

/// The spacing scale and the panel's fixed gaps (spec 5.1).
public enum Space {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let scale: [CGFloat] = [xs, s, m, l, xl, xxl]
    /// The open panel's padding: below the notch, the sides, the bottom.
    public static let panelTop: CGFloat = 30
    public static let panelSide: CGFloat = 18
    public static let panelBottom: CGFloat = 16
    /// Between the header's items, and below the header.
    public static let header: CGFloat = 14
    /// Between Home's two columns.
    public static let columnGap: CGFloat = 22
}

/// The radius scale (spec 5.1): keycaps, buttons and code, the command line and media art,
/// the approval card and drop box, the panel's bottom corners. Chips are capsules.
public enum Radius {
    public static let keycap: CGFloat = 4
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 8
    public static let card: CGFloat = 12
    public static let panelBottom: CGFloat = 22
    public static let scale: [CGFloat] = [keycap, small, medium, card, panelBottom]

    /// A concentric inner radius: `outer − padding`, never negative.
    public static func inner(outer: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, outer - padding)
    }
}

/// SF Symbol sizes (spec 5.3): monochrome, 14–16 pt, never on a tinted square.
public enum IconSize {
    /// Symbols in rows, chips and buttons.
    public static let symbol: CGFloat = 14
    /// The header's icon toggles.
    public static let header: CGFloat = 16
}

/// White ink at fixed opacities over the black panel (spec 5.1): text, hairlines, fills.
public enum Ink {
    public static let primary: Double = 0.92
    public static let secondary: Double = 0.56
    public static let tertiary: Double = 0.32
    public static let hairline: Double = 0.10
    /// Chips, the command line, buttons and code.
    public static let fill: Double = 0.07
}

/// Brand colours. Only Platy's bill cream is left; the panel has no accent colour.
public enum Brand {
    /// Bill cream: Platy's highlights.
    public static let cream = RGB(hex: 0xF2E6C9)
}

/// A state colour, always shown with its symbol or word (never colour alone). Colour is
/// for state only: green running, amber needs you, red error; done and idle are white ink.
public enum StateTone: String, CaseIterable, Sendable {
    case working, needsYou, error, done, idle

    public var rgb: RGB {
        switch self {
        case .working: RGB(hex: 0x32D74B)
        case .needsYou: RGB(hex: 0xFFB340)
        case .error: RGB(hex: 0xFF6961)
        case .done, .idle: RGB(hex: 0xFFFFFF)
        }
    }

    /// The colour's opacity: done is secondary ink, idle tertiary, the rest opaque.
    public var alpha: Double {
        switch self {
        case .done: Ink.secondary
        case .idle: Ink.tertiary
        default: 1
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
