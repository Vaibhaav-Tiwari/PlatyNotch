import CoreGraphics
import Foundation

/// How Platy, the platypus mascot, feels: what the pill (and the empty states) draw.
public enum PlatyMood: String, CaseIterable, Sendable {
    case idle, working, workingToMusic, thinking, waiting, done, dancing, focused, sleepy

    /// Seconds per animation loop (`PlatyPoseValues.at` repeats every `period`). Static
    /// moods have a period too (1), but their pose never changes.
    public var period: TimeInterval {
        switch self {
        case .idle, .focused: 1
        case .working, .workingToMusic: 0.8
        case .thinking: 3
        case .waiting: 2
        case .done: 1.6
        case .dancing: 1.2
        case .sleepy: 4
        }
    }

    /// Waiting and done play their loop once and then hold the still frame (spec 8.1:
    /// "a single 2-second wave, then still with the flag up"; "check, once"). The others loop.
    public var playsOnce: Bool {
        self == .waiting || self == .done
    }

    /// Whether the pose changes over time (idle and focused are still: they cost nothing).
    public var animates: Bool {
        self != .idle && self != .focused
    }

    /// Seconds between redraws while animating; nil = never redrawn (a static frame).
    /// The pill's budget is 12 fps (as MusicBars). Waiting waves at 6 fps, once (it then
    /// holds a still frame however long an approval waits). Sleepy is what Platy shows at
    /// night with nothing live: 1 fps.
    public var frameInterval: TimeInterval? {
        switch self {
        case .idle, .focused: nil
        case .sleepy: 1
        case .waiting: 2 * Self.pillTick
        default: Self.pillTick
        }
    }

    /// When the next frame is due after time `t` (seconds since the reference date): the
    /// next tick of a grid of `frameInterval` steps from that epoch (so Platy and the other
    /// pill timelines tick together and share frames). `t` itself for a still mood. Every
    /// loop moves throughout; a `playsOnce` mood holds still after its one loop instead.
    public func nextFrame(after t: TimeInterval) -> TimeInterval {
        guard let interval = frameInterval else { return t }
        var tick: Double = ((t / interval).rounded(.down) + 1) * interval
        if tick <= t + 1e-9 { tick += interval }
        return tick
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
        }
    }
}

/// Picks Platy's mood from what is going on.
public enum PlatyMoodResolver {
    /// Night for Platy: 23:00 to 05:59.
    public static func isNight(hour: Int) -> Bool { hour >= 23 || hour <= 5 }

    /// Priority: an approval pending or any session blocked / waiting for input → waiting;
    /// a session just finished (`showsDone`) → done; a focus session →
    /// focused; any session active → working (with headphones while music plays,
    /// `.workingToMusic`); music playing → dancing; night → sleepy;
    /// else idle. `.thinking` is reserved for the voice assistant.
    ///
    /// `sessions` are the store's session states as they are, read through the one session
    /// classifier (`AgentAttention`).
    public static func mood(sessions: [SessionState], approvalsPending: Int, musicPlaying: Bool, focusActive: Bool,
                            justFinished: Bool, hour: Int) -> PlatyMood {
        let attention = sessions.map(AgentAttention.init(state:))
        let needsYou = attention.contains(.needsYou)
        if approvalsPending > 0 || needsYou { return .waiting }
        if justFinished { return .done }
        if focusActive { return .focused }
        if attention.contains(.working) { return musicPlaying ? .workingToMusic : .working }
        if musicPlaying { return .dancing }
        if isNight(hour: hour) { return .sleepy }
        return .idle
    }
}

extension PlatyMoodResolver {
    /// The resolver's `justFinished` (Ruling 14): for 4 s after a finish (`flags`), or while
    /// an agent finished in the last 10 minutes (`log`) and no session works or needs you.
    public static func showsDone(flags: PlatyMoodFlags, log: AgentFinishLog, sessions: [SessionState],
                                 now: Date) -> Bool {
        if flags.justFinished(at: now) { return true }
        guard log.lastFinish(now: now) != nil else { return false }
        return !sessions.contains { s in
            let a = AgentAttention(state: s)
            return a == .working || a == .needsYou
        }
    }
}

/// Spots a session that just finished: one that was active is now idle or exited.
/// A thin wrapper over `SessionTransitions`, the one transition tracker.
public struct PlatyFinishWatch: Sendable {
    private var transitions = SessionTransitions()

    public init() {}

    /// Feeds the current states by session key; true when one went from active to idle
    /// or exited since the last call. The first call only takes a look.
    public mutating func update(_ states: [String: SessionState]) -> Bool {
        let pairs: [(String, SessionState)] = states.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return !transitions.update(states: pairs).finished.isEmpty
    }
}

/// The mood that lasts a few seconds after an event: done (a session finished).
public struct PlatyMoodFlags: Equatable, Sendable {
    public static let doneLength: TimeInterval = 4

    public private(set) var doneUntil: Date?

    public init() {}

    public mutating func finish(at now: Date) { doneUntil = now.addingTimeInterval(Self.doneLength) }

    public func justFinished(at now: Date) -> Bool { doneUntil.map { now < $0 } ?? false }

    /// The next moment a flag runs out (when the mood must be worked out again), nil when
    /// none is pending.
    public func nextChange(after now: Date) -> Date? {
        [doneUntil].compactMap { $0 }.filter { $0 > now }.min()
    }
}

/// The compact pill's agents ear with Platy: Platy at the ear's outer edge, then the agent
/// dots that fit, then a plain "+n" label for every live session without a dot (beyond
/// `PillDots.limit` or squeezed out). Nothing ever overlaps Platy. When space runs short:
/// fewer dots (down to one) while "+n" stays; then "+n" goes and the dots that fit stay;
/// at the narrowest ear Platy alone. Text is never truncated; VoiceOver carries the full
/// counts (`PillContent.sessionsSummary`).
public struct PlatyEarFit: Equatable, Sendable {
    /// Platy's size in the pill (points).
    public static let platy: CGFloat = 22
    /// The gap between Platy, each dot and the label.
    public static let spacing: CGFloat = 4
    /// An agent dot's diameter.
    public static let dotSize: CGFloat = 6
    /// An agent dot and the space before it.
    public static let dot: CGFloat = dotSize + spacing

    /// Dots drawn.
    public let dots: Int
    /// The n in "+n" (0: no label).
    public let overflowCount: Int

    public init(dots: Int, overflowCount: Int) {
        self.dots = dots
        self.overflowCount = overflowCount
    }

    /// The fit with `labelWidthEstimate` for the label.
    public init(earWidth: CGFloat, dots: Int, overflow: Int) {
        self.init(earWidth: earWidth, dots: dots, overflow: overflow, labelWidth: Self.labelWidthEstimate)
    }

    /// The fit with the label's drawn width for a count (`labelWidth`, the view's
    /// measured text), so the label is never cut and never passes the ear.
    public init(earWidth: CGFloat, dots: Int, overflow: Int, labelWidth: (Int) -> CGFloat) {
        let room: CGFloat = earWidth - Self.platy
        // 1. Fewer dots (down to one) while "+n" keeps every session counted.
        if dots > 0 {
            for kept in stride(from: dots, through: 1, by: -1) {
                let count: Int = dots - kept + overflow
                let label: CGFloat = count > 0 ? Self.spacing + labelWidth(count) : 0
                if CGFloat(kept) * Self.dot + label <= room {
                    self.init(dots: kept, overflowCount: count)
                    return
                }
            }
        } else if overflow > 0, Self.spacing + labelWidth(overflow) <= room {
            self.init(dots: 0, overflowCount: overflow)
            return
        }
        // 2. "+n" goes; the dots that fit stay. 3. Platy alone.
        let fitting: Int = room > 0 ? Int((room / Self.dot).rounded(.down)) : 0
        self.init(dots: min(dots, fitting), overflowCount: 0)
    }

    /// The label's text.
    public static func overflowText(_ count: Int) -> String { "+\(count)" }

    /// A width the label never exceeds: 8 pt per character (11 pt medium rounded measures
    /// 7.7 at most), so a fit made with it never cuts the label.
    public static func labelWidthEstimate(_ count: Int) -> CGFloat {
        CGFloat(overflowText(count).count) * 8
    }

    /// Where each part sits, measured from the ear's outer edge toward the notch.
    public struct Placement: Equatable, Sendable {
        public let platy: ClosedRange<CGFloat>
        public let dots: [ClosedRange<CGFloat>]
        public let label: ClosedRange<CGFloat>?
    }

    public func placement(labelWidth: CGFloat) -> Placement {
        let platyRange: ClosedRange<CGFloat> = 0...Self.platy
        let dotRanges: [ClosedRange<CGFloat>] = (0..<dots).map { i in
            let start: CGFloat = Self.platy + Self.spacing + CGFloat(i) * Self.dot
            return start...(start + Self.dotSize)
        }
        var label: ClosedRange<CGFloat>?
        if overflowCount > 0 {
            let start: CGFloat = Self.platy + CGFloat(dots) * Self.dot + Self.spacing
            label = start...(start + labelWidth)
        }
        return Placement(platy: platyRange, dots: dotRanges, label: label)
    }

    /// The width this fit draws with `labelWidth` for the label.
    public func width(labelWidth: CGFloat) -> CGFloat {
        let label: CGFloat = overflowCount > 0 ? Self.spacing + labelWidth : 0
        return Self.platy + CGFloat(dots) * Self.dot + label
    }

    /// The width this fit draws with the estimated label.
    public var width: CGFloat { width(labelWidth: Self.labelWidthEstimate(overflowCount)) }
}
