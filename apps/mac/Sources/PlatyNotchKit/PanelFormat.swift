import Foundation

/// Text the panel views show: ages, reset times, usage and state labels.
public enum PanelFormat {
    /// "now" under a minute (or in the future), then "3m", "2h", "4d".
    public static func relativeAge(from date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date).rounded(.down))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// "resets in 2h 05m"; nil when the reset time is unknown.
    public static func resetCountdown(resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        let s = Int(resetsAt.timeIntervalSince(now).rounded(.down))
        if s <= 0 { return "resetting" }
        if s < 60 { return "resets in <1m" }
        let m = s / 60
        if m < 60 { return "resets in \(m)m" }
        let h = m / 60
        if h < 24 { return "resets in \(h)h " + String(format: "%02dm", m % 60) }
        return "resets in \(h / 24)d \(h % 24)h"
    }

    /// Used percent as a 0...1 bar fill.
    public static func usageFraction(_ usedPercent: Double) -> Double {
        guard usedPercent.isFinite else { return 0 }
        return min(max(usedPercent / 100, 0), 1)
    }

    public static func usagePercent(_ usedPercent: Double) -> String {
        "\(Int((usageFraction(usedPercent) * 100).rounded()))%"
    }

    public static func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .active: "Working"
        case .idle: "Idle"
        case .waitingInput: "Waiting"
        case .blocked: "Needs approval"
        case .exited: "Exited"
        }
    }
}

/// Usage bar color band: normal below 70 %, high below 90 %, critical from 90 %.
public enum UsageLevel: Sendable, Equatable {
    case normal, high, critical

    public init(usedPercent: Double) {
        switch usedPercent {
        case 90...: self = .critical
        case 70..<90: self = .high
        default: self = .normal
        }
    }
}

/// The four colors the five session states map to (the views pick the actual color).
public enum AgentTone: Sendable, Hashable {
    /// Working: green, pulsing.
    case active
    /// Blocked on an approval or waiting for input: amber.
    case attention
    /// Idle: grey.
    case idle
    /// Exited: faint grey.
    case off

    public init(_ state: SessionState) {
        switch state {
        case .active: self = .active
        case .blocked, .waitingInput: self = .attention
        case .idle: self = .idle
        case .exited: self = .off
        }
    }

    public var pulses: Bool { self == .active }
}

/// The compact pill's agent dots: up to `limit` sessions, those needing attention first,
/// then working, then idle (store order within each group); exited sessions are left out.
public struct PillDots: Sendable, Equatable {
    public struct Dot: Sendable, Equatable {
        public var key: String
        public var tone: AgentTone
    }

    public static let limit = 3

    public let dots: [Dot]
    /// Live sessions beyond `limit` ("+n").
    public let overflow: Int

    public init(sessions: [Session], limit: Int = PillDots.limit) {
        let rank: [AgentTone: Int] = [.attention: 0, .active: 1, .idle: 2]
        let live = sessions.enumerated()
            .compactMap { i, s -> (Int, Int, Dot)? in
                let tone = AgentTone(s.state)
                guard let r = rank[tone] else { return nil }
                return (r, i, Dot(key: s.key, tone: tone))
            }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
        dots = Array(live.prefix(limit))
        overflow = max(live.count - limit, 0)
    }
}

public enum ApprovalBehavior: String, Sendable, Equatable {
    case allow, deny
}

/// Approval ordering, summary sizing, expiry countdown and the decide message.
public enum ApprovalFormat {
    /// The summary view grows to this many lines, then scrolls.
    public static let maxSummaryLines = 12

    /// Oldest first; ties by id, so two approvals created together keep a stable order.
    public static func ordered(_ approvals: [Approval]) -> [Approval] {
        approvals.sorted(by: isOlder)
    }

    public static func isOlder(_ a: Approval, _ b: Approval) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
    }

    public static func lineCount(_ summary: String) -> Int {
        max(summary.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count, 1)
    }

    /// Lines the summary view is sized for (the full text stays scrollable).
    public static func visibleLines(for summary: String) -> Int {
        min(lineCount(summary), maxSummaryLines)
    }

    public static func needsScroll(_ summary: String) -> Bool {
        lineCount(summary) > maxSummaryLines
    }

    /// "1:40" / "1:02:05" until `expiresAt` (rounded up); nil once expired.
    public static func countdown(to expiresAt: Date, now: Date) -> String? {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let s = Int(remaining.rounded(.up))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    public static func decideEnvelope(id: String, _ behavior: ApprovalBehavior) throws -> Envelope {
        try Envelope.make(.approvalDecide, id: nil,
                          ApprovalDecide(id: id, behavior: behavior.rawValue, source: "notch"))
    }
}

/// Where the user's answer to one approval stands, before `approval.resolved` arrives.
public enum DecisionPhase: Sendable, Equatable {
    case sending(ApprovalBehavior)
    case failed(String)
}

/// Optimistic answers in flight, keyed by approval id.
public struct ApprovalDecisions: Sendable, Equatable {
    private var phases: [String: DecisionPhase] = [:]

    public init() {}

    public func phase(for id: String) -> DecisionPhase? { phases[id] }

    /// Marks `id` as sending; false (and no change) if an answer is already in flight.
    public mutating func begin(id: String, _ behavior: ApprovalBehavior) -> Bool {
        if case .sending = phases[id] { return false }
        phases[id] = .sending(behavior)
        return true
    }

    public mutating func fail(id: String, message: String) {
        phases[id] = .failed(message)
    }

    /// Forgets approvals no longer pending; when disconnected, also drops answers in flight
    /// (after reconnecting, the snapshot says whether they landed).
    public mutating func sync(pending ids: Set<String>, connected: Bool) {
        phases = phases.filter { id, phase in
            guard ids.contains(id) else { return false }
            if !connected, case .sending = phase { return false }
            return true
        }
    }
}

/// What an approval card shows and whether its buttons work.
public enum ApprovalCardStatus: Sendable, Equatable {
    case ready(countdown: String, error: String?)
    case reconnecting(countdown: String)
    case sending(ApprovalBehavior)
    case expired

    public init(approval: Approval, now: Date, canAnswer: Bool, phase: DecisionPhase?) {
        guard let countdown = ApprovalFormat.countdown(to: approval.expiresAt, now: now) else {
            self = .expired
            return
        }
        switch phase {
        case .sending(let b): self = .sending(b)
        case _ where !canAnswer: self = .reconnecting(countdown: countdown)
        case .failed(let message): self = .ready(countdown: countdown, error: message)
        case nil: self = .ready(countdown: countdown, error: nil)
        }
    }

    public var canAnswer: Bool {
        if case .ready = self { return true }
        return false
    }
}
