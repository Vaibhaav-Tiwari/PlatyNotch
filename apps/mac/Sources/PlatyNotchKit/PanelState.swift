public enum PanelMode: Equatable, Sendable {
    case hidden, compact, peek(PeekReason), expanded
}

public enum PeekReason: Equatable, Sendable {
    case approval, notice
}

public enum PanelEvent: Equatable, Sendable {
    case hoverEnter, hoverExit, click, escape
    case approvalsChanged(count: Int)
    case notice, noticeTimeout
}

/// Pure state machine for the notch panel; no AppKit.
public struct PanelStateMachine: Sendable {
    public var minimal: Bool {
        didSet { if minimal != oldValue, isIdle { mode = idleMode(hasLive: hasLive) } }
    }
    public private(set) var mode: PanelMode
    private var hasLive = false
    private var approvalCount = 0

    public init(minimal: Bool = false) {
        self.minimal = minimal
        self.mode = minimal ? .hidden : .compact
    }

    /// `.hidden` when `minimal` and nothing is live (active/blocked session, music); else `.compact`.
    public func idleMode(hasLive: Bool) -> PanelMode {
        minimal && !hasLive ? .hidden : .compact
    }

    public mutating func setLive(_ hasLive: Bool) {
        self.hasLive = hasLive
        if isIdle { mode = idleMode(hasLive: hasLive) }
    }

    public mutating func handle(_ e: PanelEvent) {
        switch e {
        case .approvalsChanged(let n):
            approvalCount = max(n, 0)
            if n > 0 {
                if mode != .expanded { mode = .peek(.approval) }
            } else if mode == .peek(.approval) {
                mode = idle
            }
        case .hoverEnter:
            if isIdle { mode = .expanded }
        case .hoverExit:
            if mode == .expanded { mode = settled }
        case .click:
            mode = mode == .expanded ? settled : .expanded
        case .escape:
            switch mode {
            case .expanded: mode = settled
            case .peek(.notice): mode = settled
            case .peek(.approval): break  // stays until answered or expired
            case .hidden, .compact: break
            }
        case .notice:
            if isIdle { mode = .peek(.notice) }
        case .noticeTimeout:
            if mode == .peek(.notice) { mode = settled }
        }
    }

    private var idle: PanelMode { idleMode(hasLive: hasLive) }
    /// Where the panel rests after a transient state ends: pending approvals keep it peeking.
    private var settled: PanelMode { approvalCount > 0 ? .peek(.approval) : idle }
    private var isIdle: Bool { mode == .hidden || mode == .compact }
}
