import CoreGraphics
import Foundation

/// How Platy, the platypus mascot, feels: what the pill (and the empty states) draw.
public enum PlatyMood: String, CaseIterable, Sendable {
    case idle, working, thinking, waiting, done, dancing, focused, sleepy, celebrating

    /// Seconds per animation loop (`PlatyPoseValues.at` repeats every `period`). Static
    /// moods have a period too (1), but their pose never changes.
    public var period: TimeInterval {
        switch self {
        case .idle, .focused: 1
        case .working: 0.8
        case .thinking: 3
        case .waiting: 1.2
        case .done: 1.6
        case .dancing: 1.2
        case .sleepy: 4
        case .celebrating: 1
        }
    }

    /// Whether the pose changes over time (idle and focused are still: they cost nothing).
    public var animates: Bool {
        self != .idle && self != .focused
    }

    /// Seconds between redraws while animating; nil = never redrawn (a static frame).
    /// Sleepy is what Platy shows at night with nothing live, so it keeps the idle budget:
    /// one frame a second.
    public var frameInterval: TimeInterval? {
        switch self {
        case .idle, .focused: nil
        case .sleepy: 1
        default: 1.0 / 30
        }
    }

    /// What VoiceOver says for Platy.
    public var accessibilityLabel: String {
        switch self {
        case .idle: "Platy is resting"
        case .working: "Platy is paddling along with your agents"
        case .thinking: "Platy is thinking"
        case .waiting: "Platy is waiting for you"
        case .done: "Platy says an agent finished"
        case .dancing: "Platy is dancing to music"
        case .focused: "Platy is focusing"
        case .sleepy: "Platy is sleepy"
        case .celebrating: "Platy is celebrating a new best"
        }
    }
}

/// Picks Platy's mood from what is going on.
public enum PlatyMoodResolver {
    /// Night for Platy: 23:00 to 05:59.
    public static func isNight(hour: Int) -> Bool { hour >= 23 || hour <= 5 }

    /// Priority: an approval pending or any session blocked / waiting for input → waiting;
    /// a game's new best → celebrating; a session just finished → done; a focus session →
    /// focused; any session active → working; music playing → dancing; night → sleepy;
    /// else idle. `.thinking` is reserved for the voice assistant.
    ///
    /// `sessions` are the store's session states as they are (AgentsLive, which kept only
    /// active and blocked, was removed in Task 13).
    public static func mood(sessions: [SessionState], approvalsPending: Int, musicPlaying: Bool, focusActive: Bool,
                            justFinished: Bool, hour: Int, celebrating: Bool = false) -> PlatyMood {
        let needsYou = sessions.contains { $0 == .blocked || $0 == .waitingInput }
        if approvalsPending > 0 || needsYou { return .waiting }
        if celebrating { return .celebrating }
        if justFinished { return .done }
        if focusActive { return .focused }
        if sessions.contains(.active) { return .working }
        if musicPlaying { return .dancing }
        if isNight(hour: hour) { return .sleepy }
        return .idle
    }
}

/// Spots a session that just finished: one that was active is now idle or exited.
public struct PlatyFinishWatch: Sendable {
    private var last: [String: SessionState]?

    public init() {}

    /// Feeds the current states by session key; true when one went from active to idle
    /// or exited since the last call. The first call only takes a look.
    public mutating func update(_ states: [String: SessionState]) -> Bool {
        defer { last = states }
        guard let last else { return false }
        return states.contains { key, state in
            (state == .idle || state == .exited) && last[key] == .active
        }
    }
}

/// The moods that last a few seconds after an event: done (a session finished) and
/// celebrating (a game's new best, `GamesWidget.onNewBest`).
public struct PlatyMoodFlags: Equatable, Sendable {
    public static let doneLength: TimeInterval = 4
    public static let celebrationLength: TimeInterval = 4

    public private(set) var doneUntil: Date?
    public private(set) var celebrationUntil: Date?

    public init() {}

    public mutating func finish(at now: Date) { doneUntil = now.addingTimeInterval(Self.doneLength) }
    public mutating func celebrate(at now: Date) { celebrationUntil = now.addingTimeInterval(Self.celebrationLength) }

    public func justFinished(at now: Date) -> Bool { doneUntil.map { now < $0 } ?? false }
    public func celebrating(at now: Date) -> Bool { celebrationUntil.map { now < $0 } ?? false }

    /// The next moment a flag runs out (when the mood must be worked out again), nil when
    /// none is pending.
    public func nextChange(after now: Date) -> Date? {
        [doneUntil, celebrationUntil].compactMap { $0 }.filter { $0 > now }.min()
    }
}

/// The compact pill's agents ear with Platy: Platy first, then as many agent dots (and
/// the "+n") as fit in `earWidth`. Platy always shows.
public struct PlatyEarFit: Equatable, Sendable {
    /// Platy's size in the pill (points).
    public static let platy: CGFloat = 22
    public static let spacing: CGFloat = 4
    /// An agent dot and the space before it.
    public static let dot: CGFloat = 7 + 4
    /// The "+n" label (two digits) and the space before it.
    public static let overflowLabel: CGFloat = 18

    public let dots: Int
    public let showsOverflow: Bool

    public init(dots: Int, showsOverflow: Bool) {
        self.dots = dots
        self.showsOverflow = showsOverflow
    }

    public init(earWidth: CGFloat, dots: Int, overflow: Int) {
        let room: CGFloat = earWidth - Self.platy
        let fitting = room > 0 ? Int((room / Self.dot).rounded(.down)) : 0
        let shown = min(dots, max(fitting, 0))
        let used: CGFloat = CGFloat(shown) * Self.dot
        let overflowFits = shown == dots && overflow > 0 && used + Self.overflowLabel <= room
        self.init(dots: shown, showsOverflow: overflowFits)
    }

    /// The width this fit draws.
    public var width: CGFloat {
        let dotsWidth: CGFloat = CGFloat(dots) * Self.dot
        let label: CGFloat = showsOverflow ? Self.overflowLabel : 0
        return Self.platy + dotsWidth + label
    }
}
