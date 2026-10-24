import Foundation

/// Obvious secrets in copied text, with the same patterns as Memory's redaction
/// (`core/memory/ingest/redact.go`): private key blocks, JWTs, `sk-` API keys, AWS
/// access key ids, GitHub tokens (`gh?_`, `github_pat_`), Slack tokens (`xox?-`), Google
/// API keys (`AIza`) and Luhn-valid 13–19 digit card numbers (a stricter card rule than Go's,
/// see `containsCard`). Clipboard history skips
/// such text entirely rather than storing a redacted copy (a redacted copy would paste
/// the wrong thing). Keep the two lists in step.
public enum SecretText {
    /// The Go patterns, verbatim except the private key block, where a BEGIN line is
    /// enough to skip (Go also redacts to the END line or the end of the text).
    static let patterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        #"sk-[A-Za-z0-9_-]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"gh[pousr]_[A-Za-z0-9]{36,}"#,
        #"github_pat_[A-Za-z0-9_]{50,}"#,
        #"xox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"AIza[0-9A-Za-z_-]{35}"#,
    ].map { try! NSRegularExpression(pattern: $0) }   // constant patterns

    /// True when `text` holds anything the patterns above match.
    public static func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for p in patterns where p.firstMatch(in: text, range: range) != nil { return true }
        return containsCard(text)
    }

    /// The card rule is stricter than Go's redaction (round 2): a redaction that also
    /// catches a date or a spreadsheet cell costs a few characters, a skip loses the whole
    /// copy. A card is one standalone run of 13–19 digits, Luhn-valid, either contiguous or
    /// in card-shaped groups (4-4-4-4[-1…4], Amex 4-6-5, Diners 4-6-4) joined by one
    /// consistent separator (a space, NBSP-like space or dash); never part of a longer run
    /// of digit groups, a word, or a date-like sequence (`-./:` next to digits). A
    /// following `MM/YY(YY)` expiry or a trailing 3–4 digit CVV does not count as part of the
    /// run. Known miss: a card right after another 4-digit group with the same separator
    /// (`2027 4242 4242 4242 4242`), since allowing it would skip spreadsheet rows.
    static func containsCard(_ text: String) -> Bool {
        let s = Array(text.unicodeScalars)
        var i = 0
        while i < s.count {
            guard isDigit(s[i]) else { i += 1; continue }
            if i == 0 || !isWordChar(s[i - 1]) {
                if isCard(at: i, in: s) { return true }
            }
            while i < s.count, isDigit(s[i]) { i += 1 }
        }
        return false
    }

    /// A group separator: space, NBSP, figure space, narrow NBSP or dash.
    static func isGroupSeparator(_ c: Unicode.Scalar) -> Bool {
        [0x20, 0xA0, 0x2007, 0x202F, 0x2D].contains(c.value)
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }

    private static func isWordChar(_ c: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(c) || c == "_"
    }

    private static func isDateSeparator(_ c: Unicode.Scalar) -> Bool { "-./:".unicodeScalars.contains(c) }

    /// The end of a digit group starting at `i`.
    private static func groupEnd(_ s: [Unicode.Scalar], _ i: Int) -> Int {
        var j = i
        while j < s.count, isDigit(s[j]) { j += 1 }
        return j
    }

    /// Nothing that would make the run longer or date-like sits just before `start`.
    private static func cleanBefore(_ s: [Unicode.Scalar], _ start: Int) -> Bool {
        guard start > 0 else { return true }
        let c = s[start - 1]
        if isWordChar(c) { return false }
        if isDateSeparator(c), start >= 2, isDigit(s[start - 2]) { return false }
        return true
    }

    /// Nothing that would make the run longer or date-like sits just after `end`.
    private static func cleanAfter(_ s: [Unicode.Scalar], _ end: Int) -> Bool {
        guard end < s.count else { return true }
        let c = s[end]
        if isWordChar(c) { return false }
        if isDateSeparator(c), end + 1 < s.count, isDigit(s[end + 1]) { return false }
        return true
    }

    private static func isCard(at start: Int, in s: [Unicode.Scalar]) -> Bool {
        let first = groupEnd(s, start)
        let length = first - start
        // Contiguous: one standalone group of 13–19 digits.
        if (13...19).contains(length), cleanBefore(s, start), cleanAfter(s, first) {
            return luhn(digits(s, start, first))
        }
        guard length == 4, first < s.count, isGroupSeparator(s[first]) else { return false }
        // The run must start here: not preceded by the same separator after a digit.
        let sep = s[first]
        if start >= 2, s[start - 1] == sep, isDigit(s[start - 2]), !followsDate(s, start - 1) { return false }
        if !cleanBefore(s, start) { return false }
        var sizes = [length]
        var end = first
        while end + 1 < s.count, s[end] == sep, isDigit(s[end + 1]) {
            let next = groupEnd(s, end + 1)
            // `12/27` after the number is an expiry, not part of it.
            if next < s.count, s[next] == "/" { break }
            sizes.append(next - end - 1)
            end = next
        }
        if isCardLayout(sizes), tailAccepts(s, end), luhn(digits(s, start, end)) { return true }
        // The last group of the run is a CVV (`4242 4242 4242 4242 123`, Amex `… 10005 1234`).
        guard sizes.count >= 3, let cvv = sizes.last, (3...4).contains(cvv) else { return false }
        let cardEnd = end - cvv - 1
        return isCardLayout(Array(sizes.dropLast())) && tailAccepts(s, end) && luhn(digits(s, start, cardEnd))
    }

    /// What follows a grouped card ends it: nothing numeric, an MM/YY(YY) expiry (after any
    /// one separator or none), or one CVV group of 3–4 digits after any one separator.
    private static func tailAccepts(_ s: [Unicode.Scalar], _ end: Int) -> Bool {
        if expiryAfter(s, end) { return true }
        if cleanAfter(s, end), !continuesDigits(s, end) { return true }
        guard end + 1 < s.count, !isDigit(s[end]), !isWordChar(s[end]), isDigit(s[end + 1]) else { return false }
        let cvvEnd = groupEnd(s, end + 1)
        let n = cvvEnd - end - 1
        return (3...4).contains(n) && (expiryAfter(s, cvvEnd) || (cleanAfter(s, cvvEnd) && !continuesDigits(s, cvvEnd)))
    }

    /// A group separator followed by a digit at `k`: the digits go on.
    private static func continuesDigits(_ s: [Unicode.Scalar], _ k: Int) -> Bool {
        k + 1 < s.count && isGroupSeparator(s[k]) && isDigit(s[k + 1])
    }

    /// `MM/YY` or `MM/YYYY` (month 1–12) at `end`, or after one separator there, not
    /// continuing into a longer date (`12/27/2024`).
    static func expiryAfter(_ s: [Unicode.Scalar], _ end: Int) -> Bool {
        var k = end
        if k < s.count, !isDigit(s[k]), !isWordChar(s[k]) { k += 1 }
        let monthEnd = groupEnd(s, k)
        guard (1...2).contains(monthEnd - k), monthEnd < s.count, s[monthEnd] == "/" else { return false }
        let month = digits(s, k, monthEnd).reduce(0) { $0 * 10 + Int($1) }
        let yearEnd = groupEnd(s, monthEnd + 1)
        let yearLength = yearEnd - monthEnd - 1
        guard (1...12).contains(month), yearLength == 2 || yearLength == 4 else { return false }
        guard yearEnd < s.count else { return true }
        return !isWordChar(s[yearEnd]) && !isDateSeparator(s[yearEnd])
    }

    /// The digit group ending just before `index` belongs to a date or time (`2024-01-15`,
    /// `10:30`): a separate token, so a card after it still starts a run of its own.
    private static func followsDate(_ s: [Unicode.Scalar], _ index: Int) -> Bool {
        var k = index - 1
        while k >= 0, isDigit(s[k]) { k -= 1 }
        guard k >= 1, isDateSeparator(s[k]), isDigit(s[k - 1]) else { return false }
        return s[k] != s[index]   // a dash before dash groups is the same run, not a date
    }

    /// 4-4-4-4 with an optional last group of 1–4 (13–19 digits), Amex 4-6-5, Diners 4-6-4.
    static func isCardLayout(_ sizes: [Int]) -> Bool {
        let total = sizes.reduce(0, +)
        guard sizes.count >= 2, (13...19).contains(total) else { return false }
        if sizes == [4, 6, 5] || sizes == [4, 6, 4] { return true }
        guard let last = sizes.last, (1...4).contains(last) else { return false }
        return sizes.dropLast().allSatisfy { $0 == 4 }
    }

    private static func digits(_ s: [Unicode.Scalar], _ from: Int, _ to: Int) -> [UInt8] {
        s[from..<to].compactMap { isDigit($0) ? UInt8($0.value - 0x30) : nil }
    }

    static func luhn(_ digits: [UInt8]) -> Bool {
        var sum = 0
        var alt = false
        for d in digits.reversed() {
            var n = Int(d)
            if alt {
                n *= 2
                if n > 9 { n -= 9 }
            }
            sum += n
            alt.toggle()
        }
        return sum % 10 == 0
    }
}
