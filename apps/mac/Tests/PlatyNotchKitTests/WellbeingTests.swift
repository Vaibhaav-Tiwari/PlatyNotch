import Foundation
import PlatyNotchKit   // not @testable: the wellbeing widget uses these through their public API (C6)
import XCTest

final class WellbeingTests: XCTestCase {
    private func calendar(_ tz: String = "America/New_York") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal
    }

    /// A wall-clock time in `cal`'s time zone.
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ cal: Calendar? = nil) -> Date {
        let cal = cal ?? calendar()
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func minutes(_ m: Double) -> TimeInterval { m * 60 }

    /// Every kind last done `ago` minutes before `now`.
    private func done(_ ago: Double, before now: Date) -> [NudgeKind: Date] {
        Dictionary(uniqueKeysWithValues: NudgeKind.allCases.map { ($0, now.addingTimeInterval(-minutes(ago))) })
    }

    // MARK: - Brief tests

    func testNoNudgeDuringFocus() {
        let s = NudgeSettings()
        let now = at(2026, 10, 21, 14)
        let overdue = done(90, before: now)
        let cal = calendar()
        XCTAssertEqual(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: overdue), calendar: cal), .eyes)
        XCTAssertNil(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: overdue, inFocusSession: true), calendar: cal))
        XCTAssertNil(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: overdue, inMeeting: true), calendar: cal))
        XCTAssertNil(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: overdue, fullScreen: true), calendar: cal))
    }

    func testQuietHoursAcrossMidnight() {
        let s = NudgeSettings(quietStart: 22, quietEnd: 8)
        let cal = calendar()
        XCTAssertFalse(NudgeScheduler.isQuiet(s, at: at(2026, 10, 21, 21, 59), calendar: cal))
        XCTAssertTrue(NudgeScheduler.isQuiet(s, at: at(2026, 10, 21, 22, 0), calendar: cal))
        XCTAssertTrue(NudgeScheduler.isQuiet(s, at: at(2026, 10, 21, 23, 30), calendar: cal))
        XCTAssertTrue(NudgeScheduler.isQuiet(s, at: at(2026, 10, 22, 0, 0), calendar: cal))
        XCTAssertTrue(NudgeScheduler.isQuiet(s, at: at(2026, 10, 22, 7, 59), calendar: cal))
        XCTAssertFalse(NudgeScheduler.isQuiet(s, at: at(2026, 10, 22, 8, 0), calendar: cal))
        let night = at(2026, 10, 21, 23, 30)
        XCTAssertNil(NudgeScheduler.due(s, NudgeContext(now: night, lastDone: done(90, before: night)), calendar: cal))

        // Same-day window, and start == end means no quiet hours.
        let lunch = NudgeSettings(quietStart: 12, quietEnd: 13)
        XCTAssertTrue(NudgeScheduler.isQuiet(lunch, at: at(2026, 10, 21, 12, 30), calendar: cal))
        XCTAssertFalse(NudgeScheduler.isQuiet(lunch, at: at(2026, 10, 21, 23, 30), calendar: cal))
        let none = NudgeSettings(quietStart: 0, quietEnd: 0)
        XCTAssertFalse(NudgeScheduler.isQuiet(none, at: at(2026, 10, 21, 3), calendar: cal))
        XCTAssertNil(NudgeScheduler.quietEnd(after: at(2026, 10, 21, 3), none, calendar: cal))
    }

    /// Ruling (Task 8, C28): idle ≥ 300 s counts as a break. `due` is nil while idle, and
    /// the break resets stand and eyes (not water).
    func testIdleCountsAsABreak() {
        let s = NudgeSettings()
        let cal = calendar()
        let now = at(2026, 10, 21, 14)
        let overdue = done(90, before: now)

        // While idle: nothing, however overdue.
        XCTAssertNil(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: overdue, idleSeconds: 300), calendar: cal))
        XCTAssertNil(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: overdue, idleSeconds: 3600), calendar: cal))
        XCTAssertEqual(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: overdue, idleSeconds: 299), calendar: cal), .eyes)

        // The idle stretch resets stand and eyes to now; water keeps its time.
        let after = NudgeScheduler.recordingBreaks(overdue, settings: s, now: now, idleSeconds: 300, calendar: cal)
        XCTAssertEqual(after[.stand], now)
        XCTAssertEqual(after[.eyes], now)
        XCTAssertEqual(after[.water], overdue[.water])
        // Back at the keyboard a minute later: only water is still due.
        let back = now.addingTimeInterval(60)
        XCTAssertEqual(NudgeScheduler.due(s, NudgeContext(now: back, lastDone: after, idleSeconds: 2), calendar: cal), .water)

        // A shorter pause is no break.
        let short = NudgeScheduler.recordingBreaks(overdue, settings: s, now: now, idleSeconds: 299, calendar: cal)
        XCTAssertEqual(short, overdue)
    }

    func testPriorityEyesFirst() {
        let s = NudgeSettings()
        let cal = calendar()
        let now = at(2026, 10, 21, 14)
        XCTAssertEqual(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: done(90, before: now)), calendar: cal), .eyes)
        var last = done(90, before: now)
        last[.eyes] = now.addingTimeInterval(-minutes(5))
        XCTAssertEqual(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: last), calendar: cal), .stand)
        last[.stand] = now.addingTimeInterval(-minutes(5))
        XCTAssertEqual(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: last), calendar: cal), .water)
        last[.water] = now.addingTimeInterval(-minutes(5))
        XCTAssertNil(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: last), calendar: cal))
    }

    func testWaterCountPerDay() {
        let cal = calendar()
        var log = WaterLog()
        log.add(at: at(2026, 10, 20, 23, 50))
        log.add(at: at(2026, 10, 21, 0, 10))
        log.add(at: at(2026, 10, 21, 9))
        log.add(at: at(2026, 10, 21, 23, 59))
        XCTAssertEqual(log.count(on: at(2026, 10, 20, 12), calendar: cal), 1)
        XCTAssertEqual(log.count(on: at(2026, 10, 21, 12), calendar: cal), 3)
        XCTAssertEqual(log.count(on: at(2026, 10, 22, 12), calendar: cal), 0)
        // The day follows the injected calendar's time zone: in Tokyo the first three
        // glasses fall on the 21st (12:50, 13:10, 22:00 JST) and the last on the 22nd.
        let tokyo = calendar("Asia/Tokyo")
        XCTAssertEqual(log.count(on: at(2026, 10, 21, 12, 0, tokyo), calendar: tokyo), 3)
        XCTAssertEqual(log.count(on: at(2026, 10, 22, 12, 0, tokyo), calendar: tokyo), 1)
    }

    // MARK: - More

    func testWaterKeepsFourteenDays() throws {
        var log = WaterLog()
        let start = at(2026, 10, 1, 9)
        for day in 0..<20 { log.add(at: start.addingTimeInterval(Double(day) * 86_400)) }
        XCTAssertEqual(log.glasses.count, 14)
        XCTAssertEqual(log.glasses.first, start.addingTimeInterval(6 * 86_400))
        // Round-trips as a small Codable value.
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(WaterLog.self, from: data), log)
        XCTAssertLessThan(data.count, 2_000)
    }

    func testIntervalZeroIsOff() {
        let s = NudgeSettings(water: 0, stand: 0, eyes: 20)
        let cal = calendar()
        let now = at(2026, 10, 21, 14)
        XCTAssertNil(s.interval(.water))
        XCTAssertEqual(s.interval(.eyes), minutes(20))
        var last = done(500, before: now)
        last[.eyes] = now.addingTimeInterval(-minutes(1))
        XCTAssertNil(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: last), calendar: cal))
        XCTAssertFalse(NudgeSettings(water: 0, stand: 0, eyes: 0).anyOn)
        XCTAssertNil(NudgeScheduler.nextWake(NudgeSettings(water: 0, stand: 0, eyes: 0), lastDone: last,
                                             snoozedUntil: [:], now: now, calendar: cal))
    }

    func testNeverDoneIsNotDue() {
        // The widget seeds lastDone when it starts; an unknown kind never nudges at once.
        XCTAssertNil(NudgeScheduler.due(NudgeSettings(), NudgeContext(now: at(2026, 10, 21, 14), lastDone: [:]),
                                        calendar: calendar()))
    }

    func testSnoozeDelaysOnlyThatKind() {
        let s = NudgeSettings()
        let cal = calendar()
        let now = at(2026, 10, 21, 14)
        let last = done(90, before: now)
        let snoozed: [NudgeKind: Date] = [.eyes: now.addingTimeInterval(NudgeScheduler.snooze)]
        XCTAssertEqual(NudgeScheduler.due(s, NudgeContext(now: now, lastDone: last, snoozedUntil: snoozed), calendar: cal), .stand)
        let later = now.addingTimeInterval(NudgeScheduler.snooze)
        XCTAssertEqual(NudgeScheduler.due(s, NudgeContext(now: later, lastDone: last, snoozedUntil: snoozed), calendar: cal), .eyes)
    }

    func testNextWakeIsTheNextDueTime() {
        let s = NudgeSettings()
        let cal = calendar()
        let now = at(2026, 10, 21, 14)
        let last = done(0, before: now)
        // Eyes (20 min) comes first: one wake then, no polling.
        XCTAssertEqual(NudgeScheduler.nextWake(s, lastDone: last, snoozedUntil: [:], now: now, calendar: cal),
                       now.addingTimeInterval(minutes(20)))
        // Never sooner than a minute, even when overdue.
        XCTAssertEqual(NudgeScheduler.nextWake(s, lastDone: done(90, before: now), snoozedUntil: [:], now: now, calendar: cal),
                       now.addingTimeInterval(NudgeScheduler.minimumWake))
        // Not before `notBefore` (spacing between nudges, the grace after a wake).
        let notBefore = now.addingTimeInterval(NudgeScheduler.spacing)
        XCTAssertEqual(NudgeScheduler.nextWake(s, lastDone: done(90, before: now), snoozedUntil: [:], now: now,
                                               notBefore: notBefore, calendar: cal), notBefore)
        // A snooze moves that kind's wake.
        var snoozed = done(0, before: now)
        snoozed[.eyes] = now.addingTimeInterval(minutes(30))
        XCTAssertEqual(NudgeScheduler.nextWake(s, lastDone: last, snoozedUntil: snoozed, now: now, calendar: cal),
                       now.addingTimeInterval(minutes(30)))
    }

    func testNextWakeSkipsQuietHours() {
        let s = NudgeSettings()
        let cal = calendar()
        let now = at(2026, 10, 21, 21, 50)
        // Eyes would be due at 22:10, inside quiet hours: wake at 08:00 instead.
        XCTAssertEqual(NudgeScheduler.nextWake(s, lastDone: done(0, before: now), snoozedUntil: [:], now: now, calendar: cal),
                       at(2026, 10, 22, 8))
    }

    func testQuietEndRestartsIntervals() {
        let s = NudgeSettings()
        let cal = calendar()
        let morning = at(2026, 10, 22, 8, 5)
        let evening = done(0, before: at(2026, 10, 21, 21, 30))
        let after = NudgeScheduler.recordingBreaks(evening, settings: s, now: morning, idleSeconds: 0, calendar: cal)
        for kind in NudgeKind.allCases { XCTAssertEqual(after[kind], at(2026, 10, 22, 8)) }
        XCTAssertNil(NudgeScheduler.due(s, NudgeContext(now: morning, lastDone: after), calendar: cal),
                     "no burst of three nudges as quiet hours end")
        // Done after the quiet end: unchanged.
        let fresh = done(1, before: morning)
        XCTAssertEqual(NudgeScheduler.recordingBreaks(fresh, settings: s, now: morning, idleSeconds: 0, calendar: cal), fresh)
    }

    // MARK: - DST (America/New_York: 2026-03-08 02:00 → 03:00, 2026-11-01 02:00 → 01:00)

    func testQuietHoursSpringForward() {
        let cal = calendar()
        let s = NudgeSettings()
        // 21:50 EST on the eve: quiet ends at 08:00 EDT, which is 12:00 UTC (not 13:00).
        let eve = at(2026, 3, 7, 21, 50)
        let wake = NudgeScheduler.nextWake(s, lastDone: done(0, before: eve), snoozedUntil: [:], now: eve, calendar: cal)
        XCTAssertEqual(wake, at(2026, 3, 8, 8))
        XCTAssertEqual(wake, Date(timeIntervalSince1970: 1_772_971_200))   // 2026-03-08T12:00:00Z
        XCTAssertEqual(wake.map { cal.component(.hour, from: $0) }, 8)

        // Quiet hours ending in the skipped hour end at the first hour after it.
        let early = NudgeSettings(quietStart: 22, quietEnd: 2)
        let night = at(2026, 3, 8, 1, 30)
        XCTAssertTrue(NudgeScheduler.isQuiet(early, at: night, calendar: cal))
        let end = NudgeScheduler.quietEnd(after: night, early, calendar: cal)
        XCTAssertEqual(end, Date(timeIntervalSince1970: 1_772_953_200))   // 03:00 EDT = 07:00Z
        XCTAssertFalse(NudgeScheduler.isQuiet(early, at: end!, calendar: cal))
    }

    func testQuietHoursFallBack() {
        let cal = calendar()
        let s = NudgeSettings()
        // 01:30 happens twice; both are quiet.
        let firstOneThirty = Date(timeIntervalSince1970: 1_793_511_000)    // 05:30Z = 01:30 EDT
        let secondOneThirty = Date(timeIntervalSince1970: 1_793_514_600)   // 06:30Z = 01:30 EST
        XCTAssertEqual(cal.component(.hour, from: firstOneThirty), 1)
        XCTAssertEqual(cal.component(.hour, from: secondOneThirty), 1)
        XCTAssertTrue(NudgeScheduler.isQuiet(s, at: firstOneThirty, calendar: cal))
        XCTAssertTrue(NudgeScheduler.isQuiet(s, at: secondOneThirty, calendar: cal))
        // Quiet ends at 08:00 EST = 13:00Z, a 25-hour day.
        XCTAssertEqual(NudgeScheduler.quietEnd(after: at(2026, 10, 31, 23), s, calendar: cal),
                       Date(timeIntervalSince1970: 1_793_538_000))
    }

    // MARK: - Settings and persistence

    func testSettingsDefaultsAndTolerantDecoding() throws {
        let s = NudgeSettings()
        XCTAssertEqual([s.water, s.stand, s.eyes, s.quietStart, s.quietEnd, s.dailyWaterGoal], [60, 50, 20, 22, 8, 8])
        // Missing keys take defaults; out-of-range values are clamped.
        let partial = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"eyes": 0, "quietStart": 30, "dailyWaterGoal": -2}"#.utf8))
        XCTAssertEqual(partial.eyes, 0)
        XCTAssertEqual(partial.water, 60)
        XCTAssertEqual(partial.quietStart, 23)
        XCTAssertEqual(partial.dailyWaterGoal, 1)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(NudgeSettings.self, from: data), s)
    }

    func testProgressRoundTrips() throws {
        let now = at(2026, 10, 21, 14)
        let p = NudgeProgress(lastDone: done(3, before: now), snoozedUntil: [.water: now])
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(NudgeProgress.self, from: data), p)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"eyes\""), "kinds are keys, not array items")
    }
}
