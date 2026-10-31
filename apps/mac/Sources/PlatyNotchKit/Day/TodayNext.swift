import Foundation

/// One day of the Today card's week strip.
public struct WeekDay: Equatable, Sendable {
    /// "Sa".
    public let weekday: String
    /// "31".
    public let day: String
    /// The day's start.
    public let date: Date
    /// Wears the count-blue circle.
    public let marked: Bool

    public init(weekday: String, day: String, date: Date, marked: Bool) {
        self.weekday = weekday
        self.day = day
        self.date = date
        self.marked = marked
    }
}

/// The Today card's bottom part (Island spec 3.2, 3.5): the next event, else the week
/// strip, never "Nothing up next".
public enum TodayNext: Equatable, Sendable {
    /// `Next · in 45 min` / "Design review" / `3:44 PM · Google Meet`.
    case event(label: String, title: String, detail: String)
    /// `Free today` / `Free tonight` over the week, the next day with an event marked.
    case free(label: String, days: [WeekDay])
    /// Calendar off or not granted: "This week" with today marked, and a link to Settings.
    case noCalendar(days: [WeekDay])
    /// The first run's "Try it".
    case sample(title: String, subtitle: String)

    public static let thisWeek = "This week"
    public static let connectCalendar = "Connect Calendar"

    /// Every string it shows, in reading order.
    public var texts: [String] {
        switch self {
        case .event(let label, let title, let detail): [label, title, detail]
        case .free(let label, let days): [label] + days.flatMap { [$0.weekday, $0.day] }
        case .noCalendar(let days): [Self.thisWeek] + days.flatMap { [$0.weekday, $0.day] } + [Self.connectCalendar]
        case .sample(let title, let subtitle): [title, subtitle]
        }
    }
}

public enum TodayNextModel {
    /// "Free tonight" from this hour.
    public static let eveningHour = 17
    /// "Next · in N min" up to this many minutes ahead.
    public static let soonMinutes = 60

    /// `meetings == nil`: Calendar is off or not granted. `daysWithEvents`: the start of each
    /// day in the coming week with a timed or all-day, not-declined event.
    public static func make(meetings: [CalendarMeeting]?, daysWithEvents: Set<Date>, now: Date,
                            calendar: Calendar, locale: Locale) -> TodayNext {
        guard let meetings else {
            return .noCalendar(days: week(from: now, mark: calendar.startOfDay(for: now), calendar: calendar, locale: locale))
        }
        let candidates = meetings.filter { $0.counts && $0.end > now && calendar.isDate($0.start, inSameDayAs: now) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        if let m = candidates.first {
            let label: String
            if m.start <= now {
                label = "Now · ends " + time(m.end, calendar: calendar, locale: locale)
            } else {
                let minutes = Int((m.start.timeIntervalSince(now) / 60).rounded(.up))
                label = minutes <= soonMinutes ? "Next · in \(max(1, minutes)) min" : "Next · later today"
            }
            var detail = time(m.start, calendar: calendar, locale: locale)
            if let url = m.joinURL, let provider = MeetingLinks.providerName(url) { detail += " · " + provider }
            return .event(label: label, title: m.title, detail: detail)
        }
        let today = calendar.startOfDay(for: now)
        let next = daysWithEvents.map { calendar.startOfDay(for: $0) }.filter { $0 > today }.min()
        let label = calendar.component(.hour, from: now) >= eveningHour ? "Free tonight" : "Free today"
        return .free(label: label, days: week(from: now, mark: next, calendar: calendar, locale: locale))
    }

    /// Seven days from today; `mark` (a day's start) wears the circle.
    public static func week(from now: Date, mark: Date?, calendar: Calendar, locale: Locale) -> [WeekDay] {
        let weekday = formatter("EEEEEE", calendar: calendar, locale: locale)
        let day = formatter("d", calendar: calendar, locale: locale)
        let start = calendar.startOfDay(for: now)
        return (0..<7).compactMap { i in
            guard let d = calendar.date(byAdding: .day, value: i, to: start) else { return nil }
            return WeekDay(weekday: weekday.string(from: d), day: day.string(from: d), date: d,
                           marked: mark.map { calendar.isDate($0, inSameDayAs: d) } ?? false)
        }
    }

    /// "3:44 PM" in the locale's clock, with plain spaces.
    static func time(_ d: Date, calendar: Calendar, locale: Locale) -> String {
        QuickAddFormat.time(d, calendar: calendar, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func formatter(_ format: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.dateFormat = format
        return f
    }
}
