import Foundation

/// Obvious secrets in copied text, with the same patterns as Memory's redaction
/// (`core/memory/ingest/redact.go`): private key blocks, JWTs, `sk-` API keys, AWS
/// access key ids, GitHub tokens (`gh?_`, `github_pat_`), Slack tokens (`xox?-`), Google
/// API keys (`AIza`) and Luhn-valid 13–19 digit card numbers. Clipboard history skips
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

    /// Separators allowed between digit groups of a card number, 1 or 2 of them: space,
    /// tab, NBSP, figure space, narrow NBSP, dash (Go `cardRun`).
    static func isCardSeparator(_ v: UInt32) -> Bool {
        v == 0x20 || v == 0x09 || v == 0xA0 || v == 0x2007 || v == 0x202F || v == 0x2D
    }

    /// Luhn-valid 13–19 digit card numbers. Digit groups joined by 1–2 separators form a
    /// run; every window of whole groups in a run is a candidate (Go `redactCards`).
    static func containsCard(_ text: String) -> Bool {
        var groups: [[UInt8]] = []
        var current: [UInt8] = []
        var gap = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0x30, v <= 0x39 {
                if current.isEmpty, !groups.isEmpty, gap == 0 || gap > 2 {
                    // Not joined to the previous group: check the finished run.
                    if runHasCard(groups) { return true }
                    groups = []
                }
                current.append(UInt8(v - 0x30))
                gap = 0
            } else if !current.isEmpty || !groups.isEmpty {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                gap = isCardSeparator(v) ? gap + 1 : 3   // 3: anything else ends the run
            }
        }
        if !current.isEmpty { groups.append(current) }
        return runHasCard(groups)
    }

    private static func runHasCard(_ groups: [[UInt8]]) -> Bool {
        for i in groups.indices {
            var digits: [UInt8] = []
            for j in i..<groups.count {
                digits += groups[j]
                if digits.count > 19 { break }
                if digits.count >= 13, luhn(digits) { return true }
            }
        }
        return false
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
