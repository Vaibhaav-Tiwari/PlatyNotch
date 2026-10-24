import Foundation

/// Reads what people type into the timer's quick-add field.
///
/// "10" (minutes), "10m", "10 min", "1h30", "1h 30m", "90s", "1m30", "25:00" (m:ss),
/// "1:05:00" (h:mm:ss). Units: h/hr/hour(s), m/min/minute(s), s/sec/second(s), each at
/// most once and largest first; a bare number after hours is minutes, after minutes is
/// seconds. Nil for anything else, for zero and for more than 24 hours.
public enum DurationParser {
    public static let maximum: TimeInterval = 24 * 3600

    public static func parse(_ s: String) -> TimeInterval? {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let seconds = text.contains(":") ? colon(text) : units(text)
        guard let seconds, seconds > 0, TimeInterval(seconds) <= maximum else { return nil }
        return TimeInterval(seconds)
    }

    /// "1 h 30 min", "10 min", "1 min 30 s", "45 s".
    public static func describe(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 || parts.isEmpty { parts.append("\(s) s") }
        return parts.joined(separator: " ")
    }

    private static func colon(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) && $0.count <= 5 }) else { return nil }
        let n = parts.compactMap { Int($0) }
        if n.count == 2 { return n[1] < 60 ? n[0] * 60 + n[1] : nil }
        return n[1] < 60 && n[2] < 60 ? n[0] * 3600 + n[1] * 60 + n[2] : nil
    }

    private enum Unit: Int { case hours = 3, minutes = 2, seconds = 1 }

    private static func unit(_ word: String) -> Unit? {
        switch word {
        case "h", "hr", "hrs", "hour", "hours": .hours
        case "m", "min", "mins", "minute", "minutes": .minutes
        case "s", "sec", "secs", "second", "seconds": .seconds
        default: nil
        }
    }

    private static func units(_ text: String) -> Int? {
        let chars = Array(text)
        var i = 0
        var total = 0
        var last: Unit?
        var tokens = 0
        func skipSpaces() { while i < chars.count, chars[i] == " " { i += 1 } }
        while true {
            skipSpaces()
            guard i < chars.count else { break }
            var digits = ""
            while i < chars.count, chars[i].isASCIIDigit { digits.append(chars[i]); i += 1 }
            guard !digits.isEmpty, digits.count <= 6, let value = Int(digits) else { return nil }
            skipSpaces()
            var word = ""
            while i < chars.count, chars[i].isLetter { word.append(chars[i]); i += 1 }
            tokens += 1
            let u: Unit
            if word.isEmpty {
                // A bare number: minutes alone, else the unit below the previous one.
                switch last {
                case nil:
                    skipSpaces()
                    guard i == chars.count, tokens == 1 else { return nil }
                    u = .minutes
                case .hours: u = .minutes
                case .minutes: u = .seconds
                case .seconds: return nil
                }
            } else {
                guard let parsed = unit(word) else { return nil }
                u = parsed
            }
            if let last, u.rawValue >= last.rawValue { return nil }   // each once, largest first
            last = u
            total += value * (u == .hours ? 3600 : u == .minutes ? 60 : 1)
        }
        return tokens > 0 ? total : nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
