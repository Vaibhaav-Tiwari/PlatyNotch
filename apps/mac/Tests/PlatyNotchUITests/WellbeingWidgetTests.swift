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
final class WellbeingWidgetTests: DefaultsTestCase {
    nonisolated(unsafe) private var registries: [WidgetRegistry] = []

    override func tearDown() async throws {
        await MainActor.run {
            for r in registries { r.stopAll() }   // no task outlives its test
            registries = []
        }
        try await super.tearDown()
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

    private func context(_ registry: WidgetRegistry, _ surfaces: PanelSurfaces, _ d: UserDefaults) -> WidgetContext {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnwell\(UUID().uuidString)")
        return WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                             config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                             events: CoreEventHub(), defaults: d, notify: NoopNotifier(),
                             surfaces: surfaces, openPanel: { _ in })
    }

    /// `overdue`: every nudge last done 90 minutes ago (so all are due), saved before start.
    /// `pastGrace`: the clock moves past the start's resume grace, so a sample can show a card.
    private func rig(enabled: Bool = true, overdue: Bool = true, pastGrace: Bool = true,
                     inMeeting: @escaping () -> Bool = { false }, watchSystem: Bool = false,
                     defaults givenDefaults: UserDefaults? = nil, clock givenClock: Clock? = nil) -> Rig {
        let d = givenDefaults ?? defaults()
        let clock = givenClock ?? Clock(afternoon)
        if overdue {
            let past = clock.now.addingTimeInterval(-90 * 60)
            let p = NudgeProgress(lastDone: [.water: past, .stand: past, .eyes: past])
            d.set(try! JSONEncoder().encode(p), forKey: NudgeProgress.key)
        }
        let idle = FakeIdle()
        let w = WellbeingWidget(defaults: d, idle: idle, clock: { clock.now }, calendar: calendar,
                                inMeeting: inMeeting, watchSystem: watchSystem)
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registries.append(registry)
        let surfaces = PanelSurfaces(registry: registry)
        registry.register(w)
        if enabled { registry.setEnabled(WellbeingWidget.widgetID, true) }
        let c = NotchController(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"), plugins: [],
                                widgets: registry, surfaces: surfaces, appearance: AppearanceSettings())
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        registry.start(context: context(registry, surfaces, d))
        if enabled, pastGrace { clock.advance(NudgeScheduler.resumeGrace) }
        return Rig(widget: w, registry: registry, surfaces: surfaces, controller: c, idle: idle, clock: clock, defaults: d)
    }

    private let peek = PanelMode.peek(.widget(id: WellbeingWidget.peekID))

    private func dueDate(_ r: Rig, _ kind: NudgeKind) -> Date? {
        NudgeScheduler.dueDate(kind, r.widget.settings, lastDone: r.widget.progress.lastDone,
                               snoozedUntil: r.widget.progress.snoozedUntil)
    }

    // MARK: - Off by default, disabled does no work

    func testOffByDefaultAndDisabledDoesNoWork() {
        let r = rig(enabled: false)
        XCTAssertFalse(r.widget.defaultEnabled)
        XCTAssertFalse(r.registry.isEnabled(WellbeingWidget.widgetID), "off by default")
        XCTAssertFalse(r.widget.running)
        r.widget.sample()
        XCTAssertNil(r.widget.nextWake, "no timer")
        XCTAssertEqual(r.idle.reads, 0, "no idle reads")

        r.registry.setEnabled(WellbeingWidget.widgetID, true)
        XCTAssertTrue(r.widget.running)
        XCTAssertNotNil(r.widget.nextWake)
        XCTAssertGreaterThanOrEqual(r.widget.nextWake!, r.now.addingTimeInterval(NudgeScheduler.minimumWake))
        XCTAssertEqual(r.idle.reads, 0, "starting reads nothing")
        r.widget.sample()
        XCTAssertNil(r.widget.nudge, "no card within the grace after it starts")

        r.widget.addGlass()
        r.registry.setEnabled(WellbeingWidget.widgetID, false)
        XCTAssertFalse(r.widget.running)
        XCTAssertNil(r.widget.nextWake)
        let reads = r.idle.reads
        r.widget.sample()
        XCTAssertEqual(r.idle.reads, reads)
        XCTAssertEqual(r.widget.glassesToday(), 1, "disabled() keeps the water log")
        XCTAssertTrue(r.widget.progress.lastDone.isEmpty, "intervals start afresh when turned on again")
    }

    func testAllIntervalsOffMeansNoTimer() {
        let r = rig()
        r.widget.update(NudgeSettings(water: 0, stand: 0, eyes: 0))
        XCTAssertNil(r.widget.nextWake)
        r.widget.sample()
        XCTAssertNil(r.widget.nextWake)
        XCTAssertEqual(r.idle.reads, 0)
    }

    func testTurningOffWhileACardShowsEndsIt() {
        let r = rig()
        r.widget.sample()
        XCTAssertEqual(r.controller.mode, peek)
        r.registry.setEnabled(WellbeingWidget.widgetID, false)
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.controller.mode, .compact)
        XCTAssertNil(r.registry.peekView(id: WellbeingWidget.peekID))
    }

    func testSystemObserversOnlyWhileRunning() {
        let r = rig(watchSystem: true)
        XCTAssertEqual(r.widget.observerCount, 8, "sleep/wake, session, lock/unlock, clock, time zone")
        r.registry.setEnabled(WellbeingWidget.widgetID, false)
        XCTAssertEqual(r.widget.observerCount, 0, "removed when turned off")
        r.registry.setEnabled(WellbeingWidget.widgetID, true)
        XCTAssertEqual(r.widget.observerCount, 8)
        r.registry.stopAll()
        XCTAssertEqual(r.widget.observerCount, 0, "removed at quit")
    }

    // MARK: - Cards through the controller

    func testEyesCardShowsWithRingLengthAndDone() {
        let r = rig()
        r.widget.sample()
        XCTAssertEqual(r.idle.reads, 1, "one idle read per sample")
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
        XCTAssertGreaterThanOrEqual(r.widget.nextWake!, r.now.addingTimeInterval(NudgeScheduler.minimumWake))

        // Persisted as small Codable values, with the card time for the spacing.
        let saved = try? JSONDecoder().decode(NudgeProgress.self, from: r.defaults.data(forKey: NudgeProgress.key) ?? Data())
        XCTAssertEqual(saved?.lastDone[.eyes], r.now)
        XCTAssertEqual(saved?.lastCard, r.now)
    }

    func testSpacingBetweenCards() {
        let r = rig()
        r.widget.sample()
        r.widget.done(.eyes)
        r.clock.advance(60)
        r.widget.sample()
        XCTAssertNil(r.widget.nudge, "a minute later: still spaced")
        r.clock.advance(NudgeScheduler.spacing)
        r.widget.sample()
        XCTAssertEqual(r.widget.nudge?.kind, .stand)
        XCTAssertEqual(r.widget.nudge?.until, r.now.addingTimeInterval(NudgeScheduler.peekDuration), "10 s card")
    }

    func testSpacingSurvivesARelaunch() {
        let d = defaults()
        let clock = Clock(afternoon)
        let r = rig(defaults: d, clock: clock)
        r.widget.sample()
        let shown = r.now
        XCTAssertNotNil(r.widget.nudge)
        r.registry.stopAll()   // quit with stand and water still due

        clock.advance(10)
        let again = rig(overdue: false, defaults: d, clock: clock)   // relaunch, past its grace
        again.widget.sample()
        XCTAssertNil(again.widget.nudge, "the last card's spacing holds across the relaunch")
        XCTAssertGreaterThanOrEqual(again.widget.nextWake!, shown.addingTimeInterval(NudgeScheduler.minimumWake))
        clock.now = shown.addingTimeInterval(NudgeScheduler.spacing)
        again.widget.sample()
        XCTAssertNotNil(again.widget.nudge)
    }

    func testWaterCardPlusOneGlass() {
        let r = rig()
        var s = NudgeSettings()
        s.eyes = 0
        s.stand = 0
        r.widget.update(s)
        // Turning nudges off leaves water's (overdue) time alone.
        r.widget.sample()
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

    /// Ruling (fix round 1): only an explicit Snooze brings a nudge back after 10 minutes; a
    /// card nobody answers counts as dismissed for its interval.
    func testSnoozeAndUnansweredCards() {
        let r = rig()
        r.widget.sample()
        r.widget.snooze(.eyes)
        XCTAssertEqual(r.widget.progress.snoozedUntil[.eyes], r.now.addingTimeInterval(NudgeScheduler.snooze))
        XCTAssertEqual(r.controller.mode, .compact)

        r.clock.advance(NudgeScheduler.spacing)
        r.widget.sample()
        XCTAssertEqual(r.widget.nudge?.kind, .stand)
        r.clock.advance(NudgeScheduler.peekDuration + 1)
        r.widget.sample()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.widget.progress.lastDone[.stand], r.now, "dismissed for its interval")
        XCTAssertNil(r.widget.progress.snoozedUntil[.stand])
        XCTAssertEqual(dueDate(r, .stand), r.now.addingTimeInterval(50 * 60))
    }

    func testEyesCardRunningOutCountsAsDone() {
        let r = rig()
        r.widget.sample()
        XCTAssertEqual(r.widget.nudge?.kind, .eyes)
        r.clock.advance(NudgeScheduler.eyesBreak + 1)
        r.idle.seconds = NudgeScheduler.eyesBreak   // no input during the ring: looked away
        r.widget.sample()
        XCTAssertEqual(r.widget.progress.lastDone[.eyes], r.now)
        XCTAssertNil(r.widget.progress.snoozedUntil[.eyes])
    }

    /// Simulates `hours` of wake-ups (the clock jumps to each `nextWake`), answering every
    /// card at once or ignoring all of them. Returns how many cards showed.
    private func cards(answering: Bool, hours: Double = 3) -> Int {
        let r = rig()
        let end = r.now.addingTimeInterval(hours * 3600)
        var count = 0
        var last: Date?
        while r.now < end {
            r.widget.sample()
            if let n = r.widget.nudge, n.shownAt != last {
                count += 1
                last = n.shownAt
                if answering { n.kind == .water ? r.widget.addGlass() : r.widget.done(n.kind) }
            }
            guard let wake = r.widget.nextWake else { break }
            r.clock.now = max(wake, r.now.addingTimeInterval(0.001))
        }
        return count
    }

    func testIgnoringCardsGivesNoMoreThanAnswering() {
        let answered = cards(answering: true)
        let ignored = cards(answering: false)
        XCTAssertGreaterThan(answered, 0)
        XCTAssertLessThanOrEqual(ignored, answered, "ignoring cards never brings more of them")
        XCTAssertLessThan(ignored, 3 * 60 / 10, "nowhere near a card every 5 minutes")
    }

    /// Task 1b precedence, verified for this card: an approval beats it, and it shows when
    /// the approval is answered (while its time lasts).
    func testApprovalBeatsTheNudge() {
        let r = rig()
        r.controller.debugHandle(.event(.approvalsChanged(count: 1)))
        r.widget.sample()
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
        r.widget.sample()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.widget.nextWake, NudgeScheduler.nextSample(now: r.now, idleSeconds: 0),
                       "the adaptive sample, not a minute poll")

        r.controller.debugHandle(.setFullScreen(false))
        r.widget.sample()
        XCTAssertEqual(r.controller.mode, peek)
        r.controller.debugHandle(.setFullScreen(true))
        XCTAssertNotEqual(r.controller.mode, peek, "held over full screen")
    }

    // MARK: - Idle, focus, meetings

    /// Ruling (fix round 1): adaptive sampling sees a break that falls between due times.
    func testAdaptiveSampleCatchesABreakBetweenDueTimes() {
        let r = rig(overdue: false)
        r.widget.done(.stand)
        r.widget.done(.eyes)
        let eyesBefore = dueDate(r, .eyes)!
        let standBefore = dueDate(r, .stand)!
        XCTAssertEqual(r.widget.nextWake, NudgeScheduler.nextSample(now: r.now, idleSeconds: 0),
                       "a sample comes before the eyes are due")

        r.clock.advance(5 * 60)
        r.idle.seconds = 600   // away mid-interval
        r.widget.sample()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.widget.nextWake, r.now.addingTimeInterval(NudgeScheduler.minimumWake), "a minute while away")

        r.clock.advance(60)
        r.idle.seconds = 2     // back
        r.widget.sample()
        XCTAssertGreaterThan(dueDate(r, .eyes)!, eyesBefore)
        XCTAssertGreaterThan(dueDate(r, .stand)!, standBefore)
        XCTAssertEqual(dueDate(r, .eyes), r.now.addingTimeInterval(-60 + 20 * 60), "eyes count from the break")
        XCTAssertEqual(r.widget.nextWake, NudgeScheduler.nextSample(now: r.now, idleSeconds: 2))
    }

    func testSavesOnlyOnChange() {
        let r = rig()
        r.widget.update(NudgeSettings(water: 0, stand: 0, eyes: 60))   // nothing due for an hour
        let saves = r.widget.saves
        r.widget.sample()
        r.clock.advance(300)
        r.widget.sample()
        XCTAssertEqual(r.widget.saves, saves, "nothing changed, nothing written")
        r.idle.seconds = 400
        r.widget.sample()
        XCTAssertEqual(r.widget.saves, saves + 1, "a break is written once")
    }

    func testIdleIsABreakAndNoNudge() {
        let r = rig()
        let before = r.widget.progress.lastDone
        r.idle.seconds = NudgeScheduler.idleBreak
        r.widget.sample()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.widget.progress.lastDone[.stand], r.now)
        XCTAssertEqual(r.widget.progress.lastDone[.eyes], r.now)
        XCTAssertEqual(r.widget.progress.lastDone[.water], before[.water], "idle is no glass of water")
        XCTAssertEqual(r.widget.nextWake, r.now.addingTimeInterval(NudgeScheduler.minimumWake), "a minute while away")

        // Sitting down again: the same grace as an unlock, so no water card at once.
        r.clock.advance(60)
        r.idle.seconds = 3
        r.widget.sample()
        XCTAssertNil(r.widget.nudge, "no card within 2 minutes of sitting down")
        XCTAssertEqual(r.widget.resumeAt, r.now.addingTimeInterval(NudgeScheduler.resumeGrace))
        r.clock.advance(NudgeScheduler.resumeGrace)
        r.widget.sample()
        XCTAssertEqual(r.widget.nudge?.kind, .water, "then only water is still due")
    }

    func testFocusSessionSleepsUntilItEnds() {
        let r = rig()
        let end = r.now.addingTimeInterval(25 * 60)
        r.defaults.set(end, forKey: FocusModel.untilKey)
        r.widget.sample()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.widget.nextWake, end, "one wake at the end of the session, no polling")
        r.clock.now = end
        r.widget.sample()
        XCTAssertNotNil(r.widget.nudge)
    }

    func testMeetingHoldsNudges() {
        var meeting = true
        let r = rig(inMeeting: { meeting })
        r.widget.sample()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.widget.nextWake, NudgeScheduler.nextSample(now: r.now, idleSeconds: 0))
        meeting = false
        r.widget.sample()
        XCTAssertNotNil(r.widget.nudge)
    }

    func testMeetingSignalFollowsTheRunningMeetingWidget() {
        let d = defaults()
        let registry = WidgetRegistry(defaults: d, persist: false)
        registries.append(registry)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = CalendarService(eventKit: false)
        let inProgress = CalendarMeeting(id: "sync", title: "Sync", start: now.addingTimeInterval(-300),
                                         end: now.addingTimeInterval(1500), joinURL: nil)
        calendar.setForTesting(access: .granted, meetings: [inProgress])
        let meeting = MeetingWidget(calendar: calendar, defaults: d, clock: { now })
        registry.register(meeting)
        let signal = BuiltInWidgets.meetingSignal(registry: registry, meeting: meeting)
        XCTAssertFalse(signal(), "not running yet")

        registry.start(context: context(registry, PanelSurfaces(registry: registry), d))
        XCTAssertTrue(signal(), "in a meeting, with calendar access, while the meeting widget runs")

        calendar.setForTesting(access: .denied, meetings: [inProgress])
        XCTAssertFalse(signal(), "no calendar access, no meeting state")
        calendar.setForTesting(access: .granted, meetings: [inProgress])
        registry.setEnabled(MeetingWidget.widgetID, false)
        XCTAssertFalse(signal(), "meeting widget off")
    }

    // MARK: - Sleep, lock, clock

    func testSleepPausesAndWakeDoesNotBurst() {
        let r = rig()
        r.widget.sample()
        XCTAssertNotNil(r.widget.nudge)
        r.widget.setPaused(.sleep, true)
        XCTAssertNil(r.widget.nudge, "the card goes with the sleep")
        XCTAssertEqual(r.controller.mode, .compact)
        XCTAssertNil(r.widget.nextWake, "no timer while asleep")
        let reads = r.idle.reads
        r.widget.sample()
        XCTAssertEqual(r.idle.reads, reads, "nothing read while paused")

        r.widget.setPaused(.locked, true)
        r.clock.advance(3600)
        r.widget.setPaused(.sleep, false)
        XCTAssertNil(r.widget.nextWake, "still locked")
        r.widget.setPaused(.locked, false)
        XCTAssertEqual(r.widget.progress.lastDone[.stand], r.now, "an hour away was a break")
        XCTAssertEqual(r.widget.progress.lastDone[.eyes], r.now)
        r.widget.sample()
        XCTAssertNil(r.widget.nudge, "no card within the grace after unlocking")
        r.clock.advance(NudgeScheduler.resumeGrace)
        r.widget.sample()
        XCTAssertEqual(r.widget.nudge?.kind, .water, "then one card")
    }

    func testClockSetBackClampsSavedTimes() {
        let r = rig(overdue: false)
        r.widget.sample()
        r.widget.snooze(.water)
        r.clock.advance(-3 * 3600)   // the clock is set back three hours
        r.widget.clockChanged()
        let p = r.widget.progress
        for kind in NudgeKind.allCases { XCTAssertLessThanOrEqual(p.lastDone[kind]!, r.now) }
        XCTAssertLessThanOrEqual(p.snoozedUntil[.water]!, r.now.addingTimeInterval(NudgeScheduler.snooze))
        XCTAssertLessThanOrEqual(p.lastCard ?? r.now, r.now)
        XCTAssertNotNil(r.widget.nextWake)
        XCTAssertLessThanOrEqual(r.widget.nextWake!, r.now.addingTimeInterval(NudgeScheduler.idleBreak),
                                 "the wake is recomputed from the new time, not hours away")
    }

    // MARK: - Settings and views

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

    func testQuietHoursSleepUntilTheirEnd() {
        let clock = Clock(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23))!)
        let r = rig(clock: clock)
        r.widget.sample()
        XCTAssertNil(r.widget.nudge)
        XCTAssertEqual(r.idle.reads, 0, "no idle samples during quiet hours")
        XCTAssertEqual(r.widget.nextWake, calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 8)))
    }

    func testViewsBuild() {
        let r = rig()
        r.widget.sample()
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
