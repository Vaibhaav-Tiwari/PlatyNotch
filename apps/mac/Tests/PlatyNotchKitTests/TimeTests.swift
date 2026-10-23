import Foundation
import PlatyNotchKit   // not @testable: the Time widget uses these through their public API
import XCTest

final class TimeTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "TimeTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func calendar(_ tz: String = "America/New_York") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: String = "America/New_York") -> Date {
        calendar(tz).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - DurationParser

    func testDurationParserTable() {
        let table: [(String, TimeInterval?)] = [
            ("10", 600), ("10m", 600), ("1h30", 5400), ("1h 30m", 5400), ("90s", 90),
            ("25:00", 1500), ("1:05:00", 3900),
            (" 10 min ", 600), ("2H", 7200), ("1m30", 90), ("24h", 86400),
            ("abc", nil), ("0", nil), ("25h", nil), ("", nil), ("10x", nil), ("1:60", nil),
            ("1:2:3:4", nil), ("h", nil), ("-5", nil), ("0:00", nil), ("1h1h", nil),
        ]
        for (input, expected) in table {
            XCTAssertEqual(DurationParser.parse(input), expected, "input \(input.debugDescription)")
        }
    }

    func testDurationDescribe() {
        XCTAssertEqual(DurationParser.describe(600), "10 min")
        XCTAssertEqual(DurationParser.describe(5400), "1 h 30 min")
        XCTAssertEqual(DurationParser.describe(3600), "1 h")
        XCTAssertEqual(DurationParser.describe(90), "1 min 30 s")
        XCTAssertEqual(DurationParser.describe(45), "45 s")
    }

    // MARK: - CountdownTimer

    func testTimerPauseResume() {
        var timer = CountdownTimer(label: "Tea", duration: 10 * 60)
        XCTAssertEqual(timer.phase, .idle)
        XCTAssertEqual(timer.remaining(at: t0), 600)
        timer.start(at: t0)
        XCTAssertEqual(timer.phase, .running)
        XCTAssertEqual(timer.endsAt, t0 + 600)
        timer.pause(at: t0 + 120)
        XCTAssertEqual(timer.phase, .paused)
        XCTAssertNil(timer.endsAt)
        XCTAssertEqual(timer.remaining(at: t0 + 500), 480)   // paused: time stands still
        timer.resume(at: t0 + 300)
        XCTAssertEqual(timer.remaining(at: t0 + 300), 480)
        XCTAssertEqual(timer.remaining(at: t0 + 360), 420)
        XCTAssertEqual(timer.endsAt, t0 + 780)
        XCTAssertFalse(timer.isFinished(at: t0 + 779))
        XCTAssertTrue(timer.isFinished(at: t0 + 780))
        XCTAssertEqual(timer.remaining(at: t0 + 9999), 0)
        timer.reset()
        XCTAssertEqual(timer.phase, .idle)
        XCTAssertEqual(timer.remaining(at: t0 + 9999), 600)
        XCTAssertFalse(timer.isFinished(at: t0 + 9999))
    }

    func testTimerFinishedAfterRelaunch() {
        let d = defaults()
        let store = TimeStore(defaults: d)
        var timer = CountdownTimer(label: "Pasta", duration: 120)
        timer.start(at: t0)
        XCTAssertTrue(store.addTimer(timer))
        store.update { $0.lastCheck = t0 }   // the app quits right after starting it

        // Relaunch ten minutes later: finished, shown as done, nothing rings or reschedules.
        let relaunched = TimeStore(defaults: d)
        let now = t0 + 600
        XCTAssertTrue(relaunched.state.timers[0].isFinished(at: now))
        let events = relaunched.update { $0.advance(to: now, calendar: calendar(), announce: false) }
        XCTAssertEqual(events, [TimeEvent(kind: .timer(timer.id), dueAt: t0 + 120, ring: false)])
        XCTAssertTrue(relaunched.state.backups(now: now, calendar: calendar()).isEmpty)
        // A second launch sees nothing new (no double fire).
        let again = TimeStore(defaults: d)
        XCTAssertEqual(again.update { $0.advance(to: now + 5, calendar: calendar(), announce: true) }, [])
    }

    // MARK: - Alarm

    func testAlarmNextFireWeekdays() {
        let cal = calendar()
        let alarm = Alarm(hour: 7, minute: 30, weekdays: [2, 4])   // Mon, Wed
        let tuesday8 = date(2026, 10, 20, 8, 0)
        XCTAssertEqual(cal.component(.weekday, from: tuesday8), 3)
        XCTAssertEqual(alarm.nextFire(after: tuesday8, calendar: cal), date(2026, 10, 21, 7, 30))
        // Wednesday 07:30 exactly → the following Monday.
        XCTAssertEqual(alarm.nextFire(after: date(2026, 10, 21, 7, 30), calendar: cal), date(2026, 10, 26, 7, 30))
        // Once: today if still ahead, else tomorrow.
        let once = Alarm(hour: 7, minute: 30)
        XCTAssertEqual(once.nextFire(after: date(2026, 10, 20, 6, 0), calendar: cal), date(2026, 10, 20, 7, 30))
        XCTAssertEqual(once.nextFire(after: tuesday8, calendar: cal), date(2026, 10, 21, 7, 30))
        var off = once
        off.enabled = false
        XCTAssertNil(off.nextFire(after: tuesday8, calendar: cal))
    }

    func testAlarmOnceDisablesAfterFire() {
        var once = Alarm(hour: 7, minute: 30, label: "Gym")
        once.markFired()
        XCTAssertFalse(once.enabled)
        XCTAssertNil(once.nextFire(after: t0, calendar: calendar()))
        var weekly = Alarm(hour: 7, minute: 30, weekdays: [2])
        weekly.markFired()
        XCTAssertTrue(weekly.enabled)

        // Through the scheduler: rings once, then is off.
        let cal = calendar()
        var state = TimeState()
        state.alarms = [Alarm(hour: 7, minute: 30)]
        state.lastCheck = date(2026, 10, 20, 7, 0)
        let fire = date(2026, 10, 20, 7, 30)
        XCTAssertEqual(state.advance(to: fire, calendar: cal, announce: true),
                       [TimeEvent(kind: .alarm(state.alarms[0].id), dueAt: fire, ring: true)])
        XCTAssertFalse(state.alarms[0].enabled)
        XCTAssertEqual(state.advance(to: fire + 86_400, calendar: cal, announce: true), [])
    }

    /// 02:30 does not exist on 2026-03-08 in New York (clocks jump 02:00 → 03:00). Printed
    /// first with a throwaway test (Calendar.nextDate, .nextTimePreservingSmallerComponents):
    /// 2026-03-08T03:30:00-04:00. 01:30 on the fall-back day (2026-11-01) fires once, at the
    /// first occurrence (-04:00), and next on 2026-11-02T01:30:00-05:00.
    func testAlarmDSTGap() {
        let cal = calendar()
        let alarm = Alarm(hour: 2, minute: 30)
        let next = alarm.nextFire(after: date(2026, 3, 8, 0, 10), calendar: cal)
        XCTAssertEqual(next, ISO8601DateFormatter().date(from: "2026-03-08T03:30:00-04:00"))
        XCTAssertEqual(next, date(2026, 3, 8, 3, 30))

        let fallBack = Alarm(hour: 1, minute: 30)
        let first = fallBack.nextFire(after: date(2026, 11, 1, 0, 10), calendar: cal)!
        XCTAssertEqual(first, ISO8601DateFormatter().date(from: "2026-11-01T01:30:00-04:00"))
        XCTAssertEqual(fallBack.nextFire(after: first, calendar: cal),
                       ISO8601DateFormatter().date(from: "2026-11-02T01:30:00-05:00"))
    }

    func testAlarmSnooze() {
        let cal = calendar()
        var state = TimeState()
        state.alarms = [Alarm(hour: 7, minute: 30, weekdays: [3])]   // Tuesdays
        let fire = date(2026, 10, 20, 7, 30)
        state.lastCheck = fire - 60
        XCTAssertEqual(state.advance(to: fire, calendar: cal, announce: true).count, 1)
        state.snoozeAlarm(state.alarms[0].id, at: fire + 10)
        let again = fire + 10 + Alarm.snoozeInterval
        XCTAssertEqual(state.alarms[0].nextRing(after: fire + 20, calendar: cal), again)
        XCTAssertEqual(state.advance(to: again - 1, calendar: cal, announce: true), [])
        XCTAssertEqual(state.advance(to: again, calendar: cal, announce: true),
                       [TimeEvent(kind: .alarm(state.alarms[0].id), dueAt: again, ring: true)])
        XCTAssertNil(state.alarms[0].snoozedUntil)
        XCTAssertTrue(state.alarms[0].enabled)
        // Turning an alarm off drops its snooze.
        state.snoozeAlarm(state.alarms[0].id, at: again)
        state.setAlarmEnabled(state.alarms[0].id, false)
        XCTAssertNil(state.alarms[0].nextRing(after: again, calendar: cal))
    }

    func testMissedAlarmDoesNotRingLate() {
        let cal = calendar()
        var state = TimeState()
        state.alarms = [Alarm(hour: 7, minute: 30)]
        state.lastCheck = date(2026, 10, 20, 7, 0)
        // The Mac slept through it: past the grace, so no ring (the backup notification showed).
        let late = date(2026, 10, 20, 7, 30) + TimeState.ringGrace + 1
        XCTAssertEqual(state.advance(to: late, calendar: cal, announce: true).map(\.ring), [false])
        XCTAssertFalse(state.alarms[0].enabled)
    }

    // MARK: - World clock

    func testWorldClockDayOffset() {
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let lateEvening = date(2026, 10, 24, 22, 0, tz: "Asia/Kolkata")
        let tokyo = WorldClock(timeZoneID: "Asia/Tokyo")
        XCTAssertEqual(tokyo.label, "Tokyo")
        let d = tokyo.display(at: lateEvening, relativeTo: kolkata, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(d.dayOffset, 1)
        XCTAssertTrue(d.isNight)            // 01:30 in Tokyo
        XCTAssertEqual(d.time.replacingOccurrences(of: "\u{202F}", with: " "), "1:30 AM")   // ICU may use a narrow space
        let ny = WorldClock(timeZoneID: "America/New_York")
        let n = ny.display(at: lateEvening, relativeTo: kolkata, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(n.dayOffset, 0)      // 12:30 the same day
        XCTAssertFalse(n.isNight)
        let early = date(2026, 10, 24, 6, 0, tz: "Asia/Kolkata")
        XCTAssertEqual(ny.display(at: early, relativeTo: kolkata).dayOffset, -1)
        XCTAssertEqual(WorldClock(timeZoneID: "America/Los_Angeles").label, "Los Angeles")
        XCTAssertNil(WorldClock(timeZoneID: "Not/AZone").timeZone)
    }

    // MARK: - Stopwatch

    func testStopwatchLaps() {
        var sw = Stopwatch()
        XCTAssertFalse(sw.isRunning)
        sw.lap(at: t0)                       // not running: ignored
        XCTAssertEqual(sw.laps, [])
        sw.start(at: t0)
        sw.lap(at: t0 + 10)
        sw.lap(at: t0 + 25)
        XCTAssertEqual(sw.laps, [10, 15])
        sw.stop(at: t0 + 30)
        XCTAssertEqual(sw.elapsed(at: t0 + 100), 30)
        sw.start(at: t0 + 100)
        XCTAssertEqual(sw.elapsed(at: t0 + 105), 35)
        sw.lap(at: t0 + 105)
        XCTAssertEqual(sw.laps, [10, 15, 10])
        XCTAssertEqual(sw.currentLap(at: t0 + 107), 2)
        XCTAssertEqual(sw.runningSince, t0 + 100)
        sw.reset()
        XCTAssertEqual(sw, Stopwatch())
        XCTAssertEqual(Stopwatch.format(65.37), "1:05.3")
        XCTAssertEqual(Stopwatch.format(3725.99), "1:02:05.9")
        XCTAssertEqual(Stopwatch.format(0), "0:00.0")
    }

    // MARK: - Store, scheduler, backups

    func testPersistenceRoundTrip() throws {
        let d = defaults()
        let store = TimeStore(defaults: d)
        var timer = CountdownTimer(label: "Tea", duration: 300)
        timer.start(at: t0)
        timer.pause(at: t0 + 30)
        XCTAssertTrue(store.addTimer(timer))
        XCTAssertTrue(store.addAlarm(Alarm(hour: 6, minute: 45, weekdays: [2, 3, 4, 5, 6], label: "Work")))
        XCTAssertTrue(store.addClock(WorldClock(timeZoneID: "Europe/London")))
        store.update { $0.stopwatch.start(at: t0); $0.stopwatch.lap(at: t0 + 5); $0.lastCheck = t0 + 6 }
        XCTAssertNotNil(d.data(forKey: TimeStore.key))
        XCTAssertEqual(TimeStore.key, "time.v1")
        XCTAssertEqual(TimeStore(defaults: d).state, store.state)
        // Garbage in the key is an empty state, not a crash.
        d.set(Data("nope".utf8), forKey: TimeStore.key)
        XCTAssertEqual(TimeStore(defaults: d).state, TimeState())
    }

    func testLimits() {
        let store = TimeStore(defaults: defaults())
        for _ in 0..<TimeStore.maxTimers { XCTAssertTrue(store.addTimer(CountdownTimer(duration: 60))) }
        XCTAssertFalse(store.addTimer(CountdownTimer(duration: 60)))
        for _ in 0..<TimeStore.maxAlarms { XCTAssertTrue(store.addAlarm(Alarm(hour: 1, minute: 0))) }
        XCTAssertFalse(store.addAlarm(Alarm(hour: 1, minute: 0)))
        for _ in 0..<TimeStore.maxClocks { XCTAssertTrue(store.addClock(WorldClock(timeZoneID: "UTC"))) }
        XCTAssertFalse(store.addClock(WorldClock(timeZoneID: "UTC")))
        XCTAssertEqual([TimeStore.maxTimers, TimeStore.maxAlarms, TimeStore.maxClocks], [10, 20, 12])
    }

    func testAdvanceRingsTimerOnce() {
        let cal = calendar()
        var state = TimeState()
        var timer = CountdownTimer(duration: 60)
        timer.start(at: t0)
        state.timers = [timer]
        state.lastCheck = t0
        XCTAssertEqual(state.advance(to: t0 + 59, calendar: cal, announce: true), [])
        XCTAssertEqual(state.advance(to: t0 + 61, calendar: cal, announce: true),
                       [TimeEvent(kind: .timer(timer.id), dueAt: t0 + 60, ring: true)])
        XCTAssertEqual(state.advance(to: t0 + 62, calendar: cal, announce: true), [])
        // A clock set back never re-fires it.
        XCTAssertEqual(state.advance(to: t0 + 30, calendar: cal, announce: true), [])
        XCTAssertEqual(state.advance(to: t0 + 63, calendar: cal, announce: true), [])
    }

    func testPomodoroChainsBreak() {
        let cal = calendar()
        var state = TimeState()
        XCTAssertTrue(state.startPomodoro(at: t0))
        XCTAssertEqual(state.timers.count, 1)
        XCTAssertEqual(state.timers[0].duration, 25 * 60)
        XCTAssertEqual(state.timers[0].then, CountdownTimer.FollowUp(label: "Break", duration: 5 * 60))
        state.lastCheck = t0
        // Even when the app learns of it late (relaunch), the break starts when the focus part ended.
        let events = state.advance(to: t0 + 26 * 60, calendar: cal, announce: false)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(state.timers.count, 2)
        XCTAssertEqual(state.timers[1].label, "Break")
        XCTAssertEqual(state.timers[1].endsAt, t0 + 30 * 60)
        XCTAssertNil(state.timers[0].then)
    }

    func testBackups() {
        let cal = calendar()
        var state = TimeState()
        var running = CountdownTimer(label: "Tea", duration: 300)
        running.start(at: t0)
        var paused = CountdownTimer(duration: 300)
        paused.start(at: t0)
        paused.pause(at: t0 + 1)
        var done = CountdownTimer(duration: 10)
        done.start(at: t0 - 100)
        let alarm = Alarm(hour: 7, minute: 30, label: "Wake")
        var off = Alarm(hour: 8, minute: 0)
        off.enabled = false
        state.timers = [running, paused, done]
        state.alarms = [alarm, off]
        let backups = state.backups(now: t0 + 10, calendar: cal)
        XCTAssertEqual(backups.map(\.id), ["time.timer.\(running.id.uuidString)", "time.alarm.\(alarm.id.uuidString)"])
        XCTAssertEqual(backups[0].fireAt, t0 + 300 + TimeBackup.delay)
        XCTAssertEqual(backups[0].trigger, .interval(300 - 10 + TimeBackup.delay))
        XCTAssertEqual(backups[0].title, "Tea")
        let alarmFire = alarm.nextFire(after: t0 + 10, calendar: cal)!
        XCTAssertEqual(backups[1].fireAt, alarmFire + TimeBackup.delay)
        guard case .calendar(let comps) = backups[1].trigger else { return XCTFail("alarm backup must be a calendar trigger") }
        XCTAssertEqual(cal.date(from: comps), alarmFire + TimeBackup.delay)
        XCTAssertEqual(backups[1].title, "Wake")
    }

    func testBackupDiff() {
        let a = TimeBackup(id: "a", title: "A", body: "", fireAt: t0, trigger: .interval(5))
        let b = TimeBackup(id: "b", title: "B", body: "", fireAt: t0, trigger: .interval(5))
        let b2 = TimeBackup(id: "b", title: "B", body: "", fireAt: t0 + 60, trigger: .interval(65))
        let c = TimeBackup(id: "c", title: "C", body: "", fireAt: t0, trigger: .interval(5))
        let diff = TimeBackup.diff(old: [a, b], new: [b2, c])
        XCTAssertEqual(diff.schedule.map(\.id), ["b", "c"])
        XCTAssertEqual(diff.cancel, ["a"])
        // Same fire date: nothing to do even though the interval (relative to now) moved.
        let b3 = TimeBackup(id: "b", title: "B", body: "", fireAt: t0, trigger: .interval(3))
        XCTAssertEqual(TimeBackup.diff(old: [b], new: [b3]).schedule, [])
    }

    func testNextWake() {
        let cal = calendar()
        var state = TimeState()
        XCTAssertNil(state.nextWake(after: t0, calendar: cal))
        var timer = CountdownTimer(duration: 60)
        timer.start(at: t0)
        state.timers = [timer]
        XCTAssertEqual(state.nextWake(after: t0, calendar: cal), t0 + 60)
        state.alarms = [Alarm(hour: 7, minute: 30)]
        let now = date(2026, 10, 20, 7, 29)
        var s2 = TimeState()
        s2.alarms = state.alarms
        XCTAssertEqual(s2.nextWake(after: now, calendar: cal), date(2026, 10, 20, 7, 30))
    }

    func testCountdownCodableKeepsFields() throws {
        var timer = CountdownTimer(label: "x", duration: 90)
        timer.start(at: t0)
        let data = try JSONEncoder().encode(timer)
        XCTAssertEqual(try JSONDecoder().decode(CountdownTimer.self, from: data), timer)
    }
}
