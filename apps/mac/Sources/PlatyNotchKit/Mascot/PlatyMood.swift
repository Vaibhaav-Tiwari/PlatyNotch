import CoreGraphics
import Foundation

/// How Platy, the platypus mascot, feels: what the pill (and the empty states) draw.
public enum PlatyMood: String, CaseIterable, Sendable {
    case idle, working, workingToMusic, thinking, waiting, done, dancing, focused, sleepy, celebrating

    /// Seconds per animation loop (`PlatyPoseValues.at` repeats every `period`). Static
    /// moods have a period too (1), but their pose never changes.
    public var period: TimeInterval {
        switch self {
        case .idle, .focused: 1
        case .working, .workingToMusic: 0.8
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
    /// The pill's budget is 12 fps (as MusicBars). Waiting can last hours while an approval
    /// sits unanswered: 6 fps, and nothing at all in the still half of its loop
    /// (`nextFrame`). Sleepy is what Platy shows at night with nothing live: 1 fps.
    public var frameInterval: TimeInterval? {
        switch self {
        case .idle, .focused: nil
        case .sleepy: 1
        case .waiting: 2 * Self.pillTick
        default: Self.pillTick
        }
    }

    /// The fraction of the loop, from its start, in which the pose moves (waiting: the two
    /// taps, then the tail rests).
    public var movingFraction: Double {
        self == .waiting ? 0.5 : 1
    }

    /// When the next frame is due after time `t` (seconds since the reference date): the
    /// next tick of a grid of `frameInterval` steps from that epoch while the pose moves
    /// (so Platy and the other pill timelines tick together and share frames); the start
    /// of the next loop during a still stretch; the start of the still stretch for the last
    /// moving frame. `t` itself for a still mood.
    public func nextFrame(after t: TimeInterval) -> TimeInterval {
        guard let interval = frameInterval else { return t }
        var tick: Double = ((t / interval).rounded(.down) + 1) * interval
        if tick <= t + 1e-9 { tick += interval }
        if movingFraction >= 1 { return tick }
        let loopStart: Double = (t / period).rounded(.down) * period
        let stillStart: Double = loopStart + movingFraction * period
        if t >= stillStart - 1e-9 { return loopStart + period }
        return min(tick, stillStart)
    }

    /// The shared tick of the compact pill's timelines (12 fps, MusicBars' budget).
    public static let pillTick: TimeInterval = 1.0 / 12

    /// What VoiceOver says for Platy.
    public var accessibilityLabel: String {
        switch self {
        case .idle: "Platy is resting"
        case .working: "Platy is paddling along with your agents"
        case .workingToMusic: "Platy is paddling along with your agents, headphones on"
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
    /// focused; any session active → working (with headphones while music plays,
    /// `.workingToMusic`); music playing → dancing; night → sleepy;
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
        if sessions.contains(.active) { return musicPlaying ? .workingToMusic : .working }
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

/// The compact pill's agents ear with Platy: Platy first, then as many agent dots as fit
/// in `earWidth`, then "+n" for every live session without a dot (beyond `PillDots.limit`
/// or squeezed out by Platy). With no room for the label (Compact beside a notch) the "+n"
/// is a small badge on Platy instead. Platy always shows; every session is counted.
public struct PlatyEarFit: Equatable, Sendable {
    /// Platy's size in the pill (points).
    public static let platy: CGFloat = 22
    public static let spacing: CGFloat = 4
    /// An agent dot and the space before it.
    public static let dot: CGFloat = 7 + 4
    /// The "+n" label (two digits at the 11 pt floor) and the space before it.
    public static let overflowLabel: CGFloat = 22
    /// The "+n" badge's horizontal padding inside its capsule, each side.
    public static let badgePadding: CGFloat = 1
    /// Counts above this show as "99+" on the badge.
    public static let badgeMaxCount = 99

    /// Dots drawn.
    public let dots: Int
    /// The n in "+n" (0: no label).
    public let overflowCount: Int
    /// "+n" sits on Platy as a badge rather than after the dots.
    public let badge: Bool

    public init(dots: Int, overflowCount: Int, badge: Bool) {
        self.dots = dots
        self.overflowCount = overflowCount
        self.badge = badge
    }

    public init(earWidth: CGFloat, dots: Int, overflow: Int) {
        let room: CGFloat = earWidth - Self.platy
        let allDots: CGFloat = CGFloat(dots) * Self.dot
        let label: CGFloat = overflow > 0 ? Self.overflowLabel : 0
        if allDots + label <= room {
            self.init(dots: dots, overflowCount: overflow, badge: false)
            return
        }
        guard room >= Self.overflowLabel else {
            // No room for the label: no dots either, so the badge gets all of the room.
            self.init(dots: 0, overflowCount: dots + overflow, badge: true)
            return
        }
        let dotRoom: CGFloat = room - Self.overflowLabel
        let fitting: Int = dotRoom > 0 ? Int((dotRoom / Self.dot).rounded(.down)) : 0
        let shown = min(dots, fitting)
        self.init(dots: shown, overflowCount: dots - shown + overflow, badge: false)
    }

    /// The badge's text: "+n", or "99+" above `badgeMaxCount`.
    public static func badgeText(_ count: Int) -> String {
        count > badgeMaxCount ? "\(badgeMaxCount)+" : "+\(count)"
    }

    /// The width a badge may take. With a badge Platy sits against the notch edge of the
    /// ear; the badge runs outward from Platy's horizontal centre across the ear's free
    /// room and the pill's outer padding (`PanelLayout.pillPadding`), up to the pill's
    /// outer edge.
    public static func badgeRoom(earWidth: CGFloat, outerPadding: CGFloat) -> CGFloat {
        platy / 2 + max(0, earWidth - platy) + outerPadding
    }

    /// Where a badge `badgeWidth` wide starts, measured outward from the notch edge of
    /// the ear: at Platy's centre, moved toward the notch only if it would otherwise cross
    /// the pill's outer edge, and never past the notch edge (0).
    public static func badgeOffset(earWidth: CGFloat, outerPadding: CGFloat, badgeWidth: CGFloat) -> CGFloat {
        let outerEdge: CGFloat = max(earWidth, platy) + outerPadding
        return max(0, min(platy / 2, outerEdge - badgeWidth))
    }

    /// The width this fit draws (the badge takes none).
    public var width: CGFloat {
        let dotsWidth: CGFloat = CGFloat(dots) * Self.dot
        let label: CGFloat = overflowCount > 0 && !badge ? Self.overflowLabel : 0
        return Self.platy + dotsWidth + label
    }
}
