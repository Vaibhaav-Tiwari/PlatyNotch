/// Turns store snapshots (approval count, notice sequence) into `PanelEvent`s,
/// remembering what was already delivered so nothing is replayed.
public struct PanelFeed: Equatable, Sendable {
    public private(set) var approvalCount: Int
    /// `AppStore.noticeSequence` of the last notice delivered (or consumed). A sequence,
    /// not the notice itself: two identical notices in a row must both peek.
    public private(set) var noticeSequence: Int

    /// Seed with what is already shown (the store's `noticeSequence`) to suppress replays.
    public init(approvalCount: Int = 0, noticeSequence: Int = 0) {
        self.approvalCount = approvalCount
        self.noticeSequence = noticeSequence
    }

    /// With `holdNotices` (a focus session is running) a new notice is consumed without a
    /// `.notice` event, so it neither peeks now nor replays when focus ends. Approvals still pass.
    public mutating func update(approvalCount n: Int, noticeSequence seq: Int, holdNotices: Bool = false) -> [PanelEvent] {
        var events: [PanelEvent] = []
        if n != approvalCount {
            approvalCount = n
            events.append(.approvalsChanged(count: n))
        }
        if seq > noticeSequence {
            noticeSequence = seq
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
