import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
private final class FakeTimerStarter: TimerStarter {
    private(set) var started: [(TimeInterval, String?)] = []
    func startTimer(duration: TimeInterval, label: String?) -> Bool {
        started.append((duration, label))
        return true
    }
}

/// The Timer tool (Island spec 4, wireframe C).
@MainActor
final class TimerToolTests: DefaultsTestCase {
    func testModesAreTimerFocusStopwatch() {
        XCTAssertEqual(TimerTool.modeTitles(), ["Timer", "Focus", "Stopwatch"])
        let r = HomeRenders.builtIns(meeting: false)
        let tool = ToolCatalog.tool(PanelTools.timer, widgets: r.registry, extraTabs: [], memory: { AnyView(EmptyView()) })
        XCTAssertEqual(tool?.title, "Timer")
        XCTAssertNotNil(tool?.accessory, "the modes are chips in the header")
        r.registry.stopAll()
    }

    func testDefaultsAndBigText() {
        let m = TimerToolModel()
        XCTAssertEqual(m.timerSelection, 600)
        XCTAssertEqual(m.focusSelection, 1500)
        XCTAssertEqual(TimerTool.bigText(mode: .timer, selection: 600, running: nil), "10:00")
        XCTAssertEqual(TimerTool.bigText(mode: .focus, selection: 1500, running: nil), "25:00")
        XCTAssertEqual(TimerTool.bigText(mode: .timer, selection: 600, running: 3725), "1:02:05")
    }

    func testBigNumberUsesTimerToken() {
        XCTAssertEqual(TimerTool.numberFont, DS.font(TypeScale.timer))
        XCTAssertEqual(TypeScale.timer.size, 54)
    }

    func testStartStartsATimer() {
        let m = TimerToolModel()
        let fake = FakeTimerStarter()
        m.timerSelection = TimerPresets.timer[1]   // "5 min"
        XCTAssertTrue(m.startTimer(fake) { [] })
        XCTAssertEqual(fake.started.count, 1)
        XCTAssertEqual(fake.started.first?.0, 300)
        XCTAssertNil(fake.started.first?.1)
    }

    func testCustomParsesDuration() {
        let m = TimerToolModel()
        m.customOpen = true
        m.customText = "1h 5m"
        XCTAssertTrue(m.applyCustom())
        XCTAssertEqual(m.timerSelection, 3900)
        XCTAssertFalse(m.customOpen)
        m.customOpen = true
        m.customText = "abc"
        XCTAssertFalse(m.applyCustom())
        XCTAssertEqual(m.customMessage, "Try 10m or 1h 5m")
        XCTAssertEqual(m.timerSelection, 3900, "nothing changes, nothing starts")
    }

    func testLegacyFocusOpensFocusMode() {
        let m = TimerToolModel()
        let tool = TimerTool(time: nil, focus: nil, initial: .focus, model: m)
        tool.appeared()
        XCTAssertEqual(m.mode, .focus)
        XCTAssertEqual(PanelRoute.legacy(tab: "focus", tools: []).tool, PanelTools.timerFocus)
        let plain = TimerToolModel()
        plain.open(initial: nil, focusRunning: true)
        XCTAssertEqual(plain.mode, .focus, "a running session opens in Focus")
        let idle = TimerToolModel()
        idle.open(initial: nil, focusRunning: false)
        XCTAssertEqual(idle.mode, .timer)
    }

    /// A timer that ends while the panel is closed: nothing ticks then; on open the dock's
    /// Timer slot reads from the clock and is no longer live.
    func testDockLiveClearsWhenTimerEnds() {
        let r = HomeRenders.builtIns(meeting: false)
        let time = r.registry.widget(TimeWidget.widgetID) as! TimeWidget
        XCTAssertTrue(time.startTimer(duration: 60, label: "Tea"))
        let during = HomeData.make(today: r.today, widgets: r.registry, settings: HomeSettings(), tourSample: nil,
                                   now: Date(), dropping: false)
        XCTAssertTrue(during.dock[0].live)
        let later = HomeData.make(today: r.today, widgets: r.registry, settings: HomeSettings(), tourSample: nil,
                                  now: Date().addingTimeInterval(120), dropping: false)
        XCTAssertFalse(later.dock[0].live)
        XCTAssertEqual(later.dock[0].label, "Timer")
        r.registry.stopAll()
    }

    func testEscAndCommandBracketGoBack() {
        let r = HomeRenders.builtIns(meeting: false)
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.debugHandle(.layout(HomeRenders.layout))
        c.expand(tab: PanelTools.timer)
        XCTAssertEqual(c.panelModel.route.tool, PanelTools.timer)
        c.escapePressed()
        XCTAssertNil(c.panelModel.route.tool)
        c.expand(tab: PanelTools.timer)
        XCTAssertTrue(c.commandBracket())
        XCTAssertNil(c.panelModel.route.tool)
        XCTAssertFalse(c.commandBracket(), "nothing to go back from")
        let bracket = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "[", charactersIgnoringModifiers: "[",
                                       isARepeat: false, keyCode: 33)!
        XCTAssertTrue(NotchPanel.isCommandBracket(bracket))
        r.registry.stopAll()
    }
}
