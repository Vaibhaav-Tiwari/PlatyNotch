import Foundation

/// A calendar event as the meeting widget uses it (EventKit-free).
public struct CalendarMeeting: Equatable, Sendable, Identifiable {
    /// Unique per occurrence (a repeating event's occurrences share an EventKit id).
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// The user declined it, or it is cancelled.
    public let declined: Bool
    /// From the event's URL, location or notes (`MeetingLinks`).
    public let joinURL: URL?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                declined: Bool = false, joinURL: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.declined = declined
        self.joinURL = joinURL
    }

    /// Timed and not declined: the meetings reminders and the in-meeting state are about.
    public var counts: Bool { !isAllDay && !declined }
}

/// The meeting reminders at 10, 5 and 1 minutes before the start.
public enum MeetingReminderSchedule {
    /// Minutes before the start.
    public static let offsets = [10, 5, 1]

    /// The reminder times still ahead (strictly after `now`), earliest first, no duplicates.
    public static func fireDates(start: Date, offsets: [Int] = offsets, now: Date) -> [Date] {
        Set(offsets).sorted(by: >)
            .map { start.addingTimeInterval(-Double($0) * 60) }
            .filter { $0 > now }
    }

    /// Offsets whose time has come while the meeting has not started, largest first.
    public static func crossed(start: Date, offsets: [Int] = offsets, now: Date) -> [Int] {
        guard now < start else { return [] }
        return Set(offsets).sorted(by: >).filter { start.addingTimeInterval(-Double($0) * 60) <= now }
    }

    /// The reminder to show now: the latest one whose time has come, unless it was shown.
    /// After a sleep only that one shows (never 10 then 5 then 1 at once). Nil once the
    /// meeting started. The caller records every `crossed` offset as shown.
    public static func due(start: Date, offsets: [Int] = offsets, now: Date, shown: Set<Int>) -> Int? {
        guard let latest = crossed(start: start, offsets: offsets, now: now).last, !shown.contains(latest) else { return nil }
        return latest
    }

    /// The countdown ring: 0 at `window` before the start, 1 at the start.
    public static func progress(start: Date, now: Date, window: TimeInterval = LivePriority.meetingSoonWindow) -> Double {
        guard window > 0 else { return 1 }
        return min(1, max(0, 1 - start.timeIntervalSince(now) / window))
    }
}

/// Which meetings matter now: the ones ahead, the one in progress, and when to look again.
public enum MeetingTimeline {
    /// Timed, not declined meetings that have not ended and start within `horizon`, by start.
    public static func upcoming(_ meetings: [CalendarMeeting], now: Date,
                                horizon: TimeInterval = UpcomingMeeting.horizon) -> [CalendarMeeting] {
        meetings.filter { $0.counts && $0.end > now && $0.start <= now.addingTimeInterval(horizon) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }

    /// The meeting in progress (the one that started last when several overlap).
    public static func current(_ meetings: [CalendarMeeting], now: Date) -> CalendarMeeting? {
        meetings.filter { $0.counts && $0.start <= now && now < $0.end }
            .max { $0.start != $1.start ? $0.start < $1.start : $0.id > $1.id }
    }

    /// The next meeting that has not started yet.
    public static func next(_ meetings: [CalendarMeeting], now: Date) -> CalendarMeeting? {
        upcoming(meetings, now: now).first { $0.start > now }
    }

    /// The next moment something changes: a reminder, a start or an end. Nil when nothing is ahead.
    public static func nextWake(_ meetings: [CalendarMeeting], now: Date,
                                offsets: [Int] = MeetingReminderSchedule.offsets) -> Date? {
        upcoming(meetings, now: now).flatMap { m in
            MeetingReminderSchedule.fireDates(start: m.start, offsets: offsets, now: now) + [m.start, m.end]
        }
        .filter { $0 > now }
        .min()
    }
}
