import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class NowNotificationsSettingsTests: DefaultsTestCase {
    private func registry() -> WidgetRegistry {
        let r = WidgetRegistry(defaults: defaults(), persist: false)
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, focus: FocusModel(defaults: defaults()))
        BuiltInWidgets.register(in: r, store: AppStore(), today: today, persist: false)
        return r
    }

    func testSlotPickerWritesSlots() {
        let d = defaults()
        GlanceSlots(ids: ["meeting", "weather"]).save(to: d)
        let model = NowSettingsModel(widgets: registry(), defaults: d)
        XCTAssertEqual(model.slots, ["meeting", "weather", nil, nil])
        XCTAssertTrue(model.options.contains { $0.id == GlanceSlots.usageID && $0.title == "Claude/Codex usage" })
        model.set(slot: 2, id: GlanceSlots.usageID)
        XCTAssertEqual(GlanceSlots.decode(d.data(forKey: GlanceSlots.key))?.ids, ["meeting", "weather", GlanceSlots.usageID])
        // A glance already in a slot swaps places: never in two slots.
        model.set(slot: 0, id: "weather")
        XCTAssertEqual(model.slots, ["weather", "meeting", GlanceSlots.usageID, nil])
        // Drag reorders.
        model.move(from: 2, to: 0)
        XCTAssertEqual(GlanceSlots.decode(d.data(forKey: GlanceSlots.key))?.ids, [GlanceSlots.usageID, "weather", "meeting"])
        model.set(slot: 1, id: nil)
        XCTAssertEqual(GlanceSlots.decode(d.data(forKey: GlanceSlots.key))?.ids, [GlanceSlots.usageID, "meeting"])
        // Hero cycling.
        model.setHeroCycling(false)
        XCTAssertFalse(NowSettings.load(from: d).heroCycling)
    }

    func testLockedApprovalToggles() {
        let d = defaults()
        let model = NotificationsModel(defaults: d)
        XCTAssertEqual(model.cell(.approval, .showInPill), .locked("Always"))
        XCTAssertEqual(model.cell(.approval, .canOpen), .locked("Always"))
        XCTAssertEqual(model.cell(.approval, .quietDuringFocus), .locked("Never"))
        model.set(.approval, .canOpen, false)
        XCTAssertEqual(model.cell(.approval, .canOpen), .locked("Always"), "a locked cell never changes")
        XCTAssertEqual(model.cell(.other, .canOpen), .toggle(false))
        model.set(.other, .canOpen, true)
        XCTAssertEqual(NotificationPolicy.load(from: d)[.other].canOpen, true, "saved at once")
        for kind in NotificationKind.where({ $0 != .approval }) {
            for field in NotificationsModel.fields {
                guard case .toggle = model.cell(kind, field) else { return XCTFail("\(kind) \(field) is a switch") }
            }
        }
        XCTAssertEqual(NotificationKind.allCases.map(NotificationsModel.title),
                       ["Approvals", "Agent needs you or stopped", "Agent finished", "Alarms and timers",
                        "Meeting starting", "Reminders you asked for", "Everything else", "Plug-ins without a kind"])
    }

    func testCyclingOffHidesArrows() {
        XCTAssertTrue(NowView.showsSteps(count: 3, cycling: true))
        XCTAssertFalse(NowView.showsSteps(count: 3, cycling: false), "no ‹ › with cycling off")
        XCTAssertFalse(NowView.showsSteps(count: 1, cycling: true))
        var deck = HeroDeck()
        let t = Date()
        let items: [LiveItem] = HeroDeck.items(PriorityModel.rank([
            LiveActivity(id: "a", widgetID: "music", priority: LivePriority.musicPlaying, glyph: .musicBars,
                         tint: .accent, accessibilityLabel: "Music", title: "Music"),
            LiveActivity(id: "b", widgetID: "time", priority: LivePriority.timerRunning, glyph: .symbol("timer"),
                         tint: .accent, accessibilityLabel: "Timer", title: "Timer"),
        ], agents: nil, now: t))
        XCTAssertEqual(items.count, 2)
        deck.step(1, in: items)
        XCTAssertEqual(NowView.heroIndex(deck: deck, items: items, cycling: true), 1)
        XCTAssertEqual(NowView.heroIndex(deck: deck, items: items, cycling: false), 0, "only the top item")
    }
}

private extension NotificationKind {
    static func `where`(_ keep: (NotificationKind) -> Bool) -> [NotificationKind] { allCases.filter(keep) }
}
