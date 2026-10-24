import CoreGraphics

/// Hides the panel over full-screen apps unless the cursor reaches the top edge.
public enum FullScreenPolicy {
    /// True when one of the frontmost app's windows fills the display (Quartz
    /// coordinates, top-left origin, 1 pt tolerance): full width, down to the bottom,
    /// and from the top, or from `topInset` below it on a notched display (macOS puts
    /// full-screen windows under the camera housing). A window starting at `topInset`
    /// only counts while the menu bar is hidden: with it showing, those are the bounds
    /// of an ordinary zoomed window (on notched Macs the menu bar is as tall as the notch).
    public static func isFullScreen(windowBounds: [CGRect], displayBounds d: CGRect,
                                    topInset: CGFloat, menuBarVisible: Bool) -> Bool {
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        return windowBounds.contains { w in
            guard near(w.minX, d.minX), near(w.maxX, d.maxX), near(w.maxY, d.maxY) else { return false }
            if near(w.minY, d.minY) { return true }
            return topInset > 0 && !menuBarVisible && near(w.minY, d.minY + topInset)
        }
    }

    /// Whether the panel should be suppressed (invisible, click-through).
    /// Pending approvals, a panel the user opened, a ringing alarm or timer and the drop
    /// zone (the user dragged to the notch) always show. HUDs and widget peeks never reach
    /// here over full screen (`PanelStateMachine.setFullScreen`). Otherwise touching
    /// `revealRect` reveals it, and it stays revealed while the cursor is on `hitRect`.
    /// With `hideInFullScreen` off (Appearance) nothing is suppressed.
    public static func shouldSuppress(fullScreen: Bool, hideInFullScreen: Bool = true, mode: PanelMode,
                                      cursor: CGPoint, revealRect: CGRect, hitRect: CGRect,
                                      wasSuppressed: Bool) -> Bool {
        guard fullScreen, hideInFullScreen else { return false }
        switch mode {
        case .peek(.approval), .expanded, .peek(.ringing), .peek(.drop): return false
        default: break
        }
        if PanelLayout.contains(revealRect, cursor) { return false }
        if !wasSuppressed && PanelLayout.contains(hitRect, cursor) { return false }
        return true
    }
}
