import Foundation

/// How an agent dot in the pill shows its session's state (spec 6.7): a pulse while
/// working, solid while it waits for you (or errored), hollow otherwise.
public enum AgentDotStyle: Sendable, Equatable {
    case pulse, solid, hollow

    public init(_ a: AgentAttention) {
        switch a {
        case .working: self = .pulse
        case .needsYou, .errored: self = .solid
        case .finished, .idle, .exited: self = .hollow
        }
    }
}

/// What the compact pill shows (spec 6.1, 6.7): the agent dots beside Platy, the
/// approval badge, the top non-agent live item on the trailing side and up to two
/// indicator dots for the next ones, all from the one priority model.
public struct PillContent: Equatable, Sendable {
    public static let indicatorLimit = 2

    public let dots: PillDots
    public let approvalCount: Int
    /// The top non-agent live item whose kind shows in the pill.
    public let trailing: LiveActivity?
    /// The next ones, at most `indicatorLimit`; an ambient item never sits beside a
    /// non-ambient trailing item.
    public let indicators: [LiveActivity]
    /// Sessions by how they stand (`AgentAttention`, with the finish log), every live
    /// session counted (overflow included); exited sessions are left out. What VoiceOver
    /// reads for the agents ear.
    public let attentionCounts: [AgentAttention: Int]
    private let sessionsLive: Bool

    public init(activities: [LiveActivity], sessions: [Session], approvals: Int, hiddenKinds: Set<NotificationKind>,
                now: Date) {
        self.init(activities: activities, sessions: sessions, approvals: approvals, hiddenKinds: hiddenKinds,
                  log: AgentFinishLog(), now: now)
    }

    /// The same, with the app's finish log, so errored and finished sessions are named.
    public init(activities: [LiveActivity], sessions: [Session], approvals: Int, hiddenKinds: Set<NotificationKind>,
                log: AgentFinishLog, now: Date) {
        dots = PillDots(sessions: sessions)
        approvalCount = approvals
        var counts: [AgentAttention: Int] = [:]
        for s in sessions {
            let a = AgentAttention.of(s, log: log, now: now)
            if a != .exited { counts[a, default: 0] += 1 }
        }
        attentionCounts = counts
        let live: Bool = sessions.contains { s in
            let a = AgentAttention(state: s.state)
            return a == .working || a == .needsYou
        }
        sessionsLive = live
        // Ruling 4 (coordinator: agents count as live): with agents working or waiting, or
        // an approval, ambient items leave the pill altogether.
        let agentsLive: Bool = live || approvals > 0
        let shown: [LiveActivity] = PriorityModel.rank(activities, agents: nil, now: now).compactMap { item in
            guard case .activity(let a) = item.source, !hiddenKinds.contains(item.rank.notificationKind) else { return nil }
            if agentsLive, a.isAmbient { return nil }
            return a
        }
        let top = shown.first
        trailing = top
        let topAmbient: Bool = top?.isAmbient ?? true
        let rest = shown.dropFirst().filter { topAmbient || !$0.isAmbient }
        indicators = Array(rest.prefix(Self.indicatorLimit))
    }

    /// Live sessions (exited ones left out).
    public var sessionCount: Int { attentionCounts.values.reduce(0, +) }

    /// "3 agent sessions: 1 needs you, 2 working" (most urgent first); "No agent sessions".
    public var sessionsSummary: String {
        let total: Int = sessionCount
        guard total > 0 else { return "No agent sessions" }
        let head: String = total == 1 ? "1 agent session" : "\(total) agent sessions"
        let order: [AgentAttention] = [.needsYou, .errored, .working, .finished, .idle]
        let parts: [String] = order.compactMap { a in attentionCounts[a].map { "\($0) \(a.word)" } }
        return head + ": " + parts.joined(separator: ", ")
    }

    /// Whether Minimal mode keeps the pill up: approvals, a session working or waiting
    /// for you, or a non-ambient item the pill shows.
    public var keepsMinimalUp: Bool {
        approvalCount > 0 || sessionsLive || ([trailing].compactMap { $0 } + indicators).contains { !$0.isAmbient }
    }
}
