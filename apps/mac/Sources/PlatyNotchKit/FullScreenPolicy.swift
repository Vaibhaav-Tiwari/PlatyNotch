import CoreGraphics

/// Hides the panel over full-screen apps unless the cursor reaches the top edge.
public enum FullScreenPolicy {
    /// True when any of the frontmost app's windows covers the whole display
    /// (Quartz coordinates, 1 pt tolerance).
    public static func isFullScreen(windowBounds: [CGRect], displayBounds: CGRect) -> Bool {
        windowBounds.contains { w in
            abs(w.minX - displayBounds.minX) <= 1 && abs(w.minY - displayBounds.minY) <= 1
                && abs(w.maxX - displayBounds.maxX) <= 1 && abs(w.maxY - displayBounds.maxY) <= 1
        }
    }

    /// Whether the panel should be suppressed (invisible, click-through).
    /// Pending approvals and a panel the user opened always show. Otherwise touching
    /// `revealRect` reveals it, and it stays revealed while the cursor is on `hitRect`.
    public static func shouldSuppress(fullScreen: Bool, mode: PanelMode, cursor: CGPoint,
                                      revealRect: CGRect, hitRect: CGRect, wasSuppressed: Bool) -> Bool {
        guard fullScreen else { return false }
        switch mode {
        case .peek(.approval), .expanded: return false
        default: break
        }
        if PanelLayout.contains(revealRect, cursor) { return false }
        if !wasSuppressed && PanelLayout.contains(hitRect, cursor) { return false }
        return true
    }
}
