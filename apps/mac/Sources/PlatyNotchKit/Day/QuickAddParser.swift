import Foundation

/// What the Reminders tile's quick-add field means: a reminder, or a calendar event when
/// the text has a date and reads like one.
public struct QuickAdd: Equatable, Sendable {
    /// How long an event lasts when the text gives no duration.
    public static let defaultEventLength: TimeInterval = 30 * 60

    /// The text without its date, time and duration words, first letter capitalised.
    public let title: String
    /// When: a time, or (`hasTime == false`) the start of a day.
    public let due: Date?
    /// Has a date, and a duration phrase or one of the words "meeting", "call with", "lunch".
    public let isEvent: Bool
    /// From "for 30 min", "for an hour", "for 1h 30m"; nil without one (or without a date).
    public let duration: TimeInterval?
    /// Whether `due` has a time of day. A reminder without one is due that day (no alarm).
    /// Events always get a time (9:00, or 12:00 for lunch, when the text has none).
    public let hasTime: Bool

    public init(title: String, due: Date?, isEvent: Bool, duration: TimeInterval? = nil, hasTime: Bool = false) {
        self.title = title
        self.due = due
        self.isEvent = isEvent
        self.duration = duration
        self.hasTime = hasTime
    }

    /// The event's end: `due` plus `duration` (default 30 min). Nil for reminders.
    public var eventEnd: Date? {
        guard isEvent, let due else { return nil }
        return due.addingTimeInterval(duration ?? Self.defaultEventLength)
    }
}


/// Parses quick-add text ("call Priya at 5pm", "meeting with Sam tomorrow 3pm for 30 min").
///
/// English phrase rules run against the injected `calendar` (its time zone decides what
/// "5pm" and "tomorrow" mean) and `now`; the real clock is never read:
/// - Times: 5pm, 5:30 pm, 17:30, "at 5" (1–7 mean the afternoon: 17:00), noon, midnight.
///   A time with no day is today, or tomorrow once it has passed. "midnight" is always the
///   coming one: "tomorrow midnight" is 00:00 the day after tomorrow (the end of tomorrow).
/// - Days: today, tonight, tomorrow, "day after tomorrow", "in 2 days", "nov 3", "2nd of
///   January", and weekdays (full names or mon, tue, tues, wed, thu, thur, thurs, fri, sat,
///   sun, with or without on/next/this). A plain weekday is its next occurrence: today
///   when it is today and the time (if any) is still ahead, else next week; "next <day>"
///   is always after today. Words that are also English words only count as dates when
///   the context says so: "may 3" needs "on", an ordinal ("may 3rd"), a year, or a time or
///   the end of the text after it ("call may 3 times" has no date); unprefixed "sat" and
///   "sun" need the same ("sat down" has no date).
/// - A bare hour right after a day word is a time: "tomorrow 9" is 09:00 (same 1–7 rule).
/// - "tonight" without a time is 20:00; after 20:00 it is now + 1 hour, rounded up to the
///   next quarter hour.
/// - Relative: "in 20 min", "in an hour"; parts of the day: "tomorrow morning" (9:00),
///   afternoon (15:00), evening (18:00), night (20:00); durations: "for 30 min".
/// - Times that do not exist (the spring-forward gap) move forward by the gap: 2:30 on
///   that night is 3:30, whether or not a day was named.
/// Only when no rule matched, `NSDataDetector` looks for a date, and its answer is kept
/// only when the matched text has a year or a numeric date ("2027-12-01", "12/01",
/// "1 Dec 2027"): it resolves relative words against the real clock, so anything else it
/// finds is discarded. Its year, month, day and time are read in the Mac's time zone and
/// placed in `calendar`.
public enum QuickAddParser {
    public static func parse(_ s: String, now: Date, calendar: Calendar) -> QuickAdd {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return QuickAdd(title: "", due: nil, isEvent: false) }
        var scan = Scanner(text)

        let durationMatch = scan.find(Pattern.duration)   // masked only if the text has a date
        let duration = durationMatch.flatMap { m in
            amount(m.group(1), unit: m.group(2)).map { $0 + (m.group(3).flatMap(Double.init) ?? 0) * 60 }
        }

        var due: Date?
        var hasTime = false
        if let m = scan.take(Pattern.relative), let n = amount(m.group(1), unit: m.group(2)) {
            let unit = m.group(2)?.lowercased() ?? ""
            if unit.hasPrefix("d") || unit.hasPrefix("w") {
                let days = Int((n / 86_400).rounded())
                due = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))
            } else {
                due = now.addingTimeInterval(n)
                hasTime = true
            }
        } else {
            let day = takeDay(&scan)
            let explicit = day.hour ?? takeTime(&scan)
            (due, hasTime) = resolve(day: day, time: explicit ?? day.partOfDay,
                                     tonightDefault: day.tonight && explicit == nil, now: now, calendar: calendar)
            if due == nil, let (date, timed) = detect(&scan, calendar: calendar) {
                due = date
                hasTime = timed
            }
        }

        let isEvent = due != nil && (duration != nil || text.range(of: Pattern.eventWords, options: [.regularExpression, .caseInsensitive]) != nil)
        if isEvent, let d = due, !hasTime {
            let lunch = text.range(of: #"\blunch\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            due = at(d, (lunch ? 12 : 9, 0), calendar: calendar)
            hasTime = true
        }
        if due != nil, let m = durationMatch { scan.mask(m.range) }

        var title = tidy(scan.remaining)
        if title.isEmpty { title = isEvent ? "Event" : (due == nil ? "" : "Reminder") }
        return QuickAdd(title: title, due: due, isEvent: isEvent, duration: due == nil ? nil : duration, hasTime: hasTime)
    }

    // MARK: - Days

    private typealias Time = (hour: Int, minute: Int)

    private struct Day {
        enum Kind { case none, offset(Int), date(year: Int?, month: Int, day: Int), weekday(Int, strictlyAfterToday: Bool) }
        var kind: Kind = .none
        var partOfDay: Time?
        /// "tomorrow 9": the bare hour after a day word.
        var hour: Time?
        var tonight = false
    }

    private static func takeDay(_ scan: inout Scanner) -> Day {
        var day = Day()
        if let m = scan.take(Pattern.monthFirst, where: { m, rest in
               plausibleMonth(m.group(2), on: m.group(1), ordinal: m.group(4), year: m.group(5), rest: rest)
           }),
           let month = monthNumber(m.group(2)), let d = m.group(3).flatMap(Int.init) {
            day.kind = .date(year: m.group(5).flatMap(Int.init), month: month, day: d)
        } else if let m = scan.take(Pattern.dayFirst, where: { m, rest in
                      plausibleMonth(m.group(4), on: m.group(1), ordinal: m.group(3), year: m.group(5), rest: rest)
                  }),
                  let month = monthNumber(m.group(4)), let d = m.group(2).flatMap(Int.init) {
            day.kind = .date(year: m.group(5).flatMap(Int.init), month: month, day: d)
        } else if let m = scan.take(Pattern.dayWord) {
            let word = (m.group(1) ?? "").lowercased()
            if word.hasPrefix("day") { day.kind = .offset(2) }
            else if word == "today" || word == "tonight" { day.kind = .offset(0) }
            else { day.kind = .offset(1) }
            if word == "tonight" { day.partOfDay = (20, 0); day.tonight = true }
            if let part = m.group(2) { day.partOfDay = partOfDay(part); day.tonight = false }
            if let h = m.group(3).flatMap(Int.init), (0...23).contains(h) { day.hour = bareHour(h) }
        } else if let m = scan.take(Pattern.weekday, where: { m, rest in
                      let w = (m.group(2) ?? "").lowercased()
                      // "sat" and "sun" alone are English words: a date only with a prefix or
                      // a time (or the end of the text) after them.
                      return m.group(1) != nil || !(w == "sat" || w == "sun") || dateContextFollows(rest)
                  }),
                  let w = weekdayNumber(m.group(2)) {
            day.kind = .weekday(w, strictlyAfterToday: m.group(1)?.lowercased() == "next")
        }
        if day.partOfDay == nil, let m = scan.take(Pattern.partOfDay), let part = m.group(1) {
            day.partOfDay = partOfDay(part)
            if case .none = day.kind { day.kind = .offset(0) }
        }
        return day
    }

    /// "may" is also a verb: as a month it needs "on", an ordinal, a year, or date-like text after it.
    private static func plausibleMonth(_ month: String?, on: String?, ordinal: String?, year: String?, rest: String) -> Bool {
        guard month?.lowercased() == "may" else { return true }
        return on != nil || ordinal != nil || year != nil || dateContextFollows(rest)
    }

    /// The text after a match is empty, punctuation, or a time / connector ("at 5", "3pm", "for 30 min").
    private static func dateContextFollows(_ rest: String) -> Bool {
        rest.range(of: #"^\s*($|[,.;:!?)\-–—]|(at|by|for|from|until|to|@)\b|@|\d{1,2}(:\d\d)?\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d\d|(noon|midday|midnight|morning|afternoon|evening|night)\b)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `d`'s day at `time` (hour 24 = 00:00 the next day). A time inside the spring-forward
    /// gap moves forward by the gap (2:30 → 3:30), the same way whatever day was named.
    private static func at(_ d: Date, _ time: Time, calendar: Calendar) -> Date? {
        var base = d
        var hour = time.hour
        if hour >= 24, let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: d)) {
            base = next
            hour -= 24
        }
        var c = calendar.dateComponents([.year, .month, .day], from: base)
        c.hour = hour
        c.minute = time.minute
        c.second = 0
        return calendar.date(from: c)
    }

    private static func resolve(day: Day, time: Time?, tonightDefault: Bool, now: Date,
                                calendar: Calendar) -> (Date?, Bool) {
        let today = calendar.startOfDay(for: now)
        func on(_ d: Date?) -> Date? {
            guard let d else { return nil }
            guard let time else { return d }
            return at(d, time, calendar: calendar)
        }
        func plus(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: today) }

        switch day.kind {
        case .none:
            guard time != nil, let candidate = on(today) else { return (nil, false) }
            return (candidate > now ? candidate : on(plus(1)), true)
        case .offset(let n):
            guard let candidate = on(plus(n)) else { return (nil, false) }
            if tonightDefault, n == 0, candidate <= now {
                // "tonight" after 20:00: an hour from now, rounded up to the next quarter hour.
                let quarter: TimeInterval = 15 * 60
                let later = now.addingTimeInterval(3600)
                return (Date(timeIntervalSinceReferenceDate: (later.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter), true)
            }
            return (candidate, time != nil)
        case .date(let year, let month, let d):
            let thisYear = calendar.component(.year, from: now)
            func make(_ y: Int) -> Date? { calendar.date(from: DateComponents(year: y, month: month, day: d)) }
            guard var date = make(year ?? thisYear) else { return (nil, false) }
            if year == nil, date < today, let next = make(thisYear + 1) { date = next }
            return (on(date), time != nil)
        case .weekday(let w, let strict):
            let todayW = calendar.component(.weekday, from: now)
            var ahead = (w - todayW + 7) % 7
            if strict && ahead == 0 { ahead = 7 }
            guard var date = on(plus(ahead)) else { return (nil, false) }
            if !strict, ahead == 0, time != nil, date <= now, let later = on(plus(7)) { date = later }
            return (date, time != nil)
        }
    }

    // MARK: - Times

    private static func takeTime(_ scan: inout Scanner) -> Time? {
        if let m = scan.take(Pattern.meridiem), var h = m.group(1).flatMap(Int.init), (1...12).contains(h) {
            let minute = m.group(2).flatMap(Int.init) ?? 0
            let pm = m.group(3)?.lowercased().hasPrefix("p") ?? false
            if h == 12 { h = 0 }
            return (pm ? h + 12 : h, minute)
        }
        if let m = scan.take(Pattern.clock), let h = m.group(1).flatMap(Int.init), let mi = m.group(2).flatMap(Int.init) {
            return (h, mi)
        }
        if let m = scan.take(Pattern.namedTimeAfterAt) ?? scan.take(Pattern.namedTime) {
            // Midnight is the end of the day named (or of today): 00:00 the day after.
            return m.group(1)?.lowercased() == "midnight" ? (24, 0) : (12, 0)
        }
        if let m = scan.take(Pattern.bareHour), let h = m.group(1).flatMap(Int.init), (0...23).contains(h) {
            return bareHour(h)
        }
        return nil
    }

    /// "at 5" is 17:00: people rarely mean 5 in the morning without saying so.
    private static func bareHour(_ h: Int) -> Time {
        ((1...7).contains(h) ? h + 12 : h, 0)
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

    // MARK: - NSDataDetector fallback

    private static func detect(_ scan: inout Scanner, calendar: Calendar) -> (Date, Bool)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let text = scan.remaining
        let ns = text as NSString
        guard let match = detector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let date = match.date else { return nil }
        let found = ns.substring(with: match.range)
        // Only absolute dates: relative ones ("fri", "next week") were resolved against the
        // real clock, not `now`.
        guard found.range(of: #"\b\d{4}\b|\d{1,4}[-/.]\d{1,2}"#, options: .regularExpression) != nil else { return nil }
        var mac = Calendar(identifier: .gregorian)
        mac.timeZone = match.timeZone ?? .current
        let c = mac.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let timed = found.range(of: #"\d:\d\d|\d\s*[ap]\.?m\b|noon|midnight"#, options: [.regularExpression, .caseInsensitive]) != nil
        var parts = DateComponents(year: c.year, month: c.month, day: c.day)
        if timed { parts.hour = c.hour; parts.minute = c.minute }
        guard let placed = calendar.date(from: parts) else { return nil }
        scan.mask(match.range)
        return (placed, timed)
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
        static let duration = re(#"\bfor\s+"# + number + #"\s*(hours?|hrs?|h|minutes?|mins?|m)\b(?:\s*(\d{1,2})\s*(?:minutes?|mins?|m)\b)?"#)
        static let relative = re(#"\bin\s+"# + number + #"\s*(hours?|hrs?|h|minutes?|mins?|m|days?|d|weeks?|wks?)\b"#)
        /// 1 "on", 2 month, 3 day, 4 ordinal, 5 year.
        static let monthFirst = re(#"(?:\b(on)\s+)?\b"# + monthNames + #"\s+(\d{1,2})(st|nd|rd|th)?\b(?:,?\s+(\d{4})\b)?"#)
        /// 1 "on", 2 day, 3 ordinal, 4 month, 5 year.
        static let dayFirst = re(#"(?:\b(on)\s+)?\b(\d{1,2})(st|nd|rd|th)?\s+(?:of\s+)?"# + monthNames + #"(?:,?\s+(\d{4})\b)?"#)
        /// 1 day word, 2 part of day, 3 bare hour ("tomorrow 9", not "tomorrow 9pm" or "9:30").
        static let dayWord = re(#"\b(day\s+after\s+tomorrow|today|tonight|tomorrow|tmrw|tmr)\b(?:\s+(morning|afternoon|evening|night)\b)?(?:\s+(?:at\s+)?(\d{1,2})\b(?![:.]\d|\s*(?:am|pm|a\.m\.|p\.m\.|%|/|h\b|hrs?\b|hours?\b|m\b|mins?\b|minutes?\b)))?"#)
        /// 1 on/next/this, 2 weekday (full or short).
        static let weekday = re(#"\b(?:(on|next|this)\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|wed|thu(?:rs?)?|fri|sat|sun)(?![a-z])\.?"#)
        static let partOfDay = re(#"\b(?:this|in\s+the)\s+(morning|afternoon|evening)\b"#)
        static let atPrefix = #"(?:(?:\b(?:at|by)|@)\s*)?"#
        static let meridiem = re(atPrefix + #"\b(\d{1,2})(?::([0-5]\d))?\s*(am|pm|a\.m\.|p\.m\.)(?![a-z])"#)
        static let clock = re(atPrefix + #"\b([01]?\d|2[0-3]):([0-5]\d)\b"#)
        static let namedTimeAfterAt = re(#"(?:\b(?:at|by)\s+)\b(noon|midday|midnight)\b"#)
        static let namedTime = re(#"\b(noon|midday|midnight)\b"#)
        static let bareHour = re(#"(?:\bat|@)\s*(\d{1,2})\b(?!\s*(?:%|:|/|\.\d))"#)
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

    private func all(_ re: NSRegularExpression) -> [Match] {
        re.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { m in
            Match(range: m.range, groups: (0..<m.numberOfRanges).map { i -> String? in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : text.substring(with: r)
            })
        }
    }

    func find(_ re: NSRegularExpression) -> Match? { all(re).first }

    /// Finds and blanks out the first match.
    mutating func take(_ re: NSRegularExpression) -> Match? {
        guard let m = find(re) else { return nil }
        mask(m.range)
        return m
    }

    /// Blanks out the first match that `accept` (given the text after it) agrees with.
    mutating func take(_ re: NSRegularExpression, where accept: (Match, String) -> Bool) -> Match? {
        for m in all(re) {
            let end = m.range.location + m.range.length
            let rest = text.substring(from: end)
            if accept(m, rest) {
                mask(m.range)
                return m
            }
        }
        return nil
    }

    mutating func mask(_ r: NSRange) {
        text.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
    }
}
