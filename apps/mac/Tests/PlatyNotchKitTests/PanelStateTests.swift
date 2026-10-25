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

    // MARK: - Peek on hover, open on click (spec 9)

    private func hoverPeekMachine() -> PanelStateMachine {
        var m = PanelStateMachine()
        m.openOnHover = false
        m.peekOnHover = true
        return m
    }

    func testHoverPeekThenClickOpens() {
        var m = hoverPeekMachine()
        m.handle(.hoverEnter)
        XCTAssertEqual(m.mode, .peek(.hover))
        m.handle(.click)
        XCTAssertEqual(m.mode, .expanded)
        m.handle(.click)
        XCTAssertEqual(m.mode, .compact, "closing by click does not fall back to the peek")
        // Hover mode (the default) still opens on hover; click mode never peeks.
        var hover = PanelStateMachine()
        XCTAssertFalse(hover.peekOnHover)
        hover.handle(.hoverEnter)
        XCTAssertEqual(hover.mode, .expanded)
        var click = PanelStateMachine()
        click.openOnHover = false
        click.handle(.hoverEnter)
        XCTAssertEqual(click.mode, .compact)
    }

    func testHoverPeekExitCloses() {
        var m = hoverPeekMachine()
        m.handle(.hoverEnter)
        m.handle(.hoverExit)
        XCTAssertEqual(m.mode, .compact)
        m.handle(.hoverEnter)
        m.handle(.escape)
        XCTAssertEqual(m.mode, .compact)
        var minimal = hoverPeekMachine()
        minimal.minimal = true
        minimal.handle(.hoverEnter)
        XCTAssertEqual(minimal.mode, .peek(.hover), "from hidden too")
        minimal.handle(.hoverExit)
        XCTAssertEqual(minimal.mode, .hidden)
    }

    func testApprovalBeatsHoverPeek() {
        var m = hoverPeekMachine()
        m.handle(.hoverEnter)
        m.handle(.approvalsChanged(count: 1))
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.approvalsChanged(count: 0))
        XCTAssertEqual(m.mode, .peek(.hover), "still hovering")
        var waiting = hoverPeekMachine()
        waiting.handle(.approvalsChanged(count: 1))
        waiting.handle(.hoverEnter)
        XCTAssertEqual(waiting.mode, .peek(.approval), "hovering an approval peek never turns it into the hover peek")
    }

    func testRingingBeatsHoverPeek() {
        var m = hoverPeekMachine()
        m.handle(.hoverEnter)
        m.handle(.ringStarted(id: "t"))
        XCTAssertEqual(m.mode, .peek(.ringing(id: "t")))
        m.handle(.ringStopped(id: "t"))
        XCTAssertEqual(m.mode, .peek(.hover))
        // The hover peek beats a HUD, a notice and a widget peek.
        var below = hoverPeekMachine()
        below.handle(.hud(.volume, level: 0.5, until: .distantFuture))
        below.handle(.hoverEnter)
        XCTAssertEqual(below.mode, .peek(.hover))
        var s = PanelSurfaceState(idle: .compact)
        s.hoverPeek = true
        s.notice = true
        s.widgetPeek = WidgetPeek(id: "w", until: .distantFuture)
        XCTAssertEqual(PanelPrecedence.resolve(s), .peek(.hover))
        s.dragging = true
        XCTAssertEqual(PanelPrecedence.resolve(s), .peek(.drop))
    }

    func testHoverPeekNeverKey() {
        XCTAssertFalse(PanelMode.peek(.hover).canBecomeKey)
        XCTAssertTrue(PanelMode.peek(.hover).hasShadow)
        XCTAssertEqual(PanelMode.peek(.hover).description, "peek(hover)")
    }

    func testNoApprovalCardsInHoverPeek() {
        XCTAssertNil(ApprovalPlacement(mode: .peek(.hover), count: 2))
        XCTAssertEqual(ApprovalPlacement(mode: .peek(.approval), count: 1), .peek)
    }

    func testPeekOnHoverSettingDecodes() throws {
        XCTAssertEqual(AppearanceSettings().openOn, .hover, "the default stays open on hover")
        var s = AppearanceSettings()
        s.openOn = .peekOnHover
        let back = try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.openOn, .peekOnHover)
    }

    /// Fix round 1 (M2): a drag ends the hover peek; it comes back only with a new hover.
    func testDragEndsTheHoverPeek() {
        var m = hoverPeekMachine()
        m.handle(.hoverEnter)
        m.handle(.dragBegan)
        XCTAssertEqual(m.mode, .peek(.drop))
        m.handle(.dragEnded)
        XCTAssertEqual(m.mode, .compact)
        m.handle(.hoverEnter)
        XCTAssertEqual(m.mode, .peek(.hover))
    }

    /// Fix round 1 (M3): a notice during the hover peek is held, then shows.
    func testNoticeHeldUnderHoverPeek() {
        var m = hoverPeekMachine()
        m.handle(.hoverEnter)
        m.handle(.notice)
        XCTAssertEqual(m.mode, .peek(.hover))
        m.handle(.hoverExit)
        XCTAssertEqual(m.mode, .peek(.notice))
    }
}
