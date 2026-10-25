import CoreGraphics

/// What of a live activity fits the compact pill's live ear (`PanelLayout.liveEarWidth`):
/// the glyph always; the trailing text (countdown, "72%") when at least `minTrailing`
/// is left, truncated with an ellipsis to `trailingWidth`; the second activity's bubble
/// only when there is room after the text. Nothing is drawn past the ear.
public struct LiveEarFit: Equatable, Sendable {
    /// Room kept for the glyph (the view caps the glyph at this width).
    public static let glyph: CGFloat = 20
    public static let spacing: CGFloat = 4
    public static let bubble: CGFloat = 14
    /// Narrower than this the text is hidden rather than cut to a stub ("12:34" fits at 11 pt).
    public static let minTrailing: CGFloat = 34

    /// Width for the trailing text; 0 hides it.
    public let trailingWidth: CGFloat
    public let showsBubble: Bool

    public init(earWidth: CGFloat, hasTrailing: Bool, hasBubble: Bool) {
        let room = earWidth - Self.glyph
        let bubbleCost = Self.spacing + Self.bubble
        var text: CGFloat = 0
        var bubble = false
        if hasTrailing, hasBubble, room - bubbleCost - Self.spacing >= Self.minTrailing {
            text = room - bubbleCost - Self.spacing
            bubble = true
        } else if hasTrailing, room - Self.spacing >= Self.minTrailing {
            text = room - Self.spacing
        } else if hasBubble, room >= bubbleCost {
            bubble = true
        }
        trailingWidth = text
        showsBubble = bubble
    }

    /// The width the content takes (glyph, text, bubble and the gaps between them).
    public var usedWidth: CGFloat {
        var w = Self.glyph
        if trailingWidth > 0 { w += Self.spacing + trailingWidth }
        if showsBubble { w += Self.spacing + Self.bubble }
        return w
    }
}
