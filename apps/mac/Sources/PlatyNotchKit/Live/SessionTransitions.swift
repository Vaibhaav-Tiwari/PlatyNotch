import Foundation

/// How a session stands, most urgent first (spec 6.5: needs you → errored → working →
/// finished → idle). The one session classifier: the pill's dots, Platy's mood, the
/// agents live item and the Agents list all read sessions through it.
public enum AgentAttention: Int, Comparable, Sendable {
    case needsYou, errored, working, finished, idle, exited

    /// From the session state alone (errored and finished need the `AgentFinishLog`).
    public init(state: SessionState) {
        switch state {
        case .blocked, .waitingInput: self = .needsYou
        case .active: self = .working
        case .idle: self = .idle
        case .exited: self = .exited
        }
    }

    /// The state plus what the log knows: a failure in the last 10 minutes is errored
    /// (Ruling 3), a finish in the last 10 minutes is finished while the session rests.
    public static func of(_ s: Session, log: AgentFinishLog, now: Date) -> AgentAttention {
        let base = AgentAttention(state: s.state)
        if base == .needsYou { return .needsYou }
        if log.failed(s.key, now: now) { return .errored }
        if base == .working { return .working }
        if log.finished(s.key, now: now) { return .finished }
        return base
    }

    public static func < (lhs: AgentAttention, rhs: AgentAttention) -> Bool { lhs.rawValue < rhs.rawValue }

    public var tone: StateTone {
        switch self {
        case .needsYou: .needsYou
        case .errored: .error
        case .working: .working
        case .finished: .done
        case .idle, .exited: .idle
        }
    }
}

/// The one action a session row (and the agents hero) offers.
public enum AgentRowAction: Sendable, Equatable {
    case answer, openTerminal

    public init(_ a: AgentAttention) {
        switch a {
        case .needsYou, .errored: self = .answer
        default: self = .openTerminal
        }
    }

    public var title: String {
        switch self {
        case .answer: "Answer"
        case .openTerminal: "Open terminal"
        }
    }
}

/// What changed between two looks at the sessions.
public struct SessionChanges: Equatable, Sendable {
    /// Sessions that went from working to idle or exited (store order).
    public let finished: [String]
    /// Sessions that now need you and did not on the last look (store order).
    public let enteredNeedsYou: [String]
    /// Something finished and nothing is working or needs you any more.
    public let allFinished: Bool

    public init(finished: [String], enteredNeedsYou: [String], allFinished: Bool) {
        self.finished = finished
        self.enteredNeedsYou = enteredNeedsYou
        self.allFinished = allFinished
    }

    public static let none = SessionChanges(finished: [], enteredNeedsYou: [], allFinished: false)
}

/// The one session-transition tracker. The first call only takes a look. A session that
/// disappears has not finished (the core drops a session only 10 min after it exited, or
/// from a snapshot after a restart).
public struct SessionTransitions: Sendable {
    private var last: [String: SessionState]?

    public init() {}

    public mutating func update(_ sessions: [Session]) -> SessionChanges {
        update(states: sessions.map { ($0.key, $0.state) })
    }

    /// The same, from (key, state) pairs in store order.
    public mutating func update(states: [(String, SessionState)]) -> SessionChanges {
        let previous = last
        last = Dictionary(states, uniquingKeysWith: { _, new in new })
        guard let previous else { return .none }
        var finished: [String] = []
        var entered: [String] = []
        for (key, state) in states {
            let before = previous[key].map(AgentAttention.init(state:))
            let now = AgentAttention(state: state)
            if before == .working, now == .idle || now == .exited { finished.append(key) }
            if now == .needsYou, before != .needsYou { entered.append(key) }
        }
        let busy = states.contains { _, state in
            let a = AgentAttention(state: state)
            return a == .working || a == .needsYou
        }
        return SessionChanges(finished: finished, enteredNeedsYou: entered, allFinished: !finished.isEmpty && !busy)
    }
}

/// Finishes and failures in the last 10 minutes (spec 6.3 rank 5; Ruling 3). Every
/// window counts from a recorded date and holds only while `now` is in
/// `[date, date + window)`: after a sleep, or a clock set back, an item is gone at once
/// instead of showing a stale or negative age.
public struct AgentFinishLog: Equatable, Sendable {
    public static let window: TimeInterval = 600

    private var finishes: [String: Date] = [:]
    private var failures: [String: Date] = [:]
    private var latest: Date?

    public init() {}

    public mutating func record(_ c: SessionChanges, now: Date) {
        guard !c.finished.isEmpty else { return }
        for key in c.finished { finishes[key] = now }
        latest = now
    }

    public mutating func noteFailure(sessionKey: String, at: Date) {
        failures[sessionKey] = at
    }

    /// The session is active again.
    public mutating func clearFailure(sessionKey: String) {
        failures[sessionKey] = nil
    }

    /// The last finish, while it is within the window.
    public func lastFinish(now: Date) -> Date? {
        guard let latest, Self.within(latest, now: now) else { return nil }
        return latest
    }

    public func failed(_ key: String, now: Date) -> Bool {
        failures[key].map { Self.within($0, now: now) } ?? false
    }

    public func finished(_ key: String, now: Date) -> Bool {
        finishes[key].map { Self.within($0, now: now) } ?? false
    }

    /// The next moment something in the log runs out (to re-rank then), nil when nothing
    /// is pending.
    public func nextExpiry(after now: Date) -> Date? {
        let dates: [Date] = Array(finishes.values) + Array(failures.values)
        return dates.map { $0.addingTimeInterval(Self.window) }.filter { $0 > now }.min()
    }

    private static func within(_ date: Date, now: Date) -> Bool {
        let age: TimeInterval = now.timeIntervalSince(date)
        return age >= 0 && age < window
    }
}
