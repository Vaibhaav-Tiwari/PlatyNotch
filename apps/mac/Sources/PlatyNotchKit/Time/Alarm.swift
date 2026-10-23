import Foundation

/// An alarm at a wall-clock time, once or on some weekdays. Pure value (Codable).
public struct Alarm: Codable, Identifiable, Equatable, Sendable {
    /// Snooze length (the ringing card's "Snooze").
    public static let snoozeInterval: TimeInterval = 9 * 60

    public var id: UUID
    public var hour: Int
    public var minute: Int
    /// 1 = Sunday … 7 = Saturday (`Calendar` weekday numbers); empty = once.
    public var weekdays: Set<Int>
    public var label: String
    public var enabled: Bool
    /// Rings again at this time (after Snooze), even when a once alarm has turned itself off.
    public var snoozedUntil: Date?

    public init(id: UUID = UUID(), hour: Int, minute: Int, weekdays: Set<Int> = [], label: String = "",
                enabled: Bool = true, snoozedUntil: Date? = nil) {
        self.id = id
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.label = label
        self.enabled = enabled
        self.snoozedUntil = snoozedUntil
    }

    public var isOnce: Bool { weekdays.isEmpty }

    /// The scheduled time after `date` (exclusive); nil while off. A time that does not
    /// exist that day (the spring-forward gap) fires the same minutes past the next hour
    /// (02:30 → 03:30); on the fall-back day a repeated time fires once, the first time.
    public func nextFire(after date: Date, calendar: Calendar) -> Date? {
        guard enabled else { return nil }
        let days: [Int?] = isOnce ? [nil] : weekdays.sorted().map { $0 }
        return days.compactMap { day in
            calendar.nextDate(after: date,
                              matching: DateComponents(hour: hour, minute: minute, weekday: day),
                              matchingPolicy: .nextTimePreservingSmallerComponents,
                              repeatedTimePolicy: .first, direction: .forward)
        }.min()
    }

    /// When it rings next after `date`: the schedule or a snooze, whichever is first.
    public func nextRing(after date: Date, calendar: Calendar) -> Date? {
        let snooze = snoozedUntil.flatMap { $0 > date ? $0 : nil }
        return [snooze, nextFire(after: date, calendar: calendar)].compactMap { $0 }.min()
    }

    /// After it rang: a once alarm turns itself off; a snooze is used up.
    public mutating func markFired() {
        if isOnce { enabled = false }
        snoozedUntil = nil
    }

    public mutating func snooze(at date: Date) {
        snoozedUntil = date.addingTimeInterval(Self.snoozeInterval)
    }

    /// Turning an alarm off also drops a pending snooze.
    public mutating func setEnabled(_ on: Bool) {
        enabled = on
        if !on { snoozedUntil = nil }
    }

    /// "07:30" (24-hour; views format with the user's locale).
    public var timeText: String { String(format: "%02d:%02d", hour, minute) }
}
