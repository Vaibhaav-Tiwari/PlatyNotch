import Foundation
import XCTest
@testable import PlatyNotchKit

final class MarkdownTasksTests: DefaultsTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testParsesVariants() {
        let md = """
        # Today
        - [ ] dash open
        * [ ] star open
        + [ ] plus open
        - [x] done lower
        - [X] done upper
        1. [ ] ordered
        2) [ ] ordered paren
        \t- [ ] tab indented
            - [ ] space indented
        > - [ ] in a callout
        - [/] in progress is not a task
        - [-] cancelled is not a task
        - [ ]
        - [ ]no space after box
        -[ ] no space after dash
        [ ] no marker
        - plain item
        """
        let tasks = MarkdownTasks.parse(md, file: "a.md", calendar: utc)
        XCTAssertEqual(tasks.map(\.text), ["dash open", "star open", "plus open", "done lower", "done upper",
                                           "ordered", "ordered paren", "tab indented", "space indented",
                                           "in a callout"])
        XCTAssertEqual(tasks.map(\.line), [2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(tasks.map(\.done), [false, false, false, true, true, false, false, false, false, false])
        XCTAssertEqual(tasks[0].raw, "- [ ] dash open")
        XCTAssertEqual(tasks[8].raw, "    - [ ] space indented")
        XCTAssertTrue(tasks.allSatisfy { $0.file == "a.md" })
    }

    func testToggleOnlyThatLine() {
        let md = "- [ ] one\n- [ ] two\n- [ ] one\n"
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 2), "- [ ] one\n- [x] two\n- [ ] one\n")
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 3), "- [ ] one\n- [ ] two\n- [x] one\n")
        // Back again.
        XCTAssertEqual(MarkdownTasks.toggle("- [x] one\n", line: 1), "- [ ] one\n")
        // Not a task, out of range: unchanged.
        XCTAssertEqual(MarkdownTasks.toggle("text\n- [ ] a", line: 1), "text\n- [ ] a")
        XCTAssertEqual(MarkdownTasks.toggle("- [ ] a", line: 0), "- [ ] a")
        XCTAssertEqual(MarkdownTasks.toggle("- [ ] a", line: 5), "- [ ] a")
    }

    func testToggleUpperXUnticks() {
        XCTAssertEqual(MarkdownTasks.toggle("- [X] shout\n", line: 1), "- [ ] shout\n")
    }

    func testDueDateEmoji() {
        let md = """
        - [ ] pay rent 📅 2026-10-30
        - [ ] calendar variant 📆 2026-11-01 #home
        - [ ] spiral 🗓️ 2026-11-02
        - [ ] no space 📅2026-11-03
        - [ ] impossible 📅 2026-02-31
        - [ ] none
        """
        let tasks = MarkdownTasks.parse(md, file: "x.md", calendar: utc)
        XCTAssertEqual(tasks.map(\.due), [day(2026, 10, 30), day(2026, 11, 1), day(2026, 11, 2), day(2026, 11, 3), nil, nil])
        XCTAssertEqual(tasks[0].title, "pay rent")
        XCTAssertEqual(tasks[1].title, "calendar variant #home")
        XCTAssertEqual(tasks[0].text, "pay rent 📅 2026-10-30")
    }

    func testIgnoresCodeBlocks() {
        let md = """
        - [ ] before
        ```markdown
        - [ ] in backticks
        ```
        ~~~~
        - [ ] in tildes
        ~~~
        - [ ] still in tildes (shorter fence does not close)
        ~~~~
          ```
          - [ ] in an indented fence
          ```
        - [ ] after
        """
        let tasks = MarkdownTasks.parse(md, file: "c.md")
        XCTAssertEqual(tasks.map(\.text), ["before", "after"])
        XCTAssertEqual(tasks.map(\.line), [1, 13])
        // A toggle aimed inside a code block changes nothing.
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 3), md)
    }

    func testUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(MarkdownTasks.parse("- [ ] a\n```\n- [ ] b\n", file: "f").map(\.text), ["a"])
    }

    func testFrontmatterIsSkipped() {
        let md = "---\ntags: [x]\nlist:\n- [ ] not a task\n---\n- [ ] real\n"
        let tasks = MarkdownTasks.parse(md, file: "f")
        XCTAssertEqual(tasks.map(\.text), ["real"])
        XCTAssertEqual(tasks.first?.line, 6)
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 4), md)
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 6), "---\ntags: [x]\nlist:\n- [ ] not a task\n---\n- [x] real\n")
        // `...` also closes; an unclosed block is no frontmatter.
        XCTAssertEqual(MarkdownTasks.parse("---\na: 1\n...\n- [ ] b", file: "f").map(\.line), [4])
        XCTAssertEqual(MarkdownTasks.parse("---\n- [ ] b", file: "f").map(\.line), [2])
    }

    func testCRLFAndLoneCRLineEndings() {
        let md = "a\r\n- [ ] one\r\n- [ ] two\r\n"
        let tasks = MarkdownTasks.parse(md, file: "f")
        XCTAssertEqual(tasks.map(\.line), [2, 3])
        XCTAssertEqual(tasks.map(\.raw), ["- [ ] one", "- [ ] two"])
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 3), "a\r\n- [ ] one\r\n- [x] two\r\n")
        let old = "- [ ] a\r- [ ] b\r"
        XCTAssertEqual(MarkdownTasks.parse(old, file: "f").map(\.line), [1, 2])
        XCTAssertEqual(MarkdownTasks.toggle(old, line: 2), "- [ ] a\r- [x] b\r")
        // Mixed endings stay as they were.
        let mixed = "- [ ] a\r\n- [ ] b\n- [ ] c\r"
        XCTAssertEqual(MarkdownTasks.toggle(mixed, line: 2), "- [ ] a\r\n- [x] b\n- [ ] c\r")
        XCTAssertEqual(MarkdownTasks.lineEnding(of: Array(md.utf8)), "\r\n")
        XCTAssertEqual(MarkdownTasks.lineEnding(of: Array("a\nb".utf8)), "\n")
    }

    func testBOMAndTrailingSpacesKept() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("- [ ] first  \n".utf8)
        let tasks = MarkdownTasks.parse(bytes: bytes, file: "f")
        XCTAssertEqual(tasks.map(\.text), ["first"])
        XCTAssertEqual(tasks.first?.raw, "- [ ] first  ")
        let out = MarkdownTasks.toggled(bytes: bytes, line: 1)
        XCTAssertEqual(out, [0xEF, 0xBB, 0xBF] + Array("- [x] first  \n".utf8))
    }

    func testIndentedTaskTogglesInPlace() {
        let md = "- [ ] parent\n    - [ ] child\n\t\t- [x] grandchild\n"
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 2), "- [ ] parent\n    - [x] child\n\t\t- [x] grandchild\n")
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 3), "- [ ] parent\n    - [ ] child\n\t\t- [ ] grandchild\n")
    }

    func testToggleChangesExactlyOneByte() {
        let md = "前 - [ ] not a task\n- [ ] 日本語 📅 2026-10-30\n"
        let before = Array(md.utf8)
        let after = MarkdownTasks.toggled(bytes: before, line: 2)!
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.count, 1)
    }

    func testSkipsObsidianComments() {
        let md = """
        - [ ] before
        %%
        - [ ] in a comment
        %%
        %% - [ ] inline comment %%
        - [ ] visible %% with a note %%
        %% opens here
        - [ ] still hidden
        closes here %%
        - [ ] after
        """
        let tasks = MarkdownTasks.parse(md, file: "c.md")
        XCTAssertEqual(tasks.map(\.text), ["before", "visible %% with a note %%", "after"])
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 3), md)
    }

    func testPercentsInCodeSpansAreNotComments() {
        let md = "- [ ] use `%%` for comments\n- [ ] second ``a %% b``\n- [ ] third\n- [ ] odd ` %% stays literal\n- [ ] hidden\n"
        // The 4th line's lone backtick is literal, so its %% opens a comment.
        XCTAssertEqual(MarkdownTasks.parse(md, file: "f").map(\.line), [1, 2, 3, 4])
    }

    func testRecurringTasksAreListedButNeverToggled() {
        let md = "- [ ] stretch 🔁 every day\n"
        let tasks = MarkdownTasks.parse(md, file: "r.md")
        XCTAssertEqual(tasks.first?.isRecurring, true)
        XCTAssertEqual(MarkdownTasks.toggle(md, line: 1), md)
    }

    func testNoteHashFollowsTheBytes() {
        let a = MarkdownTasks.parse("- [ ] a\n", file: "f")
        let b = MarkdownTasks.parse("- [ ] a\n", file: "f")
        let c = MarkdownTasks.parse("- [ ] a\n\n", file: "f")
        XCTAssertEqual(a.first?.noteHash, b.first?.noteHash)
        XCTAssertNotEqual(a.first?.noteHash, c.first?.noteHash)
        XCTAssertNotEqual(a.first?.noteHash, 0)
    }

    func testStripMarkers() {
        XCTAssertEqual(MarkdownTasks.stripMarkers("a ⏳ 2026-01-01 b ✅ 2026-01-02"), "a b")
        XCTAssertEqual(MarkdownTasks.stripMarkers("📅 2026-01-01"), "📅 2026-01-01")
    }
}
