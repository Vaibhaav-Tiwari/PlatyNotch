import CoreGraphics

/// One display as baskets see it (AppKit screen coordinates, origin bottom-left).
public struct BasketScreen: Equatable, Sendable {
    /// Where a basket may go: the screen less the menu bar and the Dock.
    public var visibleFrame: CGRect
    /// Where the notch panel may ever draw on this display, with a margin (R5): a basket
    /// never overlaps it. Nil on a display without a panel.
    public var exclusion: CGRect?
    /// The display (hiding over a full-screen app is per display); nil when unknown.
    public var displayID: CGDirectDisplayID?

    public init(visibleFrame: CGRect, exclusion: CGRect?, displayID: CGDirectDisplayID? = nil) {
        self.visibleFrame = visibleFrame
        self.exclusion = exclusion
        self.displayID = displayID
    }

    /// A display with a notch panel laid out as `layout`.
    public init(visibleFrame: CGRect, layout: PanelLayout, displayID: CGDirectDisplayID? = nil) {
        self.init(visibleFrame: visibleFrame, exclusion: BasketPlacement.exclusion(for: layout), displayID: displayID)
    }
}

/// Where a basket's window goes (R5): approvals win. A basket sits at `.floating`, below
/// the notch panel's `.statusBar`, and is also kept out of everything the panel can show
/// (the approval card, the open panel, the drop zone and the reach that opens it, peeks,
/// the ringing card), so it never covers the approval card or takes its clicks, whatever
/// mode the panel is in when the basket appears or later.
public enum BasketPlacement {
    /// A basket's window.
    public static let size = CGSize(width: 260, height: 132)
    /// Kept between a basket and the panel's region, and inside the screen.
    public static let margin: CGFloat = 8

    /// The union of every rect the panel on `layout`'s display may use (its window frame,
    /// each mode's content, the approval slot and the drag reach), grown by `margin`.
    public static func exclusion(for layout: PanelLayout) -> CGRect {
        let modes: [PanelMode] = [.compact, .expanded, .peek(.approval), .peek(.notice), .peek(.drop),
                                  .peek(.widget(id: "")), .peek(.ringing(id: "")), .peek(.hud(.volume))]
        var r = layout.windowFrame.union(layout.dragZone).union(layout.revealRect)
        for m in modes {
            r = r.union(layout.contentRect(for: m))
            if let slot = layout.approvalSlot(for: m) { r = r.union(slot) }
            if let chip = layout.ringingChipRect(for: m) { r = r.union(chip) }
        }
        return r.insetBy(dx: -margin, dy: -margin)
    }

    /// A basket of `size` centred on `point` (where the user shook), moved as little as
    /// possible to fit its screen and stay out of the panel's region. Nil when no place
    /// fits (then no basket is shown).
    public static func frame(centeredAt point: CGPoint, size: CGSize = size, screens: [BasketScreen]) -> CGRect? {
        let f = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        return clamp(f, screens: screens)
    }

    /// `frame` moved onto the screen holding its center (else the nearest one) and out of
    /// that screen's exclusion, by the smallest move: below it, left of it or right of it.
    /// Nil when it fits nowhere on that screen.
    public static func clamp(_ frame: CGRect, screens: [BasketScreen]) -> CGRect? {
        guard let screen = screen(of: frame, in: screens) else { return nil }
        let bounds = screen.visibleFrame.insetBy(dx: margin, dy: margin)
        guard frame.width <= bounds.width, frame.height <= bounds.height else { return nil }
        let inside = fit(frame, in: bounds)
        guard let ex = screen.exclusion, inside.intersects(ex) else { return inside }
        var candidates: [CGRect] = []
        var below = inside
        below.origin.y = ex.minY - inside.height - 1   // 1 pt clear: edges never touch
        candidates.append(below)
        var left = inside
        left.origin.x = ex.minX - inside.width - 1
        candidates.append(left)
        var right = inside
        right.origin.x = ex.maxX + 1
        candidates.append(right)
        let valid = candidates
            .map { fit($0, in: bounds) }
            .filter { !$0.intersects(ex) && bounds.contains($0) }
        return valid.min { moved(inside, $0) < moved(inside, $1) }
    }

    /// The screen holding `frame`'s center, else the nearest one.
    public static func screen(of frame: CGRect, in screens: [BasketScreen]) -> BasketScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.first { PanelLayout.contains($0.visibleFrame, center) }
            ?? screens.min { distance(center, $0.visibleFrame) < distance(center, $1.visibleFrame) }
    }

    /// True when `frame` is clear of every screen's exclusion (tests, and a last check
    /// before a window is shown).
    public static func isClear(_ frame: CGRect, screens: [BasketScreen]) -> Bool {
        !screens.contains { $0.exclusion?.intersects(frame) ?? false }
    }

    private static func fit(_ r: CGRect, in b: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(r.minX, b.minX), b.maxX - r.width)
        r.origin.y = min(max(r.minY, b.minY), b.maxY - r.height)
        return r
    }

    private static func moved(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.minX - b.minX, a.minY - b.minY)
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}
