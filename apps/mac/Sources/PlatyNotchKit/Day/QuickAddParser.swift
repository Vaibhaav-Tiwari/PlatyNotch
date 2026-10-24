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
/// English phrase rules run first, against the injected `calendar` (its time zone decides
/// what "5pm" and "tomorrow" mean) and `now`: times (5pm, 5:30 pm, 17:30, at 5, noon,
/// midnight), days (today, tonight, tomorrow, weekdays, "next friday", "nov 3", "2nd of
/// January", "in 2 days"), relative times ("in 20 min", "in an hour"), parts of the day
/// ("tomorrow morning") and durations ("for 30 min"). A time with no day is today, or
/// tomorrow when it has passed. Only when no rule matched, `NSDataDetector` looks for an
/// absolute date ("2027-12-01"); its year, month, day and time are read in the Mac's time
/// zone and placed in `calendar`.
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
            let day = takeDay(&scan, now: now, calendar: calendar)
            let time = takeTime(&scan) ?? day.partOfDay
            (due, hasTime) = resolve(day: day, time: time, now: now, calendar: calendar)
            if due == nil, let (date, timed) = detect(&scan, calendar: calendar) {
                due = date
                hasTime = timed
            }
        }

        let isEvent = due != nil && (duration != nil || text.range(of: Pattern.eventWords, options: [.regularExpression, .caseInsensitive]) != nil)
        if isEvent, let d = due, !hasTime {
            let lunch = text.range(of: #"\blunch\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            due = calendar.date(bySettingHour: lunch ? 12 : 9, minute: 0, second: 0, of: d)
            hasTime = true
        }
        if due != nil, let m = durationMatch { scan.mask(m.range) }

        var title = tidy(scan.remaining)
        if title.isEmpty { title = isEvent ? "Event" : (due == nil ? "" : "Reminder") }
        return QuickAdd(title: title, due: due, isEvent: isEvent, duration: due == nil ? nil : duration, hasTime: hasTime)
    }

    // MARK: - Days

    private struct Day {
        enum Kind { case none, offset(Int), date(year: Int?, month: Int, day: Int), weekday(Int, strictlyAfterToday: Bool) }
        var kind: Kind = .none
        var partOfDay: (hour: Int, minute: Int)?
    }

    private static func takeDay(_ scan: inout Scanner, now: Date, calendar: Calendar) -> Day {
        var day = Day()
        if let m = scan.take(Pattern.monthFirst),
           let month = monthNumber(m.group(1)), let d = m.group(2).flatMap(Int.init) {
            day.kind = .date(year: m.group(3).flatMap(Int.init), month: month, day: d)
        } else if let m = scan.take(Pattern.dayFirst),
                  let month = monthNumber(m.group(2)), let d = m.group(1).flatMap(Int.init) {
            day.kind = .date(year: m.group(3).flatMap(Int.init), month: month, day: d)
        } else if let m = scan.take(Pattern.dayWord) {
            let word = m.group(1)?.lowercased() ?? ""
            day.kind = .offset(word.hasPrefix("to") && !word.hasPrefix("tom") ? 0 : 1)
            if word == "tonight" { day.partOfDay = (20, 0) }
            if let part = m.group(2) { day.partOfDay = partOfDay(part) }
        } else if let m = scan.take(Pattern.weekdayFull) ?? scan.take(Pattern.weekdayShort),
                  let w = weekdayNumber(m.group(2)) {
            day.kind = .weekday(w, strictlyAfterToday: m.group(1)?.lowercased() == "next")
        }
        if day.partOfDay == nil, let m = scan.take(Pattern.partOfDay), let part = m.group(1) {
            day.partOfDay = partOfDay(part)
            if case .none = day.kind { day.kind = .offset(0) }
        }
        return day
    }

    private static func resolve(day: Day, time: (hour: Int, minute: Int)?, now: Date,
                                calendar: Calendar) -> (Date?, Bool) {
        let today = calendar.startOfDay(for: now)
        func at(_ d: Date) -> Date? {
            guard let time else { return d }
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: d)
        }
        func plus(_ days: Int, _ d: Date = today) -> Date? { calendar.date(byAdding: .day, value: days, to: d) }

        switch day.kind {
        case .none:
            guard let time else { return (nil, false) }
            guard let candidate = at(today) else { return (nil, false) }
            // Midnight means the coming one.
            let rolled = candidate <= now || (time.hour == 0 && time.minute == 0) ? plus(1, candidate) : candidate
            return (rolled, true)
        case .offset(let n):
            return (plus(n).flatMap(at), time != nil)
        case .date(let year, let month, let d):
            let thisYear = calendar.component(.year, from: now)
            func make(_ y: Int) -> Date? { calendar.date(from: DateComponents(year: y, month: month, day: d)) }
            guard var date = make(year ?? thisYear) else { return (nil, false) }
            if year == nil, date < today, let next = make(thisYear + 1) { date = next }
            return (at(date), time != nil)
        case .weekday(let w, let strict):
            let todayW = calendar.component(.weekday, from: now)
            var ahead = (w - todayW + 7) % 7
            if strict && ahead == 0 { ahead = 7 }
            guard var date = plus(ahead).flatMap(at) else { return (nil, false) }
            if !strict, ahead == 0, time != nil, date <= now, let later = plus(7, date) { date = later }
            return (date, time != nil)
        }
    }

    // MARK: - Times

    private static func takeTime(_ scan: inout Scanner) -> (hour: Int, minute: Int)? {
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
            return m.group(1)?.lowercased() == "midnight" ? (0, 0) : (12, 0)
        }
        if let m = scan.take(Pattern.bareHour), let h = m.group(1).flatMap(Int.init), (0...23).contains(h) {
            // "at 5" is 17:00: people rarely mean 5 in the morning without saying so.
            return ((1...7).contains(h) ? h + 12 : h, 0)
        }
        return nil
    }

    private static func partOfDay(_ word: String) -> (hour: Int, minute: Int)? {
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
        var mac = Calendar(identifier: .gregorian)
        mac.timeZone = match.timeZone ?? .current
        let c = mac.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let found = ns.substring(with: match.range)
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
        static let monthNames = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?"#
        static let duration = re(#"\bfor\s+"# + number + #"\s*(hours?|hrs?|h|minutes?|mins?|m)\b(?:\s*(\d{1,2})\s*(?:minutes?|mins?|m)\b)?"#)
        static let relative = re(#"\bin\s+"# + number + #"\s*(hours?|hrs?|h|minutes?|mins?|m|days?|d|weeks?|wks?)\b"#)
        static let monthFirst = re(#"(?:\bon\s+)?\b"# + monthNames + #"\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4})\b)?"#)
        static let dayFirst = re(#"(?:\bon\s+)?\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + monthNames + #"(?:,?\s+(\d{4})\b)?"#)
        static let dayWord = re(#"\b(today|tonight|tomorrow|tmrw|tmr)\b(?:\s+(morning|afternoon|evening|night)\b)?"#)
        static let weekdayFull = re(#"\b(?:(on|next|this)\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#)
        static let weekdayShort = re(#"\b(on|next|this)\s+(mon|tues?|wed|thur?s?|fri|sat|sun)\b\.?"#)
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

    func find(_ re: NSRegularExpression) -> Match? {
        let s = text as String
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: text.length)) else { return nil }
        let groups = (0..<m.numberOfRanges).map { i -> String? in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : text.substring(with: r)
        }
        return Match(range: m.range, groups: groups)
    }

    /// Finds and blanks out the first match.
    mutating func take(_ re: NSRegularExpression) -> Match? {
        guard let m = find(re) else { return nil }
        mask(m.range)
        return m
    }

    mutating func mask(_ r: NSRange) {
        text.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
    }
}
