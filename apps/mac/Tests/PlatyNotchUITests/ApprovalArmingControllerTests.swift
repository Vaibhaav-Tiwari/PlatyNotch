import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Final review A1b: every path that moves an approval card between the peek and the
/// open panel, or pushes it down under the "N approvals waiting" header, re-arms it.
/// No window: the controller runs with a layout only; the cursor is pinned.
@MainActor
final class ApprovalArmingControllerTests: XCTestCase {
    private let mbpLayout = PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                                        auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                                        auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))

    private func approval(_ id: String, age: TimeInterval) -> Approval {
        let created = Date().addingTimeInterval(-age)
        return Approval(id: id, sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                        project: nil, cwd: nil, tool: "Bash", summary: "ls",
                        createdAt: created, expiresAt: created.addingTimeInterval(600))
    }

    /// The arming clock: every card noted "now" was first shown at `start`.
    private var now = Date()

    private func controller(approvals: [Approval]) throws -> NotchController {
        let store = AppStore()
        store.apply(.connected)
        for a in approvals { store.apply(try Envelope.make(.approvalAdded, a)) }
        let c = NotchController(store: store, client: CoreClient(socketPath: "/nonexistent"), plugins: [])
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        c.armingClock = { [unowned self] in self.now }
        c.debugHandle(.layout(mbpLayout))
        c.debugHandle(.event(.approvalsChanged(count: approvals.count)))
        return c
    }

    /// Lets 5 s pass on the arming clock, then: is the card armed?
    private func armedLongAgo(_ c: NotchController, _ id: String) -> Bool {
        now = now.addingTimeInterval(5)
        return c.arming.isArmed(id, at: now)
    }

    /// Is the card armed right now (0.1 s later on the arming clock)?
    private func armedJustNow(_ c: NotchController, _ id: String) -> Bool {
        c.arming.isArmed(id, at: now.addingTimeInterval(0.1))
    }

    func testClickFromPeekToPanelRearms() throws {
        let c = try controller(approvals: [approval("a", age: 10)])
        XCTAssertEqual(c.mode, .peek(.approval))
        XCTAssertTrue(armedLongAgo(c, "a"))
        c.debugHandle(.event(.click))
        XCTAssertEqual(c.mode, .expanded)
        XCTAssertFalse(armedJustNow(c, "a"), "the card moved from the peek into the open panel")
        XCTAssertTrue(armedLongAgo(c, "a"))
        c.debugHandle(.event(.click))
        XCTAssertEqual(c.mode, .peek(.approval))
        XCTAssertFalse(armedJustNow(c, "a"), "and back into the peek")
    }

    /// Menu bar "Open PlatyNotch" and platynotch://open both call `expand(tab: nil)`.
    func testMenuOpenAndURLOpenRearm() throws {
        let c = try controller(approvals: [approval("a", age: 10)])
        XCTAssertTrue(armedLongAgo(c, "a"))
        c.expand()
        XCTAssertEqual(c.mode, .expanded)
        XCTAssertFalse(armedJustNow(c, "a"))
    }

    func testExpandToTabRearms() throws {
        let c = try controller(approvals: [approval("a", age: 10)])
        XCTAssertTrue(armedLongAgo(c, "a"))
        c.expand(tab: BuiltinTab.today)
        XCTAssertEqual(c.mode, .expanded)
        XCTAssertFalse(armedJustNow(c, "a"))
    }

    /// A second approval while the panel is open adds the "2 approvals waiting" header
    /// above the list (and shortens the cards): the first card moved, so it re-arms.
    func testHeaderPushRearms() throws {
        let c = try controller(approvals: [approval("a", age: 10)])
        c.expand()
        XCTAssertTrue(armedLongAgo(c, "a"))
        c.store.apply(try Envelope.make(.approvalAdded, approval("b", age: 1)))
        c.debugHandle(.event(.approvalsChanged(count: 2)))
        XCTAssertFalse(armedJustNow(c, "a"), "the header pushed the oldest card down")
        XCTAssertFalse(armedJustNow(c, "b"))
    }

    /// A1 end to end: the open panel, a drag over it, an approval arrives, the drop lands:
    /// the approval stays a peek (and its arming is the peek's).
    func testDropDuringNewApprovalKeepsPeek() throws {
        let c = try controller(approvals: [])
        c.debugHandle(.event(.click))
        c.debugHandle(.event(.dragBegan))
        c.store.apply(try Envelope.make(.approvalAdded, approval("a", age: 0)))
        c.debugHandle(.event(.approvalsChanged(count: 1)))
        c.debugHandle(.event(.dragEndedInside))
        XCTAssertEqual(c.mode, .peek(.approval))
        XCTAssertFalse(armedJustNow(c, "a"))
        XCTAssertTrue(armedLongAgo(c, "a"), "a peek left alone arms as usual")
    }
}
