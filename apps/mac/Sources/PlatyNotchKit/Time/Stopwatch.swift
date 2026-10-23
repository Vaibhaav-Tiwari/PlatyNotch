import Foundation

/// A stopwatch with laps. Pure value (Codable): a running stopwatch keeps counting across
/// a relaunch.
public struct Stopwatch: Codable, Equatable, Sendable {
    /// Laps recorded at most (further laps are ignored).
    public static let maxLaps = 99

    /// Time counted before the current run.
    public var accumulated: TimeInterval
    /// Start of the current run while running.
    public var runningSince: Date?
    /// Each lap's own length, oldest first.
    public var laps: [TimeInterval]

    public init(accumulated: TimeInterval = 0, runningSince: Date? = nil, laps: [TimeInterval] = []) {
        self.accumulated = accumulated
        self.runningSince = runningSince
        self.laps = laps
    }

    public var isRunning: Bool { runningSince != nil }

    public func elapsed(at date: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    /// The lap in progress (elapsed since the last lap).
    public func currentLap(at date: Date) -> TimeInterval {
        max(0, elapsed(at: date) - laps.reduce(0, +))
    }

    public mutating func start(at date: Date) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    public mutating func stop(at date: Date) {
        guard runningSince != nil else { return }
        accumulated = elapsed(at: date)
        runningSince = nil
    }

    /// Records a lap; ignored while stopped and once `maxLaps` are recorded.
    public mutating func lap(at date: Date) {
        guard isRunning, laps.count < Self.maxLaps else { return }
        laps.append(currentLap(at: date))
    }

    /// "m:ss.t" or "h:mm:ss.t" (tenths truncated).
    public static func format(_ t: TimeInterval) -> String {
        let tenths = Int((max(0, t) * 10).rounded(.down))
        let total = tenths / 10, h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths % 10)
                     : String(format: "%d:%02d.%d", m, s, tenths % 10)
    }

    public mutating func reset() {
        self = Stopwatch()
    }
}
