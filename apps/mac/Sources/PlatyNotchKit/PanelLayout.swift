import CoreGraphics

/// Where the notch panel sits on one screen and which rect each mode occupies.
/// Pure geometry in AppKit screen coordinates (origin bottom-left).
public struct PanelLayout: Equatable, Sendable {
    /// Extra width on each side of the physical notch in compact mode (standard pill width).
    public static let compactEar: CGFloat = 64
    /// Compact pill width on screens without a notch (standard pill width).
    public static let pillWidth: CGFloat = 200

    /// Horizontal padding inside the compact pill, each side (`CompactPill`).
    public static func pillPadding(hasNotch: Bool) -> CGFloat { hasNotch ? 6 : 14 }

    /// Room for the live ear's content in the compact pill: beside a notch, the ear less
    /// the pill's padding; without one, half the pill less its padding (the agent dots
    /// take the other half).
    public var liveEarWidth: CGFloat {
        let pad = Self.pillPadding(hasNotch: hasNotch)
        return hasNotch ? ear - pad : (anchor.width - 2 * pad) / 2
    }

    /// Ear width beside a notch for each Appearance › Pill width.
    public static func ear(_ width: AppearanceSettings.PillWidth) -> CGFloat {
        switch width {
        case .compact: 40
        case .standard: compactEar
        case .wide: 96
        }
    }

    /// Pill width without a notch for each Appearance › Pill width.
    public static func pillWidth(_ width: AppearanceSettings.PillWidth) -> CGFloat {
        switch width {
        case .compact: 150
        case .standard: pillWidth
        case .wide: 260
        }
    }
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
    /// Without a notch, the approval peek, the open panel and the drop zone (which has the
    /// open panel's size) start with a header strip this tall (the ringing chip's place) instead of the usual 10 pt inset.
    public static let headerStrip: CGFloat = 26
    /// How much taller those two are without a notch, so card room is unchanged.
    public static let headerStripExtra: CGFloat = headerStrip - 10
    /// The ringing chip (bell + Stop).
    public static let chipSize = CGSize(width: 84, height: 20)
    /// How near the notch (or pill) a drag must come to open the drop zone.
    public static let dragReach: CGFloat = 60
    /// Height of the top-edge strip that reveals a hidden panel on screens without a notch.
    public static let revealDepth: CGFloat = 3

    public let screenFrame: CGRect
    /// The physical notch, or the pill just below the menu bar.
    public let anchor: CGRect
    public let hasNotch: Bool
    /// Extra width on each side of the notch in compact mode (`ear(_:)`).
    public let ear: CGFloat

    public init(screenFrame: CGRect, visibleFrame: CGRect, auxLeft: CGRect?, auxRight: CGRect?,
                pillWidth: AppearanceSettings.PillWidth = .standard) {
        self.screenFrame = screenFrame
        ear = Self.ear(pillWidth)
        if let notch = NotchGeometry.notchRect(screenFrame: screenFrame, auxLeft: auxLeft, auxRight: auxRight) {
            anchor = notch
            hasNotch = true
        } else {
            anchor = NotchGeometry.pillRect(screenFrame: screenFrame, visibleFrame: visibleFrame,
                                            width: Self.pillWidth(pillWidth))
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
        hasNotch ? anchor.insetBy(dx: -ear, dy: 0) : anchor
    }

    /// The fixed window frame: big enough for every mode's content.
    public var windowFrame: CGRect {
        let size = CGSize(width: max(Self.expandedSize.width, compactRect.width),
                          height: max(expandedSize.height, compactRect.height))
        return NotchGeometry.panelFrame(anchor: anchor, size: size, screenFrame: usable)
    }

    /// The visible content for `mode` (hidden draws nothing but keeps the compact rect).
    public func contentRect(for mode: PanelMode) -> CGRect {
        switch mode {
        case .hidden, .compact: compactRect
        case .peek(.approval):
            NotchGeometry.panelFrame(anchor: anchor, size: CGSize(width: Self.peekSize.width,
                                                                  height: Self.peekSize.height + stripExtra),
                                     screenFrame: usable)
        case .peek(.notice):
            NotchGeometry.panelFrame(anchor: anchor, size: CGSize(width: Self.peekSize.width,
                                                                  height: (hasNotch ? anchor.height : 0) + Self.noticeHeight),
                                     screenFrame: usable)
        case .expanded, .peek(.drop):
            NotchGeometry.panelFrame(anchor: anchor, size: expandedSize, screenFrame: usable)
        case .peek(.widget): below(width: Self.surfaceWidth, height: Self.widgetPeekHeight)
        case .peek(.ringing): below(width: Self.surfaceWidth, height: Self.ringingHeight)
        case .peek(.hud): below(width: max(Self.hudMinWidth, compactRect.width), height: Self.hudHeight)
        }
    }

    private var stripExtra: CGFloat { hasNotch ? 0 : Self.headerStripExtra }
    private var expandedSize: CGSize {
        CGSize(width: Self.expandedSize.width, height: Self.expandedSize.height + stripExtra)
    }

    /// Inset from the content rect's top to where a mode's content starts: below the
    /// camera housing on a notch; below the header strip for the approval peek, the
    /// open panel and the drop zone without one; else 10 pt.
    public func contentInset(for mode: PanelMode) -> CGFloat {
        if hasNotch { return anchor.height + 4 }
        switch mode {
        case .peek(.approval), .expanded, .peek(.drop): return Self.headerStrip
        default: return 10
        }
    }

    /// Where the approval cards sit (the approval peek, the open panel's column).
    public func approvalSlot(for mode: PanelMode) -> CGRect? {
        switch mode {
        case .peek(.approval), .expanded:
            let c = contentRect(for: mode)
            return CGRect(x: c.minX + 12, y: c.minY + 10, width: c.width - 24,
                          height: c.height - 10 - contentInset(for: mode))
        default: return nil
        }
    }

    /// The ringing chip under an approval peek or the open panel: the right ear beside the
    /// camera on a notch, else the right of the header strip. Never inside `approvalSlot`.
    public func ringingChipRect(for mode: PanelMode) -> CGRect? {
        switch mode {
        case .peek(.approval), .expanded, .peek(.drop): break
        default: return nil
        }
        let c = contentRect(for: mode)
        let size = Self.chipSize
        if hasNotch {
            let left = anchor.maxX + 6, right = c.maxX - 10
            let w = min(size.width, right - left)
            return CGRect(x: right - w, y: anchor.midY - size.height / 2, width: w, height: size.height)
        }
        return CGRect(x: c.maxX - 10 - size.width, y: c.maxY - 3 - size.height, width: size.width, height: size.height)
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
