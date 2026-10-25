import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Task 19: the open panel's approval cards show the full command, the path and a diff
/// box of fixed height; the peek keeps its summary and gains only "Show changes".
@MainActor
final class ApprovalPreviewCardTests: DefaultsTestCase {
    private let t0 = Date()

    private func approval(_ tool: String, _ input: [String: JSONValue]?, id: String = "ap") -> Approval {
        Approval(id: id, sessionKey: "s", agent: "claude-code", agentName: "Claude Code", project: "platynotch",
                 tool: tool, summary: "Write notes.txt", input: input.map { RawJSON(.object($0)) }, createdAt: t0,
                 expiresAt: t0.addingTimeInterval(300))
    }

    private func write(lines: Int) -> Approval {
        let content = (1...lines).map { "line \($0)" }.joined(separator: "\n")
        return approval("Write", ["file_path": .string("/r/notes.txt"), "content": .string(content)])
    }

    private func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 496).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark).environment(\.panelTicking, false))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func card(_ a: Approval, cards: Int = 1, expanded: Bool = false) -> ApprovalCard {
        ApprovalCard(approval: a, session: nil, canAnswer: true, phase: nil, arming: ApprovalArming(),
                     preview: ApprovalPreview(approval: a), cards: cards, diffExpanded: expanded,
                     onDecide: { _ in }, onOpenTerminal: { _ in })
    }

    func testShowAllNeverChangesCardHeight() {
        let big = write(lines: 300)
        let twelve = write(lines: 11)   // 11 lines + the hunk line = 12 diff lines
        XCTAssertEqual(ApprovalPreview(approval: twelve).diff.count, 12)
        let collapsed = height(card(big))
        let expanded = height(card(big, expanded: true))
        let small = height(card(twelve))
        XCTAssertGreaterThan(collapsed, 0)
        XCTAssertEqual(collapsed, expanded, "Show all never changes the card's height")
        XCTAssertEqual(collapsed, small)
        let box = height(ApprovalDiffBox(preview: ApprovalPreview(approval: big), cards: 1))
        XCTAssertEqual(height(ApprovalDiffBox(preview: ApprovalPreview(approval: big), cards: 1, expanded: true)), box)
        XCTAssertEqual(ApprovalDiffBox.boxHeight(preview: ApprovalPreview(approval: big), cards: 1),
                       8 * Theme.monoLineHeight)
        XCTAssertEqual(ApprovalDiffBox.boxHeight(preview: ApprovalPreview(approval: big), cards: 3),
                       4 * Theme.monoLineHeight)
        // A short diff takes only its lines.
        XCTAssertEqual(ApprovalDiffBox.boxHeight(preview: ApprovalPreview(approval: write(lines: 2)), cards: 1),
                       3 * Theme.monoLineHeight)
        // Several cards: shorter boxes, still fixed.
        XCTAssertEqual(height(card(big, cards: 3)), height(card(big, cards: 3, expanded: true)))
        XCTAssertLessThan(height(card(big, cards: 3)), collapsed)
    }

    func testNoPreviewInPeek() throws {
        let store = AppStore()
        store.apply(.connected)
        try store.apply(Envelope.make(.approvalAdded, write(lines: 40)))
        let peek = ApprovalPeek(store: store, responder: ApprovalResponder(client: CoreClient(socketPath: "/nonexistent")),
                                arming: ApprovalArming(), onExpand: {}, onDecide: { _, _ in }, onOpenTerminal: { _ in })
        let first = try XCTUnwrap(peek.firstCard())
        XCTAssertNil(first.preview, "the peek keeps today's summary")
        XCTAssertEqual(first.maxLines, 6)
        XCTAssertTrue(first.showChanges)
    }

    func testShowChangesOnlyWithDiff() throws {
        XCTAssertTrue(ApprovalPeek.showsChanges(write(lines: 3)))
        XCTAssertFalse(ApprovalPeek.showsChanges(approval("Bash", ["command": .string("ls")])))
        XCTAssertFalse(ApprovalPeek.showsChanges(approval("WebFetch", nil)))
        let store = AppStore()
        store.apply(.connected)
        try store.apply(Envelope.make(.approvalAdded, approval("Bash", ["command": .string("ls")])))
        var expanded = 0
        let peek = ApprovalPeek(store: store, responder: ApprovalResponder(client: CoreClient(socketPath: "/nonexistent")),
                                arming: ApprovalArming(), onExpand: { expanded += 1 }, onDecide: { _, _ in },
                                onOpenTerminal: { _ in })
        let card = try XCTUnwrap(peek.firstCard())
        XCTAssertFalse(card.showChanges)
        card.onExpand?()
        XCTAssertEqual(expanded, 1, "the link and More open the panel")
    }

    func testDiffSignsNotColourOnly() {
        XCTAssertEqual(ApprovalDiffBox.sign(.added), "+")
        XCTAssertEqual(ApprovalDiffBox.sign(.removed), "\u{2212}")
        XCTAssertEqual(ApprovalDiffBox.sign(.context), " ")
        XCTAssertEqual(ApprovalDiffBox.sign(.hunk), "")
        XCTAssertEqual(ApprovalDiffBox.text(DiffLine(kind: .removed, text: "b")), "\u{2212}b")
        XCTAssertEqual(ApprovalDiffBox.text(DiffLine(kind: .added, text: "x\u{200B}")), "+x\u{200B}")
        XCTAssertEqual(ApprovalDiffBox.tone(.added), .done)
        XCTAssertEqual(ApprovalDiffBox.tone(.removed), .error)
        XCTAssertNil(ApprovalDiffBox.tone(.context))
    }

    /// The card shows the payload's full command (not a shortened summary) and its path.
    func testCardShowsCommandAndPath() {
        let bash = approval("Bash", ["command": .string("git status &&\nmake test\u{200B}")])
        let c = card(bash)
        XCTAssertEqual(c.summaryText, "git status &&\nmake test⟨U+200B⟩")
        XCTAssertTrue(c.hasHidden)
        let plain = ApprovalCard(approval: bash, session: nil, canAnswer: true, phase: nil, arming: ApprovalArming(),
                                 onDecide: { _ in }, onOpenTerminal: { _ in })
        XCTAssertEqual(plain.summaryText, "Write notes.txt", "no preview: today's summary")
        XCTAssertEqual(card(write(lines: 2)).preview?.path, "/r/notes.txt")
    }
}
