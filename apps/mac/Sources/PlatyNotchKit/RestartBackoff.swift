import Foundation

/// Restart delay policy for the supervised core: 1, 2, 5, 10 s (then stays at 10 s).
/// The sequence resets once the core has stayed up for `stableAfter` seconds.
public struct RestartBackoff: Sendable, Equatable {
    public static let delays: [TimeInterval] = [1, 2, 5, 10]
    public static let stableAfter: TimeInterval = 60

    private var index = 0

    public init() {}

    /// Delay to wait before the next restart.
    public mutating func nextDelay() -> TimeInterval {
        let d = Self.delays[min(index, Self.delays.count - 1)]
        index += 1
        return d
    }

    /// Call when the core exited after running for `uptime` seconds; resets the sequence if it was stable.
    public mutating func recordExit(uptime: TimeInterval) {
        if uptime >= Self.stableAfter { index = 0 }
    }

    public mutating func reset() { index = 0 }
}
