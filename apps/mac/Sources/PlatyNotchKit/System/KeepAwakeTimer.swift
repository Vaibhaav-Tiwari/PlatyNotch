import Foundation

/// How long "keep awake" keeps the display on.
public enum KeepAwakeDuration: String, CaseIterable, Codable, Sendable {
    case thirtyMinutes, oneHour, twoHours, untilOff

    /// nil: until the user turns it off (or quits).
    public var interval: TimeInterval? {
        switch self {
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .untilOff: nil
        }
    }

    public var label: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilOff: "Until turned off"
        }
    }
}

/// One keep-awake run: a power assertion held from `startedAt` until `until` (nil: until
/// turned off). Never persisted: a timed keep-awake does not survive a relaunch.
public struct KeepAwakeSession: Equatable, Sendable {
    public let duration: KeepAwakeDuration
    public let startedAt: Date
    /// A wall-clock deadline, so a Mac asleep past it finds it expired on wake.
    public let until: Date?

    public init(duration: KeepAwakeDuration, now: Date) {
        self.duration = duration
        startedAt = now
        until = duration.interval.map { now.addingTimeInterval($0) }
    }

    /// Seconds left (never negative); nil until turned off.
    public func remaining(at now: Date) -> TimeInterval? {
        until.map { max(0, $0.timeIntervalSince(now)) }
    }

    public func isExpired(at now: Date) -> Bool {
        until.map { now >= $0 } ?? false
    }
}
