import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Never the real idle state: a value the test sets, and a count of reads.
@MainActor
private final class FakeIdle: IdleClock {
    var seconds: TimeInterval = 0
    var reads = 0
    func secondsSinceLastInput() -> TimeInterval {
        reads += 1
        return seconds
    }
}

@MainActor
private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

/// The wellbeing widget through the real registry, `PanelSurfaces` and a `NotchController`
/// (no window; the cursor is pinned).
@MainActor
final class WellbeingWidgetTests: XCTestCase {
    nonisolated(unsafe) private var suites: [String] = []
    nonisolated(unsafe) private var registries: [WidgetRegistry] = []

    override func tearDown() async throws {
        await MainActor.run {
            for r in registries { r.stopAll() }   // no task outlives its test
            registries = []
            for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
            suites = []
        }
        try await super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "WellbeingWidgetTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    /// 2026-10-21 14:00 New York: outside the default quiet hours.
    private var afternoon: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14))! }

    @MainActor private struct Rig {
        let widget: WellbeingWidget
        let registry: WidgetRegistry
        let surfaces: PanelSurfaces
        let controller: NotchController
        let idle: FakeIdle
        let clock: Clock
        let defaults: UserDefaults
        var now: Date { clock.now }
    }

    /// `overdue`: every nudge last done 90 minutes ago (so all are due), saved before start.
    private func rig(enabled: Bool = true, overdue: Bool = true, inMeeting: @escaping () -> Bool = { false },
                     defaults givenDefaults: UserDefaults? = nil) -> Rig {
        let d = givenDefaults ?? defaults()
        let clock = Clock(afternoon)
        if overdue {
            let past = clock.now.addingTimeInterval(-90 * 60)
            let p = NudgeProgress(lastDone: [.water: past, .stand: past, .eyes: past])
            d.set(try! JSONEncoder().encode(p), forKey: NudgeProgress.key)
        }
        let idle = FakeIdle()
        let w = WellbeingWidget(defaults: d, idle: idle, clock: { clock.now }, calendar: calendar,
                                inMeeting: inMeeting, watchSystem: false)
        let client = CoreClient(socketPath: "/nonexistent")
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registries.append(registry)
        let surfaces = PanelSurfaces(registry: registry)
        registry.register(w)
        if enabled { registry.setEnabled(WellbeingWidget.widgetID, true) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnwell\(UUID().uuidString)")
        let c = NotchController(store: AppStore(), client: client, plugins: [], widgets: registry, surfaces: surfaces,
                                minimal: false)
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        registry.start(context: WidgetContext(store: AppStore(), client: client,
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: d, notify: NoopNotifier(),
                                              surfaces: surfaces, openPanel: { _ in }))
        return Rig(widget: w, registry: registry, surfaces: surfaces, controller: c, idle: idle, clock: clock, defaults: d)
    }

    private let peek = PanelMode.peek(.widget(id: WellbeingWidget.peekID))

    // MARK: - Off by default, disabled does no work

    func testOffByDefaultAndDisabledDoesNoWork() {
        let r = rig(enabled: false)
        XCTAssertFalse(r.widget.defaultEnabled)
        XCTAssertFalse(r.registry.isEnabled(WellbeingWidget.widgetID), "off by default")
        XCTAssertFalse(r.widget.running)
        r.widget.check()
        XCTAssertNil(r.widget.nextWake, "no timer")
        XCTAssertEqual(r.idle.reads, 0, "no idle reads")

        r.registry.setEnabled(WellbeingWidget.widgetID, true)
        XCTAssertTrue(r.widget.running)
        XCTAssertNotNil(r.widget.nextWake)
        XCTAssertGreaterThanOrEqual(r.widget.nextWake!, r.now.addingTimeInterval(NudgeScheduler.resumeGrace),
                                    "no card right after it starts")
        XCTAssertEqual(r.idle.reads, 0, "starting reads nothing")

        r.widget.addGlass()
        r.registry.setEnabled(WellbeingWidget.widgetID, false)
        XCTAssertFalse(r.widget.running)
        XCTAssertNil(r.widget.nextWake)
        r.widget.check()
        XCTAssertEqual(r.idle.reads, 0)
        XCTAssertEqual(r.widget.glassesToday(), 1, "disabled() keeps the water log")
        XCTAssertTrue(r.widget.progress.lastDone.isEmpty, "intervals start afresh when turned on again")
    }

    func testAllIntervalsOffMeansNoTimer() {
        let r = rig()
        r.widget.update(NudgeSettings(water: 0, stand: 0, eyes: 0))
        XCTAssertNil(r.widget.nextWake)
        r.widget.check()
        XCTAssertNil(r.widget.nextWake)
        XCTAssertEqual(r.idle.reads, 0)
    }

    // MARK: - Cards through the controller

    func testEyesCardShowsWithRingLengthAndDone() {
        let r = rig()
        r.widget.check()
        XCTAssertEqual(r.idle.reads, 1, "one idle read per check")
        XCTAssertEqual(r.widget.nudge?.kind, .eyes, "eyes beats stand beats water")
        XCTAssertEqual(r.widget.nudge?.until, r.now.addingTimeInterval(NudgeScheduler.eyesBreak))
        XCTAssertEqual(r.controller.mode, peek)
        XCTAssertFalse(r.controller.mode.canBecomeKey, "the card never takes focus")
        XCTAssertNotNil(r.registry.peekView(id: WellbeingWidget.peekID))
        XCTAssertNil(r.registry.peekView(id: "other.peek"))

        r.widget.done(.eyes)
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.controller.mode, .compact)
        XCTAssertEqual(r.widget.progress.lastDone[.eyes], r.now)
        XCTAssertGreaterThanOrEqual(r.widget.nextWake!, r.now.addingTimeInterval(NudgeScheduler.spacing),
                                    "stand is due too, but not in a burst")

        // Persisted as small Codable values.
        let saved = try? JSONDecoder().decode(NudgeProgress.self, from: r.defaults.data(forKey: NudgeProgress.key) ?? Data())
        XCTAssertEqual(saved?.lastDone[.eyes], r.now)
    }

    func testSpacingBetweenCards() {
        let r = rig()
        r.widget.check()
        r.widget.done(.eyes)
        r.clock.advance(60)
        r.widget.check()
        XCTAssertNil(r.widget.nudge, "a minute later: still spaced")
        r.clock.advance(NudgeScheduler.spacing)
        r.widget.check()
        XCTAssertEqual(r.widget.nudge?.kind, .stand)
        XCTAssertEqual(r.widget.nudge?.until, r.now.addingTimeInterval(NudgeScheduler.peekDuration), "10 s card")
    }

    func testWaterCardPlusOneGlass() {
        let r = rig()
        var s = NudgeSettings()
        s.eyes = 0
        s.stand = 0
        r.widget.update(s)
        // Turning nudges off leaves water's (overdue) time alone.
        r.widget.check()
        XCTAssertEqual(r.widget.nudge?.kind, .water)
        r.widget.addGlass()
        XCTAssertEqual(r.widget.glassesToday(), 1)
        XCTAssertEqual(r.controller.mode, .compact)
        XCTAssertEqual(r.widget.progress.lastDone[.water], r.now)
        // A new instance on the same defaults reads the log back.
        let again = WellbeingWidget(defaults: r.defaults, idle: FakeIdle(), clock: { [clock = r.clock] in clock.now },
                                    calendar: calendar, watchSystem: false)
        XCTAssertEqual(again.glassesToday(), 1)
    }

    func testSnoozeAndUnansweredCards() {
        let r = rig()
        r.widget.check()
        r.widget.snooze(.eyes)
        XCTAssertEqual(r.widget.progress.snoozedUntil[.eyes], r.now.addingTimeInterval(NudgeScheduler.snooze))
        XCTAssertEqual(r.controller.mode, .compact)

        // Stand shows after the spacing; nobody answers: counts as a snooze.
        r.clock.advance(NudgeScheduler.spacing)
        r.widget.check()
        XCTAssertEqual(r.widget.nudge?.kind, .stand)
        r.clock.advance(NudgeScheduler.peekDuration + 1)
        r.widget.check()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.widget.progress.snoozedUntil[.stand], r.now.addingTimeInterval(NudgeScheduler.snooze))
    }

    func testEyesCardWithoutInputCountsAsDone() {
        let r = rig()
        r.widget.check()
        XCTAssertEqual(r.widget.nudge?.kind, .eyes)
        r.clock.advance(NudgeScheduler.eyesBreak + 1)
        r.idle.seconds = NudgeScheduler.eyesBreak   // no input during the ring: looked away
        r.widget.check()
        XCTAssertEqual(r.widget.progress.lastDone[.eyes], r.now)
        XCTAssertNil(r.widget.progress.snoozedUntil[.eyes])
    }

    /// Task 1b precedence, verified for this card: an approval beats it, and it shows when
    /// the approval is answered (while its time lasts).
    func testApprovalBeatsTheNudge() {
        let r = rig()
        r.controller.debugHandle(.event(.approvalsChanged(count: 1)))
        r.widget.check()
        XCTAssertNotNil(r.widget.nudge)
        XCTAssertEqual(r.controller.mode, .peek(.approval))
        r.controller.debugHandle(.event(.escape))
        XCTAssertEqual(r.controller.mode, .peek(.approval), "Escape never hides an approval")
        r.controller.debugHandle(.event(.approvalsChanged(count: 0)))
        XCTAssertEqual(r.controller.mode, peek)
    }

    /// Full screen through `PanelContextProvider` (C28): nothing is due, and a card already
    /// up is held by the panel (Task 1b).
    func testFullScreenSuppressesNudges() {
        let r = rig()
        XCTAssertFalse(r.surfaces.fullScreen)
        r.controller.debugHandle(.setFullScreen(true))
        XCTAssertTrue(r.surfaces.fullScreen)
        let provider: PanelContextProvider = r.surfaces
        XCTAssertTrue(provider.fullScreen)
        r.widget.check()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.widget.nextWake, r.now.addingTimeInterval(NudgeScheduler.minimumWake), "rechecks in a minute")

        r.controller.debugHandle(.setFullScreen(false))
        r.widget.check()
        XCTAssertEqual(r.controller.mode, peek)
        r.controller.debugHandle(.setFullScreen(true))
        XCTAssertNotEqual(r.controller.mode, peek, "held over full screen")
    }

    // MARK: - Idle, focus, meetings

    func testIdleIsABreakAndNoNudge() {
        let r = rig()
        let before = r.widget.progress.lastDone
        r.idle.seconds = NudgeScheduler.idleBreak
        r.widget.check()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.widget.progress.lastDone[.stand], r.now)
        XCTAssertEqual(r.widget.progress.lastDone[.eyes], r.now)
        XCTAssertEqual(r.widget.progress.lastDone[.water], before[.water], "idle is no glass of water")
        XCTAssertEqual(r.widget.nextWake, r.now.addingTimeInterval(NudgeScheduler.minimumWake), "a minute while away")

        r.clock.advance(60)
        r.idle.seconds = 3
        r.widget.check()
        XCTAssertEqual(r.widget.nudge?.kind, .water, "back: only water is still due")
    }

    func testFocusSessionHoldsNudges() {
        let r = rig()
        r.defaults.set(r.now.addingTimeInterval(600), forKey: FocusModel.untilKey)
        r.widget.check()
        XCTAssertNil(r.widget.nudge)
        r.defaults.removeObject(forKey: FocusModel.untilKey)
        r.widget.check()
        XCTAssertNotNil(r.widget.nudge)
    }

    func testMeetingHoldsNudges() {
        var meeting = true
        let r = rig(inMeeting: { meeting })
        r.widget.check()
        XCTAssertNil(r.widget.nudge)
        meeting = false
        r.widget.check()
        XCTAssertNotNil(r.widget.nudge)
    }

    func testMeetingSignalNeedsTheRunningMeetingWidget() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registries.append(registry)
        let calendar = CalendarService(eventKit: false)
        let meeting = MeetingWidget(calendar: calendar)
        registry.register(meeting)
        let signal = WellbeingWidget.meetingSignal(registry: registry, meeting: meeting)
        XCTAssertFalse(signal(), "not running")
        XCTAssertNotEqual(calendar.access, .granted)
        XCTAssertFalse(signal(), "no calendar access, no meeting state")
    }

    // MARK: - Sleep and lock

    func testSleepPausesAndWakeDoesNotBurst() {
        let r = rig()
        r.widget.check()
        XCTAssertNotNil(r.widget.nudge)
        r.widget.setPaused(.sleep, true)
        XCTAssertNil(r.widget.nudge, "the card goes with the sleep")
        XCTAssertEqual(r.controller.mode, .compact)
        XCTAssertNil(r.widget.nextWake, "no timer while asleep")
        let reads = r.idle.reads
        r.widget.check()
        XCTAssertEqual(r.idle.reads, reads, "nothing read while paused")

        r.widget.setPaused(.locked, true)
        r.clock.advance(3600)
        r.widget.setPaused(.sleep, false)
        XCTAssertNil(r.widget.nextWake, "still locked")
        r.widget.setPaused(.locked, false)
        XCTAssertEqual(r.widget.progress.lastDone[.stand], r.now, "an hour away was a break")
        XCTAssertEqual(r.widget.progress.lastDone[.eyes], r.now)
        XCTAssertGreaterThanOrEqual(r.widget.nextWake!, r.now.addingTimeInterval(NudgeScheduler.resumeGrace))
    }

    // MARK: - Settings

    func testSettingsPersistAndRestartTheChangedInterval() {
        let r = rig()
        var s = r.widget.settings
        s.stand = 30
        s.quietStart = 23
        s.dailyWaterGoal = 10
        r.widget.update(s)
        XCTAssertEqual(r.widget.progress.lastDone[.stand], r.now, "a changed interval counts from now")
        XCTAssertNotEqual(r.widget.progress.lastDone[.eyes], r.now)
        let saved = try? JSONDecoder().decode(NudgeSettings.self, from: r.defaults.data(forKey: NudgeSettings.key) ?? Data())
        XCTAssertEqual(saved, s)
    }

    func testViewsBuild() {
        let r = rig()
        r.widget.check()
        var views: [AnyView] = [r.widget.tileView()]
        if let s = r.widget.settingsView() { views.append(s) }
        for kind in NudgeKind.allCases {
            views.append(AnyView(NudgeCard(widget: r.widget, nudge: .init(kind: kind, shownAt: r.now, until: r.now))))
        }
        for v in views {
            let host = NSHostingView(rootView: v.frame(width: PanelLayout.surfaceWidth))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
        let card = NSHostingView(rootView: NudgeCard(widget: r.widget, nudge: r.widget.nudge!)
            .frame(width: PanelLayout.surfaceWidth - 24))
        XCTAssertLessThanOrEqual(card.fittingSize.height, PanelLayout.widgetPeekHeight, "fits the peek")
    }
}
