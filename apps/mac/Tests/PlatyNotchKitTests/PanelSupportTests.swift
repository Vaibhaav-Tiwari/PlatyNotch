import Foundation
import XCTest
@testable import PlatyNotchKit

final class PanelSupportTests: XCTestCase {
    func testModeDescription() {
        XCTAssertEqual(PanelMode.hidden.description, "hidden")
        XCTAssertEqual(PanelMode.compact.description, "compact")
        XCTAssertEqual(PanelMode.peek(.approval).description, "peek(approval)")
        XCTAssertEqual(PanelMode.peek(.notice).description, "peek(notice)")
        XCTAssertEqual(PanelMode.expanded.description, "expanded")
    }

    func testCanBecomeKeyOnlyExpandedOrApproval() {
        XCTAssertTrue(PanelMode.expanded.canBecomeKey)
        XCTAssertTrue(PanelMode.peek(.approval).canBecomeKey)
        XCTAssertFalse(PanelMode.peek(.notice).canBecomeKey)
        XCTAssertFalse(PanelMode.compact.canBecomeKey)
        XCTAssertFalse(PanelMode.hidden.canBecomeKey)
    }

    func testShadowOnlyWhenOpen() {
        XCTAssertFalse(PanelMode.hidden.hasShadow)
        XCTAssertFalse(PanelMode.compact.hasShadow)
        XCTAssertTrue(PanelMode.expanded.hasShadow)
        XCTAssertTrue(PanelMode.peek(.notice).hasShadow)
    }

    func testHasLiveSessions() {
        func s(_ st: SessionState) -> Session {
            Session(key: "k", agent: "claude-code", agentName: "Claude Code", sessionID: "1", state: st,
                    startedAt: Date(), updatedAt: Date())
        }
        XCTAssertFalse(PanelMode.hasLive(sessions: []))
        XCTAssertFalse(PanelMode.hasLive(sessions: [s(.idle), s(.waitingInput), s(.exited)]))
        XCTAssertTrue(PanelMode.hasLive(sessions: [s(.idle), s(.active)]))
        XCTAssertTrue(PanelMode.hasLive(sessions: [s(.blocked)]))
    }
}
