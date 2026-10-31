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

/// The type scale (Island spec 9): SF Pro 13 body, 14 semibold titles, 12 secondary,
/// 11 captions, 10.5 dock labels, 10 semibold badges, SF Mono 12; SF Pro Rounded semibold
/// for the pill time and the two display numbers. Text styles stay in `minimum`…`maximum`;
/// only `display` goes above.
public enum TypeScale {
    /// The one title per block (a project, a track).
    public static let title = TypeStyle(size: 14, weight: .semibold)
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

    /// The dock's labels under each circle.
    public static let dockLabel = TypeStyle(size: 10.5, weight: .regular)
    /// The white digits on a count badge.
    public static let badge = TypeStyle(size: 10, weight: .semibold)
    /// The closed pill's time left.
    public static let pillTime = TypeStyle(size: 12, weight: .semibold, rounded: true)
    /// The Today card's temperature.
    public static let temperature = TypeStyle(size: 34, weight: .semibold, rounded: true)
    /// The Timer tool's value.
    public static let timer = TypeStyle(size: 54, weight: .semibold, rounded: true)

    public static let all: [TypeStyle] = [title, body, secondary, caption, mono, glyph, dockLabel, badge, pillTime]
    /// The big, friendly numbers: the only text above `maximum` (not in `all`).
    public static let display: [TypeStyle] = [temperature, timer]
    public static let maximum: CGFloat = 15
    public static let minimum: CGFloat = 10
    /// The smallest literal `.system(size:)` a view may write (dock labels and badges use
    /// their tokens).
    public static let literalMinimum: CGFloat = 11
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
    public static let panelSide: CGFloat = 16
    public static let panelBottom: CGFloat = 14
    /// Between the header's items, and below the header.
    public static let header: CGFloat = 14
    /// Between Home's two columns.
    public static let columnGap: CGFloat = 22
}

/// The radius scale (Island spec 9): keycaps, buttons and code, wells, art and the approval
/// card, Island's cards, the panel's bottom corners. Chips and badges are capsules.
public enum Radius {
    public static let keycap: CGFloat = 4
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 8
    public static let card: CGFloat = 12
    /// Island's cards (Now Playing, Today, tool bodies).
    public static let island: CGFloat = 16
    public static let panelBottom: CGFloat = 22
    public static let scale: [CGFloat] = [keycap, small, medium, card, island, panelBottom]

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

/// White ink at fixed opacities over the black panel (Island spec 9): text, hairlines, fills.
public enum Ink {
    public static let primary: Double = 0.94
    public static let secondary: Double = 0.60
    public static let tertiary: Double = 0.36
    public static let hairline: Double = 0.06
    /// Between list rows.
    public static let rowHairline: Double = 0.05
    /// Settings and the legacy chips, the command line, buttons and code.
    public static let fill: Double = 0.07
}

/// Island's opaque surfaces on the black panel (spec 9): cards, raised controls, outlines,
/// and the one blue for counts.
public enum Surface {
    /// Cards (radius 16, padding 12).
    public static let card = RGB(hex: 0x121214)
    /// Circles, chips, wells, buttons and fields.
    public static let raised = RGB(hex: 0x1C1C1F)
    /// The search ring, keycaps and hover.
    public static let stroke = RGB(hex: 0x2A2A2E)
    /// Badges, the week strip's marked day, the caret.
    public static let countBlue = RGB(hex: 0x4C8DFF)
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
