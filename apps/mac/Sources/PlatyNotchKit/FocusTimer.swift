import Foundation

/// A focus session countdown that can be paused: a thin wrapper over `CountdownTimer`
/// (one countdown implementation) with the focus presets. Pure value: every query takes
/// the time, so it persists (Codable) and tests without a clock.
public struct FocusTimer: Codable, Equatable, Sendable {
    public static let presets = [25, 50, 90]

    public typealias Phase = CountdownTimer.Phase

    public private(set) var countdown: CountdownTimer

    public init(minutes: Int) {
        countdown = CountdownTimer(label: "Focus", duration: TimeInterval(max(1, minutes) * 60))
    }

    public var duration: TimeInterval { countdown.duration }
    public var minutes: Int { Int(duration / 60) }
    public var phase: Phase { countdown.phase }

    public mutating func start(at date: Date) { countdown.start(at: date) }
    public mutating func pause(at date: Date) { countdown.pause(at: date) }
    public mutating func resume(at date: Date) { countdown.resume(at: date) }

    public func remaining(at date: Date) -> TimeInterval { countdown.remaining(at: date) }

    /// When a running timer reaches zero; nil while idle or paused.
    public var endsAt: Date? { countdown.endsAt }

    /// Started and counted down to zero.
    public func isDone(at date: Date) -> Bool { countdown.isFinished(at: date) }

    /// Counting down right now (focus holds notices only while this is true).
    public func isRunning(at date: Date) -> Bool { countdown.isRunning(at: date) }

    /// `isDone(at:)` now.
    public var isDone: Bool { isDone(at: Date()) }

    // MARK: - Codable (the countdown's fields; Plan 3's own format still loads)

    private enum Plan3Keys: String, CodingKey { case duration, elapsedBefore, runningSince, phase }

    public init(from decoder: Decoder) throws {
        let legacy = try decoder.container(keyedBy: Plan3Keys.self)
        if legacy.contains(.phase) {
            let duration = try legacy.decode(TimeInterval.self, forKey: .duration)
            let before = try legacy.decodeIfPresent(TimeInterval.self, forKey: .elapsedBefore) ?? 0
            var c = CountdownTimer(label: "Focus", duration: duration)
            switch try legacy.decode(Phase.self, forKey: .phase) {
            case .idle: break
            case .paused: c.pausedRemaining = max(0, duration - before)
            case .running:
                let since = try legacy.decodeIfPresent(Date.self, forKey: .runningSince) ?? Date()
                c.startedAt = since.addingTimeInterval(-before)
            }
            countdown = c
        } else {
            countdown = try CountdownTimer(from: decoder)
        }
    }

    public func encode(to encoder: Encoder) throws { try countdown.encode(to: encoder) }
}
