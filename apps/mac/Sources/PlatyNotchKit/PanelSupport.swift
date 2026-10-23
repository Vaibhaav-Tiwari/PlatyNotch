extension PanelMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .hidden: "hidden"
        case .compact: "compact"
        case .peek(.approval): "peek(approval)"
        case .peek(.notice): "peek(notice)"
        case .expanded: "expanded"
        }
    }
}

extension PanelMode {
    /// The panel takes keyboard focus only when open for the user or showing an approval.
    public var canBecomeKey: Bool {
        self == .expanded || self == .peek(.approval)
    }

    /// No shadow while hidden or compact (it would outline the notch).
    public var hasShadow: Bool {
        self != .hidden && self != .compact
    }

    /// Whether anything is "live" for `PanelStateMachine.setLive`: an active or blocked session.
    public static func hasLive(sessions: [Session]) -> Bool {
        sessions.contains { $0.state == .active || $0.state == .blocked }
    }
}
