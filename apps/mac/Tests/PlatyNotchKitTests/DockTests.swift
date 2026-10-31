import Foundation
import PlatyNotchKit
import XCTest

/// The dock (Island spec 3.3, 3.4).
final class DockTests: DefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_450_000)
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let all: Set<String> = ["time", "focus", "notes", "reminders", "clipboard", "shelf", "games"]

    private func items(_ layout: DockLayout = .standard, titles: [String: String] = [:], enabled: Set<String>? = nil,
                       focus: FocusTimer? = nil, timers: [CountdownTimer] = [], stopwatch: Stopwatch? = nil,
                       due: Int = 0, shelf: Int = 0, key: String? = "⌥⌘K") -> [DockItemState] {
        DockState.items(layout: layout, toolTitles: titles, enabledWidgets: enabled ?? all, focus: focus, timers: timers,
                        stopwatch: stopwatch, remindersDue: due, shelfCount: shelf, searchKey: key, now: now)
    }

    private func item(_ t: DockTool, in list: [DockItemState]) -> DockItemState? {
        list.first { $0.slot == .core(t) }
    }

    private func running(_ seconds: TimeInterval, label: String = "") -> CountdownTimer {
        CountdownTimer(label: label, duration: seconds, startedAt: now)
    }

    func testStandardDock() {
        XCTAssertEqual(DockLayout.standard.slots,
                       [.timer, .note, .remind, .clipboard, .shelf, .memory, .games, .search].map(DockSlot.core))
        XCTAssertEqual(DockLayout.maxSlots, 8)
        XCTAssertEqual(DockTool.allCases.map(\.title),
                       ["Timer", "Note", "Remind", "Clipboard", "Shelf", "Memory", "Games", "Search"])
        XCTAssertEqual(DockTool.allCases.map(\.symbol), ["timer", "note.text", "checklist", "doc.on.clipboard", "tray",
                                                         "brain", "gamecontroller", "magnifyingglass"])
        XCTAssertEqual(DockTool.allCases.map(\.toolID),
                       ["timer", "notes", "reminders", "clipboard", "shelf", "memory", "games", "search"])
        XCTAssertEqual(DockTool.timer.widgetIDs, ["time", "focus"])
        XCTAssertEqual(DockTool.memory.widgetIDs, [])
        XCTAssertEqual(DockTool.search.widgetIDs, [])
    }

    func testSearchAlwaysPresentAndLast() {
        XCTAssertEqual(DockLayout(slots: [.core(.timer)]).slots, [.core(.timer), .core(.search)])
        XCTAssertEqual(DockLayout(slots: [.core(.timer), .core(.timer), .core(.note)]).slots,
                       [.core(.timer), .core(.note), .core(.search)], "duplicates dropped")
        let ten = DockLayout(slots: DockTool.allCases.filter { $0 != .search }.map(DockSlot.core)
                             + [.tool("a"), .tool("b"), .tool("c")])
        XCTAssertEqual(ten.slots.count, 8)
        XCTAssertTrue(ten.slots.contains(.core(.search)), "Search is kept when the dock is cut to 8")
    }

    func testNinthRefused() {
        var d = DockLayout.standard
        XCTAssertFalse(d.add(.tool("baskets")))
        XCTAssertEqual(d.slots.count, 8)
        var small = DockLayout(slots: [.core(.timer)])
        XCTAssertTrue(small.add(.tool("baskets")))
        XCTAssertFalse(small.add(.tool("baskets")), "already there")
    }

    func testSearchCannotBeRemoved() {
        var d = DockLayout.standard
        XCTAssertFalse(d.remove(.core(.search)))
        XCTAssertTrue(d.remove(.core(.games)))
        XCTAssertFalse(d.slots.contains(.core(.games)))
    }

    func testMoveAndRoundTrip() {
        var d = DockLayout.standard
        d.move(fromOffsets: IndexSet(integer: 6), toOffset: 0)
        XCTAssertEqual(d.slots.first, .core(.games))
        _ = d.remove(.core(.memory))
        XCTAssertTrue(d.add(.tool("baskets")))
        d.save(to: defaults())
        XCTAssertEqual(DockLayout.load(from: defaults()), d)
        let json = String(decoding: try! JSONEncoder().encode(DockSlot.tool("baskets")), as: UTF8.self)
        XCTAssertEqual(json, #""tool:baskets""#)
        XCTAssertEqual(String(decoding: try! JSONEncoder().encode(DockSlot.core(.timer)), as: UTF8.self), #""timer""#)
        XCTAssertEqual(DockLayout.key, "dock.layout")
    }

    func testDamagedSavedValueIsStandard() {
        XCTAssertEqual(DockLayout.load(from: defaults()), .standard)
        defaults().set(Data("x".utf8), forKey: DockLayout.key)
        XCTAssertEqual(DockLayout.load(from: defaults()), .standard)
    }

    func testBadges() {
        XCTAssertNil(DockState.badge(0))
        XCTAssertEqual(DockState.badge(3), "3")
        XCTAssertEqual(DockState.badge(99), "99")
        XCTAssertEqual(DockState.badge(120), "99+")
    }

    func testRemindAndShelfBadges() {
        let list = items(due: 3, shelf: 2)
        XCTAssertEqual(item(.remind, in: list)?.badge, "3")
        XCTAssertEqual(item(.shelf, in: list)?.badge, "2")
        for t in DockTool.allCases where t != .remind && t != .shelf {
            XCTAssertNil(item(t, in: list)?.badge, "\(t)")
        }
    }

    func testTimerLiveOrder() {
        var focus = FocusTimer(minutes: 25)
        focus.start(at: now.addingTimeInterval(-(1500 - 1122)))   // 18:42 left
        let tea = running(190, label: "Tea")
        let withFocus = item(.timer, in: items(focus: focus, timers: [tea]))
        XCTAssertEqual(withFocus?.label, "18:42")
        XCTAssertEqual(withFocus?.live, true)
        XCTAssertEqual(item(.timer, in: items(timers: [tea, running(600)]))?.label, "3:10", "the soonest timer")
        let sw = Stopwatch(accumulated: 3725)
        var on = sw
        on.runningSince = now
        XCTAssertEqual(item(.timer, in: items(stopwatch: on))?.label, "1:02:05")
        XCTAssertEqual(item(.timer, in: items(stopwatch: sw))?.live, false, "a stopped stopwatch is not live")
    }

    func testEndedTimerIsNotLive() {
        let ended = CountdownTimer(duration: 60, startedAt: now.addingTimeInterval(-120))
        let t = item(.timer, in: items(timers: [ended]))
        XCTAssertEqual(t?.label, "Timer")
        XCTAssertEqual(t?.live, false)
    }

    func testOffWidgetSlotUnavailable() {
        let list = items(enabled: all.subtracting(["reminders"]))
        XCTAssertEqual(item(.remind, in: list)?.available, false)
        XCTAssertEqual(list.count, 8, "still present")
        XCTAssertEqual(item(.memory, in: list)?.available, true, "no widget needed")
        XCTAssertEqual(item(.timer, in: items(enabled: ["focus"]))?.available, true, "Timer needs time or focus")
        XCTAssertEqual(item(.timer, in: items(enabled: []))?.available, false)
    }

    func testMissingPluginDropsOutKeepsOrder() {
        let layout = DockLayout(slots: [.tool("plugin:x"), .core(.timer), .tool("baskets")])
        let list = items(layout, titles: ["baskets": "Baskets"])
        XCTAssertEqual(list.map(\.slot), [.core(.timer), .tool("baskets"), .core(.search)])
        XCTAssertEqual(list[1].label, "Baskets")
        XCTAssertEqual(layout.slots.first, .tool("plugin:x"), "the saved order is kept")
    }

    func testSearchLabel() {
        XCTAssertEqual(item(.search, in: items(key: "⌥⌘K"))?.label, "⌥⌘K")
        XCTAssertEqual(item(.search, in: items(key: nil))?.label, "Search")
    }

    func testRemindersDueCount() {
        let today9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        let items: [ReminderItem] = [
            ReminderItem(id: "a", title: "overdue", due: now.addingTimeInterval(-86_400 * 2), hasTime: false),
            ReminderItem(id: "b", title: "today timed", due: today9, hasTime: true),
            ReminderItem(id: "c", title: "today day", due: cal.startOfDay(for: now), hasTime: false),
            ReminderItem(id: "d", title: "tomorrow", due: now.addingTimeInterval(86_400 + 3600), hasTime: true),
            ReminderItem(id: "e", title: "undated", due: nil, hasTime: false),
        ]
        XCTAssertEqual(RemindersDue.count(items, now: now, calendar: cal), 3)
    }
}
