import Foundation
import XCTest
@testable import PlatyNotchKit

final class ApprovalSafetyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Arming

    func testDecideBeforeArmTimeIgnored() {
        var arm = ApprovalArming()
        XCTAssertTrue(arm.noteVisible(["a"], at: t0))
        XCTAssertFalse(arm.isArmed("a", at: t0))
        XCTAssertFalse(arm.isArmed("a", at: t0.addingTimeInterval(0.69)))
        XCTAssertFalse(arm.attempt("a", at: t0.addingTimeInterval(0.3)))
        XCTAssertTrue(arm.showsLookFirst("a", at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(arm.isArmed("never-shown", at: t0.addingTimeInterval(100)), "a card never shown is never armed")
    }

    func testDecideAfterArmTimeAccepted() {
        var arm = ApprovalArming()
        arm.noteVisible(["a"], at: t0)
        XCTAssertTrue(arm.attempt("a", at: t0.addingTimeInterval(ApprovalArming.delay)))
        XCTAssertFalse(arm.showsLookFirst("a", at: t0.addingTimeInterval(ApprovalArming.delay)))
        XCTAssertFalse(arm.noteVisible(["a"], at: t0.addingTimeInterval(5)), "unchanged positions change nothing")
        XCTAssertTrue(arm.isArmed("a", at: t0.addingTimeInterval(5)))
    }

    func testArmResetsWhenAnotherApprovalMovesIntoFirstSlot() {
        var arm = ApprovalArming()
        arm.noteVisible(["a", "b"], at: t0)
        XCTAssertTrue(arm.isArmed("b", at: t0.addingTimeInterval(2)))
        // "a" answered: "b" slides into the first slot and must be looked at again.
        let t1 = t0.addingTimeInterval(2)
        XCTAssertTrue(arm.noteVisible(["b"], at: t1))
        XCTAssertFalse(arm.isArmed("b", at: t1.addingTimeInterval(0.1)))
        XCTAssertTrue(arm.isArmed("b", at: t1.addingTimeInterval(0.7)))
    }

    func testArmResetsWhenHiddenAndShownAgain() {
        var arm = ApprovalArming()
        arm.noteVisible(["a"], at: t0)
        arm.noteVisible([], at: t0.addingTimeInterval(1))
        XCTAssertFalse(arm.isArmed("a", at: t0.addingTimeInterval(1)))
        arm.noteVisible(["a"], at: t0.addingTimeInterval(2))
        XCTAssertFalse(arm.isArmed("a", at: t0.addingTimeInterval(2.5)))
        XCTAssertTrue(arm.isArmed("a", at: t0.addingTimeInterval(2.7)))
    }

    func testLookFirstFades() {
        var arm = ApprovalArming()
        arm.noteVisible(["a"], at: t0)
        arm.attempt("a", at: t0)
        XCTAssertTrue(arm.showsLookFirst("a", at: t0.addingTimeInterval(1)))
        XCTAssertFalse(arm.showsLookFirst("a", at: t0.addingTimeInterval(ApprovalArming.lookFirstDuration + 0.01)))
    }

    // MARK: Hidden characters

    func testPlainSummaryUnchanged() {
        let s = "cd \"/tmp/données/日本語\" && ls\n\tgrep -n 'x' *.swift"
        let v = SummarySanitizer.visible(s)
        XCTAssertEqual(v.text, s)
        XCTAssertFalse(v.hadHidden)
    }

    func testBidiAndInvisibleCharactersShown() {
        let v = SummarySanitizer.visible("rm -rf \u{202E}gnp.exe\u{202C} \u{2066}x\u{2069}\u{200B}\u{FEFF}")
        XCTAssertEqual(v.text, "rm -rf ⟨U+202E⟩gnp.exe⟨U+202C⟩ ⟨U+2066⟩x⟨U+2069⟩⟨U+200B⟩⟨U+FEFF⟩")
        XCTAssertTrue(v.hadHidden)
        for scalar in [0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202D, 0x2067, 0x2068] {
            let c = String(UnicodeScalar(scalar)!)
            XCTAssertEqual(SummarySanitizer.visible("a\(c)b").text,
                           "a⟨U+\(String(format: "%04X", scalar))⟩b")
        }
    }

    func testControlCharactersShownExceptNewlineAndTab() {
        let v = SummarySanitizer.visible("a\rb\u{0}c\u{7}d\u{7F}e\nf\tg")
        XCTAssertEqual(v.text, "a⟨U+000D⟩b⟨U+0000⟩c⟨U+0007⟩d⟨U+007F⟩e\nf\tg")
        XCTAssertTrue(v.hadHidden)
        XCTAssertEqual(SummarySanitizer.visible("a\r\nb").text, "a⟨U+000D⟩\nb", "CR of CRLF is shown, the newline kept")
    }

    func testANSIEscapesShown() {
        let v = SummarySanitizer.visible("echo \u{1B}[31mred\u{1B}[0m \u{1B}]0;title\u{07}")
        XCTAssertEqual(v.text, "echo ⟨ESC⟩[31mred⟨ESC⟩[0m ⟨ESC⟩]0;title⟨U+0007⟩")
        XCTAssertTrue(v.hadHidden)
    }

    func testFirstLineIsSanitizedAndClamped() {
        XCTAssertEqual(ApprovalFormat.firstLine("git status\nmore"), "git status")
        XCTAssertEqual(ApprovalFormat.firstLine("\u{202E}x\ny"), "⟨U+202E⟩x")
        XCTAssertEqual(ApprovalFormat.firstLine(""), "")
        XCTAssertEqual(ApprovalFormat.firstLine("a\nb", lineCountSuffix: true), "a … (+1 line)")
        XCTAssertEqual(ApprovalFormat.firstLine("a\nb\nc", lineCountSuffix: true), "a … (+2 lines)")
    }
}
