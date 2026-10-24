import CoreGraphics
import Foundation

/// Where window snapping (v0.2 Task 5) puts the focused window.
public enum SnapTarget: String, CaseIterable, Codable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case maximize, center
    case topLeft, topRight, bottomLeft, bottomRight

    /// What Settings shows next to the shortcut.
    public var title: String {
        switch self {
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .leftThird: "Left third"
        case .centerThird: "Center third"
        case .rightThird: "Right third"
        case .leftTwoThirds: "Left two thirds"
        case .rightTwoThirds: "Right two thirds"
        case .maximize: "Maximize"
        case .center: "Center"
        case .topLeft: "Top left quarter"
        case .topRight: "Top right quarter"
        case .bottomLeft: "Bottom left quarter"
        case .bottomRight: "Bottom right quarter"
        }
    }

    /// Center keeps the window's size and only moves it (it shrinks only when it would
    /// not fit the screen); every other target sets the size too.
    public var keepsSize: Bool { self == .center }

    /// The default shortcut: ⌃⌥ with arrows (halves), U I J K (quarters), D F G (thirds),
    /// E T (two thirds), ↩ (maximize) and C (center). None is a clipboard preset (R6).
    public var defaultCombo: KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: KeyCombo.control | KeyCombo.option)
    }

    /// `kVK_*` of the default shortcut's key.
    private var keyCode: UInt32 {
        switch self {
        case .leftHalf: 123      // ←
        case .rightHalf: 124     // →
        case .bottomHalf: 125    // ↓
        case .topHalf: 126       // ↑
        case .topLeft: 32        // U
        case .topRight: 34       // I
        case .bottomLeft: 38     // J
        case .bottomRight: 40    // K
        case .leftThird: 2       // D
        case .centerThird: 3     // F
        case .rightThird: 5      // G
        case .leftTwoThirds: 14  // E
        case .rightTwoThirds: 17 // T
        case .maximize: 36       // ↩
        case .center: 8          // C
        }
    }

    /// The feature id each shortcut is held under in `HotKeyCatalog` ("snap.leftHalf").
    public var hotKeyFeature: String { "snap." + rawValue }
}

/// A display as AppKit reports it (bottom-left origin, y up): its whole frame and the
/// part outside the menu bar and Dock.
public struct SnapScreen: Equatable, Sendable {
    public var frame: CGRect
    public var visible: CGRect

    public init(frame: CGRect, visible: CGRect) {
        self.frame = frame
        self.visible = visible
    }
}

/// What to do to the window, in Accessibility coordinates (top-left origin of the primary
/// display, y down). `size` is nil when the window is only moved. `area` (the target)
/// and `bounds` (the screen's visible frame) let a window that kept another size than
/// asked be centred again (`SnapLayout.position(centering:in:)`).
public struct SnapPlan: Equatable, Sendable {
    public var position: CGPoint
    public var size: CGSize?
    public var area: CGRect
    public var bounds: CGRect

    public init(position: CGPoint, size: CGSize?, area: CGRect = .zero, bounds: CGRect = .zero) {
        self.position = position
        self.size = size
        self.area = area
        self.bounds = bounds
    }
}

/// Window snapping geometry. `frame(for:in:gap:)` works in AppKit coordinates (the
/// screen's `visibleFrame`); Accessibility uses a top-left origin, so every frame read
/// from or written to a window goes through `axFrame(from:primaryScreenHeight:)` (R15).
public enum SnapLayout {
    /// Gaps Settings offers, in points (0: windows touch each other and the edges).
    public static let gapPresets: [Int] = [0, 4, 8, 12]
    public static let gapDefaultsKey = "snap.gap"

    /// The target's frame inside `visible` (AppKit coordinates). `gap` is left at every
    /// screen edge and between neighbouring targets, so three thirds (or two halves, or
    /// four quarters) tile `visible` exactly: three widths and four gaps make its width.
    /// `center` returns the area the window is centered in (the maximize frame).
    public static func frame(for t: SnapTarget, in visible: CGRect, gap: CGFloat) -> CGRect {
        let g: CGFloat = max(0, gap)
        let x0: CGFloat = visible.minX
        let y0: CGFloat = visible.minY
        let w: CGFloat = visible.width
        let h: CGFloat = visible.height
        let halfW: CGFloat = (w - 3 * g) / 2
        let halfH: CGFloat = (h - 3 * g) / 2
        let third: CGFloat = (w - 4 * g) / 3
        let full = CGRect(x: x0 + g, y: y0 + g, width: w - 2 * g, height: h - 2 * g)
        // AppKit's y grows upwards: the top half has the larger y.
        let lowY: CGFloat = y0 + g
        let highY: CGFloat = y0 + 2 * g + halfH
        let rightX: CGFloat = x0 + 2 * g + halfW
        switch t {
        case .maximize, .center:
            return full
        case .leftHalf:
            return CGRect(x: x0 + g, y: full.minY, width: halfW, height: full.height)
        case .rightHalf:
            return CGRect(x: rightX, y: full.minY, width: halfW, height: full.height)
        case .topHalf:
            return CGRect(x: full.minX, y: highY, width: full.width, height: halfH)
        case .bottomHalf:
            return CGRect(x: full.minX, y: lowY, width: full.width, height: halfH)
        case .topLeft:
            return CGRect(x: x0 + g, y: highY, width: halfW, height: halfH)
        case .topRight:
            return CGRect(x: rightX, y: highY, width: halfW, height: halfH)
        case .bottomLeft:
            return CGRect(x: x0 + g, y: lowY, width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: rightX, y: lowY, width: halfW, height: halfH)
        case .leftThird:
            return CGRect(x: x0 + g, y: full.minY, width: third, height: full.height)
        case .centerThird:
            return CGRect(x: x0 + 2 * g + third, y: full.minY, width: third, height: full.height)
        case .rightThird:
            return CGRect(x: x0 + 3 * g + 2 * third, y: full.minY, width: third, height: full.height)
        case .leftTwoThirds:
            return CGRect(x: x0 + g, y: full.minY, width: 2 * third + g, height: full.height)
        case .rightTwoThirds:
            return CGRect(x: x0 + 2 * g + third, y: full.minY, width: 2 * third + g, height: full.height)
        }
    }

    /// AppKit ⇄ Accessibility: both measure from the primary display (the one at the
    /// origin, `NSScreen.screens.first`), AppKit from its bottom edge going up and AX from
    /// its top edge going down. The flip uses the primary display's height for every
    /// display, also one above, below or left of it (negative coordinates). Its own inverse.
    public static func axFrame(from frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The screen a window (AppKit coordinates) belongs to: the one holding its center,
    /// else the one it overlaps most (a window mostly off-screen), else the first.
    /// Nil only for no screens.
    public static func screenIndex(for window: CGRect, in screens: [SnapScreen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: window.midX, y: window.midY)
        if let i = screens.firstIndex(where: { $0.frame.contains(center) }) { return i }
        var best = 0
        var bestArea: CGFloat = 0
        for (i, s) in screens.enumerated() {
            let r = s.frame.intersection(window)
            let area: CGFloat = r.isNull ? 0 : r.width * r.height
            if area > bestArea {
                best = i
                bestArea = area
            }
        }
        return best
    }

    /// What to set on a window at `windowAX` (Accessibility coordinates) to snap it to `t`
    /// on its own screen. A window whose size cannot be set (`resizable` false), and
    /// `center`, keep their size: centered in the target, kept inside the visible frame
    /// (its top-left corner wins when it is larger). Nil when there are no screens.
    public static func plan(_ t: SnapTarget, windowAX: CGRect, resizable: Bool, screens: [SnapScreen],
                            primaryScreenHeight: CGFloat, gap: CGFloat) -> SnapPlan? {
        let window = axFrame(from: windowAX, primaryScreenHeight: primaryScreenHeight)
        guard let i = screenIndex(for: window, in: screens) else { return nil }
        let visible = screens[i].visible
        let target = frame(for: t, in: visible, gap: gap)
        let cocoa: CGRect
        let setsSize: Bool
        if !resizable || t.keepsSize {
            var size = window.size
            // Center may shrink a too-large resizable window to the area; a fixed one never.
            if resizable {
                size = CGSize(width: min(size.width, target.width), height: min(size.height, target.height))
            }
            setsSize = size != window.size
            cocoa = clamped(centered(size, in: target), to: visible)
        } else {
            setsSize = true
            cocoa = target
        }
        // Whole points, edges rounded (not origin and size apart): neighbouring targets
        // share an edge exactly, with no 1 pt seam or overlap.
        let ax = edgesRounded(axFrame(from: cocoa, primaryScreenHeight: primaryScreenHeight))
        return SnapPlan(position: ax.origin, size: setsSize ? ax.size : nil,
                        area: axFrame(from: target, primaryScreenHeight: primaryScreenHeight),
                        bounds: axFrame(from: visible, primaryScreenHeight: primaryScreenHeight))
    }

    /// Where a window of `size` goes when it kept another size than `plan` asked for (an
    /// app that says its size is settable but refuses it): centred in the plan's area and
    /// kept inside its bounds, top-left corner first. Accessibility coordinates.
    public static func position(centering size: CGSize, in plan: SnapPlan) -> CGPoint {
        let a = plan.area
        let b = plan.bounds
        var x: CGFloat = a.midX - size.width / 2
        var y: CGFloat = a.midY - size.height / 2
        if size.width >= b.width { x = b.minX } else { x = min(max(x, b.minX), b.maxX - size.width) }
        // AX y grows downwards: the top edge is minY.
        if size.height >= b.height { y = b.minY } else { y = min(max(y, b.minY), b.maxY - size.height) }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// `r` with each edge on a whole point; the size follows from the edges.
    static func edgesRounded(_ r: CGRect) -> CGRect {
        let minX: CGFloat = r.minX.rounded()
        let minY: CGFloat = r.minY.rounded()
        let maxX: CGFloat = r.maxX.rounded()
        let maxY: CGFloat = r.maxY.rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Moves `r` inside `bounds`; when it is wider or taller, its left or top edge
    /// (AppKit's maxY) lines up with the bounds' so the title bar stays reachable.
    private static func clamped(_ r: CGRect, to bounds: CGRect) -> CGRect {
        var x: CGFloat = r.minX
        var y: CGFloat = r.minY
        if r.width >= bounds.width { x = bounds.minX } else { x = min(max(x, bounds.minX), bounds.maxX - r.width) }
        if r.height >= bounds.height {
            y = bounds.maxY - r.height
        } else {
            y = min(max(y, bounds.minY), bounds.maxY - r.height)
        }
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }
}
