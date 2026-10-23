import Foundation

/// A focus session countdown that can be paused. Pure value: every query takes the time,
/// so it persists (Codable) and tests without a clock.
public struct FocusTimer: Codable, Equatable, Sendable {
    public static let presets = [25, 50, 90]

    public enum Phase: String, Codable, Sendable { case idle, running, paused }

    public let duration: TimeInterval
    /// Time counted before the current run (sum of earlier runs).
    private var elapsedBefore: TimeInterval = 0
    /// Start of the current run while running.
    private var runningSince: Date?
    public private(set) var phase: Phase = .idle

    public init(minutes: Int) {
        duration = TimeInterval(max(1, minutes) * 60)
    }

    public var minutes: Int { Int(duration / 60) }

    public mutating func start(at date: Date) {
        elapsedBefore = 0
        runningSince = date
        phase = .running
    }

    public mutating func pause(at date: Date) {
        guard phase == .running, let since = runningSince else { return }
        elapsedBefore = min(duration, elapsedBefore + max(0, date.timeIntervalSince(since)))
        runningSince = nil
        phase = .paused
    }

    public mutating func resume(at date: Date) {
        guard phase == .paused else { return }
        runningSince = date
        phase = .running
    }

    public func remaining(at date: Date) -> TimeInterval {
        var elapsed = elapsedBefore
        if phase == .running, let since = runningSince { elapsed += max(0, date.timeIntervalSince(since)) }
        return max(0, duration - elapsed)
    }

    /// When a running timer reaches zero; nil while idle or paused.
    public var endsAt: Date? {
        guard phase == .running, let since = runningSince else { return nil }
        return since.addingTimeInterval(duration - elapsedBefore)
    }

    /// Started and counted down to zero.
    public func isDone(at date: Date) -> Bool { phase != .idle && remaining(at: date) <= 0 }

    /// Counting down right now (focus holds notices only while this is true).
    public func isRunning(at date: Date) -> Bool { phase == .running && remaining(at: date) > 0 }

    /// `isDone(at:)` now.
    public var isDone: Bool { isDone(at: Date()) }
}
