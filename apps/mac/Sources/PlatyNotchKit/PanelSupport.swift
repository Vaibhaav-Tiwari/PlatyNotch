import Foundation

extension PanelMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .hidden: "hidden"
        case .compact: "compact"
        case .peek(.approval): "peek(approval)"
        case .peek(.notice): "peek(notice)"
        case .peek(.widget(let id)): "peek(widget:\(id))"
        case .peek(.hud(let kind)): "peek(hud:\(kind.rawValue))"
        case .peek(.ringing(let id)): "peek(ringing:\(id))"
        case .peek(.drop): "peek(drop)"
        case .peek(.hover): "peek(hover)"
        case .expanded: "expanded"
        }
    }
}

extension PanelMode {
    /// The panel takes keyboard focus only when open for the user or showing an approval.
    /// Widget peeks, HUDs, ringing and the drop zone never take focus (their buttons work
    /// with a click on the non-activating panel).
    public var canBecomeKey: Bool {
        self == .expanded || self == .peek(.approval)
    }

    /// The drop zone: the whole window accepts mouse events (C20), so a drag gets its
    /// first drag-enter without waiting for the cursor sample to catch up.
    public var acceptsDrops: Bool {
        self == .peek(.drop)
    }

    /// No shadow while hidden or compact (it would outline the notch).
    public var hasShadow: Bool {
        self != .hidden && self != .compact
    }

    /// Whether anything is "live" for `PanelStateMachine.setLive`: an active or blocked session.
    public static func hasLive(sessions: [Session]) -> Bool {
        sessions.contains { $0.state == .active || $0.state == .blocked }
    }

    /// Sessions, or any widget live activity above ambient priority (music, focus, timers).
    /// Ambient ones (shelf, weather) never keep the pill up in Minimal mode. The
    /// plugin-compatible form: the app itself uses `PillContent.keepsMinimalUp`, which
    /// also counts approvals and sessions waiting for you, and leaves out hidden kinds.
    public static func hasLive(sessions: [Session], activities: [LiveActivity], now: Date) -> Bool {
        hasLive(sessions: sessions) || LiveArbiter.hasLive(activities, now: now)
    }
}
