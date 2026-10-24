import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
private final class FakeWidget: NotchWidget {
    let id: String
    let title: String
    let systemImage = "star"
    let defaultEnabled: Bool
    var starts = 0
    var stops = 0
    var disables = 0
    var live: [LiveActivity] = []
    var liveActivities: [LiveActivity] { live }

    init(_ id: String, defaultEnabled: Bool = true) {
        self.id = id
        self.title = id.capitalized
        self.defaultEnabled = defaultEnabled
    }

    func start(context: WidgetContext) { starts += 1 }
    func stop() { stops += 1 }
    func disabled() { disables += 1 }
    func tileView() -> AnyView { AnyView(Text(verbatim: title)) }
}

@MainActor
final class WidgetRegistryTests: DefaultsTestCase {



    private func context() -> WidgetContext {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnwidget\(UUID().uuidString)")
        return WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                             config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                             events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                             openPanel: { _ in })
    }

    /// Disabled widgets do no work: never started, and stopped when turned off.
    func testDisabledWidgetsNeverStart() {
        let registry = WidgetRegistry(defaults: defaults())
        let on = FakeWidget("music")
        let off = FakeWidget("weather", defaultEnabled: false)
        registry.register(on)
        registry.register(off)
        XCTAssertEqual(on.starts, 0)   // nothing runs before the app starts the registry
        registry.start(context: context())
        XCTAssertEqual(on.starts, 1)
        XCTAssertEqual(off.starts, 0)
        XCTAssertEqual(registry.visibleWidgets.map(\.id), ["music"])

        registry.setEnabled("music", false)
        XCTAssertEqual(on.stops, 1)
        XCTAssertTrue(registry.visibleWidgets.isEmpty)
        registry.setEnabled("music", false)   // already off: no second stop
        XCTAssertEqual(on.stops, 1)

        registry.setEnabled("weather", true)
        XCTAssertEqual(off.starts, 1)
        registry.setEnabled("weather", true)  // already on: no second start
        XCTAssertEqual(off.starts, 1)

        registry.stopAll()
        XCTAssertEqual(off.stops, 1)
        XCTAssertEqual(on.stops, 1)           // was not running
    }

    func testLateRegistrationStartsOnlyWhenEnabled() {
        let registry = WidgetRegistry(defaults: defaults())
        registry.start(context: context())
        let late = FakeWidget("late")
        let lateOff = FakeWidget("lateOff", defaultEnabled: false)
        registry.register(late)
        registry.register(lateOff)
        XCTAssertEqual(late.starts, 1)
        XCTAssertEqual(lateOff.starts, 0)
    }

    func testDuplicateIDIgnored() {
        let registry = WidgetRegistry(defaults: defaults())
        let a = FakeWidget("music")
        let b = FakeWidget("music")
        registry.register(a)
        registry.register(b)
        registry.start(context: context())
        XCTAssertEqual(registry.widgets.count, 1)
        XCTAssertEqual(a.starts, 1)
        XCTAssertEqual(b.starts, 0)
    }

    func testLayoutPersistsAndUserChoiceSurvivesRelaunch() {
        let d = defaults()
        let first = WidgetRegistry(defaults: d)
        first.register(FakeWidget("a"))
        first.register(FakeWidget("b"))
        first.register(FakeWidget("c", defaultEnabled: false))
        first.setEnabled("a", false)
        first.move("b", to: 0)

        let relaunched = WidgetRegistry(defaults: d)
        relaunched.register(FakeWidget("a"))
        relaunched.register(FakeWidget("b"))
        relaunched.register(FakeWidget("c", defaultEnabled: false))
        XCTAssertEqual(relaunched.orderedWidgets.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(relaunched.visibleWidgets.map(\.id), ["b"])
    }

    func testReadOnlyRegistryNeverWrites() {
        let d = defaults()
        let registry = WidgetRegistry(defaults: d, persist: false)
        registry.register(FakeWidget("a"))
        registry.setEnabled("a", false)
        XCTAssertNil(d.data(forKey: WidgetLayout.key))
        XCTAssertFalse(registry.isEnabled("a"))
    }

    /// Only running widgets feed the pill; order follows the user's layout.
    func testLiveActivitiesOnlyFromRunningWidgets() {
        let registry = WidgetRegistry(defaults: defaults())
        let music = FakeWidget("music")
        let focus = FakeWidget("focus")
        music.live = [LiveActivity(id: "music:playing", widgetID: "music", priority: LivePriority.musicPlaying, glyph: .musicBars)]
        focus.live = [LiveActivity(id: "focus:session", widgetID: "focus", priority: LivePriority.focusSession,
                                   glyph: .symbol("moon.fill"))]
        registry.register(music)
        registry.register(focus)
        XCTAssertTrue(registry.liveActivities.isEmpty)   // not started yet
        registry.start(context: context())
        XCTAssertEqual(registry.liveActivities.map(\.id), ["music:playing", "focus:session"])
        // Music playing and focus running: focus owns the pill, music gets the bubble.
        let pick = LiveArbiter.pick(registry.liveActivities, now: Date())
        XCTAssertEqual(pick.primary?.id, "focus:session")
        XCTAssertEqual(pick.bubble?.id, "music:playing")
        registry.setEnabled("music", false)
        XCTAssertEqual(registry.liveActivities.map(\.id), ["focus:session"])
    }

    func testPluginContextRegistersWidgets() {
        let registry = WidgetRegistry(defaults: defaults())
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnplugw\(UUID().uuidString)")
        let ctx = PluginContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                events: CoreEventHub(), runner: CoreRunner(binaryURL: dir.appendingPathComponent("notch")),
                                widgets: registry, openSettings: { _ in })
        ctx.register(widget: FakeWidget("pro.phone", defaultEnabled: false))
        XCTAssertEqual(registry.orderedWidgets.map(\.id), ["pro.phone"])
        XCTAssertFalse(registry.isEnabled("pro.phone"))
    }

    func testNoopNotifierIsUnavailable() async {
        let n = NoopNotifier()
        XCTAssertFalse(n.isAvailable)
        let granted = await n.requestAuthorization()
        XCTAssertFalse(granted)
        let added = await n.schedule(id: "x", title: "t", body: "b", at: nil)
        XCTAssertFalse(added)
        n.cancel(id: "x")
        // `swift test` runs unbundled, so the app picks the no-op notifier.
        XCTAssertFalse(Notifiers.make().isAvailable)
    }

    func testBuiltInsHaveThePlanIDs() {
        let registry = WidgetRegistry(defaults: defaults())
        let today = TodayServices(client: CoreClient(socketPath: "/nonexistent"))
        BuiltInWidgets.register(in: registry, store: AppStore(), today: today, persist: false)
        let everyday = ["music", "meeting", "focus", "loops", "time", "hud", "shelf", "clipboard",
                        "reminders", "weather", "wellbeing", "system", "games", "launch"]
        XCTAssertEqual(registry.orderedWidgets(in: .everyday).map(\.id), everyday)
        XCTAssertEqual(Array(registry.orderedWidgets.prefix(everyday.count)).map(\.id), everyday,
                       "power features follow the everyday widgets")
        XCTAssertEqual(registry.visibleWidgets.count, 9,
                       "the HUD (needs Accessibility), clipboard history (C22), Reminders (private data), weather (network) "
                       + "and wellbeing (nudges interrupt) are off by default")
        XCTAssertFalse(registry.isEnabled(WellbeingWidget.widgetID))
        XCTAssertTrue(registry.isEnabled(GamesWidget.widgetID), "on by default; does nothing until played")
        XCTAssertTrue(registry.isEnabled(LaunchWidget.widgetID), "on by default; no network until a site is pinned")
        XCTAssertFalse(registry.isEnabled(RemindersWidget.widgetID))
        XCTAssertFalse(registry.isEnabled(WeatherWidget.widgetID))
        XCTAssertFalse(registry.isEnabled(ClipboardWidget.widgetID))
        XCTAssertTrue(registry.isEnabled(ShelfWidget.widgetID), "the shelf needs no permission and is on")
        XCTAssertFalse(registry.isEnabled(HUDWidget.widgetID))
        XCTAssertTrue(registry.isEnabled(SystemWidget.widgetID), "battery and keep-awake need no permission")
        for id in [FileActionsWidget.widgetID, WindowSnapWidget.widgetID, NotesWidget.widgetID] {
            XCTAssertTrue(registry.orderedWidgets(in: .power).contains { $0.id == id })
            XCTAssertFalse(registry.isEnabled(id), "power features are off by default")
        }
    }

    /// Turning a widget off calls `disabled()` after `stop`; quitting (`stopAll`) does not.
    func testDisableCallsDisabledButQuitDoesNot() {
        let registry = WidgetRegistry(defaults: defaults())
        let a = FakeWidget("a")
        let b = FakeWidget("b")
        registry.register(a)
        registry.register(b)
        registry.start(context: context())
        registry.setEnabled("a", false)
        XCTAssertEqual(a.stops, 1)
        XCTAssertEqual(a.disables, 1)
        registry.stopAll()
        XCTAssertEqual(b.stops, 1)
        XCTAssertEqual(b.disables, 0)
        XCTAssertEqual(a.disables, 1)
    }
}
