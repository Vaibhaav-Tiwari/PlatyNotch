/// Turns store snapshots (approval count, latest notice) into `PanelEvent`s,
/// remembering what was already delivered so nothing is replayed.
public struct PanelFeed: Equatable, Sendable {
    public private(set) var approvalCount: Int
    public private(set) var lastNotice: Notice?

    /// Seed with what is already shown (e.g. the store's latest notice) to suppress replays.
    public init(approvalCount: Int = 0, lastNotice: Notice? = nil) {
        self.approvalCount = approvalCount
        self.lastNotice = lastNotice
    }

    /// With `holdNotices` (a focus session is running) a new notice is consumed without a
    /// `.notice` event, so it neither peeks now nor replays when focus ends. Approvals still pass.
    public mutating func update(approvalCount n: Int, latestNotice: Notice?, holdNotices: Bool = false) -> [PanelEvent] {
        var events: [PanelEvent] = []
        if n != approvalCount {
            approvalCount = n
            events.append(.approvalsChanged(count: n))
        }
        if let latestNotice, latestNotice != lastNotice {
            lastNotice = latestNotice
            if !holdNotices { events.append(.notice) }
        }
        return events
    }
}

/// Panel state handed from an old controller to its replacement when displays change,
/// so a rebuild neither collapses an open panel nor replays the last notice.
public struct PanelCarryOver: Sendable {
    public var machine: PanelStateMachine
    public var feed: PanelFeed

    public init(machine: PanelStateMachine, feed: PanelFeed) {
        self.machine = machine
        self.feed = feed
    }
}
