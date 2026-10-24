import Foundation

/// An incomplete reminder (EventKit-free).
public struct ReminderItem: Equatable, Sendable, Identifiable {
    /// EventKit's `calendarItemIdentifier`.
    public let id: String
    public let title: String
    public let due: Date?
    /// Whether `due` has a time of day (else it is due that whole day).
    public let hasTime: Bool
    public let listTitle: String

    public init(id: String, title: String, due: Date?, hasTime: Bool, listTitle: String = "") {
        self.id = id
        self.title = title
        self.due = due
        self.hasTime = hasTime
        self.listTitle = listTitle
    }
}

/// A Reminders list.
public struct ReminderList: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Which reminders the tile shows and how.
public enum RemindersDay {
    /// Overdue: a timed reminder whose time has passed, or a day reminder from before today.
    public static func isOverdue(_ r: ReminderItem, now: Date, calendar: Calendar) -> Bool {
        guard let due = r.due else { return false }
        return r.hasTime ? due < now : due < calendar.startOfDay(for: now)
    }

    /// Due today or overdue (nothing later, nothing without a date): overdue first, then by
    /// due time (day reminders before timed ones on the same day), then title.
    public static func today(_ items: [ReminderItem], now: Date, calendar: Calendar) -> [ReminderItem] {
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return [] }
        return items.filter { $0.due.map { $0 < endOfToday } ?? false }
            .sorted { a, b in
                let ao = isOverdue(a, now: now, calendar: calendar), bo = isOverdue(b, now: now, calendar: calendar)
                if ao != bo { return ao }
                if a.due != b.due { return a.due! < b.due! }
                if a.hasTime != b.hasTime { return !a.hasTime }
                return a.title.localizedCompare(b.title) == .orderedAscending
            }
    }

    /// "Overdue", "Today", "5:00 PM", "Yesterday 5:00 PM", "Oct 20".
    public static func dueText(_ r: ReminderItem, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        guard let due = r.due else { return "" }
        let time = r.hasTime ? QuickAddFormat.time(due, calendar: calendar, locale: locale) : nil
        if calendar.isDate(due, inSameDayAs: now) { return time ?? "Today" }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(due, inSameDayAs: $0) } ?? false
        if yesterday { return time.map { "Yesterday \($0)" } ?? "Yesterday" }
        return QuickAddFormat.day(due, now: now, calendar: calendar, locale: locale)
    }
}

/// The line under the quick-add field: what will be created.
public enum QuickAddFormat {
    /// Exactly what will be saved: "Reminder · Today 5:00 PM", "Event · Sat 3:00 PM – 3:30 PM",
    /// "Reminder · No date", and " (past)" for an explicit day whose time is over.
    public static func preview(_ q: QuickAdd, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let kind = q.isEvent ? "Event" : "Reminder"
        guard let due = q.due else { return "\(kind) · No date" }
        var when = dayWord(due, now: now, calendar: calendar, locale: locale)
        if q.hasTime { when += " " + time(due, calendar: calendar, locale: locale) }
        if let end = q.eventEnd { when += " – " + time(end, calendar: calendar, locale: locale) }
        if q.isPast { when += " (past)" }
        return "\(kind) · \(when)"
    }

    static func dayWord(_ d: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "Today" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: t) { return "Tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: d)).day ?? 99
        if (2..<7).contains(days) { return format(d, "EEE", calendar: calendar, locale: locale) }
        return day(d, now: now, calendar: calendar, locale: locale)
    }

    static func day(_ d: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let sameYear = calendar.component(.year, from: d) == calendar.component(.year, from: now)
        return format(d, sameYear ? "MMMd" : "yMMMd", calendar: calendar, locale: locale)
    }

    static func time(_ d: Date, calendar: Calendar, locale: Locale) -> String {
        format(d, "jmm", calendar: calendar, locale: locale)
    }

    private static func format(_ d: Date, _ template: String, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }
}
