import Foundation

/// Something worth a short celebration (spec 8.4).
public enum MomentEvent: Hashable, Sendable {
    /// Every agent finished: something finished and nothing works or needs you.
    case allAgentsFinished(at: Date)
    /// A game ended with a new best score.
    case newBest(game: String, score: Int)
    /// A focus session ran to its end.
    case focusComplete(endedAt: Date)
}

/// Decides whether a moment plays: each event at most once, and never while an approval
/// is waiting (the moment is dropped, not kept for later). How long it plays is
/// `PlatyMoodFlags.celebrationLength` (2 s).
public struct MomentGate: Sendable {
    /// How many past events the gate remembers (older ones cannot come again anyway).
    public static let memory = 64

    private var seen: [MomentEvent] = []

    public init() {}

    /// Events remembered now (tests).
    public var remembered: Int { seen.count }

    public mutating func admit(_ e: MomentEvent, approvalsPending: Int) -> Bool {
        guard !seen.contains(e) else { return false }
        seen.append(e)
        if seen.count > Self.memory { seen.removeFirst(seen.count - Self.memory) }
        return approvalsPending == 0
    }
}
