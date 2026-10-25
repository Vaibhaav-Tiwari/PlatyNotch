import Foundation
import XCTest
@testable import PlatyNotchKit

/// Task 17: what an approval card previews, built only from what the hook payload carries.
final class ApprovalPreviewTests: DefaultsTestCase {
    private func approval(_ tool: String, _ input: [String: JSONValue]?) -> Approval {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        return Approval(id: "ap", sessionKey: "s", agent: "claude-code", agentName: "Claude Code", tool: tool,
                        summary: "summary", input: input.map { RawJSON(.object($0)) }, createdAt: t,
                        expiresAt: t.addingTimeInterval(60))
    }

    func testEditMakesUnifiedDiff() {
        let p = ApprovalPreview(approval: approval("Edit", ["file_path": .string("/r/a.txt"),
                                                            "old_string": .string("a\nb\nc"),
                                                            "new_string": .string("a\nB\nc")]))
        XCTAssertEqual(p.path, "/r/a.txt")
        XCTAssertNil(p.command)
        XCTAssertEqual(p.diff, [DiffLine(kind: .hunk, text: "@@ -1,3 +1,3 @@"), DiffLine(kind: .context, text: "a"),
                                DiffLine(kind: .removed, text: "b"), DiffLine(kind: .added, text: "B"),
                                DiffLine(kind: .context, text: "c")])
        XCTAssertFalse(p.hasMore)
    }

    func testContextIsThreeLinesAndFarChangesSplit() {
        let old = (1...20).map { "l\($0)" }
        var new = old
        new[1] = "X2"
        new[17] = "X18"
        let d = LineDiff.unified(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        XCTAssertEqual(d.filter { $0.kind == .hunk }.map(\.text), ["@@ -1,5 +1,5 @@", "@@ -15,6 +15,6 @@"])
        XCTAssertEqual(LineDiff.unified(old: "same", new: "same"), [])
    }

    func testCollapsedToTwelve() {
        let content = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let p = ApprovalPreview(approval: approval("Write", ["file_path": .string("/r/new.txt"),
                                                             "content": .string(content)]))
        XCTAssertEqual(p.diff.first, DiffLine(kind: .hunk, text: "@@ -0,0 +1,40 @@"))
        XCTAssertTrue(p.diff.dropFirst().allSatisfy { $0.kind == .added })
        XCTAssertEqual(p.lines(expanded: false).count, ApprovalPreview.collapsedLines)
        XCTAssertEqual(p.lines(expanded: false).count, 12)
        XCTAssertTrue(p.hasMore)
        XCTAssertEqual(p.lines(expanded: true).count, 41)
    }

    func testMultiEdit() {
        let edits: JSONValue = .array([
            .object(["old_string": .string("one"), "new_string": .string("ONE")]),
            .object(["old_string": .string("x\ny"), "new_string": .string("x\nz")]),
        ])
        let p = ApprovalPreview(approval: approval("MultiEdit", ["file_path": .string("/r/m.swift"), "edits": edits]))
        XCTAssertEqual(p.diff.filter { $0.kind == .hunk }.count, 2, "one hunk group per edit")
        XCTAssertEqual(p.diff.filter { $0.kind == .added }.map(\.text), ["ONE", "z"])
        XCTAssertEqual(p.diff.filter { $0.kind == .removed }.map(\.text), ["one", "y"])
    }

    func testNotebookEditIsAllAdded() {
        let p = ApprovalPreview(approval: approval("NotebookEdit", ["notebook_path": .string("/r/n.ipynb"),
                                                                    "new_source": .string("print(1)\nprint(2)")]))
        XCTAssertEqual(p.path, "/r/n.ipynb")
        XCTAssertEqual(p.diff.map(\.kind), [.hunk, .added, .added])
    }

    func testBashHasCommandNoDiff() {
        let p = ApprovalPreview(approval: approval("Bash", ["command": .string("git status &&\nmake test")]))
        XCTAssertEqual(p.command, "git status &&\nmake test", "newlines kept: the full command")
        XCTAssertNil(p.path)
        XCTAssertEqual(p.diff, [])
        XCTAssertFalse(p.hasMore)
    }

    func testHiddenCharactersStayVisible() {
        let p = ApprovalPreview(approval: approval("Edit", ["file_path": .string("/r/a\u{202E}txt"),
                                                            "old_string": .string("x"),
                                                            "new_string": .string("x\u{200B}\u{1B}[2J")]))
        XCTAssertTrue(p.hadHidden)
        XCTAssertEqual(p.path, "/r/a⟨U+202E⟩txt")
        XCTAssertEqual(p.diff.filter { $0.kind == .added }.map(\.text), ["x⟨U+200B⟩⟨ESC⟩[2J"])
        let bash = ApprovalPreview(approval: approval("Bash", ["command": .string("ls\u{2066}")]))
        XCTAssertEqual(bash.command, "ls⟨U+2066⟩")
        XCTAssertTrue(bash.hadHidden)
        XCTAssertFalse(ApprovalPreview(approval: approval("Bash", ["command": .string("ls")])).hadHidden)
    }

    func testHugeInputUsesFallback() {
        XCTAssertTrue(LineDiff.usesFallback(oldLines: 2000, newLines: 2000))
        XCTAssertFalse(LineDiff.usesFallback(oldLines: 500, newLines: 500))
        let old = (0..<2000).map { "o\($0)" }.joined(separator: "\n")
        let new = (0..<2000).map { "n\($0)" }.joined(separator: "\n")
        let d = LineDiff.unified(old: old, new: new)
        XCTAssertEqual(d.count, 4001)
        XCTAssertEqual(d.filter { $0.kind == .hunk }.map(\.text), ["@@ -1,2000 +1,2000 @@"])
        XCTAssertEqual(d.filter { $0.kind == .removed }.count, 2000)
        XCTAssertEqual(d.filter { $0.kind == .added }.count, 2000)
    }

    func testBoxLines() {
        XCTAssertEqual(ApprovalPreview.boxLines(diffCount: 40, cards: 1), 8)
        XCTAssertEqual(ApprovalPreview.boxLines(diffCount: 40, cards: 3), 4)
        XCTAssertEqual(ApprovalPreview.boxLines(diffCount: 3, cards: 1), 3)
        XCTAssertEqual(ApprovalPreview.boxLines(diffCount: 0, cards: 2), 0)
    }

    func testNoInputMeansSummaryOnly() {
        let p = ApprovalPreview(approval: approval("WebFetch", nil))
        XCTAssertNil(p.command)
        XCTAssertNil(p.path)
        XCTAssertEqual(p.diff, [])
        XCTAssertFalse(p.hadHidden)
        // Strings of the wrong type are ignored, never guessed at.
        let odd = ApprovalPreview(approval: approval("Edit", ["file_path": .int(3), "old_string": .string("a")]))
        XCTAssertNil(odd.path)
        XCTAssertEqual(odd.diff, [])
    }
}
