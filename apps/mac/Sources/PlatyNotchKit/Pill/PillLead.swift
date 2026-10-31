import Foundation

/// What the closed pill leads with (Island spec 7, wireframe F).
public enum PillLead: Equatable, Sendable {
    /// An approval waits: the amber count badge (always first).
    case approval(count: Int)
    /// A session waits for you: its app icon and "Needs you".
    case needsYou(sessionID: String)
    /// Music plays: mini art and bars in the art's colour.
    case music
    /// A timer runs: Platy and the time left.
    case timer(remaining: String)
    /// Agents work: today's agent dots.
    case agents
    /// Nothing live: Platy alone.
    case none
}

public enum PillLeads {
    /// Approvals, then a session needing you, then by `order`: music, timer, working agents
    /// (music first) or working agents, timer, music (agents first).
    public static func lead(approvals: Int, sessions: [Session], log: AgentFinishLog, timerRemaining: TimeInterval?,
                            musicPlaying: Bool, order: PillOrder, now: Date) -> PillLead {
        if approvals > 0 { return .approval(count: approvals) }
        let states: [(Session, AgentAttention)] = sessions.map { ($0, AgentAttention.of($0, log: log, now: now)) }
        if let waiting = states.first(where: { $0.1 == .needsYou }) { return .needsYou(sessionID: waiting.0.sessionID) }
        let working: Bool = states.contains { $0.1 == .working }
        let timer: PillLead? = timerRemaining.flatMap { $0 > 0 ? .timer(remaining: DockState.clock($0)) : nil }
        let ranked: [PillLead?] = order == .musicFirst
            ? [musicPlaying ? .music : nil, timer, working ? .agents : nil]
            : [working ? .agents : nil, timer, musicPlaying ? .music : nil]
        return ranked.compactMap { $0 }.first ?? .none
    }
}
