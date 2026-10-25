import Foundation

/// The Agents list order (spec 6.5): needs you → errored → working → finished → idle →
/// ended, by `AgentAttention.of`, then the most recently updated first.
public enum AgentsOrder {
    public static func sorted(_ sessions: [Session], log: AgentFinishLog, now: Date) -> [Session] {
        let rated: [(Session, AgentAttention)] = sessions.map { ($0, AgentAttention.of($0, log: log, now: now)) }
        return rated.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.0.updatedAt != b.0.updatedAt { return a.0.updatedAt > b.0.updatedAt }
            return a.0.key < b.0.key
        }.map(\.0)
    }
}

/// The words under a session's project name in the Agents list.
public enum SessionStatusLine {
    /// "Waiting for approval", "Running tests · 4 m", "Finished · 3 m ago", "Idle", …
    /// Working counts from `startedAt`; finished from `updatedAt` (the session's last
    /// change is its finish). A clock that went backwards shows 0, never a negative time.
    public static func text(_ s: Session, attention: AgentAttention, now: Date) -> String {
        switch attention {
        case .needsYou: return s.state == .blocked ? "Waiting for approval" : "Needs your input"
        case .errored: return "Stopped with an error"
        case .working: return "\(s.title ?? s.tool ?? "Working") · \(minutes(from: s.startedAt, to: now)) m"
        case .finished: return "Finished · \(minutes(from: s.updatedAt, to: now)) m ago"
        case .idle: return "Idle"
        case .exited: return "Ended"
        }
    }

    /// The session's last message or tool, on one line, hidden characters spelled out
    /// (`SummarySanitizer`).
    public static func lastAction(_ s: Session) -> String? {
        guard let raw = s.message ?? s.tool, !raw.isEmpty else { return nil }
        return SummarySanitizer.visible(raw, singleLine: true).text
    }

    private static func minutes(from start: Date, to now: Date) -> Int {
        let seconds: TimeInterval = now.timeIntervalSince(start)
        return max(0, Int(seconds / 60))
    }
}
