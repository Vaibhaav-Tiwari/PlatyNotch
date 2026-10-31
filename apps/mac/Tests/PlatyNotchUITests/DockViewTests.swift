import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// The dock on Home (Island spec 3.3, 3.4).
@MainActor
final class DockViewTests: DefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_450_000)
    private let all: Set<String> = ["time", "focus", "notes", "reminders", "clipboard", "shelf", "games"]

    private func items(enabled: Set<String>? = nil, timers: [CountdownTimer] = [], focus: FocusTimer? = nil,
                       due: Int = 0, shelf: Int = 0) -> [DockItemState] {
        DockState.items(layout: .standard, toolTitles: [:], enabledWidgets: enabled ?? all, focus: focus, timers: timers,
                        stopwatch: nil, remindersDue: due, shelfCount: shelf, searchKey: "⌥⌘K", now: now)
    }

    private func focus(left: TimeInterval) -> FocusTimer {
        var f = FocusTimer(minutes: 25)
        f.start(at: now.addingTimeInterval(-(1500 - left)))
        return f
    }

    func testEightSlotsInOrder() {
        XCTAssertEqual(DockView.labels(items()),
                       ["Timer", "Note", "Remind", "Clipboard", "Shelf", "Memory", "Games", "⌥⌘K"])
    }

    func testBadgesAndLive() {
        let list = items(focus: focus(left: 1122), due: 3)
        XCTAssertEqual(list.first { $0.slot == .core(.remind) }?.badge, "3")
        let timer = list[0]
        XCTAssertEqual(timer.label, "18:42")
        XCTAssertEqual(DockButton.tone(timer), .needsYou)
        XCTAssertNil(DockButton.tone(list[1]))
    }

    func testTapRoutesToTool() {
        for t in DockTool.allCases {
            XCTAssertEqual(ExpandedPanel.route(for: .core(t)), PanelRoute(destination: .home, tool: t.toolID), "\(t)")
        }
        XCTAssertEqual(ExpandedPanel.route(for: .core(.remind)), PanelRoute(destination: .home, tool: "reminders"))
        XCTAssertEqual(ExpandedPanel.route(for: .tool("baskets")), PanelRoute(destination: .home, tool: "baskets"))
    }

    func testSearchSlotOpensSearch() {
        XCTAssertEqual(ExpandedPanel.route(for: .core(.search)).tool, PanelTools.search)
        let r = HomeRenders.builtIns(meeting: false)
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.debugHandle(.layout(HomeRenders.layout))
        c.openSearch()
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home, tool: PanelTools.search))
        XCTAssertTrue(c.panelModel.commandFocused, "the field takes focus")
        r.registry.stopAll()
    }

    func testOffSlotOpensTurnOn() {
        let r = HomeRenders.builtIns(meeting: false)
        r.registry.setEnabled(RemindersWidget.widgetID, false)
        let list = items(enabled: all.subtracting(["reminders"]))
        let remind = list.first { $0.slot == .core(.remind) }!
        XCTAssertFalse(remind.available)
        XCTAssertEqual(DockButton.labelInk(remind), Ink.tertiary, "dimmed")
        let tool = ToolCatalog.tool("reminders", widgets: r.registry, extraTabs: [], memory: { AnyView(EmptyView()) })
        XCTAssertEqual(tool?.title, "Remind")
        XCTAssertEqual(tool?.offWidgetID, RemindersWidget.widgetID)
        XCTAssertEqual(ToolOffView.title(for: "Remind"), "Turn on Remind")
        ToolCatalog.turnOn(tool!, widgets: r.registry)
        XCTAssertTrue(r.registry.isEnabled(RemindersWidget.widgetID))
        r.registry.stopAll()
    }

    func testFoldedShowsOneSearchSlot() {
        XCTAssertEqual(DockView.labels(items(), folded: true), ["All tools"])
    }

    func testDockFitsThePanel() {
        let host = NSHostingView(rootView: DockView(items: items(due: 120, shelf: 5), onOpen: { _ in })
            .environment(\.colorScheme, .dark).environment(\.panelTicking, false))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 640 - 2 * Space.panelSide)
    }

    func testAccessibilityLabels() {
        let list = items(enabled: all.subtracting(["notes"]), focus: focus(left: 1122), due: 3)
        XCTAssertEqual(DockView.accessibilityLabel(list.first { $0.slot == .core(.remind) }!), "Remind, 3 due")
        XCTAssertEqual(DockView.accessibilityLabel(list[0]), "Timer, 18:42 left")
        XCTAssertEqual(DockView.accessibilityLabel(list.first { $0.slot == .core(.note) }!), "Note, off")
        XCTAssertEqual(DockView.accessibilityLabel(list.first { $0.slot == .core(.search) }!), "Search, ⌥⌘K")
    }
}
