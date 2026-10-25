import Foundation

/// All agent sessions together as one live item (spec 6.7), ranked by the most urgent
/// session: needs you or errored → rank 4, working → 9, a finish in the last 10 minutes
/// → 5, else nothing.
public struct AgentsLive: Equatable, Sendable {
    public let rank: LiveRank
    /// "Claude Code · platynotch": the most urgent session.
    public let title: String
    /// What that session is doing, e.g. "Running tests" or "Needs your input".
    public let subtitle: String?
    public let startedAt: Date
    /// Sessions that need you or errored.
    public let needsYou: Int
    public let working: Int
    /// Sessions that have not exited.
    public let total: Int

    public init(rank: LiveRank, title: String, subtitle: String?, startedAt: Date, needsYou: Int, working: Int, total: Int) {
        self.rank = rank
        self.title = title
        self.subtitle = subtitle
        self.startedAt = startedAt
        self.needsYou = needsYou
        self.working = working
        self.total = total
    }

    public static func make(sessions: [Session], log: AgentFinishLog, now: Date) -> AgentsLive? {
        let rated: [(Session, AgentAttention)] = sessions.map { ($0, AgentAttention.of($0, log: log, now: now)) }
        let needsYou = rated.filter { $0.1 == .needsYou || $0.1 == .errored }
        let working = rated.filter { $0.1 == .working }
        let total = rated.filter { $0.1 != .exited }.count
        let rank: LiveRank
        let pool: [(Session, AgentAttention)]
        if !needsYou.isEmpty {
            rank = .agentNeedsYou
            // Needs you before errored, then the oldest.
            let best = needsYou.map(\.1).min() ?? .needsYou
            pool = needsYou.filter { $0.1 == best }
        } else if !working.isEmpty {
            rank = .agentsWorking
            pool = working
        } else if let finishedAt = log.lastFinish(now: now) {
            let finished = rated.filter { $0.1 == .finished }
            let lead = finished.min { $0.0.startedAt < $1.0.startedAt }?.0
            return AgentsLive(rank: .agentFinished, title: lead.map(title(of:)) ?? "Agent finished",
                              subtitle: "Finished", startedAt: finishedAt, needsYou: 0, working: 0, total: total)
        } else {
            return nil
        }
        guard let (lead, attention) = pool.min(by: { $0.0.startedAt < $1.0.startedAt }) else { return nil }
        return AgentsLive(rank: rank, title: title(of: lead), subtitle: subtitle(lead, attention), startedAt: lead.startedAt,
                          needsYou: needsYou.count, working: working.count, total: total)
    }

    /// "Claude Code · platynotch", or the agent's name alone without a project.
    public static func title(of s: Session) -> String {
        guard let project = s.project, !project.isEmpty else { return s.agentName }
        return "\(s.agentName) · \(project)"
    }

    private static func subtitle(_ s: Session, _ a: AgentAttention) -> String {
        switch a {
        case .needsYou: s.state == .blocked ? "Waiting for approval" : "Needs your input"
        case .errored: "Stopped with an error"
        default: s.title ?? s.tool ?? "Working"
        }
    }
}
