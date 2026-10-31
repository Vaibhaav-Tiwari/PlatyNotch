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
    /// "Waiting for approval", "Running tests · 4 m", "Finished · 3 m ago", "Idle", …;
    /// under a minute, "Running tests · just now" and "Finished · just now".
    /// Working counts from `startedAt`; finished from `finishedAt` (`AgentFinishLog`) when
    /// known, else `updatedAt` (the session's last change is its finish). A clock that went
    /// backwards shows 0, never a negative time.
    public static func text(_ s: Session, attention: AgentAttention, now: Date, finishedAt: Date? = nil) -> String {
        switch attention {
        case .needsYou: return s.state == .blocked ? "Waiting for approval" : "Needs your input"
        case .errored: return "Stopped with an error"
        case .working:
            let m: Int = minutes(from: s.startedAt, to: now)
            return "\(s.title ?? s.tool ?? "Working") · " + (m == 0 ? "just now" : "\(m) m")
        case .finished:
            let m: Int = minutes(from: finishedAt ?? s.updatedAt, to: now)
            return "Finished · " + (m == 0 ? "just now" : "\(m) m ago")
        case .idle: return "Idle"
        case .exited: return "Ended"
        }
    }

    /// The dense row's status and age (Quiet Notch wireframe C): "running tests · 12 m",
    /// "waiting for you · 3 m", "finished · 1 h", "ended". The status starts lower-case
    /// unless its first word is capitalised throughout ("AskUserQuestion" stays).
    public static func compact(_ s: Session, attention: AgentAttention, now: Date, finishedAt: Date? = nil) -> String {
        let status: String
        let since: Date
        switch attention {
        case .needsYou:
            status = s.state == .blocked ? "waiting for approval" : "waiting for you"
            since = s.updatedAt
        case .errored:
            status = "stopped with an error"
            since = s.updatedAt
        case .working:
            status = lowerFirst(s.title ?? s.tool ?? "working")
            since = s.startedAt
        case .finished:
            status = "finished"
            since = finishedAt ?? s.updatedAt
        case .idle:
            status = "idle"
            since = s.updatedAt
        case .exited:
            return "ended"
        }
        return "\(status) · \(age(from: since, to: now))"
    }

    /// "just now", "12 m", "1 h", "2 d"; never negative.
    public static func age(from start: Date, to now: Date) -> String {
        let m: Int = minutes(from: start, to: now)
        if m == 0 { return "just now" }
        if m < 60 { return "\(m) m" }
        if m < 24 * 60 { return "\(m / 60) h" }
        return "\(m / (24 * 60)) d"
    }

    /// "Running tests" → "running tests"; a word with another capital ("AskUserQuestion",
    /// "README") is kept.
    static func lowerFirst(_ text: String) -> String {
        let firstWord: Substring = text.prefix { !$0.isWhitespace }
        guard let first = firstWord.first, first.isUppercase,
              !firstWord.dropFirst().contains(where: \.isUppercase) else { return text }
        return first.lowercased() + text.dropFirst()
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
