import Foundation

/// What the Reminders tile's quick-add field means: a reminder, or a calendar event when
/// the text has a date and reads like one.
public struct QuickAdd: Equatable, Sendable {
    /// How long an event lasts when the text gives no duration.
    public static let defaultEventLength: TimeInterval = 30 * 60

    /// The text without the date, time and duration words that were understood, first
    /// letter capitalised. Anything not understood stays.
    public let title: String
    /// When: a time, or (`hasTime == false`) the start of a day.
    public let due: Date?
    /// Has a date, and a duration ("for 30 min", a range "3-4pm") or one of the words
    /// "meeting", "call with", "lunch".
    public let isEvent: Bool
    /// From "for 30 min", "for an hour", "for 1h 30m" or a range ("3-4pm"); nil without
    /// one (or without a date).
    public let duration: TimeInterval?
    /// Whether `due` has a time of day. A reminder without one is due that day (no alarm).
    /// Events always get a time (9:00, or 12:00 for lunch, when the text has none).
    public let hasTime: Bool
    /// `due` is already over: only when the text named the day explicitly ("today 8",
    /// "this friday 9am", "2026-10-01"). Saved as typed; the preview says "(past)".
    public let isPast: Bool

    public init(title: String, due: Date?, isEvent: Bool, duration: TimeInterval? = nil, hasTime: Bool = false,
                isPast: Bool = false) {
        self.title = title
        self.due = due
        self.isEvent = isEvent
        self.duration = duration
        self.hasTime = hasTime
        self.isPast = isPast
    }

    /// The event's end: `due` plus `duration` (default 30 min). Nil for reminders.
    public var eventEnd: Date? {
        guard isEvent, let due else { return nil }
        return due.addingTimeInterval(duration ?? Self.defaultEventLength)
    }
}

/// Parses quick-add text ("call Priya at 5pm", "meeting with Sam tomorrow 3pm for 30 min")
/// against the injected `calendar` (its time zone decides what "5pm" and "tomorrow" mean)
/// and `now`. The real clock is never read and no system date detection is used.
///
/// Two independent passes, then a combine step. Each pass removes from the title exactly
/// the text it understood, and nothing else.
///
/// **Date pass** (at most one, first kind found wins: an absolute date beats a day word,
/// which beats a weekday; a second, conflicting date phrase stays in the title):
/// - Absolute: ISO `YYYY-MM-DD`; "D Mon [YYYY]" ("2nd of January", "1 Dec 2027") and
///   "Mon D[st|nd|rd|th] [YYYY]" ("nov 3", "may 3rd"). Month names are whole words; "may"
///   counts only with "on", an ordinal, a year, or a time / the end of the text after the
///   day. Without a year: the next occurrence on or after today. The day is checked
///   against the month ("jan 32", "feb 30" are no date).
/// - Numeric dates with slashes or dots ("12/01", "12.01.2027") are locale-ambiguous:
///   text containing one gets no date at all.
/// - Relative: today, tonight, tomorrow, "day after tomorrow", "in 2 days", "this
///   morning", "tomorrow evening".
/// - Weekdays, full or short (mon, tue, tues, wed, thu, thur, thurs, fri, sat, sun), with or
///   without on / next / this. Unprefixed "sat" / "sun" need a time or the end of the text
///   after them ("sat down" is no date).
///
/// **Time pass** (at most one): ranges ("3-4pm", "3pm-4pm", "3 to 4pm", "15:00-16:00": start
/// and duration; a missing start meridiem is the end's, or am when that would make the
/// start later than the end); "H[:MM] am/pm", "H.MM am/pm"; 24 h "HH:MM"; noon; midnight
/// (the end of the day: "tomorrow midnight" is 00:00 the day after tomorrow); "at H"; "in N
/// minutes/hours"; and a bare hour, only right after a day word or weekday and only at
/// the end of the text or before punctuation ("tomorrow 9", "wed 9"; "tomorrow 5 apples"
/// keeps the 5). An hour with no am/pm means 13:00–19:00 for 1–7; after "tonight" it means
/// pm for 1–11.
///
/// **Combine:**
/// - Date and time: that day at that time. A plain weekday that is today, with the time
///   already gone, means next week. Explicit today / "this <weekday>" / an absolute date
///   are kept as typed even when past (`isPast`).
/// - Date only: due that day, no time ("tonight": 20:00, or after 20:00 now + 1 h rounded
///   up to the quarter hour).
/// - Time only: today if still ahead, else tomorrow.
/// - "in N minutes/hours" is now + N, and any date phrase stays in the title.
/// - Times in the spring-forward gap move forward by it (2:30 → 3:30), the same with or
///   without a day; a repeated fall-back hour takes its first occurrence.
///
/// "every …" never makes a recurrence: the date it names is used once and the phrase
/// stays in the title ("every monday at 9" → "Every monday", next Monday 09:00).
public enum QuickAddParser {
    public static func parse(_ s: String, now: Date, calendar: Calendar) -> QuickAdd {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return QuickAdd(title: "", due: nil, isEvent: false) }
        if text.range(of: Pattern.numericDate, options: .regularExpression) != nil {
            return QuickAdd(title: tidy(text), due: nil, isEvent: false)
        }
        var scan = Scanner(text)
        let forDuration = scan.find(Pattern.duration)   // masked only when used

        var due: Date?
        var hasTime = false
        var isPast = false
        var rangeDuration: TimeInterval?
        if let m = scan.take(Pattern.relativeTime), let n = amount(m.group(1), unit: m.group(2)) {
            due = now.addingTimeInterval(n)
            hasTime = true
        } else {
            let date = datePass(&scan, now: now, calendar: calendar)
            let time = timePass(&scan, after: date, calendar: calendar)
            rangeDuration = time?.duration
            (due, hasTime, isPast) = combine(date: date, time: time, now: now, calendar: calendar)
        }

        var duration = rangeDuration
        if duration == nil, due != nil, let m = forDuration,
           let d = amount(m.group(1), unit: m.group(2)).map({ $0 + (m.group(3).flatMap(Double.init) ?? 0) * 60 }) {
            duration = d
            scan.mask(m.range)
        }

        let isEvent = due != nil && (duration != nil || text.range(of: Pattern.eventWords, options: [.regularExpression, .caseInsensitive]) != nil)
        if isEvent, let d = due, !hasTime {
            let lunch = text.range(of: #"\blunch\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            due = at(d, (lunch ? 12 : 9, 0), calendar: calendar)
            hasTime = true
            isPast = due.map { $0 < now } ?? false
        }

        var title = tidy(scan.remaining)
        if title.isEmpty { title = isEvent ? "Event" : (due == nil ? "" : "Reminder") }
        return QuickAdd(title: title, due: due, isEvent: isEvent, duration: due == nil ? nil : duration,
                        hasTime: hasTime, isPast: isPast)
    }

    // MARK: - Date pass

    typealias Time = (hour: Int, minute: Int)

    private struct DateHit {
        enum Kind {
            /// Start of that day; always kept as typed.
            case absolute(Date)
            /// Days from today. 0 is an explicit today.
            case offset(Int)
            case weekday(Int, mode: WeekdayMode)
        }
        enum WeekdayMode { case plain, this, next }
        var kind: Kind
        /// Where the matched text ends (for "tomorrow 9").
        var end: Int
        var partOfDay: Time?
        var tonight = false
    }

    private static func datePass(_ scan: inout Scanner, now: Date, calendar: Calendar) -> DateHit? {
        let today = calendar.startOfDay(for: now)
        var hit: DateHit?
        func record(_ m: Scanner.Match, _ kind: DateHit.Kind) {
            hit = DateHit(kind: kind, end: m.range.location + m.range.length)
            // "every monday": the phrase stays in the title (no recurrence is made).
            if !scan.before(m.range).lowercased().hasSuffix("every ") { scan.mask(m.range) }
        }

        if let m = scan.find(Pattern.iso, where: { m, _ in
               validDate(Int(m.group(1)!)!, Int(m.group(2)!)!, Int(m.group(3)!)!, calendar) != nil
           }) {
            record(m, .absolute(validDate(Int(m.group(1)!)!, Int(m.group(2)!)!, Int(m.group(3)!)!, calendar)!))
        } else if let (m, d) = monthDate(&scan, Pattern.monthFirst, on: 1, month: 2, day: 3, ordinal: 4, year: 5,
                                         today: today, calendar: calendar)
                    ?? monthDate(&scan, Pattern.dayFirst, on: 1, month: 4, day: 2, ordinal: 3, year: 5,
                                 today: today, calendar: calendar) {
            record(m, .absolute(d))
        } else if let m = scan.find(Pattern.relativeDays), let n = amount(m.group(1), unit: m.group(2)) {
            record(m, .offset(Int((n / 86_400).rounded())))
        } else if let m = scan.find(Pattern.dayWord) {
            let word = (m.group(1) ?? "").lowercased()
            let offset = word.hasPrefix("day") ? 2 : (word == "today" || word == "tonight") ? 0 : 1
            record(m, .offset(offset))
            if word == "tonight" { hit?.partOfDay = (20, 0); hit?.tonight = true }
            if let part = m.group(2) { hit?.partOfDay = partOfDay(part); hit?.tonight = false }
        } else if let m = scan.find(Pattern.weekday, where: { m, rest in
                      let w = (m.group(2) ?? "").lowercased()
                      return m.group(1) != nil || !(w == "sat" || w == "sun") || dateContextFollows(rest)
                  }), let w = weekdayNumber(m.group(2)) {
            let mode: DateHit.WeekdayMode = switch m.group(1)?.lowercased() {
            case "next": .next
            case "this": .this
            default: .plain
            }
            record(m, .weekday(w, mode: mode))
        }

        if let m = scan.find(Pattern.partOfDay), let part = m.group(1) {
            scan.mask(m.range)
            if hit == nil { hit = DateHit(kind: .offset(0), end: m.range.location + m.range.length) }
            hit?.partOfDay = partOfDay(part)
            hit?.tonight = false
        }
        return hit
    }

    /// A month-name date that exists; with no year, its next occurrence on or after today.
    private static func monthDate(_ scan: inout Scanner, _ re: NSRegularExpression, on: Int, month: Int, day: Int,
                                  ordinal: Int, year: Int, today: Date, calendar: Calendar) -> (Scanner.Match, Date)? {
        func resolve(_ m: Scanner.Match) -> Date? {
            guard let mo = monthNumber(m.group(month)), let d = m.group(day).flatMap(Int.init) else { return nil }
            if let y = m.group(year).flatMap(Int.init) { return validDate(y, mo, d, calendar) }
            let thisYear = calendar.component(.year, from: today)
            for y in thisYear...(thisYear + 8) {
                if let date = validDate(y, mo, d, calendar), date >= today { return date }
            }
            return nil
        }
        guard let m = scan.find(re, where: { m, rest in
            plausibleMonth(m.group(month), on: m.group(on), ordinal: m.group(ordinal), year: m.group(year), rest: rest)
                && resolve(m) != nil
        }) else { return nil }
        return resolve(m).map { (m, $0) }
    }

    /// The start of that day, or nil when the day does not exist in that month.
    static func validDate(_ y: Int, _ m: Int, _ d: Int, _ calendar: Calendar) -> Date? {
        guard (1...12).contains(m), d >= 1,
              let first = calendar.date(from: DateComponents(year: y, month: m, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first), days.contains(d) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// "may" is also a verb: as a month it needs "on", an ordinal, a year, or date-like text after it.
    private static func plausibleMonth(_ month: String?, on: String?, ordinal: String?, year: String?, rest: String) -> Bool {
        guard month?.lowercased() == "may" else { return true }
        return on != nil || ordinal != nil || year != nil || dateContextFollows(rest)
    }

    /// The text after a match is empty, punctuation, a time or a connector ("at 5", "3pm", "for 30 min").
    private static func dateContextFollows(_ rest: String) -> Bool {
        rest.range(of: #"^\s*($|[,.;:!?)\-–—]|(at|by|for|from|until|to)\b|@|\d{1,2}([:.]\d\d)?\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d\d|\d{1,2}\s*($|[,.;!?])|(noon|midday|midnight|morning|afternoon|evening|night)\b)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Time pass

    private struct TimeHit {
        var time: Time
        /// No am/pm and no minutes ("at 5", "tomorrow 9"): "tonight" makes it pm.
        var bare: Bool
        var duration: TimeInterval?
    }

    private static func timePass(_ scan: inout Scanner, after date: DateHit?, calendar: Calendar) -> TimeHit? {
        if let m = scan.take(Pattern.range12),
           let sh = m.group(1).flatMap(Int.init), let eh = m.group(5).flatMap(Int.init),
           (1...12).contains(sh), (1...12).contains(eh) {
            let sm = (m.group(2) ?? m.group(3)).flatMap(Int.init) ?? 0
            let em = (m.group(6) ?? m.group(7)).flatMap(Int.init) ?? 0
            let endPM = m.group(8)!.lowercased().hasPrefix("p")
            let end = hour24(eh, pm: endPM) * 60 + em
            var start: Int
            if let own = m.group(4) {
                start = hour24(sh, pm: own.lowercased().hasPrefix("p")) * 60 + sm
            } else {
                start = hour24(sh, pm: endPM) * 60 + sm
                if start > end { start = hour24(sh, pm: !endPM) * 60 + sm }
            }
            var length = end - start
            if length <= 0 { length += 24 * 60 }
            return TimeHit(time: (start / 60, start % 60), bare: false, duration: TimeInterval(length * 60))
        }
        if let m = scan.take(Pattern.range24),
           let sh = m.group(1).flatMap(Int.init), let sm = m.group(2).flatMap(Int.init),
           let eh = m.group(3).flatMap(Int.init), let em = m.group(4).flatMap(Int.init) {
            var length = (eh * 60 + em) - (sh * 60 + sm)
            if length <= 0 { length += 24 * 60 }
            return TimeHit(time: (sh, sm), bare: false, duration: TimeInterval(length * 60))
        }
        if let m = scan.take(Pattern.meridiem), let h = m.group(1).flatMap(Int.init), (1...12).contains(h) {
            let minute = (m.group(2) ?? m.group(3)).flatMap(Int.init) ?? 0
            return TimeHit(time: (hour24(h, pm: m.group(4)!.lowercased().hasPrefix("p")), minute), bare: false)
        }
        if let m = scan.take(Pattern.clock), let h = m.group(1).flatMap(Int.init), let mi = m.group(2).flatMap(Int.init) {
            return TimeHit(time: (h, mi), bare: false)
        }
        if let m = scan.take(Pattern.namedTimeAfterAt) ?? scan.take(Pattern.namedTime) {
            // Midnight is the end of the day named (or of today): hour 24.
            return TimeHit(time: m.group(1)?.lowercased() == "midnight" ? (24, 0) : (12, 0), bare: false)
        }
        if let m = scan.take(Pattern.atHour), let h = m.group(1).flatMap(Int.init), (0...23).contains(h) {
            return TimeHit(time: (h, 0), bare: true)
        }
        // A bare hour only right after a day word or weekday, at the end or before punctuation.
        if let date, case .absolute = date.kind {} else if let date,
           let m = scan.take(Pattern.bareHourAfterDate, from: date.end),
           let h = m.group(1).flatMap(Int.init), (0...23).contains(h) {
            return TimeHit(time: (h, 0), bare: true)
        }
        return nil
    }

    private static func hour24(_ h: Int, pm: Bool) -> Int {
        let base = h == 12 ? 0 : h
        return pm ? base + 12 : base
    }

    private static func partOfDay(_ word: String) -> Time? {
        switch word.lowercased() {
        case "morning": (9, 0)
        case "afternoon": (15, 0)
        case "evening": (18, 0)
        case "night": (20, 0)
        default: nil
        }
    }

    // MARK: - Combine

    private static func combine(date: DateHit?, time: TimeHit?, now: Date, calendar: Calendar) -> (Date?, Bool, Bool) {
        let today = calendar.startOfDay(for: now)
        func plus(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: today) }

        var t = time?.time
        if let time, time.bare {
            let h = time.time.hour
            let pmRange = date?.tonight == true ? 1...11 : 1...7
            if pmRange.contains(h) { t = (h + 12, time.time.minute) }
        }

        guard let date else {
            guard let t, let candidate = at(today, t, calendar: calendar) else { return (nil, false, false) }
            return (candidate > now ? candidate : at(plus(1) ?? today, t, calendar: calendar), true, false)
        }

        // The day the date pass named.
        let base: Date?
        var plainToday = false
        switch date.kind {
        case .absolute(let d): base = d
        case .offset(let n): base = plus(n)
        case .weekday(let w, let mode):
            var ahead = (w - calendar.component(.weekday, from: now) + 7) % 7
            if mode == .next, ahead == 0 { ahead = 7 }
            plainToday = mode == .plain && ahead == 0
            base = plus(ahead)
        }
        guard let base else { return (nil, false, false) }

        if let t {
            guard var due = at(base, t, calendar: calendar) else { return (nil, false, false) }
            if plainToday, due <= now, let later = plus(7).flatMap({ at($0, t, calendar: calendar) }) { due = later }
            return (due, true, due < now)
        }
        if let part = date.partOfDay {
            guard let due = at(base, part, calendar: calendar) else { return (nil, false, false) }
            if date.tonight, due <= now {
                // "tonight" after 20:00: an hour from now, rounded up to the next quarter hour.
                let quarter: TimeInterval = 15 * 60
                let later = now.addingTimeInterval(3600).timeIntervalSinceReferenceDate
                return (Date(timeIntervalSinceReferenceDate: (later / quarter).rounded(.up) * quarter), true, false)
            }
            return (due, true, due < now)
        }
        return (base, false, base < today)
    }

    /// `d`'s day at `time` (hour 24 = 00:00 the next day), built from components so a time
    /// in the spring-forward gap moves forward by the gap (2:30 → 3:30) whatever day it is.
    static func at(_ d: Date, _ time: Time, calendar: Calendar) -> Date? {
        var base = calendar.startOfDay(for: d)
        var hour = time.hour
        if hour >= 24, let next = calendar.date(byAdding: .day, value: 1, to: base) {
            base = next
            hour -= 24
        }
        var c = calendar.dateComponents([.year, .month, .day], from: base)
        c.hour = hour
        c.minute = time.minute
        c.second = 0
        return calendar.date(from: c)
    }

    // MARK: - Helpers

    /// Seconds in "30 min", "1.5 hours", "an hour", "half an hour", "2 days".
    private static func amount(_ number: String?, unit: String?) -> TimeInterval? {
        guard let number = number?.lowercased(), let unit = unit?.lowercased(), !unit.isEmpty else { return nil }
        let n: Double
        if number.hasPrefix("half") { n = 0.5 } else if number == "a" || number == "an" { n = 1 } else if let v = Double(number) { n = v } else { return nil }
        let scale: Double = switch unit.first ?? "m" {
        case "h": 3600
        case "d": 86_400
        case "w": 7 * 86_400
        default: 60
        }
        return n * scale
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static func monthNumber(_ s: String?) -> Int? {
        guard let s = s?.lowercased() else { return nil }
        return months.firstIndex { s.hasPrefix($0) }.map { $0 + 1 }
    }

    /// Calendar weekday numbers: Sunday = 1.
    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static func weekdayNumber(_ s: String?) -> Int? {
        guard let s = s?.lowercased() else { return nil }
        return weekdays.firstIndex { s.hasPrefix($0) }.map { $0 + 1 }
    }

    /// Collapses spaces, drops connector words left at either end ("at", "on", "by"…) and
    /// stray punctuation, and capitalises the first letter.
    private static func tidy(_ s: String) -> String {
        var words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        let trailing: Set<String> = ["at", "on", "by", "due", "for", "in", "the", "this", "next", "@", "-", "–", "—", ",", "from", "until"]
        let leading: Set<String> = ["at", "on", "by", "@", "-", "–", "—", ","]
        func bare(_ w: String) -> String { w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) }
        while let last = words.last, trailing.contains(bare(last)) || bare(last).isEmpty { words.removeLast() }
        while let first = words.first, leading.contains(bare(first)) || bare(first).isEmpty { words.removeFirst() }
        var out = words.joined(separator: " ")
        out = out.replacingOccurrences(of: #"\s+([,;:!?])"#, with: "$1", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        guard let first = out.first else { return "" }
        return first.uppercased() + out.dropFirst()
    }

    private enum Pattern {
        static let number = #"(an?|half\s+an?|\d+(?:\.\d+)?)"#
        /// Whole words only: "decaf", "mayo", "junk" and "marshmallows" are not months.
        static let monthNames = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?![a-z])\.?"#
        /// Slash or dotted numeric dates, read differently per locale: never parsed.
        static let numericDate = #"\b\d{1,4}/\d{1,2}(?:/\d{2,4})?\b|\b\d{1,2}\.\d{1,2}\.\d{2,4}\b"#
        static let duration = re(#"\bfor\s+"# + number + #"\s*(hours?|hrs?|h|minutes?|mins?|m)\b(?:\s*(\d{1,2})\s*(?:minutes?|mins?|m)\b)?"#)
        static let relativeTime = re(#"\bin\s+"# + number + #"\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#)
        static let relativeDays = re(#"\bin\s+"# + number + #"\s*(days?|d|weeks?|wks?)\b"#)
        /// 1 year, 2 month, 3 day.
        static let iso = re(#"(?:\bon\s+)?\b(\d{4})-(\d{2})-(\d{2})\b"#)
        /// 1 "on", 2 month, 3 day, 4 ordinal, 5 year.
        static let monthFirst = re(#"(?:\b(on)\s+)?\b"# + monthNames + #"\s+(\d{1,2})(st|nd|rd|th)?\b(?:,?\s+(\d{4})\b)?"#)
        /// 1 "on", 2 day, 3 ordinal, 4 month, 5 year.
        static let dayFirst = re(#"(?:\b(on)\s+)?\b(\d{1,2})(st|nd|rd|th)?\s+(?:of\s+)?"# + monthNames + #"(?:,?\s+(\d{4})\b)?"#)
        /// 1 day word, 2 part of day.
        static let dayWord = re(#"\b(day\s+after\s+tomorrow|today|tonight|tomorrow|tmrw|tmr)\b(?:\s+(morning|afternoon|evening|night)\b)?"#)
        /// 1 on/next/this, 2 weekday (full or short).
        static let weekday = re(#"\b(?:(on|next|this)\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|wed|thu(?:rs?)?|fri|sat|sun)(?![a-z])\.?"#)
        static let partOfDay = re(#"\b(?:this|in\s+the)\s+(morning|afternoon|evening)\b"#)
        static let atPrefix = #"(?:(?:\b(?:at|by|from)|@)\s*)?"#
        static let meridiemWord = #"(am|pm|a\.m\.|p\.m\.)(?![a-z])"#
        /// 1 h, 2 :mm, 3 .mm, 4 start meridiem, 5 h, 6 :mm, 7 .mm, 8 end meridiem.
        static let range12 = re(atPrefix + #"\b(\d{1,2})(?::([0-5]\d)|\.([0-5]\d))?\s*(?:(am|pm)\s*)?(?:-|–|—|to|until)\s*(\d{1,2})(?::([0-5]\d)|\.([0-5]\d))?\s*"# + meridiemWord)
        static let range24 = re(atPrefix + #"\b([01]?\d|2[0-3]):([0-5]\d)\s*(?:-|–|—|to|until)\s*([01]?\d|2[0-3]):([0-5]\d)\b"#)
        /// 1 h, 2 :mm, 3 .mm, 4 meridiem.
        static let meridiem = re(atPrefix + #"\b(\d{1,2})(?::([0-5]\d)|\.([0-5]\d))?\s*"# + meridiemWord)
        static let clock = re(atPrefix + #"\b([01]?\d|2[0-3]):([0-5]\d)\b"#)
        static let namedTimeAfterAt = re(#"(?:\b(?:at|by)\s+)\b(noon|midday|midnight)\b"#)
        static let namedTime = re(#"\b(noon|midday|midnight)\b"#)
        static let atHour = re(#"(?:\bat|@)\s*(\d{1,2})\b(?!\s*(?:%|:|/|\.\d))"#)
        /// Anchored at the end of the date phrase.
        static let bareHourAfterDate = re(#"^\s*(\d{1,2})\s*(?=$|[,.;!?])"#)
        static let eventWords = #"\b(meeting|meetings|lunch)\b|\bcall\s+with\b"#

        private static func re(_ p: String) -> NSRegularExpression {
            // The patterns are constants: a typo is a programming error caught by the tests.
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
    }
}

/// The text being parsed, with what was understood blanked out (same length, so ranges
/// stay valid).
private struct Scanner {
    struct Match {
        let range: NSRange
        let groups: [String?]
        func group(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
    }

    private var text: NSMutableString

    init(_ s: String) { text = NSMutableString(string: s) }

    var remaining: String { text as String }

    private func all(_ re: NSRegularExpression, in range: NSRange? = nil) -> [Match] {
        let r = range ?? NSRange(location: 0, length: text.length)
        return re.matches(in: text as String, range: r).map { m in
            Match(range: m.range, groups: (0..<m.numberOfRanges).map { i -> String? in
                let g = m.range(at: i)
                return g.location == NSNotFound ? nil : text.substring(with: g)
            })
        }
    }

    func find(_ re: NSRegularExpression) -> Match? { all(re).first }

    /// The first match that `accept` (given the text after it) agrees with. Not masked.
    func find(_ re: NSRegularExpression, where accept: (Match, String) -> Bool) -> Match? {
        all(re).first { accept($0, text.substring(from: $0.range.location + $0.range.length)) }
    }

    /// The text before `range`.
    func before(_ range: NSRange) -> String { text.substring(to: range.location) }

    /// Finds and blanks out the first match.
    mutating func take(_ re: NSRegularExpression) -> Match? {
        guard let m = find(re) else { return nil }
        mask(m.range)
        return m
    }

    /// Finds and blanks out a match of `re` (anchored with `^`) starting at `location`.
    mutating func take(_ re: NSRegularExpression, from location: Int) -> Match? {
        guard location <= text.length,
              let m = all(re, in: NSRange(location: location, length: text.length - location)).first else { return nil }
        mask(m.range)
        return m
    }

    mutating func mask(_ r: NSRange) {
        text.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
    }
}
