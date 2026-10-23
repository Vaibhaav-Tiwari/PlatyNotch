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
        XCTAssertFalse(arm.attempt("a", slot: 0, at: t0.addingTimeInterval(0.3)))
        XCTAssertTrue(arm.showsLookFirst("a", at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(arm.isArmed("never-shown", at: t0.addingTimeInterval(100)), "a card never shown is never armed")
    }

    func testDecideAfterArmTimeAccepted() {
        var arm = ApprovalArming()
        arm.noteVisible(["a"], at: t0)
        XCTAssertTrue(arm.attempt("a", slot: 0, at: t0.addingTimeInterval(ApprovalArming.delay)))
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
        arm.attempt("a", slot: 0, at: t0)
        XCTAssertTrue(arm.showsLookFirst("a", at: t0.addingTimeInterval(1)))
        XCTAssertFalse(arm.showsLookFirst("a", at: t0.addingTimeInterval(ApprovalArming.lookFirstDuration + 0.01)))
    }

    func testDecideRechecksSlotAtDecideTime() {
        var arm = ApprovalArming()
        arm.noteVisible(["a", "b"], at: t0)
        let later = t0.addingTimeInterval(5)
        XCTAssertTrue(arm.attempt("b", slot: 1, at: later))
        // "a" was resolved but the view has not re-noted positions yet: "b" now sits in
        // slot 0, which is not where it was armed, so the answer is refused.
        XCTAssertFalse(arm.attempt("b", slot: 0, at: later))
        XCTAssertTrue(arm.showsLookFirst("b", at: later))
        XCTAssertFalse(arm.attempt("b", slot: nil, at: later), "an approval no longer pending is never answered")
    }

    // MARK: Hidden characters

    func testTagCharactersAndFormatCategoryShown() {
        // "hi" spelled in Unicode tag characters (invisible), plus U+E007F CANCEL TAG.
        let v = SummarySanitizer.visible("ls\u{E0068}\u{E0069}\u{E007F}")
        XCTAssertEqual(v.text, "ls⟨U+E0068⟩⟨U+E0069⟩⟨U+E007F⟩")
        XCTAssertTrue(v.hadHidden)
        for scalar: UInt32 in [0x061C, 0x2060, 0x2061, 0x2064, 0x00AD, 0x180E, 0xFE00, 0xFE0F, 0xE0100, 0xE01EF] {
            let c = String(UnicodeScalar(scalar)!)
            XCTAssertEqual(SummarySanitizer.visible("a\(c)b").text, "a⟨U+\(String(format: "%04X", scalar))⟩b",
                           String(format: "U+%04X", scalar))
        }
    }

    func testLineAndParagraphSeparatorsShown() {
        let v = SummarySanitizer.visible("echo safe\u{2028}rm -rf ~\u{2029}")
        XCTAssertEqual(v.text, "echo safe⟨U+2028⟩rm -rf ~⟨U+2029⟩")
        XCTAssertTrue(v.hadHidden)
        XCTAssertEqual(ApprovalFormat.lineCount(v.text), 1)
    }

    func testSingleLineFormMarksNewlinesAndTabs() {
        XCTAssertEqual(SummarySanitizer.visible("a\nb\tc", singleLine: true).text, "a⟨U+000A⟩b⟨U+0009⟩c")
        XCTAssertTrue(SummarySanitizer.visible("a\nb", singleLine: true).hadHidden)
        XCTAssertEqual(SummarySanitizer.visible("a\nb").text, "a\nb")
    }

    func testVisibleApprovalSanitizesHeaderFields() {
        let clean = Approval(id: "1", sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                             project: "données", cwd: "/tmp/日本語", tool: "Bash", summary: "ls",
                             createdAt: t0, expiresAt: t0.addingTimeInterval(100))
        let v = VisibleApproval(clean)
        XCTAssertEqual(v.agentName, "Claude Code")
        XCTAssertEqual(v.project, "données")
        XCTAssertEqual(v.cwd, "/tmp/日本語")
        XCTAssertEqual(v.tool, "Bash")
        XCTAssertEqual(v.summary, "ls")
        XCTAssertFalse(v.hadHidden)

        var dirty = clean
        dirty.agentName = "Claude\u{202E}edoC"
        dirty.tool = "Bash\nRead"
        dirty.project = "p\u{200B}"
        dirty.cwd = "/tmp/\u{E0041}"
        let d = VisibleApproval(dirty)
        XCTAssertEqual(d.agentName, "Claude⟨U+202E⟩edoC")
        XCTAssertEqual(d.tool, "Bash⟨U+000A⟩Read")
        XCTAssertEqual(d.project, "p⟨U+200B⟩")
        XCTAssertEqual(d.cwd, "/tmp/⟨U+E0041⟩")
        XCTAssertEqual(d.summary, "ls")
        XCTAssertTrue(d.hadHidden, "a hidden character in any header field sets the warning")

        var onlyCwd = clean
        onlyCwd.cwd = "/tmp/\u{FEFF}"
        XCTAssertTrue(VisibleApproval(onlyCwd).hadHidden)
        var noProject = clean
        noProject.project = nil
        noProject.cwd = nil
        XCTAssertNil(VisibleApproval(noProject).project)
        XCTAssertNil(VisibleApproval(noProject).cwd)
    }

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

    func testFirstLineShowsHiddenSeparatorsInsteadOfSplittingOnThem() {
        // U+2028 and CR must not hide what follows; ESC and zero-width are marked.
        XCTAssertEqual(ApprovalFormat.firstLine("ls\u{2028}rm -rf ~"), "ls⟨U+2028⟩rm -rf ~")
        XCTAssertEqual(ApprovalFormat.firstLine("ls\rrm -rf ~\nnext"), "ls⟨U+000D⟩rm -rf ~")
        XCTAssertEqual(ApprovalFormat.firstLine("\u{1B}[2Kok\u{200B}\r\nnext", lineCountSuffix: true),
                       "⟨ESC⟩[2Kok⟨U+200B⟩⟨U+000D⟩ … (+1 line)")
        XCTAssertEqual(ApprovalFormat.firstLine("a\tb\u{85}c"), "a\tb⟨U+0085⟩c")
    }
}
