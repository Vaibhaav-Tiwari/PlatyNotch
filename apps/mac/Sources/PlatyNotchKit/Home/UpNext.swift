import Foundation

/// One calendar event or reminder that may show in Home's "Up next" (spec 2.2).
public struct UpNextItem: Equatable, Sendable {
    public enum Kind: Sendable { case event, reminder }

    public let id: String
    public let title: String
    /// An event's start, a reminder's due date; nil for an undated reminder.
    public let date: Date?
    /// The date carries a time of day (a reminder due "Today" without a time does not).
    public let hasTime: Bool
    public let isAllDay: Bool
    public let kind: Kind
    /// An event's end; nil counts as `QuickAdd.defaultEventLength` after the start.
    public let end: Date?

    public init(id: String, title: String, date: Date?, hasTime: Bool, isAllDay: Bool, kind: Kind, end: Date? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.hasTime = hasTime
        self.isAllDay = isAllDay
        self.kind = kind
        self.end = end
    }
}

/// One drawn row: a 58 pt time column, the title and a quiet note.
public struct UpNextRow: Equatable, Sendable {
    public let id: String
    public let time: String
    public let title: String
    public let note: String?
    public let overdue: Bool

    public init(id: String, time: String, title: String, note: String?, overdue: Bool) {
        self.id = id
        self.time = time
        self.title = title
        self.note = note
        self.overdue = overdue
    }
}

/// Calendar events and reminders merged into at most three rows: overdue reminders first
/// (oldest first), then by time. Pure: every query takes the time.
public enum UpNext {
    public static let limit = 3
    /// An event this close to starting says "in N m".
    static let soonWindow: TimeInterval = 60 * 60

    public static func rows(_ items: [UpNextItem], now: Date, calendar: Calendar, locale: Locale) -> [UpNextRow] {
        var overdue: [(Int, UpNextItem, Date)] = []
        var upcoming: [(Int, UpNextItem, Date)] = []
        for (index, item) in items.enumerated() {
            guard let date = item.date else { continue }   // an undated reminder has no place in time
            switch item.kind {
            case .event:
                if item.isAllDay { continue }
                let end: Date = item.end ?? date.addingTimeInterval(QuickAdd.defaultEventLength)
                if end <= now { continue }
                upcoming.append((index, item, date))
            case .reminder:
                if isOverdue(item, date: date, now: now, calendar: calendar) {
                    overdue.append((index, item, date))
                } else {
                    upcoming.append((index, item, date))
                }
            }
        }
        let first: [(Int, UpNextItem, Date)] = overdue.sorted { a, b in a.2 != b.2 ? a.2 < b.2 : a.0 < b.0 }
        let then: [(Int, UpNextItem, Date)] = upcoming.sorted { a, b in a.2 != b.2 ? a.2 < b.2 : a.0 < b.0 }
        return (first + then).prefix(limit).map { entry in
            row(entry.1, date: entry.2, overdue: entry.1.kind == .reminder && first.contains { $0.1.id == entry.1.id },
                now: now, calendar: calendar, locale: locale)
        }
    }

    /// A timed reminder is overdue once its time has passed; one with only a day, once that
    /// day is over.
    private static func isOverdue(_ item: UpNextItem, date: Date, now: Date, calendar: Calendar) -> Bool {
        if item.hasTime { return date < now }
        return calendar.startOfDay(for: date) < calendar.startOfDay(for: now)
    }

    private static func row(_ item: UpNextItem, date: Date, overdue: Bool, now: Date, calendar: Calendar,
                            locale: Locale) -> UpNextRow {
        let today: Bool = calendar.isDate(date, inSameDayAs: now)
        let clock: String = QuickAddFormat.time(date, calendar: calendar, locale: locale)
        let time: String
        if overdue {
            time = "Overdue"
        } else if item.kind == .reminder && !item.hasTime {
            time = QuickAddFormat.dayWord(date, now: now, calendar: calendar, locale: locale)
        } else if today {
            time = clock
        } else {
            time = QuickAddFormat.dayWord(date, now: now, calendar: calendar, locale: locale)
        }
        var note: String?
        switch item.kind {
        case .reminder:
            note = "reminder"
        case .event:
            let until: TimeInterval = date.timeIntervalSince(now)
            if until <= 0 {
                note = "now"
            } else if until <= soonWindow {
                note = "in \(Int((until / 60).rounded(.up))) m"
            } else if !today {
                note = clock
            }
        }
        return UpNextRow(id: item.id, time: time, title: item.title, note: note, overdue: overdue)
    }
}
