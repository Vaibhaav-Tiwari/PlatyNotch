import XCTest
@testable import PlatyNotchKit

final class PanelStateTests: XCTestCase {
    func testApprovalForcesPeekFromHidden() {
        var m = PanelStateMachine(minimal: true)
        XCTAssertEqual(m.mode, .hidden)
        m.handle(.approvalsChanged(count: 1))
        XCTAssertEqual(m.mode, .peek(.approval))
    }

    func testHoverExitKeepsApprovalPeek() {
        var m = PanelStateMachine()
        m.handle(.approvalsChanged(count: 2))
        m.handle(.hoverExit)
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.noticeTimeout)
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.approvalsChanged(count: 0))
        XCTAssertEqual(m.mode, .compact)
    }

    func testApprovalDoesNotCollapseExpanded() {
        var m = PanelStateMachine()
        m.handle(.click)
        m.handle(.approvalsChanged(count: 1))
        XCTAssertEqual(m.mode, .expanded)
        m.handle(.click)
        XCTAssertEqual(m.mode, .peek(.approval))
    }

    func testClickTogglesExpanded() {
        var m = PanelStateMachine()
        m.handle(.click)
        XCTAssertEqual(m.mode, .expanded)
        m.handle(.click)
        XCTAssertEqual(m.mode, .compact)
        m.handle(.click)
        m.handle(.escape)
        XCTAssertEqual(m.mode, .compact)
    }

    func testMinimalHiddenWhenIdle() {
        var m = PanelStateMachine(minimal: true)
        XCTAssertEqual(m.mode, .hidden)
        XCTAssertEqual(m.idleMode(hasLive: true), .compact)
        m.setLive(true)
        XCTAssertEqual(m.mode, .compact)
        m.setLive(false)
        XCTAssertEqual(m.mode, .hidden)
        m.handle(.notice)
        XCTAssertEqual(m.mode, .peek(.notice))
        m.handle(.noticeTimeout)
        XCTAssertEqual(m.mode, .hidden)
        m.handle(.click)
        m.handle(.escape)
        XCTAssertEqual(m.mode, .hidden)
    }

    func testEscapeFromExpandedWithApprovalSettlesToPeek() {
        var m = PanelStateMachine(minimal: true)
        m.handle(.click)
        m.handle(.approvalsChanged(count: 1))
        m.handle(.escape)
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.escape)
        XCTAssertEqual(m.mode, .peek(.approval))
    }

    func testEscapeFromExpandedWithoutApprovalIsIdle() {
        var m = PanelStateMachine()
        m.handle(.click)
        m.handle(.escape)
        XCTAssertEqual(m.mode, .compact)
    }

    func testEscapeFromNoticePeekIsIdle() {
        var m = PanelStateMachine(minimal: true)
        m.handle(.notice)
        m.handle(.escape)
        XCTAssertEqual(m.mode, .hidden)
    }

    func testHoverExitFromExpandedWithApprovalsPeeks() {
        var m = PanelStateMachine()
        m.handle(.hoverEnter)
        m.handle(.approvalsChanged(count: 1))
        XCTAssertEqual(m.mode, .expanded)
        m.handle(.hoverExit)
        XCTAssertEqual(m.mode, .peek(.approval))
    }
}
