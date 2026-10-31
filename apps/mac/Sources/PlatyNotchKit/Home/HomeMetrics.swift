import CoreGraphics

/// Fixed sizes in the open panel's chrome (spec 2, 5.1).
public enum HomeMetrics {
    /// The header row (Platy, the switcher, the status text and the icon toggles).
    public static let nav: CGFloat = 32
    /// Between the header and the body.
    public static let gap: CGFloat = 8
    /// The 600 pt panel's column gap and the media art.
    public static let columnGap: CGFloat = 22
    public static let artSize: CGFloat = 54
    /// Left : right column widths, 1.15 : 1.
    public static let columnRatio: CGFloat = 1.15
    /// One Agents row: 7 pt above and below a 16 pt line, plus its hairline.
    public static let agentRow: CGFloat = 32
    /// The drop box's height.
    public static let dropBoxHeight: CGFloat = 74
}
