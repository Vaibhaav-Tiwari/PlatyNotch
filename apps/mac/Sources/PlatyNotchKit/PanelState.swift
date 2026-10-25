import Foundation

public enum PanelMode: Equatable, Sendable {
    case hidden, compact, peek(PeekReason), expanded
}

public enum PeekReason: Equatable, Sendable {
    case approval, notice
    /// A widget's short peek (wellbeing nudge, plug-in, AirPods); the id is the widget's own.
    case widget(id: String)
    /// A brief level HUD (volume, brightness, keyboard backlight).
    case hud(HUDKind)
    /// A ringing alarm or timer: sticky until the widget stops it.
    case ringing(id: String)
    /// The drop zone while a drag is near the notch.
    case drop
    /// Now's hero only, while the cursor rests on the pill (Appearance › Open on: Peek on
    /// hover, open on click). Never takes keyboard focus, never holds approval cards.
    case hover
}

public enum HUDKind: String, Equatable, Sendable, CaseIterable {
    case volume, brightness, keyboardBacklight
}

/// A HUD on screen until `until`. `level` is 0…1.
public struct HUDState: Equatable, Sendable {
    public var kind: HUDKind
    public var level: Double
    public var until: Date

    public init(kind: HUDKind, level: Double, until: Date) {
        self.kind = kind
        self.level = min(max(level, 0), 1)
        self.until = until
    }
}

/// A widget peek on screen until `until`.
public struct WidgetPeek: Equatable, Sendable {
    public var id: String
    public var until: Date

    public init(id: String, until: Date) {
        self.id = id
        self.until = until
    }
}

public enum PanelEvent: Equatable, Sendable {
    case hoverEnter, hoverExit, click, escape
    case approvalsChanged(count: Int)
    case notice, noticeTimeout
    /// Shows widget peek `id` until `until` (replaces any other widget peek).
    case widgetPeek(id: String, until: Date)
    /// The widget closes its peek early (no-op unless `id` is the current peek).
    case widgetPeekEnded(id: String)
    /// Shows (or updates and extends) the HUD.
    case hud(HUDKind, level: Double, until: Date)
    /// Ends HUDs and widget peeks whose `until` is at or before `now`.
    case expire(now: Date)
    case ringStarted(id: String), ringStopped(id: String)
    /// The cursor carrying a drag came near the notch / left the drop zone or the drag ended.
    case dragBegan, dragEnded
    /// The drag ended (a drop, or the button released) with the cursor still on the drop
    /// zone: a panel that was open when the drag began opens again, unless an approval
    /// is pending or arrived during the drag.
    case dragEndedInside
}

/// Everything the panel's mode is derived from (the inputs of `PanelPrecedence.resolve`).
public struct PanelSurfaceState: Equatable, Sendable {
    public var approvals = 0
    /// The user opened the panel (hover, click, menu).
    public var open = false
    /// Ringing ids, oldest first.
    public var ringing: [String] = []
    public var dragging = false
    /// The panel was open when the current drag began (`.dragBegan` closes it); a drag
    /// that ends on the panel (`.dragEndedInside`) opens it again.
    public var openBeforeDrag = false
    public var hud: HUDState?
    public var notice = false
    public var widgetPeek: WidgetPeek?
    /// The cursor rests on the pill with "Peek on hover, open on click" on.
    public var hoverPeek = false
    public var fullScreen = false
    /// `.hidden` or `.compact`: where the panel rests with nothing to show.
    public var idle: PanelMode

    public init(idle: PanelMode) { self.idle = idle }
}

/// The precedence between panel surfaces, highest first:
///
/// 1. A pending approval: the approval peek, or the open panel (which lists approvals on top).
///    Nothing covers it; Escape never hides it.
/// 2. The open panel.
/// 3. The drop zone while a drag is near the notch. Never shown while an approval is
///    pending; a drag near an open panel (no approval) replaces it, and a drop on it
///    gives the open panel back (Task 5).
/// 4. Ringing (alarm, timer): beats HUDs and peeks; shows over full screen. Under an
///    approval, the open panel or the drop zone it is a fixed ringing chip with Stop in
///    the header (`ringingChip`), so the alarm never pressures an answer, never moves an
///    approval card and never covers the panel a drag opened.
/// 5. The hover peek (Peek on hover, open on click).
/// 6. A HUD (dropped over full screen; a tiny indicator under an approval or the open panel).
/// 7. An agent notice.
/// 8. A widget peek such as a nudge (held, not shown, over full screen).
/// 9. Idle: compact, or hidden in Minimal mode.
public enum PanelPrecedence {
    public static func resolve(_ s: PanelSurfaceState) -> PanelMode {
        if s.approvals > 0 { return s.open ? .expanded : .peek(.approval) }
        if s.open { return .expanded }
        if s.dragging { return .peek(.drop) }
        if let ring = s.ringing.first { return .peek(.ringing(id: ring)) }
        if s.hoverPeek { return .peek(.hover) }
        if let hud = s.hud, !s.fullScreen { return .peek(.hud(hud.kind)) }
        if s.notice { return .peek(.notice) }
        if let peek = s.widgetPeek, !s.fullScreen { return .peek(.widget(id: peek.id)) }
        return s.idle
    }

    /// The ringing id drawn as the header chip: something rings but an approval peek,
    /// the open panel or the drop zone is showing.
    public static func ringingChip(_ s: PanelSurfaceState) -> String? {
        guard let ring = s.ringing.first else { return nil }
        switch resolve(s) {
        case .peek(.approval), .expanded, .peek(.drop): return ring
        default: return nil
        }
    }

    /// A HUD that cannot show as its own surface because an approval peek or the open
    /// panel is up is drawn as a thin level line inside it. Under ringing or the drop zone it is dropped.
    public static func hudIndicator(_ s: PanelSurfaceState) -> HUDState? {
        guard let hud = s.hud, !s.fullScreen else { return nil }
        switch resolve(s) {
        case .peek(.approval), .expanded: return hud
        default: return nil
        }
    }

    /// Whether a HUD sent now would show as its own full surface: false over full
    /// screen, under an approval or the open panel (only the 2 pt indicator), under
    /// ringing and during the drop zone. The media-key tap takes a key (hiding the
    /// system HUD) only when this holds: never without full feedback.
    public static func hudWouldShow(_ s: PanelSurfaceState) -> Bool {
        guard !s.fullScreen else { return false }
        var probe = s
        probe.hud = HUDState(kind: .volume, level: 0, until: .distantFuture)
        return resolve(probe).isHUD
    }
}

/// Pure state machine for the notch panel; no AppKit.
public struct PanelStateMachine: Sendable {
    public var minimal: Bool {
        didSet { if minimal != oldValue { refresh() } }
    }
    /// Hovering the pill opens the panel (Appearance › Open on: hover). Off (click mode),
    /// only a click opens it; moving away still closes it.
    public var openOnHover = true
    /// Hovering the pill shows Now's hero as a peek (`.peek(.hover)`) and a click opens the
    /// panel (Appearance › Open on: Peek on hover). Used only while `openOnHover` is off.
    public var peekOnHover = false
    public private(set) var mode: PanelMode
    private var hasLive = false
    private var state: PanelSurfaceState

    public init(minimal: Bool = false) {
        self.minimal = minimal
        let idle: PanelMode = minimal ? .hidden : .compact
        self.state = PanelSurfaceState(idle: idle)
        self.mode = idle
    }

    /// `.hidden` when `minimal` and nothing is live (active/blocked session, music); else `.compact`.
    public func idleMode(hasLive: Bool) -> PanelMode {
        minimal && !hasLive ? .hidden : .compact
    }

    public mutating func setLive(_ hasLive: Bool) {
        self.hasLive = hasLive
        refresh()
    }

    /// Over a full-screen app HUDs are dropped and widget peeks held (approvals and ringing still show).
    public mutating func setFullScreen(_ fullScreen: Bool) {
        state.fullScreen = fullScreen
        if fullScreen { state.hud = nil }
        refresh()
    }

    /// Ringing ids, oldest first (games pause while any rings).
    public var ringing: [String] { state.ringing }
    public var hud: HUDState? { state.hud }
    public var widgetPeek: WidgetPeek? { state.widgetPeek }
    public var isDragging: Bool { state.dragging }
    /// See `PanelPrecedence.ringingChip`.
    public var ringingChip: String? { PanelPrecedence.ringingChip(state) }
    /// See `PanelPrecedence.hudIndicator`.
    public var hudIndicator: HUDState? { PanelPrecedence.hudIndicator(state) }
    /// See `PanelPrecedence.hudWouldShow`.
    public var hudWouldShow: Bool { PanelPrecedence.hudWouldShow(state) }
    /// When the next HUD or widget peek ends (send `.expire` then).
    public var nextExpiry: Date? {
        [state.hud?.until, state.widgetPeek?.until].compactMap { $0 }.min()
    }

    public mutating func handle(_ e: PanelEvent) {
        switch e {
        case .approvalsChanged(let n):
            state.approvals = max(n, 0)
            if n > 0 {
                state.notice = false   // a notice under an approval is dropped
                // An approval that arrives mid-drag is never opened by the drop (A1).
                state.openBeforeDrag = false
            }
        case .hoverEnter:
            if openOnHover, isIdle || mode.isHUD {
                open()
            } else if !openOnHover, peekOnHover, isIdle || mode.isHUD {
                state.hoverPeek = true
            }
        case .hoverExit:
            state.open = false   // also when ringing covers the open panel
            state.hoverPeek = false
        case .click:
            // From anywhere, ringing and the drop zone included (menu "Open PlatyNotch",
            // `expand(tab:)`); the ringing card and drop zone themselves never send it.
            if mode == .expanded { state.open = false } else { open() }
        case .escape:
            switch mode {
            case .expanded: state.open = false
            case .peek(.notice): state.notice = false
            case .peek(.hud): state.hud = nil
            case .peek(.widget): state.widgetPeek = nil
            case .peek(.hover): state.hoverPeek = false
            case .peek(.approval): break  // stays until answered or expired
            case .peek(.ringing), .peek(.drop): break   // the widget / the drag ends them
            case .hidden, .compact: break
            }
        case .notice:
            // Shown unless something above a notice is up (else dropped, as before).
            switch mode {
            case .hidden, .compact, .peek(.hud), .peek(.widget), .peek(.notice): state.notice = true
            default: break
            }
        case .noticeTimeout:
            state.notice = false
        case .widgetPeek(let id, let until):
            state.widgetPeek = WidgetPeek(id: id, until: until)
        case .widgetPeekEnded(let id):
            if state.widgetPeek?.id == id { state.widgetPeek = nil }
        case .hud(let kind, let level, let until):
            if !state.fullScreen { state.hud = HUDState(kind: kind, level: level, until: until) }
        case .expire(let now):
            if let h = state.hud, h.until <= now { state.hud = nil }
            if let p = state.widgetPeek, p.until <= now { state.widgetPeek = nil }
        case .ringStarted(let id):
            if !state.ringing.contains(id) { state.ringing.append(id) }
        case .ringStopped(let id):
            state.ringing.removeAll { $0 == id }
        case .dragBegan:
            state.dragging = true
            // A drag near the open panel turns it into the drop zone (remembered, so a
            // drop gives it back). With an approval pending the panel stays as it is (rule 1).
            if state.approvals == 0 {
                state.openBeforeDrag = state.open
                state.open = false
            }
        case .dragEnded:
            state.dragging = false
            state.openBeforeDrag = false
        case .dragEndedInside:
            state.dragging = false
            // Never while an approval is pending: the drop would expand the approval
            // peek under the cursor (rule 1, A1).
            if state.openBeforeDrag, state.approvals == 0 { state.open = true }
            state.openBeforeDrag = false
        }
        refresh()
    }

    /// Opening the panel consumes the notice and widget peek it covers; a HUD stays (as an indicator).
    private mutating func open() {
        state.open = true
        state.hoverPeek = false
        state.notice = false
        state.widgetPeek = nil
    }

    private mutating func refresh() {
        state.idle = idleMode(hasLive: hasLive)
        mode = PanelPrecedence.resolve(state)
    }

    private var isIdle: Bool { mode == .hidden || mode == .compact }
}

extension PanelMode {
    public var isHUD: Bool {
        if case .peek(.hud) = self { return true }
        return false
    }
}
