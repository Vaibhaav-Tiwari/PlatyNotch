import Foundation
@testable import PlatyNotchKit
import XCTest

/// Final review B3: clipboard history skips text holding an obvious secret. The table
/// mirrors `core/memory/ingest/ingest_test.go` `TestRedact` (every string Go redacts is a
/// secret here; every string Go keeps is not), plus one row per remaining pattern.
final class SecretTextTests: XCTestCase {
    func testGoRedactTableIsSecret() {
        let secrets = [
            "card 4242 4242 4242 4242 end",
            "card 4242-4242-4242-4242 end",
            "card 4242424242424242 end",
            "key sk-abcdefghijklmnopqrstuvwx1234 ok",
            "aws AKIAIOSFODNN7EXAMPLE ok",
            "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc_DEF-123 ok",
            "a\n-----BEGIN RSA PRIVATE KEY-----\nMIIE\nabc\n-----END RSA PRIVATE KEY-----\nb",
            "-----BEGIN PRIVATE KEY-----\ntruncated",
            "on 2024-01-15 4242 4242 4242 4242 paid",
            "order 123 4242424242424242",
            "4242 4242 4242 4242 12/27",
        ]
        for s in secrets { XCTAssertTrue(SecretText.containsSecret(s), s) }
    }

    /// Round 2: the skip rule is stricter than Go's redaction. A redaction that also catches
    /// part of a longer number costs a few characters; a skip loses the whole copy, so these
    /// (which Go redacts a window of) are kept.
    func testStricterThanGoRedaction() {
        for s in ["x 1398 8333 3494 9149 9432 0603 y",   // 24 digits in groups: longer than a card
                  "4242  4242  4242  4242"] {             // two separators between groups
            XCTAssertFalse(SecretText.containsSecret(s), s)
        }
    }

    func testGoKeepTableIsNotSecret() {
        for s in ["num 1234567890123456 x", "short sk-abc", "phone 555-1234", "id 12345678901234567890123"] {
            XCTAssertFalse(SecretText.containsSecret(s), s)
        }
    }

    func testRemainingPatterns() {
        let rows: [(String, Bool)] = [
            ("ghp_" + String(repeating: "a", count: 36), true),
            ("gho_" + String(repeating: "B", count: 40), true),
            ("ghp_" + String(repeating: "a", count: 35), false),
            ("github_pat_" + String(repeating: "x", count: 50), true),
            ("github_pat_short", false),
            ("token xoxb-1234567890-abcdef", true),
            ("xoxq-1234567890", false),
            ("AIza" + String(repeating: "Z", count: 35), true),
            ("AIza" + String(repeating: "Z", count: 34), false),
            ("-----BEGIN OPENSSH PRIVATE KEY-----", true),
            ("-----BEGIN PUBLIC KEY-----", false),
            ("eyJhbGciOiJIUzI1NiJ9 alone", false),
            ("4242\u{00A0}4242\u{00A0}4242\u{00A0}4242", true),    // NBSP throughout
            ("4242\u{00A0}4242\u{2007}4242\u{202F}4242", false),   // mixed separators
            ("4242 - 4242 - 4242 - 4242", false),   // three separators between groups
            ("4242 4242 4242 4242", true),          // one space
            ("4242424242424241", false),            // Luhn fails
            ("", false),
            ("Meeting at 10:30 in room 4242, call 555 0100", false),
        ]
        for (s, want) in rows { XCTAssertEqual(SecretText.containsSecret(s), want, s) }
    }

    /// Round 2: the reviewer's false positives are kept; real card formats are skipped.
    func testReviewCasesAndCardFormats() {
        let keep = [
            "12\t4242\t4242\t4242\t4242\t7",           // tab-separated cells
            "2024-01-15 2024-03-02",
            "2024-01-15 2024-03-02 2024-07-31",
            "1998-04-12\t2001-11-30\t2015-06-01",
            "commit 4242424242424242a1b2c3d4e5f60718293a4b5c",   // git SHA with a digit run
            "4b3a2c1d-4242-4242-4242-424242424242",   // UUID
            "Order 1234567890123456",                   // not Luhn-valid
            "id 12345678901234567890123",               // 23 digits
            "4242 4242 4242 4242 4242 4242",            // longer than a card
            "4242-4242 4242-4242",                      // mixed separators
            "v4242424242424242",                        // part of a word
            "10:4242424242424242",                      // time-like
            "2024.4242424242424242",                    // date-like
        ]
        for s in keep { XCTAssertFalse(SecretText.containsSecret(s), s) }
        let skip = [
            "4242 4242 4242 4242", "4242-4242-4242-4242", "4242424242424242",
            "3782 822463 10005", "378282246310005",      // Amex 4-6-5 and contiguous
            "3056 930902 5904",                          // Diners 4-6-4
            "4222 2222 2222 2",                          // 13-digit Visa 4-4-4-1
            "on 2024-01-15 4242 4242 4242 4242 paid",    // after a date
            "4242 4242 4242 4242 12/27",                 // with an expiry
            "card: 4242-4242-4242-4242.",
        ]
        for s in skip { XCTAssertTrue(SecretText.containsSecret(s), s) }
    }

    func testLuhn() {
        XCTAssertTrue(SecretText.luhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2]))
        XCTAssertFalse(SecretText.luhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 1]))
    }
}
