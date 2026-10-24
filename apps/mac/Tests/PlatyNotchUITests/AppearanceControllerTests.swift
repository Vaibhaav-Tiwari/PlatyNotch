import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Appearance settings through the real `NotchController` (no window: a layout and a
/// pinned cursor), above all the Plan 3 ruling that full-screen hiding never hides a
/// pending approval or a ringing alarm (C32).
@MainActor
final class AppearanceControllerTests: DefaultsTestCase {



    private var mbpLayout: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }

    private func controller(_ appearance: AppearanceSettings = AppearanceSettings()) -> NotchController {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let c = NotchController(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"), plugins: [],
                                widgets: registry, surfaces: PanelSurfaces(registry: registry),
                                appearance: appearance)
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse; away from the notch
        c.debugHandle(.layout(mbpLayout))
        return c
    }

    func testHideInFullScreenNeverHidesAnApprovalOrRinging() {
        let c = controller()
        XCTAssertTrue(c.appearance.hideInFullScreen)
        c.debugHandle(.setFullScreen(true))
        XCTAssertEqual(c.mode, .compact)
        XCTAssertFalse(c.contentVisible, "the resting pill hides over full screen")

        c.debugHandle(.event(.approvalsChanged(count: 1)))
        XCTAssertEqual(c.mode, .peek(.approval))
        XCTAssertTrue(c.contentVisible, "a pending approval always shows")
        c.debugHandle(.event(.approvalsChanged(count: 0)))
        XCTAssertFalse(c.contentVisible)

        c.debugHandle(.event(.ringStarted(id: "alarm")))
        XCTAssertEqual(c.mode, .peek(.ringing(id: "alarm")))
        XCTAssertTrue(c.contentVisible, "a ringing alarm always shows")
        c.debugHandle(.event(.approvalsChanged(count: 1)))
        XCTAssertTrue(c.contentVisible, "approval over ringing, still shown")
        c.debugHandle(.event(.approvalsChanged(count: 0)))
        c.debugHandle(.event(.ringStopped(id: "alarm")))
        XCTAssertFalse(c.contentVisible)
    }

    func testHideInFullScreenOffKeepsThePill() {
        var a = AppearanceSettings()
        a.hideInFullScreen = false
        let c = controller(a)
        c.debugHandle(.setFullScreen(true))
        XCTAssertEqual(c.mode, .compact)
        XCTAssertTrue(c.contentVisible, "the pill stays over full screen")
        XCTAssertTrue(c.coveredByFullScreen, "games and nudges still see full screen")
        c.debugHandle(.event(.hud(.volume, level: 0.5, until: .distantFuture)))
        XCTAssertEqual(c.mode, .compact, "HUDs still drop over full screen (the system HUD shows)")
        c.debugHandle(.event(.approvalsChanged(count: 1)))
        XCTAssertTrue(c.contentVisible)
    }

    func testTurningHidingOnLiveHidesThePill() {
        var a = AppearanceSettings()
        a.hideInFullScreen = false
        let c = controller(a)
        c.debugHandle(.setFullScreen(true))
        XCTAssertTrue(c.contentVisible)
        c.appearance.hideInFullScreen = true
        XCTAssertFalse(c.contentVisible)
    }

    func testModeAppliedLive() {
        let c = controller()
        XCTAssertEqual(c.mode, .compact)
        c.appearance.mode = .minimal
        XCTAssertEqual(c.mode, .hidden, "Minimal with nothing live")
        c.appearance.mode = .alwaysOn
        XCTAssertEqual(c.mode, .compact)
    }

    func testClickModeIgnoresHover() {
        var a = AppearanceSettings()
        a.openOn = .click
        let c = controller(a)
        c.hoverSample(inside: true, at: 0)
        c.hoverSample(inside: true, at: 1)
        XCTAssertEqual(c.mode, .compact, "resting on the pill does not open it")
        c.debugHandle(.event(.click))
        XCTAssertEqual(c.mode, .expanded)
        c.hoverSample(inside: false, at: 2)
        c.hoverSample(inside: false, at: 3)
        XCTAssertEqual(c.mode, .compact, "moving away closes it")
        c.appearance.openOn = .hover
        c.hoverSample(inside: true, at: 4)
        c.hoverSample(inside: true, at: 5)
        XCTAssertEqual(c.mode, .expanded, "hover mode again, applied live")
    }

    func testHoverDelay() {
        var a = AppearanceSettings()
        a.hoverDelay = 0.4
        let c = controller(a)
        c.hoverSample(inside: true, at: 10)
        c.hoverSample(inside: true, at: 10.3)
        XCTAssertEqual(c.mode, .compact, "not yet: 0.3 s of 0.4")
        c.hoverSample(inside: true, at: 10.41)
        XCTAssertEqual(c.mode, .expanded)

        let d = controller()
        d.hoverSample(inside: true, at: 0)
        d.hoverSample(inside: true, at: 0.121)
        XCTAssertEqual(d.mode, .expanded, "the 0.12 s default")
    }

    func testOutOfRangeSettingsAreClamped() {
        var a = AppearanceSettings()
        a.spring = SpringParams(response: 9, dampingFraction: 0, blur: 99)
        a.hoverDelay = 7
        let c = controller(a)
        XCTAssertEqual(c.appearance.spring, SpringParams(response: 1, dampingFraction: 0.5, blur: 20))
        XCTAssertEqual(c.appearance.hoverDelay, 1)
    }

    /// The HUD goes to the display under the cursor (Task 4). With the panels on fewer
    /// displays (Appearance › Displays: menu-bar display / with a notch) a HUD for a
    /// display without a panel is not taken, so the system HUD shows there.
    func testHUDOnADisplayWithoutAPanelIsNotTaken() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let surfaces = PanelSurfaces(registry: registry)
        let c = NotchController(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"), plugins: [],
                                widgets: registry, surfaces: surfaces)
        c.cursorLocation = { CGPoint(x: 100, y: 100) }
        c.debugHandle(.layout(mbpLayout))
        c.debugHandle(.display(1))
        surfaces.defaultHUDDisplay = { 2 }   // the cursor is on display 2, which has no panel
        XCTAssertFalse(surfaces.showHUD(kind: .volume, level: 0.5))
        XCTAssertEqual(c.mode, .compact)
        XCTAssertFalse(surfaces.hudReadiness.covers(2))
        surfaces.defaultHUDDisplay = { 1 }
        XCTAssertTrue(surfaces.showHUD(kind: .volume, level: 0.5))
        XCTAssertEqual(c.mode, .peek(.hud(.volume)))
    }
}
