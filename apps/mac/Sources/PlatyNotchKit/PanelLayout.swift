import CoreGraphics

/// Where the notch panel sits on one screen and which rect each mode occupies.
/// Pure geometry in AppKit screen coordinates (origin bottom-left).
public struct PanelLayout: Equatable, Sendable {
    /// Extra width on each side of the physical notch in compact mode.
    public static let compactEar: CGFloat = 64
    /// Compact pill width on screens without a notch.
    public static let pillWidth: CGFloat = 200
    /// Room for an approval card below the notch: header, a few summary lines, buttons.
    public static let peekSize = CGSize(width: 420, height: 210)
    /// Height of a notice peek below the notch (or the menu bar).
    public static let noticeHeight: CGFloat = 64
    public static let expandedSize = CGSize(width: 560, height: 380)
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
        case .expanded: NotchGeometry.panelFrame(anchor: anchor, size: Self.expandedSize, screenFrame: usable)
        }
    }

    /// Where the cursor counts as "on the panel" for `mode`.
    /// Hidden: the notch itself, or a strip at the screen's top edge above the pill.
    public func hitRect(for mode: PanelMode) -> CGRect {
        guard mode == .hidden else { return contentRect(for: mode) }
        return hasNotch ? anchor : revealRect
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

    /// AppKit global coordinates (bottom-left of the primary display) → Quartz (top-left).
    public static func cgRect(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
