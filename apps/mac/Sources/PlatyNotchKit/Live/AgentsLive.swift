import Foundation

/// All agent sessions together as one live item (spec 6.7), ranked by the most urgent
/// session: needs you or errored → rank 4, a finish in the last 10 minutes → 5, working
/// → 9, else nothing. So one working session beside one that just finished ranks 5 (the
/// finished summary, with the working count beside it).
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
    /// The most urgent session's key ("" when it is no longer listed, e.g. a finished
    /// session the core already dropped).
    public let leadKey: String
    /// How that session stands (errored stays errored: the hero shows the error state).
    public let leadAttention: AgentAttention

    public init(rank: LiveRank, title: String, subtitle: String?, startedAt: Date, needsYou: Int, working: Int, total: Int,
                leadKey: String = "", leadAttention: AgentAttention? = nil) {
        self.rank = rank
        self.title = title
        self.subtitle = subtitle
        self.startedAt = startedAt
        self.needsYou = needsYou
        self.working = working
        self.total = total
        self.leadKey = leadKey
        self.leadAttention = leadAttention ?? Self.attention(for: rank)
    }

    /// The attention a rank stands for when no session says otherwise.
    public static func attention(for rank: LiveRank) -> AgentAttention {
        switch rank {
        case .agentNeedsYou: .needsYou
        case .agentFinished: .finished
        default: .working
        }
    }

    public static func make(sessions: [Session], log: AgentFinishLog, now: Date) -> AgentsLive? {
        let rated: [(Session, AgentAttention)] = sessions.map { ($0, AgentAttention.of($0, log: log, now: now)) }
        let needsYou = rated.filter { $0.1 == .needsYou || $0.1 == .errored }
        let working = rated.filter { $0.1 == .working }
        let total = rated.filter { $0.1 != .exited }.count
        if !needsYou.isEmpty {
            // Needs you before errored, then the oldest.
            let best = needsYou.map(\.1).min() ?? .needsYou
            return lead(needsYou.filter { $0.1 == best }, rank: .agentNeedsYou, needsYou: needsYou.count,
                        working: working.count, total: total)
        }
        if let finishedAt = log.lastFinish(now: now) {
            let finished = rated.filter { $0.1 == .finished }
            guard let (s, _) = finished.min(by: { $0.0.startedAt < $1.0.startedAt }) else {
                return AgentsLive(rank: .agentFinished, title: "Agent finished", subtitle: "Finished", startedAt: finishedAt,
                                  needsYou: 0, working: working.count, total: total, leadKey: "", leadAttention: .finished)
            }
            return AgentsLive(rank: .agentFinished, title: title(of: s), subtitle: "Finished", startedAt: finishedAt,
                              needsYou: 0, working: working.count, total: total, leadKey: s.key, leadAttention: .finished)
        }
        if !working.isEmpty {
            return lead(working, rank: .agentsWorking, needsYou: 0, working: working.count, total: total)
        }
        return nil
    }

    private static func lead(_ pool: [(Session, AgentAttention)], rank: LiveRank, needsYou: Int, working: Int,
                             total: Int) -> AgentsLive? {
        guard let (s, attention) = pool.min(by: { $0.0.startedAt < $1.0.startedAt }) else { return nil }
        return AgentsLive(rank: rank, title: title(of: s), subtitle: subtitle(s, attention), startedAt: s.startedAt,
                          needsYou: needsYou, working: working, total: total, leadKey: s.key, leadAttention: attention)
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
