import CoreGraphics

/// Where the notch panel sits on one screen and which rect each mode occupies.
/// Pure geometry in AppKit screen coordinates (origin bottom-left).
public struct PanelLayout: Equatable, Sendable {
    /// Extra width on each side of the physical notch in compact mode.
    public static let compactEar: CGFloat = 64
    /// Compact pill width on screens without a notch.
    public static let pillWidth: CGFloat = 200
    /// Room for an approval card below the notch: header, a few summary lines, buttons,
    /// and a one-line row for the next approval.
    public static let peekSize = CGSize(width: 420, height: 236)
    /// Height of a notice peek below the notch (or the menu bar).
    public static let noticeHeight: CGFloat = 64
    public static let expandedSize = CGSize(width: 560, height: 380)
    /// Width of widget peeks and the ringing card.
    public static let surfaceWidth: CGFloat = 380
    /// A widget peek below the notch: icon, a line or two and one or two buttons (nudge, plug-in, AirPods).
    public static let widgetPeekHeight: CGFloat = 92
    /// A ringing alarm or timer: pulsing ring, label, Snooze and Stop.
    public static let ringingHeight: CGFloat = 128
    /// A slim level HUD that grows out of the pill.
    public static let hudHeight: CGFloat = 34
    /// The HUD is at least this wide (wider when the compact pill is).
    public static let hudMinWidth: CGFloat = 300
    /// How near the notch (or pill) a drag must come to open the drop zone.
    public static let dragReach: CGFloat = 60
    /// Height of the top-edge strip that reveals a hidden panel on screens without a notch.
    public static let revealDepth: CGFloat = 3

    public let screenFrame: CGRect
    /// The physical notch, or the pill just below the menu bar.
    public let anchor: CGRect
    public let hasNotch: Bool

    public init(screenFrame: CGRect, visibleFrame: CGRect, auxLeft: CGRect?, auxRight: CGRect?) {
        self.screenFrame = screenFrame
        if let notch = NotchGeometry.notchRect(screenFrame: screenFrame, auxLeft: auxLeft, auxRight: auxRight) {
            anchor = notch
            hasNotch = true
        } else {
            anchor = NotchGeometry.pillRect(screenFrame: screenFrame, visibleFrame: visibleFrame,
                                            width: Self.pillWidth)
            hasNotch = false
        }
    }

    /// The screen area panels may use: everything up to the anchor's top
    /// (the screen top on a notch, just below the menu bar otherwise).
    public var usableFrame: CGRect { usable }

    private var usable: CGRect {
        CGRect(x: screenFrame.minX, y: screenFrame.minY,
               width: screenFrame.width, height: anchor.maxY - screenFrame.minY)
    }

    private var compactRect: CGRect {
        hasNotch ? anchor.insetBy(dx: -Self.compactEar, dy: 0) : anchor
    }

    /// The fixed window frame: big enough for every mode's content.
    public var windowFrame: CGRect {
        let size = CGSize(width: max(Self.expandedSize.width, compactRect.width),
                          height: max(Self.expandedSize.height, compactRect.height))
        return NotchGeometry.panelFrame(anchor: anchor, size: size, screenFrame: usable)
    }

    /// The visible content for `mode` (hidden draws nothing but keeps the compact rect).
    public func contentRect(for mode: PanelMode) -> CGRect {
        switch mode {
        case .hidden, .compact: compactRect
        case .peek(.approval): NotchGeometry.panelFrame(anchor: anchor, size: Self.peekSize, screenFrame: usable)
        case .peek(.notice):
            NotchGeometry.panelFrame(anchor: anchor, size: CGSize(width: Self.peekSize.width,
                                                                  height: (hasNotch ? anchor.height : 0) + Self.noticeHeight),
                                     screenFrame: usable)
        case .expanded, .peek(.drop):
            NotchGeometry.panelFrame(anchor: anchor, size: Self.expandedSize, screenFrame: usable)
        case .peek(.widget): below(width: Self.surfaceWidth, height: Self.widgetPeekHeight)
        case .peek(.ringing): below(width: Self.surfaceWidth, height: Self.ringingHeight)
        case .peek(.hud): below(width: max(Self.hudMinWidth, compactRect.width), height: Self.hudHeight)
        }
    }

    /// A surface `height` tall below the notch (its rect includes the notch) or below the pill.
    private func below(width: CGFloat, height: CGFloat) -> CGRect {
        NotchGeometry.panelFrame(anchor: anchor, size: CGSize(width: width, height: (hasNotch ? anchor.height : 0) + height),
                                 screenFrame: usable)
    }

    /// Where the cursor counts as "on the panel" for `mode`.
    /// Hidden: the notch itself, or a strip at the screen's top edge above the pill.
    /// A HUD is click-through except for the pill it grows from.
    public func hitRect(for mode: PanelMode) -> CGRect {
        switch mode {
        case .hidden: hasNotch ? anchor : revealRect
        case .peek(.hud): compactRect
        default: contentRect(for: mode)
        }
    }

    /// Where a drag counts as "near the notch": `dragReach` around the anchor.
    public var dragZone: CGRect {
        anchor.insetBy(dx: -Self.dragReach, dy: -Self.dragReach)
    }

    /// Whether a drag at `p` should show the drop zone: near the notch, or anywhere on
    /// the drop zone once it is `showing`.
    public func dragHover(_ p: CGPoint, showing: Bool) -> Bool {
        Self.contains(dragZone, p) || (showing && Self.contains(contentRect(for: .peek(.drop)), p))
    }

    /// The top-edge strip above the compact content (reveals a hidden or full-screen-suppressed panel).
    public var revealRect: CGRect {
        let c = compactRect
        return CGRect(x: c.minX, y: screenFrame.maxY - Self.revealDepth, width: c.width, height: Self.revealDepth)
    }

    /// Over a full-screen app: where the cursor keeps a revealed panel showing. The
    /// mode's hit rect stretched up to the top-edge strip, so moving down from the edge
    /// to a pill below the (hidden) menu bar does not hide it on the way.
    public func fullScreenHoldRect(for mode: PanelMode) -> CGRect {
        hitRect(for: mode).union(revealRect)
    }

    /// Converts a screen rect into the window's content coordinates with a top-left origin (SwiftUI).
    public static func localRect(_ rect: CGRect, in window: CGRect) -> CGRect {
        CGRect(x: rect.minX - window.minX, y: window.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Like `CGRect.contains` but inclusive of the max edges: the cursor pinned at the
    /// top of the screen reports `y == maxY`.
    public static func contains(_ rect: CGRect, _ p: CGPoint) -> Bool {
        p.x >= rect.minX && p.x <= rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
    }

    /// The window passes clicks through unless its content is visible and the cursor
    /// is on the hit rect. Depends only on the current cursor, never on earlier state.
    public static func ignoresMouse(visible: Bool, hitRect: CGRect, cursor: CGPoint) -> Bool {
        !(visible && contains(hitRect, cursor))
    }

    /// `ignoresMouse` for a mode: the drop zone takes the whole window while visible (C20).
    public static func ignoresMouse(mode: PanelMode, visible: Bool, layout: PanelLayout, cursor: CGPoint) -> Bool {
        if mode.acceptsDrops { return !visible }
        return ignoresMouse(visible: visible, hitRect: layout.hitRect(for: mode), cursor: cursor)
    }

    /// AppKit global coordinates (bottom-left of the primary display) → Quartz (top-left).
    public static func cgRect(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
