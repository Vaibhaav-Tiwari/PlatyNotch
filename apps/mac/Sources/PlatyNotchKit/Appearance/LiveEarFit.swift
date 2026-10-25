import CoreGraphics

/// What of a live activity fits the compact pill's live ear (`PanelLayout.liveEarWidth`):
/// the glyph always; the trailing text (countdown, "72%") when at least `minTrailing`
/// is left, truncated with an ellipsis to `trailingWidth`; then up to two indicator dots
/// for the next live items, which go before the text does (`init(earWidth:hasTrailing:indicators:)`).
/// Nothing is drawn past the ear.
public struct LiveEarFit: Equatable, Sendable {
    /// Room kept for the glyph (the view caps the glyph at this width).
    public static let glyph: CGFloat = 20
    public static let spacing: CGFloat = 4
    public static let bubble: CGFloat = 14
    /// An indicator dot (each also costs `spacing` before it).
    public static let indicator: CGFloat = 6
    /// Narrower than this the text is hidden rather than cut to a stub ("12:34" fits at 11 pt).
    public static let minTrailing: CGFloat = 34

    /// Width for the trailing text; 0 hides it.
    public let trailingWidth: CGFloat
    public let showsBubble: Bool
    /// Indicator dots drawn after the text.
    public let indicatorsShown: Int

    /// The pill's fit: indicators cost `indicator + spacing` each and are dropped, last
    /// first, before the trailing text is hidden. With the text hidden, as many as fit show.
    public init(earWidth: CGFloat, hasTrailing: Bool, indicators: Int) {
        let room: CGFloat = earWidth - Self.glyph
        let cost: CGFloat = Self.indicator + Self.spacing
        var text: CGFloat = 0
        var shown: Int = 0
        let wanted: Int = max(indicators, 0)
        if hasTrailing, let n = (0...wanted).reversed().first(where: { k in
            room - Self.spacing - CGFloat(k) * cost >= Self.minTrailing
        }) {
            text = room - Self.spacing - CGFloat(n) * cost
            shown = n
        } else if room > 0 {
            shown = min(wanted, Int((room / cost).rounded(.down)))
        }
        trailingWidth = text
        showsBubble = false
        indicatorsShown = shown
    }

    /// The bubble form (one second activity as a 14 pt bubble), kept for callers that
    /// still draw it.
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
        indicatorsShown = 0
    }

    /// The width the content takes (glyph, text, bubble or indicators and the gaps between them).
    public var usedWidth: CGFloat {
        var w = Self.glyph
        if trailingWidth > 0 { w += Self.spacing + trailingWidth }
        if showsBubble { w += Self.spacing + Self.bubble }
        w += CGFloat(indicatorsShown) * (Self.spacing + Self.indicator)
        return w
    }
}
