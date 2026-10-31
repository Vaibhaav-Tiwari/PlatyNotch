import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class HeaderTogglesTests: DefaultsTestCase {
    private final class FakePower: PowerSourceReading {
        var state: BatteryState?
        func read() -> BatteryState? { state }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
    }

    private func services() -> HeaderServices {
        HeaderServices(keepAwake: KeepAwake(asserter: FakeAsserter()), power: FakePower(), defaults: defaults())
    }

    /// Hands out an assertion id, like macOS does.
    private final class FakeAsserter: PowerAsserting {
        private(set) var live: Set<UInt32> = []
        func begin(reason: String) -> UInt32? { live.insert(7); return 7 }
        func end(_ id: UInt32) { live.remove(id) }
    }

    func testClickStartsPreferredDuration() {
        let s = services()
        s.toggleKeepAwake()
        XCTAssertEqual(s.keepAwake.session?.duration, .twoHours)
        s.stop()
    }

    /// The Mac slept past the deadline: the icon already shows off, so the click starts a new run.
    func testClickAfterExpiredSessionStartsNewRun() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let k = KeepAwake(asserter: FakeAsserter(), clock: { now })
        let s = HeaderServices(keepAwake: k, power: FakePower(), defaults: defaults())
        s.startKeepAwake(.thirtyMinutes)
        now = now.addingTimeInterval(3 * 3600)
        s.toggleKeepAwake()
        XCTAssertNotNil(k.session)
        XCTAssertEqual(k.session?.startedAt, now)
        s.stop()
    }

    func testSecondClickStops() {
        let s = services()
        s.toggleKeepAwake()
        s.toggleKeepAwake()
        XCTAssertNil(s.keepAwake.session)
        XCTAssertFalse(s.keepAwake.holdsAssertion)
    }

    func testChosenDurationIsRemembered() {
        let s = services()
        s.startKeepAwake(.oneHour)
        s.toggleKeepAwake()   // off
        s.toggleKeepAwake()   // on again with the last choice
        XCTAssertEqual(s.keepAwake.session?.duration, .oneHour)
    }

    func testMirrorClickTurnsMirrorOn() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        XCTAssertFalse(registry.isEnabled(MirrorWidget.widgetID))
        var route = PanelRoute(destination: .now)
        HeaderToggles.openMirror(registry: registry, route: &route)
        XCTAssertTrue(registry.isEnabled(MirrorWidget.widgetID))
        XCTAssertEqual(route.destination, .library)
        XCTAssertEqual(route.tool, MirrorWidget.widgetID)
    }

    func testWorksWithSystemWidgetOff() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(SystemWidget.inert())
        registry.setEnabled(SystemWidget.widgetID, false)
        let asserter = FakeAsserter()
        let s = HeaderServices(keepAwake: KeepAwake(asserter: asserter), power: FakePower(), defaults: defaults())
        s.toggleKeepAwake()
        XCTAssertTrue(s.keepAwake.holdsAssertion)
        XCTAssertFalse(asserter.live.isEmpty)
    }

    /// The System tile and the header share one assertion; turning the widget off leaves a started keep awake alone.
    func testSharedKeepAwakeSurvivesWidgetOff() {
        let asserter = FakeAsserter()
        let shared = KeepAwake(asserter: asserter)
        let w = SystemWidget(power: NoPowerSource(), asserter: NoPowerAsserter(), headphones: NoHeadphones(),
                             downloads: .none, defaults: defaults(), persist: false, keepAwake: shared)
        XCTAssertTrue(w.keepAwake === shared)
        shared.start(.oneHour)
        w.disabled()
        XCTAssertTrue(shared.holdsAssertion)
    }

    func testBatteryBadgeFollowsReading() {
        let power = FakePower()
        power.state = BatteryState(percent: 64, charging: true, pluggedIn: true, minutesRemaining: nil)
        let s = HeaderServices(keepAwake: KeepAwake(asserter: FakeAsserter()), power: power, defaults: defaults())
        XCTAssertEqual(HeaderBattery.badge(s.battery)?.text, "64% charging")
    }

    /// With everything showing (battery, keep awake with its time) the toggles stay within the nav row.
    func testTogglesFitTheNavRow() {
        let power = FakePower()
        power.state = BatteryState(percent: 64, charging: true, pluggedIn: true, minutesRemaining: nil)
        let s = HeaderServices(keepAwake: KeepAwake(asserter: FakeAsserter()), power: power, defaults: defaults())
        s.toggleKeepAwake()
        var route = PanelRoute(destination: .now)
        let view = HeaderToggles(services: s, widgets: WidgetRegistry(defaults: defaults(), persist: false),
                                 route: Binding(get: { route }, set: { route = $0 }), onOpenSettings: {},
                                 fixedNow: Date())
            .environment(\.panelTicking, false)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        XCTAssertLessThanOrEqual(size.height, NowMetrics.nav)
        XCTAssertLessThan(size.width, 260)
        s.stop()
    }
}
