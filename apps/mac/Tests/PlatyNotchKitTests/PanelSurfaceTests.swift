import CoreGraphics
import Foundation
import XCTest
@testable import PlatyNotchKit

/// Transient surfaces (Plan 3b Task 1b, ruling C5): widget peeks, HUDs, ringing and the
/// drag-expanded drop zone, and their precedence against approvals and the open panel.
final class PanelSurfaceTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    var soon: Date { t0.addingTimeInterval(10) }

    // MARK: - Transitions

    func testWidgetPeekShowsAndExpires() {
        var m = PanelStateMachine()
        m.handle(.widgetPeek(id: "wellbeing.water", until: soon))
        XCTAssertEqual(m.mode, .peek(.widget(id: "wellbeing.water")))
        XCTAssertEqual(m.nextExpiry, soon)
        m.handle(.expire(now: t0.addingTimeInterval(5)))
        XCTAssertEqual(m.mode, .peek(.widget(id: "wellbeing.water")))
        m.handle(.expire(now: soon))
        XCTAssertEqual(m.mode, .compact)
        XCTAssertNil(m.nextExpiry)
    }

    func testWidgetPeekReplacedAndEndedById() {
        var m = PanelStateMachine(minimal: true)
        m.handle(.widgetPeek(id: "a", until: soon))
        m.handle(.widgetPeek(id: "b", until: soon))
        XCTAssertEqual(m.mode, .peek(.widget(id: "b")))
        m.handle(.widgetPeekEnded(id: "a"))   // not the one showing: no change
        XCTAssertEqual(m.mode, .peek(.widget(id: "b")))
        m.handle(.widgetPeekEnded(id: "b"))
        XCTAssertEqual(m.mode, .hidden)
    }

    func testEscapeDismissesWidgetPeekAndHUD() {
        var m = PanelStateMachine()
        m.handle(.widgetPeek(id: "a", until: soon))
        m.handle(.escape)
        XCTAssertEqual(m.mode, .compact)
        m.handle(.hud(.volume, level: 0.5, until: soon))
        m.handle(.escape)
        XCTAssertEqual(m.mode, .compact)
    }

    func testHUDShowsUpdatesAndExpires() {
        var m = PanelStateMachine()
        m.handle(.hud(.volume, level: 0.5, until: t0.addingTimeInterval(1.5)))
        XCTAssertEqual(m.mode, .peek(.hud(.volume)))
        XCTAssertEqual(m.hud?.level, 0.5)
        m.handle(.hud(.volume, level: 0.6, until: t0.addingTimeInterval(2)))
        XCTAssertEqual(m.hud?.level, 0.6)
        m.handle(.expire(now: t0.addingTimeInterval(1.6)))   // extended: still showing
        XCTAssertEqual(m.mode, .peek(.hud(.volume)))
        m.handle(.hud(.brightness, level: 0.2, until: t0.addingTimeInterval(3)))
        XCTAssertEqual(m.mode, .peek(.hud(.brightness)))
        m.handle(.expire(now: t0.addingTimeInterval(3)))
        XCTAssertEqual(m.mode, .compact)
    }

    func testRingingIsStickyUntilStopped() {
        var m = PanelStateMachine(minimal: true)
        m.handle(.ringStarted(id: "time.alarm.1"))
        XCTAssertEqual(m.mode, .peek(.ringing(id: "time.alarm.1")))
        m.handle(.escape)
        m.handle(.hoverExit)
        m.handle(.expire(now: soon.addingTimeInterval(3600)))
        m.handle(.noticeTimeout)
        XCTAssertEqual(m.mode, .peek(.ringing(id: "time.alarm.1")))
        m.handle(.ringStarted(id: "time.timer.2"))
        XCTAssertEqual(m.mode, .peek(.ringing(id: "time.alarm.1")), "oldest ring shows first")
        m.handle(.ringStopped(id: "time.alarm.1"))
        XCTAssertEqual(m.mode, .peek(.ringing(id: "time.timer.2")))
        m.handle(.ringStopped(id: "time.timer.2"))
        XCTAssertEqual(m.mode, .hidden)
        XCTAssertTrue(m.ringing.isEmpty)
    }

    func testDragBeganShowsDropZoneEndedRestores() {
        var m = PanelStateMachine()
        m.handle(.dragBegan)
        XCTAssertEqual(m.mode, .peek(.drop))
        m.handle(.escape)   // the drag owns it
        XCTAssertEqual(m.mode, .peek(.drop))
        m.handle(.dragEnded)
        XCTAssertEqual(m.mode, .compact)
    }

    /// A drag near an open panel turns it into the drop zone (same rect); afterwards it rests.
    func testDragNearOpenPanelReplacesIt() {
        var m = PanelStateMachine()
        m.handle(.click)
        m.handle(.dragBegan)
        XCTAssertEqual(m.mode, .peek(.drop))
        m.handle(.dragEnded)
        XCTAssertEqual(m.mode, .compact)
    }

    /// Fix round 1: opening (menu "Open PlatyNotch", a widget) works while ringing or
    /// while the drop zone shows. Ringing then shows as the header chip.
    func testOpeningWhileRingingOrDroppingShowsPanel() {
        var m = PanelStateMachine()
        m.handle(.ringStarted(id: "r"))
        m.handle(.click)
        XCTAssertEqual(m.mode, .expanded)
        XCTAssertEqual(m.ringingChip, "r")
        m.handle(.click)
        XCTAssertEqual(m.mode, .peek(.ringing(id: "r")))
        XCTAssertNil(m.ringingChip, "the full ringing card needs no chip")
        m.handle(.ringStopped(id: "r"))
        m.handle(.dragBegan)
        m.handle(.click)
        XCTAssertEqual(m.mode, .expanded)
        m.handle(.click)
        XCTAssertEqual(m.mode, .peek(.drop))
        m.handle(.dragEnded)
        XCTAssertEqual(m.mode, .compact)
    }

    func testOpeningClearsWidgetPeekButKeepsHUDAsIndicator() {
        var m = PanelStateMachine()
        m.handle(.widgetPeek(id: "a", until: soon))
        m.handle(.hud(.volume, level: 0.3, until: soon))
        m.handle(.click)
        XCTAssertEqual(m.mode, .expanded)
        XCTAssertEqual(m.hudIndicator?.kind, .volume)
        m.handle(.click)
        XCTAssertEqual(m.mode, .peek(.hud(.volume)))
        m.handle(.expire(now: soon))
        XCTAssertEqual(m.mode, .compact, "the widget peek was consumed by opening the panel")
    }

    func testHoverOverHUDOpensPanel() {
        var m = PanelStateMachine()
        m.handle(.hud(.volume, level: 0.3, until: soon))
        m.handle(.hoverEnter)
        XCTAssertEqual(m.mode, .expanded)
        m.handle(.hoverExit)
        XCTAssertEqual(m.mode, .peek(.hud(.volume)))
    }

    func testHoverOverWidgetPeekDoesNotOpen() {
        // The peek's own buttons ("+1 glass") must stay under the cursor.
        var m = PanelStateMachine()
        m.handle(.widgetPeek(id: "a", until: soon))
        m.handle(.hoverEnter)
        XCTAssertEqual(m.mode, .peek(.widget(id: "a")))
    }

    func testNoticeBeatsWidgetPeekAndResumesIt() {
        var m = PanelStateMachine()
        m.handle(.widgetPeek(id: "a", until: soon))
        m.handle(.notice)
        XCTAssertEqual(m.mode, .peek(.notice))
        m.handle(.noticeTimeout)
        XCTAssertEqual(m.mode, .peek(.widget(id: "a")))
    }

    func testCarryOverKeepsSurfaces() {
        var m = PanelStateMachine()
        m.handle(.ringStarted(id: "r"))
        let copy = PanelCarryOver(machine: m, feed: PanelFeed()).machine
        XCTAssertEqual(copy.mode, .peek(.ringing(id: "r")))
    }

    // MARK: - Precedence pairs

    func testApprovalBeatsRinging() {
        var m = PanelStateMachine()
        m.handle(.ringStarted(id: "r"))
        m.handle(.approvalsChanged(count: 1))
        XCTAssertEqual(m.mode, .peek(.approval))
        XCTAssertEqual(m.ringingChip, "r", "the alarm stays stoppable without answering the approval")
        m.handle(.approvalsChanged(count: 0))
        XCTAssertEqual(m.mode, .peek(.ringing(id: "r")))
        XCTAssertNil(m.ringingChip)
    }

    func testRingingDuringApprovalWaits() {
        var m = PanelStateMachine()
        m.handle(.approvalsChanged(count: 1))
        m.handle(.ringStarted(id: "r"))
        XCTAssertEqual(m.mode, .peek(.approval))
        XCTAssertEqual(m.ringingChip, "r")
        m.handle(.ringStopped(id: "r"))   // Stop on the chip
        XCTAssertNil(m.ringingChip)
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.escape)
        XCTAssertEqual(m.mode, .peek(.approval), "Escape never hides an approval")
    }

    func testApprovalBeatsWidgetPeekAndPeekResumes() {
        var m = PanelStateMachine()
        m.handle(.widgetPeek(id: "a", until: soon))
        m.handle(.approvalsChanged(count: 1))
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.widgetPeek(id: "b", until: soon))
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.approvalsChanged(count: 0))
        XCTAssertEqual(m.mode, .peek(.widget(id: "b")))
    }

    func testHUDNeverCoversApprovalBecomesIndicator() {
        var m = PanelStateMachine()
        m.handle(.approvalsChanged(count: 1))
        m.handle(.hud(.volume, level: 0.7, until: soon))
        XCTAssertEqual(m.mode, .peek(.approval))
        XCTAssertEqual(m.hudIndicator, HUDState(kind: .volume, level: 0.7, until: soon))
        m.handle(.escape)
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.expire(now: soon))
        XCTAssertNil(m.hudIndicator)
        XCTAssertEqual(m.mode, .peek(.approval))
    }

    func testHUDDuringExpandedApprovalIsIndicator() {
        var m = PanelStateMachine()
        m.handle(.click)
        m.handle(.approvalsChanged(count: 1))
        m.handle(.hud(.brightness, level: 0.1, until: soon))
        XCTAssertEqual(m.mode, .expanded)
        XCTAssertEqual(m.hudIndicator?.kind, .brightness)
    }

    func testRingingBeatsHUD() {
        var m = PanelStateMachine()
        m.handle(.hud(.volume, level: 0.5, until: soon))
        m.handle(.ringStarted(id: "r"))
        XCTAssertEqual(m.mode, .peek(.ringing(id: "r")))
        XCTAssertNil(m.hudIndicator, "a HUD under the ringing card is dropped, not drawn")
        m.handle(.ringStopped(id: "r"))
        XCTAssertEqual(m.mode, .peek(.hud(.volume)))
    }

    func testRingingBeatsNudgePeek() {
        var m = PanelStateMachine()
        m.handle(.widgetPeek(id: "wellbeing.eyes", until: soon))
        m.handle(.ringStarted(id: "r"))
        XCTAssertEqual(m.mode, .peek(.ringing(id: "r")))
        m.handle(.widgetPeek(id: "wellbeing.water", until: soon))
        XCTAssertEqual(m.mode, .peek(.ringing(id: "r")))
    }

    /// Fix round 1: ringing never takes over the open panel; it shows as the header chip.
    func testRingingNeverCoversOpenPanel() {
        var m = PanelStateMachine()
        m.handle(.click)
        m.handle(.ringStarted(id: "r"))
        XCTAssertEqual(m.mode, .expanded)
        XCTAssertEqual(m.ringingChip, "r")
        m.handle(.hoverExit)
        XCTAssertEqual(m.mode, .peek(.ringing(id: "r")))
        m.handle(.ringStopped(id: "r"))
        XCTAssertEqual(m.mode, .compact)

        var withApproval = PanelStateMachine()
        withApproval.handle(.click)
        withApproval.handle(.approvalsChanged(count: 1))
        withApproval.handle(.ringStarted(id: "r"))
        XCTAssertEqual(withApproval.mode, .expanded)
        XCTAssertEqual(withApproval.ringingChip, "r")
    }

    /// Task 5 carry: a drag near the notch shows the drop zone even while something rings
    /// (the ringing card never covers the panel the drag opened); ringing is the header
    /// chip meanwhile and the full card comes back when the drag ends.
    func testDropZoneBeatsRingingWhichShowsAsChip() {
        var m = PanelStateMachine()
        m.handle(.dragBegan)
        m.handle(.ringStarted(id: "r"))
        XCTAssertEqual(m.mode, .peek(.drop))
        XCTAssertEqual(m.ringingChip, "r")
        m.handle(.dragEnded)
        XCTAssertEqual(m.mode, .peek(.ringing(id: "r")))
        XCTAssertNil(m.ringingChip)

        var open = PanelStateMachine()
        open.handle(.ringStarted(id: "r"))
        open.handle(.click)
        open.handle(.dragBegan)
        XCTAssertEqual(open.mode, .peek(.drop), "not the ringing card over the open panel")
        XCTAssertEqual(open.ringingChip, "r")
        open.handle(.dragEndedInside)
        XCTAssertEqual(open.mode, .expanded, "the open panel comes back, ringing as its chip")
        XCTAssertEqual(open.ringingChip, "r")
    }

    /// Task 5 carry: `.dragBegan` clears `open`; a drag that ends with the cursor still on
    /// the panel (a drop, or a release there) gives back the panel that was open.
    func testDragEndedInsideRestoresOpenPanel() {
        var m = PanelStateMachine()
        m.handle(.click)
        m.handle(.dragBegan)
        XCTAssertEqual(m.mode, .peek(.drop))
        m.handle(.dragEndedInside)
        XCTAssertEqual(m.mode, .expanded)

        var away = PanelStateMachine()
        away.handle(.click)
        away.handle(.dragBegan)
        away.handle(.dragEnded)   // left the drop zone: the panel rests
        XCTAssertEqual(away.mode, .compact)
        away.handle(.dragBegan)
        away.handle(.dragEndedInside)
        XCTAssertEqual(away.mode, .compact, "only a panel open when this drag began comes back")

        var closed = PanelStateMachine()
        closed.handle(.dragBegan)
        closed.handle(.dragEndedInside)
        XCTAssertEqual(closed.mode, .compact)

        var approval = PanelStateMachine()
        approval.handle(.approvalsChanged(count: 1))
        approval.handle(.dragBegan)
        approval.handle(.dragEndedInside)
        XCTAssertEqual(approval.mode, .peek(.approval))
    }

    /// Final review A1: an approval that arrives during a drag that began over the open
    /// panel must stay a peek when the drag ends on the panel: restoring `open` would turn
    /// it into the expanded list under the cursor.
    func testApprovalArrivingMidDragIsNotExpandedByTheDrop() {
        var m = PanelStateMachine()
        m.handle(.click)
        m.handle(.dragBegan)
        m.handle(.approvalsChanged(count: 1))
        m.handle(.dragEndedInside)
        XCTAssertEqual(m.mode, .peek(.approval))

        // Answered before the drop: the remembered open panel is gone with it.
        var answered = PanelStateMachine()
        answered.handle(.click)
        answered.handle(.dragBegan)
        answered.handle(.approvalsChanged(count: 1))
        answered.handle(.approvalsChanged(count: 0))
        XCTAssertEqual(answered.mode, .peek(.drop))
        answered.handle(.dragEndedInside)
        XCTAssertEqual(answered.mode, .compact)

        // Still pending at drop time after a plain drag end: no reopen either.
        var ended = PanelStateMachine()
        ended.handle(.click)
        ended.handle(.dragBegan)
        ended.handle(.approvalsChanged(count: 2))
        ended.handle(.dragEnded)
        XCTAssertEqual(ended.mode, .peek(.approval))
    }

    /// Ruling: while any approval is pending the drop zone is not shown; the approval
    /// (peek or the open panel's approval list) stays visible and answerable.
    func testDragWhileApprovalPendingKeepsApproval() {
        var m = PanelStateMachine()
        m.handle(.approvalsChanged(count: 1))
        m.handle(.dragBegan)
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.approvalsChanged(count: 0))   // answered mid-drag: the drop zone appears
        XCTAssertEqual(m.mode, .peek(.drop))
        m.handle(.approvalsChanged(count: 1))   // a new approval takes the drop zone away
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.dragEnded)
        XCTAssertEqual(m.mode, .peek(.approval))

        var open = PanelStateMachine()
        open.handle(.click)
        open.handle(.approvalsChanged(count: 1))
        open.handle(.dragBegan)
        XCTAssertEqual(open.mode, .expanded)
    }

    func testDropZoneBeatsHUDAndPeek() {
        var m = PanelStateMachine()
        m.handle(.widgetPeek(id: "a", until: soon))
        m.handle(.hud(.volume, level: 0.5, until: soon))
        m.handle(.dragBegan)
        XCTAssertEqual(m.mode, .peek(.drop))
        m.handle(.dragEnded)
        XCTAssertEqual(m.mode, .peek(.hud(.volume)))
    }

    func testHUDBeatsNoticeAndWidgetPeek() {
        var m = PanelStateMachine()
        m.handle(.widgetPeek(id: "a", until: soon))
        m.handle(.notice)
        m.handle(.hud(.volume, level: 0.5, until: t0.addingTimeInterval(1)))
        XCTAssertEqual(m.mode, .peek(.hud(.volume)))
        m.handle(.expire(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(m.mode, .peek(.notice))
    }

    func testNoticeDroppedDuringApprovalRingingDropAndOpen() {
        for setup in [PanelEvent.approvalsChanged(count: 1), .ringStarted(id: "r"), .dragBegan, .click] {
            var m = PanelStateMachine()
            m.handle(setup)
            m.handle(.notice)
            XCTAssertFalse(m.mode == .peek(.notice), "\(setup)")
        }
    }

    func testPrecedenceTable() {
        let hud = HUDState(kind: .volume, level: 0.5, until: soon)
        let peek = WidgetPeek(id: "a", until: soon)
        func s(_ f: (inout PanelSurfaceState) -> Void) -> PanelMode {
            var st = PanelSurfaceState(idle: .compact)
            f(&st)
            return PanelPrecedence.resolve(st)
        }
        XCTAssertEqual(s { _ in }, .compact)
        XCTAssertEqual(s { $0.approvals = 1; $0.ringing = ["r"]; $0.dragging = true; $0.hud = hud; $0.widgetPeek = peek },
                       .peek(.approval))
        XCTAssertEqual(s { $0.approvals = 1; $0.open = true; $0.ringing = ["r"] }, .expanded)
        XCTAssertEqual(s { $0.open = true; $0.ringing = ["r"]; $0.dragging = true; $0.hud = hud; $0.notice = true }, .expanded)
        XCTAssertEqual(s { $0.ringing = ["r"]; $0.dragging = true; $0.hud = hud }, .peek(.drop))
        XCTAssertEqual(s { $0.ringing = ["r"]; $0.hud = hud }, .peek(.ringing(id: "r")))
        XCTAssertEqual(s { $0.dragging = true; $0.hud = hud; $0.notice = true }, .peek(.drop))
        XCTAssertEqual(s { $0.hud = hud; $0.notice = true; $0.widgetPeek = peek }, .peek(.hud(.volume)))
        XCTAssertEqual(s { $0.notice = true; $0.widgetPeek = peek }, .peek(.notice))
        XCTAssertEqual(s { $0.widgetPeek = peek }, .peek(.widget(id: "a")))
    }

    // MARK: - Full screen

    func testFullScreenSuppressesHUDAndPeeksButNotRingingOrApproval() {
        var m = PanelStateMachine()
        m.setFullScreen(true)
        m.handle(.hud(.volume, level: 0.5, until: soon))
        XCTAssertEqual(m.mode, .compact, "HUD dropped over full screen")
        XCTAssertNil(m.hud)
        m.handle(.widgetPeek(id: "wellbeing.eyes", until: soon))
        XCTAssertEqual(m.mode, .compact, "nudge held over full screen")
        m.handle(.ringStarted(id: "r"))
        XCTAssertEqual(m.mode, .peek(.ringing(id: "r")))
        m.handle(.approvalsChanged(count: 1))
        XCTAssertEqual(m.mode, .peek(.approval))
        m.handle(.approvalsChanged(count: 0))
        m.handle(.ringStopped(id: "r"))
        XCTAssertEqual(m.mode, .compact)
        m.setFullScreen(false)   // still before `until`: the peek shows now
        XCTAssertEqual(m.mode, .peek(.widget(id: "wellbeing.eyes")))
    }

    func testFullScreenWithHUDShowingDropsIt() {
        var m = PanelStateMachine()
        m.handle(.hud(.volume, level: 0.5, until: soon))
        m.setFullScreen(true)
        XCTAssertEqual(m.mode, .compact)
        XCTAssertNil(m.hudIndicator)
    }

    func testRingingChipOnlyWhereTheCardCannotShow() {
        func chip(_ f: (inout PanelSurfaceState) -> Void) -> String? {
            var st = PanelSurfaceState(idle: .compact)
            st.ringing = ["r"]
            f(&st)
            return PanelPrecedence.ringingChip(st)
        }
        XCTAssertEqual(chip { $0.approvals = 1 }, "r")
        XCTAssertEqual(chip { $0.open = true }, "r")
        XCTAssertEqual(chip { $0.approvals = 2; $0.open = true }, "r")
        XCTAssertNil(chip { _ in })
        XCTAssertEqual(chip { $0.dragging = true }, "r", "the drop zone carries the chip (Task 5)")
        var none = PanelSurfaceState(idle: .compact)
        none.approvals = 1
        XCTAssertNil(PanelPrecedence.ringingChip(none))
    }

    func testFullScreenPolicyNeverSuppressesRingingOrDrop() {
        let away = CGPoint(x: 10, y: 10)
        let strip = CGRect(x: 0, y: 979, width: 10, height: 3)
        for mode: PanelMode in [.peek(.ringing(id: "r")), .peek(.drop), .peek(.approval), .expanded] {
            XCTAssertFalse(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: mode, cursor: away,
                                                           revealRect: strip, hitRect: strip, wasSuppressed: true), "\(mode)")
        }
        for mode: PanelMode in [.peek(.hud(.volume)), .peek(.widget(id: "a"))] {
            XCTAssertTrue(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: mode, cursor: away,
                                                          revealRect: strip, hitRect: strip, wasSuppressed: true), "\(mode)")
        }
    }

    // MARK: - Mode properties

    func testFocusAndShadowForNewModes() {
        for mode: PanelMode in [.peek(.widget(id: "a")), .peek(.hud(.volume)), .peek(.ringing(id: "r")), .peek(.drop)] {
            XCTAssertFalse(mode.canBecomeKey, "\(mode) never takes keyboard focus")
            XCTAssertTrue(mode.hasShadow, "\(mode)")
        }
        XCTAssertTrue(PanelMode.peek(.drop).acceptsDrops)
        XCTAssertFalse(PanelMode.expanded.acceptsDrops)
        XCTAssertFalse(PanelMode.compact.acceptsDrops)
        XCTAssertEqual(PanelMode.peek(.widget(id: "a")).description, "peek(widget:a)")
        XCTAssertEqual(PanelMode.peek(.hud(.keyboardBacklight)).description, "peek(hud:keyboardBacklight)")
        XCTAssertEqual(PanelMode.peek(.ringing(id: "r")).description, "peek(ringing:r)")
        XCTAssertEqual(PanelMode.peek(.drop).description, "peek(drop)")
    }
}

/// Layout of the transient surfaces.
final class PanelSurfaceLayoutTests: XCTestCase {
    var mbp: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }
    var ext: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), auxLeft: nil, auxRight: nil)
    }
    let modes: [PanelMode] = [.peek(.widget(id: "a")), .peek(.hud(.volume)), .peek(.ringing(id: "r")), .peek(.drop)]

    func testSurfaceHeightsBelowNotch() {
        let l = mbp
        let w = l.contentRect(for: .peek(.widget(id: "a")))
        XCTAssertEqual(w.maxY, 982)
        XCTAssertEqual(w.height, l.anchor.height + PanelLayout.widgetPeekHeight)
        XCTAssertEqual(w.width, PanelLayout.surfaceWidth)
        XCTAssertEqual(w.midX, 756)
        let r = l.contentRect(for: .peek(.ringing(id: "r")))
        XCTAssertEqual(r.height, l.anchor.height + PanelLayout.ringingHeight)
        let h = l.contentRect(for: .peek(.hud(.volume)))
        XCTAssertEqual(h.height, l.anchor.height + PanelLayout.hudHeight)
        XCTAssertGreaterThanOrEqual(h.width, l.contentRect(for: .compact).width, "the HUD grows out of the pill")
        XCTAssertEqual(l.contentRect(for: .peek(.drop)), l.contentRect(for: .expanded))
        // Without a notch the surfaces sit below the pill / menu bar.
        let e = ext.contentRect(for: .peek(.hud(.volume)))
        XCTAssertEqual(e.height, PanelLayout.hudHeight)
        XCTAssertEqual(e.maxY, 1055)
    }

    func testHeightsOrdered() {
        XCTAssertLessThan(PanelLayout.hudHeight, PanelLayout.widgetPeekHeight)
        XCTAssertLessThan(PanelLayout.widgetPeekHeight, PanelLayout.ringingHeight)
        XCTAssertLessThan(PanelLayout.ringingHeight, PanelLayout.peekSize.height)
    }

    func testWindowContainsSurfaces() {
        for l in [mbp, ext] {
            for m in modes { XCTAssertTrue(l.windowFrame.contains(l.contentRect(for: m)), "\(m)") }
        }
    }

    /// Fix round 1: the ringing chip never moves an approval card or changes a height.
    /// Same mode with and without ringing, so the same content and slot rects; the chip
    /// sits in the header strip (beside the camera on a notch), outside the slot.
    func testRingingChipNeverMovesApprovalCards() {
        func machine(open: Bool, ringing: Bool) -> PanelStateMachine {
            var m = PanelStateMachine()
            if open { m.handle(.click) }
            m.handle(.approvalsChanged(count: 2))
            if ringing { m.handle(.ringStarted(id: "time.alarm")) }
            return m
        }
        for open in [false, true] {
            let plain = machine(open: open, ringing: false)
            let ringing = machine(open: open, ringing: true)
            XCTAssertEqual(plain.mode, ringing.mode)
            XCTAssertNil(plain.ringingChip)
            XCTAssertEqual(ringing.ringingChip, "time.alarm")
            for l in [mbp, ext] {
                let mode = ringing.mode
                XCTAssertEqual(l.contentRect(for: plain.mode), l.contentRect(for: mode))
                let slot = try! XCTUnwrap(l.approvalSlot(for: mode))
                XCTAssertEqual(l.approvalSlot(for: plain.mode), slot)
                let chip = try! XCTUnwrap(l.ringingChipRect(for: mode))
                XCTAssertFalse(chip.intersects(slot), "\(mode) chip \(chip) over cards \(slot)")
                XCTAssertTrue(l.contentRect(for: mode).contains(chip), "\(mode) chip inside the hit rect")
                if l.hasNotch { XCTAssertFalse(chip.intersects(l.anchor), "chip clear of the camera housing") }
                XCTAssertGreaterThanOrEqual(chip.width, 60)
            }
        }
        // Card room on a screen without a notch is what it was before the header strip.
        XCTAssertEqual(ext.approvalSlot(for: .peek(.approval))!.height, PanelLayout.peekSize.height - 20)
        XCTAssertNil(mbp.ringingChipRect(for: .compact))
        // The drop zone carries the chip too (Task 5), above its content.
        for l in [mbp, ext] {
            let chip = try! XCTUnwrap(l.ringingChipRect(for: .peek(.drop)))
            let content = l.contentRect(for: .peek(.drop))
            XCTAssertTrue(content.contains(chip))
            XCTAssertLessThanOrEqual(content.maxY - l.contentInset(for: .peek(.drop)), chip.minY + 0.5,
                                     "drop content starts below the chip")
        }
        XCTAssertNil(mbp.approvalSlot(for: .peek(.notice)))
    }

    /// Final review A5: beside a very wide notch the chip never gets a negative width; below
    /// `minChipWidth` it is not drawn at all.
    func testRingingChipClampedBesideWideNotch() {
        for notch in stride(from: CGFloat(180), through: 900, by: 40) {
            let side = (1512 - notch) / 2
            let l = PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                                auxLeft: CGRect(x: 0, y: 950, width: side, height: 32),
                                auxRight: CGRect(x: side + notch, y: 950, width: side, height: 32))
            for mode in [PanelMode.peek(.approval), .expanded, .peek(.drop)] {
                if let chip = l.ringingChipRect(for: mode) {
                    XCTAssertGreaterThanOrEqual(chip.width, PanelLayout.minChipWidth, "notch \(notch) \(mode)")
                    XCTAssertFalse(chip.intersects(l.anchor), "notch \(notch) \(mode)")
                } else {
                    let room = l.contentRect(for: mode).maxX - 10 - (l.anchor.maxX + 6)
                    XCTAssertLessThan(room, PanelLayout.minChipWidth, "notch \(notch) \(mode): hidden only when narrow")
                }
            }
        }
        let huge = PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                               auxLeft: CGRect(x: 0, y: 950, width: 300, height: 32),
                               auxRight: CGRect(x: 1212, y: 950, width: 300, height: 32))
        XCTAssertNil(huge.ringingChipRect(for: .expanded), "a 912 pt notch leaves no room")
    }

    func testHUDIsClickThroughBeyondThePill() {
        let l = mbp
        XCTAssertEqual(l.hitRect(for: .peek(.hud(.volume))), l.contentRect(for: .compact))
        XCTAssertEqual(l.hitRect(for: .peek(.widget(id: "a"))), l.contentRect(for: .peek(.widget(id: "a"))))
        XCTAssertEqual(l.hitRect(for: .peek(.ringing(id: "r"))), l.contentRect(for: .peek(.ringing(id: "r"))))
    }

    /// C20: the drop zone's hit rect is the expanded rect, and the drag zone that triggers it
    /// lies inside it, so the window accepts the drag before the first drag-enter.
    func testDragZoneInsideDropHitRect() {
        for l in [mbp, ext] {
            let hit = l.hitRect(for: .peek(.drop))
            XCTAssertEqual(hit, l.contentRect(for: .expanded))
            let below = l.dragZone.intersection(l.usableFrame)
            XCTAssertFalse(below.isEmpty)
            XCTAssertTrue(hit.contains(below), "drag zone \(below) inside drop rect \(hit)")
        }
    }

    func testDragHover() {
        let l = mbp
        // Near the notch: in. Far away: out.
        XCTAssertTrue(l.dragHover(CGPoint(x: 756, y: 930), showing: false))
        XCTAssertTrue(l.dragHover(CGPoint(x: 654 - 50, y: 960), showing: false))
        XCTAssertFalse(l.dragHover(CGPoint(x: 756, y: 850), showing: false), "100 pt below the notch is not near")
        XCTAssertFalse(l.dragHover(CGPoint(x: 100, y: 970), showing: false))
        // Once the drop zone shows, the whole drop rect keeps it.
        XCTAssertTrue(l.dragHover(CGPoint(x: 756, y: 650), showing: true))
        XCTAssertFalse(l.dragHover(CGPoint(x: 756, y: 400), showing: true))
    }

    func testIgnoresMouseForDropModeIsWholeWindow() {
        let l = mbp
        let far = CGPoint(x: 10, y: 10)
        XCTAssertFalse(PanelLayout.ignoresMouse(mode: .peek(.drop), visible: true, layout: l, cursor: far))
        XCTAssertTrue(PanelLayout.ignoresMouse(mode: .peek(.drop), visible: false, layout: l, cursor: far))
        XCTAssertTrue(PanelLayout.ignoresMouse(mode: .peek(.hud(.volume)), visible: true, layout: l,
                                               cursor: CGPoint(x: 756, y: 925)), "HUD body is click-through")
        XCTAssertFalse(PanelLayout.ignoresMouse(mode: .compact, visible: true, layout: l, cursor: CGPoint(x: 756, y: 960)))
    }
}
