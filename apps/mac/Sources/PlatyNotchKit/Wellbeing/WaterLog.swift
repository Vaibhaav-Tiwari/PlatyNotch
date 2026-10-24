import Foundation

/// Glasses of water logged with "+1 glass", for the daily count. Only the last
/// `keepDays` days are kept (a small UserDefaults value).
public struct WaterLog: Codable, Equatable, Sendable {
    /// UserDefaults key (JSON).
    public static let key = "wellbeing.water"
    public static let keepDays = 14
    /// A bound on a damaged or scripted log (far more than anyone drinks in 14 days).
    static let maxEntries = 1_000

    /// When each glass was logged, oldest first.
    public private(set) var glasses: [Date]

    public init(glasses: [Date] = []) {
        self.glasses = glasses.sorted()
    }

    /// Logs a glass at `at` and drops glasses more than `keepDays` days before it.
    public mutating func add(at date: Date) {
        glasses.append(date)
        glasses.sort()
        prune(now: date)
    }

    /// Drops glasses logged more than `keepDays` days before `now`.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.keepDays) * 86_400)
        glasses.removeAll { $0 <= cutoff }
        if glasses.count > Self.maxEntries { glasses.removeFirst(glasses.count - Self.maxEntries) }
    }

    /// Glasses on `day`'s local date in `calendar`.
    public func count(on day: Date, calendar: Calendar) -> Int {
        glasses.reduce(0) { $0 + (calendar.isDate($1, inSameDayAs: day) ? 1 : 0) }
    }
}
