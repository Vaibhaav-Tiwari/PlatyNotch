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
            "x 1398 8333 3494 9149 9432 0603 y",
            "4242 4242 4242 4242 12/27",
        ]
        for s in secrets { XCTAssertTrue(SecretText.containsSecret(s), s) }
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
            ("4242\u{00A0}4242\u{2007}4242\u{202F}4242", true),
            ("4242 - 4242 - 4242 - 4242", false),   // three separators between groups
            ("4242  4242  4242  4242", true),       // two
            ("4242424242424241", false),            // Luhn fails
            ("", false),
            ("Meeting at 10:30 in room 4242, call 555 0100", false),
        ]
        for (s, want) in rows { XCTAssertEqual(SecretText.containsSecret(s), want, s) }
    }

    func testLuhn() {
        XCTAssertTrue(SecretText.luhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2]))
        XCTAssertFalse(SecretText.luhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 1]))
    }
}
