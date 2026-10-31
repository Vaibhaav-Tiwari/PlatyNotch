import CoreGraphics

/// Fixed sizes in the open panel (Island spec 2, 3, 9).
public enum HomeMetrics {
    /// The header row (Platy, the switcher and the icon toggles).
    public static let nav: CGFloat = 32
    /// Between the header and the body.
    public static let gap: CGFloat = 8
    /// The open panel's width.
    public static let panelWidth: CGFloat = 640
    /// Between Home's two cards, and from the cards to the dock.
    public static let cardGap: CGFloat = 10
    public static let dockTop: CGFloat = 12
    /// Inside a card, and inside a tool's body.
    public static let cardPadding: CGFloat = 12
    public static let toolPadding: CGFloat = 14
    /// The Now Playing art, its source-app badge and the badge's border.
    public static let artSize: CGFloat = 74
    public static let sourceBadge: CGFloat = 20
    public static let sourceBadgeBorder: CGFloat = 2
    /// The art glow behind the Now Playing card.
    public static let glowBlur: CGFloat = 34
    public static let glowOpacity: Double = 0.45
    /// The playback progress bar.
    public static let progressHeight: CGFloat = 4
    /// The dock: a circle, its symbol, the slot; a badge's height; a live circle's amber fill.
    public static let dockCircle: CGFloat = 38
    public static let dockIcon: CGFloat = 17
    public static let dockSlot: CGFloat = 66
    public static let badgeHeight: CGFloat = 16
    public static let liveFill: Double = 0.18
    /// The Today card: the weather symbol, a week-strip day and its marked circle.
    public static let weatherSymbol: CGFloat = 40
    public static let weekDay: CGFloat = 22
    public static let weekMark: CGFloat = 20
    /// Agents' app icons and usage rings.
    public static let agentIcon: CGFloat = 24
    public static let usageRing: CGFloat = 14
    /// The closed pill's mini art and app icon.
    public static let pillArt: CGFloat = 20
    public static let pillAppIcon: CGFloat = 18
    /// The Timer tool's right column.
    public static let timerColumn: CGFloat = 170
    /// Now Playing : Today widths.
    public static let nowPlayingRatio: CGFloat = 1.25
    /// The drop box's height.
    public static let dropBoxHeight: CGFloat = 74

    // Quiet Notch's two columns, until the two-card Home replaces them.
    public static let columnGap: CGFloat = 22
    public static let legacyArtSize: CGFloat = 54
    public static let columnRatio: CGFloat = 1.15
}
