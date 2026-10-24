import Foundation

/// A countdown that can be paused: the one countdown implementation (the Time widget's
/// timers and, through `FocusTimer`, focus sessions). Pure value: every query takes the
/// time, so it persists (Codable) and survives a relaunch: a timer whose end passed while
/// the app was quit reads as finished.
///
/// Running: `startedAt` is set, shifted back by the time counted before a pause, so the
/// timer ends at `startedAt + duration`. Paused: `pausedRemaining` is set. Idle: neither.
public struct CountdownTimer: Codable, Identifiable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, running, paused }

    /// What starts by itself when this timer finishes (the pomodoro's break).
    public struct FollowUp: Codable, Equatable, Sendable {
        public var label: String
        public var duration: TimeInterval
        public init(label: String, duration: TimeInterval) {
            self.label = label
            self.duration = duration
        }
    }

    public var id: UUID
    public var label: String
    public var duration: TimeInterval
    public var startedAt: Date?
    public var pausedRemaining: TimeInterval?
    public var then: FollowUp?

    public init(id: UUID = UUID(), label: String = "", duration: TimeInterval, startedAt: Date? = nil,
                pausedRemaining: TimeInterval? = nil, then: FollowUp? = nil) {
        self.id = id
        self.label = label
        self.duration = max(1, duration)
        self.startedAt = startedAt
        self.pausedRemaining = pausedRemaining
        self.then = then
    }

    public var phase: Phase {
        if startedAt != nil { return .running }
        return pausedRemaining != nil ? .paused : .idle
    }

    /// When a running timer reaches zero; nil while idle or paused.
    public var endsAt: Date? { startedAt?.addingTimeInterval(duration) }

    public func remaining(at date: Date) -> TimeInterval {
        if let startedAt { return max(0, duration - max(0, date.timeIntervalSince(startedAt))) }
        return pausedRemaining ?? duration
    }

    /// Started and counted down to zero (stays true until `reset`).
    public func isFinished(at date: Date) -> Bool { phase != .idle && remaining(at: date) <= 0 }

    /// Counting down right now.
    public func isRunning(at date: Date) -> Bool { phase == .running && remaining(at: date) > 0 }

    /// Starts from the full duration.
    public mutating func start(at date: Date) {
        startedAt = date
        pausedRemaining = nil
    }

    public mutating func pause(at date: Date) {
        guard phase == .running else { return }
        pausedRemaining = remaining(at: date)
        startedAt = nil
    }

    public mutating func resume(at date: Date) {
        guard phase == .paused, let left = pausedRemaining else { return }
        startedAt = date.addingTimeInterval(left - duration)
        pausedRemaining = nil
    }

    /// Back to idle with the full duration.
    public mutating func reset() {
        startedAt = nil
        pausedRemaining = nil
    }
}
