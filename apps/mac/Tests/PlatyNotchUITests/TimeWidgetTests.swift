import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Records what would go to Notification Center (never the real one).
@MainActor
private final class FakeNotifier: Notifier {
    var isAvailable = true
    /// False: adds are refused until `requestAuthorization` (the real "not determined" case).
    var authorized = true
    var authorizationRequests = 0
    var pending: [String: Date] = [:]
    var calendarIDs: Set<String> = []
    var cancelled: [String] = []

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        authorized = true
        return true
    }

    func schedule(id: String, title: String, body: String, at date: Date?) async -> Bool {
        guard authorized else { return false }
        pending[id] = date
        calendarIDs.remove(id)
        return true
    }

    func schedule(id: String, title: String, body: String, matching components: DateComponents) async -> Bool {
        guard authorized else { return false }
        pending[id] = Self.calendar.date(from: components)
        calendarIDs.insert(id)
        return true
    }

    func cancel(id: String) {
        pending[id] = nil
        cancelled.append(id)
    }

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }
}

@MainActor
private final class FakeSound: RingSound {
    var playing: TimeSound?
    var plays: [TimeSound] = []
    func play(_ sound: TimeSound) { playing = sound; plays.append(sound) }
    func stop() { playing = nil }
    var isPlaying: Bool { playing != nil }
}

@MainActor
private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class TimeWidgetTests: DefaultsTestCase {
    // 2026-10-20 06:00 New York, a Tuesday.
    private let t0 = FakeNotifier.calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 6))!



    private struct Rig {
        let widget: TimeWidget
        let notifier: FakeNotifier
        let sound: FakeSound
        let clock: Clock
        let surfaces: PanelSurfaces
        let defaults: UserDefaults
    }

    private func rig(defaults d: UserDefaults? = nil, at start: Date? = nil, authorized: Bool = true) -> Rig {
        let d = d ?? defaults()
        let clock = Clock(start ?? t0)
        let notifier = FakeNotifier()
        notifier.authorized = authorized
        let sound = FakeSound()
        let surfaces = PanelSurfaces()
        let widget = TimeWidget(defaults: d, sound: sound, clock: { clock.now }, calendar: { FakeNotifier.calendar })
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pntime\(UUID().uuidString)")
        let context = WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                    config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                    events: CoreEventHub(), defaults: d, notify: notifier, surfaces: surfaces,
                                    openPanel: { _ in })
        widget.start(context: context)
        return Rig(widget: widget, notifier: notifier, sound: sound, clock: clock, surfaces: surfaces, defaults: d)
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testTimerBackupScheduledAndCancelledOnPause() async {
        let r = rig()
        XCTAssertTrue(r.widget.addTimer("10m"))
        let timer = r.widget.state.timers[0]
        let id = TimeBackup.timerID(timer.id)
        await r.widget.backupsSettled()
        XCTAssertEqual(r.notifier.pending[id], t0 + 600 + TimeBackup.delay)
        XCTAssertFalse(r.notifier.calendarIDs.contains(id))
        await settle()
        XCTAssertEqual(r.notifier.authorizationRequests, 1)   // asked on the first timer
        XCTAssertTrue(r.widget.addTimer("5"))
        await settle()
        XCTAssertEqual(r.notifier.authorizationRequests, 1)   // only once
        r.widget.toggleTimer(timer.id)                         // pause
        await r.widget.backupsSettled()
        XCTAssertNil(r.notifier.pending[id])
        XCTAssertEqual(r.widget.liveActivities.first?.priority, LivePriority.timerRunning)   // the other one
        XCTAssertFalse(r.widget.addTimer("abc"))
        r.widget.stop()
    }

    func testFinishedTimerRingsThenCancelsBackup() async {
        let r = rig()
        XCTAssertTrue(r.widget.addTimer("1m"))
        let timer = r.widget.state.timers[0]
        let id = TimeBackup.timerID(timer.id)
        XCTAssertEqual(r.widget.liveActivities.map(\.priority), [LivePriority.timerRunning])
        XCTAssertEqual(r.widget.liveActivities.first?.countdownTo, t0 + 60)
        await r.widget.backupsSettled()
        XCTAssertNotNil(r.notifier.pending[id])
        r.clock.now = t0 + 60
        r.widget.tick()
        await r.widget.backupsSettled()
        XCTAssertEqual(r.widget.ringing.map(\.id), [id])
        XCTAssertEqual(r.surfaces.ringing, [id])
        XCTAssertEqual(r.surfaces.rings.first?.title, "1 min")
        XCTAssertEqual(r.sound.playing, .chime)
        XCTAssertNil(r.notifier.pending[id])
        XCTAssertTrue(r.notifier.cancelled.contains(id))
        XCTAssertEqual(r.widget.liveActivities.first?.priority, LivePriority.timerFinished)
        XCTAssertNotNil(r.widget.peekView(id: id))
        // Stop: silent, reset, no notice.
        r.widget.stopRing(id)
        XCTAssertNil(r.sound.playing)
        XCTAssertEqual(r.surfaces.ringing, [])
        XCTAssertEqual(r.widget.state.timers[0].phase, .idle)
        XCTAssertEqual(r.widget.liveActivities, [])
        r.widget.stop()
    }

    /// The panel's chip and the menu bar's "Stop <title>" go through PanelSurfaces.
    func testStopFromMenuBarSilences() async {
        let r = rig()
        r.widget.addAlarm(hour: 6, minute: 1)
        r.clock.now = t0 + 60
        r.widget.tick()
        let id = TimeBackup.alarmID(r.widget.state.alarms[0].id)
        XCTAssertEqual(r.surfaces.rings.map(\.id), [id])
        XCTAssertEqual(r.sound.playing, .alarm)
        XCTAssertEqual(r.widget.liveActivities.first?.priority, LivePriority.alarmRinging)
        r.surfaces.stopRinging(id: id)          // menu bar Stop
        await settle()
        XCTAssertEqual(r.widget.ringing, [])
        XCTAssertNil(r.sound.playing)
        XCTAssertFalse(r.widget.state.alarms[0].enabled)   // a once alarm turns itself off
        r.widget.stop()
    }

    /// Ledger carry: a widget disabled mid-ring stops its sound.
    func testWidgetStopSilencesRinging() {
        let r = rig()
        r.widget.addAlarm(hour: 6, minute: 1)
        r.clock.now = t0 + 60
        r.widget.tick()
        XCTAssertEqual(r.sound.playing, .alarm)
        r.widget.stop()
        XCTAssertNil(r.sound.playing)
        XCTAssertEqual(r.surfaces.ringing, [])
        XCTAssertEqual(r.widget.ringing, [])
    }

    func testAlarmBackupIsCalendarTriggerAndSnoozeMovesIt() async {
        let r = rig()
        r.widget.addAlarm(hour: 7, minute: 30, weekdays: [3], label: "Wake")   // Tuesdays
        let id = TimeBackup.alarmID(r.widget.state.alarms[0].id)
        let fire = t0 + 90 * 60
        await r.widget.backupsSettled()
        XCTAssertTrue(r.notifier.calendarIDs.contains(id))
        XCTAssertEqual(r.notifier.pending[id], fire + TimeBackup.delay)
        r.clock.now = fire
        r.widget.tick()
        await r.widget.backupsSettled()
        XCTAssertEqual(r.surfaces.rings.first?.title, "Wake")
        // Next week's backup is already pending.
        XCTAssertEqual(r.notifier.pending[id], fire + 7 * 86_400 + TimeBackup.delay)
        r.clock.now = fire + 5
        r.widget.snoozeRing(id)
        await r.widget.backupsSettled()
        XCTAssertNil(r.sound.playing)
        XCTAssertEqual(r.surfaces.ringing, [])
        XCTAssertEqual(r.notifier.pending[id], fire + 5 + Alarm.snoozeInterval + TimeBackup.delay)
        r.clock.now = fire + 5 + Alarm.snoozeInterval
        r.widget.tick()
        XCTAssertEqual(r.surfaces.ringing, [id])
        r.widget.stop()
    }

    /// Review focus: quit with a timer running → on relaunch it shows finished; nothing
    /// rings and its (already delivered) backup is neither rescheduled nor removed.
    func testRelaunchShowsFinishedWithoutDoubleFire() async {
        let d = defaults()
        let first = rig(defaults: d)
        XCTAssertTrue(first.widget.addTimer("2m"))
        let timer = first.widget.state.timers[0]
        await first.widget.backupsSettled()
        first.widget.stop()                        // app quits (stop alone, no disabled())
        XCTAssertNotNil(first.notifier.pending[TimeBackup.timerID(timer.id)])   // backup stays

        let relaunched = rig(defaults: d, at: t0 + 10 * 60)
        await relaunched.widget.backupsSettled()
        XCTAssertTrue(relaunched.widget.state.timers[0].isFinished(at: t0 + 600))
        XCTAssertEqual(relaunched.widget.ringing, [])
        XCTAssertNil(relaunched.sound.playing)
        XCTAssertTrue(relaunched.notifier.pending.isEmpty)
        XCTAssertTrue(relaunched.notifier.cancelled.isEmpty)
        XCTAssertEqual(relaunched.widget.liveActivities.map(\.priority), [LivePriority.timerFinished])
        relaunched.clock.now = t0 + 10 * 60 + 30
        relaunched.widget.tick()
        XCTAssertEqual(relaunched.widget.ringing, [])
        relaunched.widget.stop()
    }

    func testFocusSessionHoldsTimersButNotAlarms() {
        let d = defaults()
        d.set(t0 + 3600, forKey: "focusUntil")
        let r = rig(defaults: d)
        r.widget.addTimer("1m")
        r.widget.addAlarm(hour: 6, minute: 2)
        r.clock.now = t0 + 60
        r.widget.tick()
        XCTAssertEqual(r.widget.ringing, [])           // timer: notice only
        XCTAssertNil(r.sound.playing)
        XCTAssertEqual(r.widget.liveActivities.first?.priority, LivePriority.timerFinished)
        r.clock.now = t0 + 120
        r.widget.tick()
        XCTAssertEqual(r.widget.ringing.count, 1)      // the alarm still rings
        XCTAssertEqual(r.sound.playing, .alarm)
        r.widget.stop()
    }

    func testStopwatchLiveActivityCountsUp() {
        let r = rig()
        r.widget.toggleStopwatch()
        r.clock.now = t0 + 10
        r.widget.toggleStopwatch()
        r.clock.now = t0 + 20
        r.widget.toggleStopwatch()
        let live = r.widget.liveActivities.first
        XCTAssertEqual(live?.priority, LivePriority.stopwatch)
        XCTAssertEqual(live?.countUpFrom, t0 + 10)     // 10 s counted before this run
        r.widget.stop()
    }

    func testPomodoroAndLimits() {
        let r = rig()
        XCTAssertTrue(r.widget.addTimer("pomodoro"))
        XCTAssertEqual(r.widget.state.timers[0].duration, 25 * 60)
        for _ in 1..<TimeStore.maxTimers { XCTAssertTrue(r.widget.addTimer("1h")) }
        XCTAssertFalse(r.widget.addTimer("1h"))
        XCTAssertFalse(r.widget.startPomodoro())
        XCTAssertTrue(r.widget.addClock("Asia/Tokyo"))
        XCTAssertFalse(r.widget.addClock("Nowhere/Land"))
        r.widget.stop()
    }

    // MARK: - Fix round 1

    /// A fresh user's first timer: the add before the permission answer is refused, and
    /// the backup is scheduled once permission is granted.
    func testFirstBackupScheduledAfterPermissionGranted() async {
        let r = rig(authorized: false)
        XCTAssertTrue(r.widget.addTimer("10m"))
        r.widget.addAlarm(hour: 7, minute: 30)
        await r.widget.backupsSettled()
        XCTAssertEqual(r.notifier.authorizationRequests, 1)
        XCTAssertEqual(r.notifier.pending[TimeBackup.timerID(r.widget.state.timers[0].id)], t0 + 600 + TimeBackup.delay)
        XCTAssertNotNil(r.notifier.pending[TimeBackup.alarmID(r.widget.state.alarms[0].id)])
        r.widget.stop()
    }

    /// Denied: nothing is recorded, so every later change retries (and never crashes).
    func testRefusedAddIsRetried() async {
        let r = rig(authorized: false)
        r.notifier.isAvailable = false            // no prompt possible
        XCTAssertTrue(r.widget.addTimer("10m"))
        await r.widget.backupsSettled()
        XCTAssertTrue(r.notifier.pending.isEmpty)
        r.notifier.authorized = true              // allowed later in System Settings
        XCTAssertTrue(r.widget.addTimer("5m"))
        await r.widget.backupsSettled()
        XCTAssertEqual(r.notifier.pending.count, 2)
        r.widget.stop()
    }

    /// Disabled widgets do no work: turning Time off cancels every backup; turning it back
    /// on reschedules, and a once alarm that came due while off keeps its next occurrence.
    func testDisableCancelsBackupsAndReenableReschedules() async {
        let r = rig()
        r.widget.addTimer("10m")
        r.widget.addAlarm(hour: 6, minute: 30)
        await r.widget.backupsSettled()
        let alarmID = TimeBackup.alarmID(r.widget.state.alarms[0].id)
        XCTAssertEqual(r.notifier.pending.count, 2)
        r.widget.stop()
        r.widget.disabled()
        await r.widget.backupsSettled()
        XCTAssertTrue(r.notifier.pending.isEmpty)
        XCTAssertTrue(r.notifier.cancelled.contains(alarmID))

        // On again at 07:00: the 06:30 alarm came due while off. It does not ring and stays on.
        r.clock.now = t0 + 3600
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pntime\(UUID().uuidString)")
        r.widget.start(context: WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: r.defaults, notify: r.notifier,
                                              surfaces: r.surfaces, openPanel: { _ in }))
        await r.widget.backupsSettled()
        XCTAssertEqual(r.widget.ringing, [])
        XCTAssertTrue(r.widget.state.alarms[0].enabled)
        XCTAssertEqual(r.notifier.pending[alarmID], t0 + 86_400 + 30 * 60 + TimeBackup.delay)
        XCTAssertTrue(r.widget.state.timers[0].isFinished(at: r.clock.now))   // shown done, no backup
        XCTAssertNil(r.notifier.pending[TimeBackup.timerID(r.widget.state.timers[0].id)])
        r.widget.stop()
    }

    /// Alarm and timer ring together; stopping the alarm switches the loop to the chime.
    func testStoppingAlarmSwitchesToChime() {
        let r = rig()
        r.widget.addTimer("1m")
        r.widget.addAlarm(hour: 6, minute: 1)
        r.clock.now = t0 + 60
        r.widget.tick()
        XCTAssertEqual(r.widget.ringing.count, 2)
        XCTAssertEqual(r.sound.playing, .alarm)
        r.widget.stopRing(TimeBackup.alarmID(r.widget.state.alarms[0].id))
        XCTAssertEqual(r.sound.playing, .chime)
        r.widget.stopRing(TimeBackup.timerID(r.widget.state.timers[0].id))
        XCTAssertNil(r.sound.playing)
        r.widget.stop()
    }

    /// The sounds are found under `swift test` too (UIResources looks next to the test bundle).
    func testBundledSoundsFound() {
        for s in TimeSound.allCases { XCTAssertNotNil(s.url, "\(s.rawValue).wav") }
    }
}
