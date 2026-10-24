import Foundation
import XCTest
@testable import PlatyNotchKit

/// Plan 3b Task 7: quick add, meeting reminders and join links, weather.
final class DayTests: XCTestCase {
    /// New York, Friday 23 October 2026.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, in c: Calendar? = nil) -> Date {
        (c ?? cal).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func parse(_ s: String, at now: Date) -> QuickAdd {
        QuickAddParser.parse(s, now: now, calendar: cal)
    }

    // MARK: - Quick add

    func testQuickAddTimeToday() {
        let q = parse("call Priya at 5pm", at: date(2026, 10, 23, 14))
        XCTAssertEqual(q.title, "Call Priya")
        XCTAssertEqual(q.due, date(2026, 10, 23, 17))
        XCTAssertTrue(q.hasTime)
        XCTAssertFalse(q.isEvent, "a call without \"call with\" is a reminder")
        XCTAssertNil(q.duration)
    }

    func testQuickAddPastTimeTomorrow() {
        let q = parse("call Priya at 5pm", at: date(2026, 10, 23, 18))
        XCTAssertEqual(q.title, "Call Priya")
        XCTAssertEqual(q.due, date(2026, 10, 24, 17))
        // Exactly now is past too.
        XCTAssertEqual(parse("call Priya at 5pm", at: date(2026, 10, 23, 17)).due, date(2026, 10, 24, 17))
    }

    func testQuickAddEvent() {
        let q = parse("meeting with Sam tomorrow 3pm for 30 min", at: date(2026, 10, 23, 14))
        XCTAssertEqual(q.title, "Meeting with Sam")
        XCTAssertEqual(q.due, date(2026, 10, 24, 15))
        XCTAssertTrue(q.isEvent)
        XCTAssertEqual(q.duration, 30 * 60)
        XCTAssertEqual(q.eventEnd, date(2026, 10, 24, 15, 30))
    }

    func testQuickAddNoDate() {
        let q = parse("buy milk", at: date(2026, 10, 23, 14))
        XCTAssertEqual(q, QuickAdd(title: "Buy milk", due: nil, isEvent: false))
        XCTAssertNil(q.eventEnd)
        // The event words alone are not enough: an event needs a date.
        let notes = parse("meeting notes for Sam", at: date(2026, 10, 23, 14))
        XCTAssertFalse(notes.isEvent)
        XCTAssertNil(notes.due)
        XCTAssertEqual(notes.title, "Meeting notes for Sam")
        // Numbers that are not times stay in the title.
        XCTAssertEqual(parse("read 5 pages", at: date(2026, 10, 23, 14)), QuickAdd(title: "Read 5 pages", due: nil, isEvent: false))
        // A duration without a date stays in the title of a plain reminder.
        let practice = parse("practice piano for 30 min", at: date(2026, 10, 23, 14))
        XCTAssertEqual(practice, QuickAdd(title: "Practice piano for 30 min", due: nil, isEvent: false))
    }

    func testQuickAddEmptyAndWhitespace() {
        XCTAssertEqual(parse("   ", at: date(2026, 10, 23, 14)).title, "")
        XCTAssertNil(parse("", at: date(2026, 10, 23, 14)).due)
        // Only a date: the title falls back to a word.
        let onlyTime = parse("at 5pm", at: date(2026, 10, 23, 14))
        XCTAssertEqual(onlyTime.title, "Reminder")
        XCTAssertEqual(onlyTime.due, date(2026, 10, 23, 17))
    }

    func testQuickAddPhrases() {
        let now = date(2026, 10, 23, 14)   // Friday 14:00
        struct Case { let text: String; let title: String; let due: Date?; let event: Bool; let duration: TimeInterval?; let hasTime: Bool }
        let cases: [Case] = [
            Case(text: "submit report by 17:30", title: "Submit report", due: date(2026, 10, 23, 17, 30), event: false, duration: nil, hasTime: true),
            Case(text: "pay rent tomorrow", title: "Pay rent", due: date(2026, 10, 24), event: false, duration: nil, hasTime: false),
            Case(text: "stretch in 20 min", title: "Stretch", due: date(2026, 10, 23, 14, 20), event: false, duration: nil, hasTime: true),
            Case(text: "check the oven in an hour", title: "Check the oven", due: date(2026, 10, 23, 15), event: false, duration: nil, hasTime: true),
            Case(text: "call with Raj at 10:30am", title: "Call with Raj", due: date(2026, 10, 24, 10, 30), event: true, duration: nil, hasTime: true),
            Case(text: "standup meeting at 9", title: "Standup meeting", due: date(2026, 10, 24, 9), event: true, duration: nil, hasTime: true),
            Case(text: "water plants at 5", title: "Water plants", due: date(2026, 10, 23, 17), event: false, duration: nil, hasTime: true),
            Case(text: "lunch with Ana monday", title: "Lunch with Ana", due: date(2026, 10, 26, 12), event: true, duration: nil, hasTime: true),
            Case(text: "lunch tomorrow", title: "Lunch", due: date(2026, 10, 24, 12), event: true, duration: nil, hasTime: true),
            Case(text: "team sync friday 4pm for 1.5 hours", title: "Team sync", due: date(2026, 10, 23, 16), event: true, duration: 5400, hasTime: true),
            Case(text: "Meeting with Sam next tuesday at noon for an hour", title: "Meeting with Sam", due: date(2026, 10, 27, 12), event: true, duration: 3600, hasTime: true),
            Case(text: "1:1 meeting for 1h 30m tomorrow 11am", title: "1:1 meeting", due: date(2026, 10, 24, 11), event: true, duration: 5400, hasTime: true),
            Case(text: "dentist on nov 3 at 9:15am", title: "Dentist", due: date(2026, 11, 3, 9, 15), event: false, duration: nil, hasTime: true),
            Case(text: "send card 2nd of January", title: "Send card", due: date(2027, 1, 2), event: false, duration: nil, hasTime: false),
            Case(text: "dinner tonight", title: "Dinner", due: date(2026, 10, 23, 20), event: false, duration: nil, hasTime: true),
            Case(text: "gym tomorrow morning", title: "Gym", due: date(2026, 10, 24, 9), event: false, duration: nil, hasTime: true),
            Case(text: "take out bins on fri", title: "Take out bins", due: date(2026, 10, 23), event: false, duration: nil, hasTime: false),
            Case(text: "review PR friday at 9am", title: "Review PR", due: date(2026, 10, 30, 9), event: false, duration: nil, hasTime: true),
            Case(text: "plan week next friday", title: "Plan week", due: date(2026, 10, 30), event: false, duration: nil, hasTime: false),
            Case(text: "Email Jo @ 4:45 PM", title: "Email Jo", due: date(2026, 10, 23, 16, 45), event: false, duration: nil, hasTime: true),
            Case(text: "pick up Mia at 3 p.m.", title: "Pick up Mia", due: date(2026, 10, 23, 15), event: false, duration: nil, hasTime: true),
            Case(text: "renew passport in 2 days", title: "Renew passport", due: date(2026, 10, 25), event: false, duration: nil, hasTime: false),
            Case(text: "midnight snack at midnight", title: "Midnight snack", due: date(2026, 10, 24, 0), event: false, duration: nil, hasTime: true),
            Case(text: "sat down with notes", title: "Sat down with notes", due: nil, event: false, duration: nil, hasTime: false),
        ]
        for c in cases {
            let q = parse(c.text, at: now)
            XCTAssertEqual(q.title, c.title, c.text)
            XCTAssertEqual(q.due, c.due, c.text)
            XCTAssertEqual(q.isEvent, c.event, c.text)
            XCTAssertEqual(q.duration, c.duration, c.text)
            XCTAssertEqual(q.hasTime, c.hasTime, c.text)
        }
    }

    /// Fix round 2: the reviewer's probe table. New York, now = Fri 2026-10-23 14:00 unless
    /// a row says otherwise. `due` nil means no date; `time` false means a day only.
    func testQuickAddProbeTable() {
        struct Row {
            let text: String
            var now: Date? = nil
            let title: String
            let due: Date?
            var time = true
            var event = false
            var duration: TimeInterval? = nil
            var past = false
        }
        let fri = date(2026, 10, 23, 14)
        let rows: [Row] = [
            // Month names inside words and "may".
            Row(text: "order 6 decaf beans", title: "Order 6 decaf beans", due: nil, time: false),
            Row(text: "buy 2 marshmallows", title: "Buy 2 marshmallows", due: nil, time: false),
            Row(text: "bring 3 mayo jars", title: "Bring 3 mayo jars", due: nil, time: false),
            Row(text: "read 4 junk mail", title: "Read 4 junk mail", due: nil, time: false),
            Row(text: "call may 3 times", title: "Call may 3 times", due: nil, time: false),
            Row(text: "dinner may 3", title: "Dinner", due: date(2027, 5, 3), time: false),
            Row(text: "on may 3 dentist", title: "Dentist", due: date(2027, 5, 3), time: false),
            Row(text: "may 3rd 2pm call with Sam", title: "Call with Sam", due: date(2027, 5, 3, 14), event: true),
            // Weekdays.
            Row(text: "call wed 3pm", title: "Call", due: date(2026, 10, 28, 15)),
            Row(text: "fri review", title: "Review", due: date(2026, 10, 23), time: false),
            Row(text: "review Thurs", title: "Review", due: date(2026, 10, 29), time: false),
            Row(text: "sat down with Tom", title: "Sat down with Tom", due: nil, time: false),
            Row(text: "sun 10am brunch", title: "Brunch", due: date(2026, 10, 25, 10)),
            // A bare hour counts only right after the day, at the end: "9" stays here.
            Row(text: "next mon standup 9", title: "Standup 9", due: date(2026, 10, 26), time: false),
            Row(text: "wed 9", title: "Reminder", due: date(2026, 10, 28, 9)),
            Row(text: "this friday lunch with Priya", title: "Lunch with Priya", due: date(2026, 10, 23, 12), event: true, past: true),
            // Day words.
            Row(text: "tomorrow 9", title: "Reminder", due: date(2026, 10, 24, 9)),
            Row(text: "pay bill day after tomorrow", title: "Pay bill", due: date(2026, 10, 25), time: false),
            Row(text: "tonight", now: date(2026, 10, 23, 19), title: "Reminder", due: date(2026, 10, 23, 20)),
            Row(text: "tonight", now: date(2026, 10, 23, 23, 50), title: "Reminder", due: date(2026, 10, 24, 1)),
            Row(text: "tonight 9", title: "Reminder", due: date(2026, 10, 23, 21)),
            Row(text: "call tonight at 9", now: date(2026, 10, 23, 22), title: "Call", due: date(2026, 10, 23, 21), past: true),
            Row(text: "tonight 11", title: "Reminder", due: date(2026, 10, 23, 23)),
            Row(text: "tomorrow midnight", title: "Reminder", due: date(2026, 10, 25, 0)),
            Row(text: "today 8", title: "Reminder", due: date(2026, 10, 23, 8), past: true),
            // Times alone: today if ahead, else tomorrow.
            Row(text: "at 12", title: "Reminder", due: date(2026, 10, 24, 12)),
            Row(text: "noon", title: "Reminder", due: date(2026, 10, 24, 12)),
            Row(text: "in 2 hours", title: "Reminder", due: date(2026, 10, 23, 16)),
            Row(text: "in 90 minutes", title: "Reminder", due: date(2026, 10, 23, 15, 30)),
            Row(text: "every day at 9", title: "Every day", due: date(2026, 10, 24, 9)),
            Row(text: "every monday at 9", title: "Every monday", due: date(2026, 10, 26, 9)),
            Row(text: "call mom at 5", title: "Call mom", due: date(2026, 10, 23, 17)),
            Row(text: "call Priya at 5pm", title: "Call Priya", due: date(2026, 10, 23, 17)),
            // A range is a start and a duration, so it is an event (C26).
            Row(text: "meeting 3-4pm", title: "Meeting", due: date(2026, 10, 23, 15), event: true, duration: 3600),
            Row(text: "sync 3pm-4:30pm", title: "Sync", due: date(2026, 10, 23, 15), event: true, duration: 5400),
            Row(text: "review 3 to 4pm", title: "Review", due: date(2026, 10, 23, 15), event: true, duration: 3600),
            Row(text: "standup 11-1pm tomorrow", title: "Standup", due: date(2026, 10, 24, 11), event: true, duration: 7200),
            Row(text: "block 15:00-16:00", title: "Block", due: date(2026, 10, 23, 15), event: true, duration: 3600),
            Row(text: "meet 10.30pm", title: "Meet", due: date(2026, 10, 23, 22, 30)),
            // Absolute dates.
            Row(text: "2027-12-01 renew passport", title: "Renew passport", due: date(2027, 12, 1), time: false),
            Row(text: "call 2027-12-01 9pm", title: "Call", due: date(2027, 12, 1, 21)),
            Row(text: "sync 2027-12-01 15:00", title: "Sync", due: date(2027, 12, 1, 15)),
            // The absolute date wins; the conflicting word stays in the title.
            Row(text: "pay 2027-12-01 tomorrow", title: "Pay tomorrow", due: date(2027, 12, 1), time: false),
            // Numeric slash dates are locale-ambiguous: no date at all.
            Row(text: "12/01 renew passport", title: "12/01 renew passport", due: nil, time: false),
            Row(text: "renew 12/01/2027 9am", title: "Renew 12/01/2027 9am", due: nil, time: false),
            // Days that do not exist.
            Row(text: "jan 32", title: "Jan 32", due: nil, time: false),
            Row(text: "feb 30 pay", title: "Feb 30 pay", due: nil, time: false),
            Row(text: "2027-02-30 pay", title: "2027-02-30 pay", due: nil, time: false),
            // A number that is not right before the end stays.
            Row(text: "tomorrow 5 apples", title: "5 apples", due: date(2026, 10, 24), time: false),
            Row(text: "buy tomorrow 3 apples", title: "Buy 3 apples", due: date(2026, 10, 24), time: false),
            // No real clock: now in 2020.
            Row(text: "pay rent tomorrow", now: date(2020, 3, 4, 10), title: "Pay rent", due: date(2020, 3, 5), time: false),
            Row(text: "fri review", now: date(2020, 3, 4, 10), title: "Review", due: date(2020, 3, 6), time: false),
            Row(text: "dinner may 3", now: date(2020, 3, 4, 10), title: "Dinner", due: date(2020, 5, 3), time: false),
            Row(text: "jan 3 dentist", now: date(2020, 3, 4, 10), title: "Dentist", due: date(2021, 1, 3), time: false),
            Row(text: "feb 29 leap", now: date(2020, 3, 4, 10), title: "Leap", due: date(2024, 2, 29), time: false),
            Row(text: "call Priya at 5pm", now: date(2020, 3, 4, 10), title: "Call Priya", due: date(2020, 3, 4, 17)),
            Row(text: "file 2020-03-01", now: date(2020, 3, 4, 10), title: "File", due: date(2020, 3, 1), time: false, past: true),
            Row(text: "12/01 renew passport", now: date(2020, 3, 4, 10), title: "12/01 renew passport", due: nil, time: false),
            // Controller probe: "H:MM" without am/pm reads like "at H"; a leading zero or 13+ is 24 h.
            Row(text: "pick up kids at 3:15", title: "Pick up kids", due: date(2026, 10, 23, 15, 15)),
            Row(text: "call at 7:45", title: "Call", due: date(2026, 10, 23, 19, 45)),
            Row(text: "standup at 9:30", title: "Standup", due: date(2026, 10, 24, 9, 30)),
            Row(text: "alarm 03:15", title: "Alarm", due: date(2026, 10, 24, 3, 15)),
            Row(text: "call at 17:30", title: "Call", due: date(2026, 10, 23, 17, 30)),
            Row(text: "pickup tonight at 9:30", now: date(2026, 10, 23, 19), title: "Pickup", due: date(2026, 10, 23, 21, 30)),
            // A rejected time keeps its words.
            Row(text: "at 13pm", title: "13pm", due: nil, time: false),
            Row(text: "at 13pm tomorrow", title: "13pm", due: date(2026, 10, 24), time: false),
        ]
        for r in rows {
            let q = parse(r.text, at: r.now ?? fri)
            let label = "\(r.text) @ \(r.now ?? fri)"
            XCTAssertEqual(q.title, r.title, label)
            XCTAssertEqual(q.due, r.due, label)
            XCTAssertEqual(q.hasTime, r.due == nil ? false : r.time, label)
            XCTAssertEqual(q.isEvent, r.event, label)
            XCTAssertEqual(q.duration, r.duration, label)
            XCTAssertEqual(q.isPast, r.past, label)
        }
    }

    /// The three DST cases (New York).
    func testQuickAddDaylightSavingCases() {
        // Spring forward, 14 March 2027: 2:00–3:00 does not exist; both give 3:30.
        let spring = date(2027, 3, 13, 22)
        let a = parse("at 2:30am", at: spring).due
        let b = parse("tomorrow at 2:30am", at: spring).due
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.map { cal.dateComponents([.day, .hour, .minute], from: $0) },
                       DateComponents(day: 14, hour: 3, minute: 30))
        // Fall back, 7 November 2027: 1:30 happens twice; the first (still EDT) is taken.
        let fall = parse("at 1:30am", at: date(2027, 11, 6, 22)).due
        XCTAssertEqual(fall.map { cal.dateComponents([.day, .hour, .minute], from: $0) },
                       DateComponents(day: 7, hour: 1, minute: 30))
        XCTAssertEqual(fall.map { cal.timeZone.isDaylightSavingTime(for: $0) }, true)
    }

    /// Review fix 1: month names never match inside words, and "may" needs date context.
    func testQuickAddMonthNamesAreWholeWords() {
        let now = date(2026, 10, 23, 14)
        for text in ["order 6 decaf beans", "buy 2 marshmallows", "bring 3 mayo jars", "read 4 junk mail", "call may 3 times"] {
            let q = parse(text, at: now)
            XCTAssertNil(q.due, text)
            XCTAssertEqual(q.title, text.prefix(1).uppercased() + text.dropFirst(), text)
        }
        // Real months still work, "may" with context too.
        XCTAssertEqual(parse("dentist may 3", at: now).due, date(2027, 5, 3))
        XCTAssertEqual(parse("dentist may 3rd", at: now).due, date(2027, 5, 3))
        XCTAssertEqual(parse("dentist on may 3", at: now).due, date(2027, 5, 3))
        XCTAssertEqual(parse("dentist may 3 at 9am", at: now).due, date(2027, 5, 3, 9))
        XCTAssertEqual(parse("send card dec 6", at: now).due, date(2026, 12, 6))
        XCTAssertEqual(parse("send card 6 dec.", at: now).due, date(2026, 12, 6))
    }

    /// Review fix 2: unprefixed weekdays use the injected clock (2020 here), never the real one.
    func testQuickAddUnprefixedWeekdaysUseInjectedNow() {
        let now = date(2020, 3, 4, 10)   // Wednesday 4 March 2020, 10:00
        XCTAssertEqual(cal.component(.weekday, from: now), 4)
        let wed = parse("call wed 3pm", at: now)
        XCTAssertEqual(wed.title, "Call")
        XCTAssertEqual(wed.due, date(2020, 3, 4, 15), "today is Wednesday and 15:00 is still ahead")
        XCTAssertEqual(parse("call wed 9am", at: now).due, date(2020, 3, 11, 9), "today's time has passed: next week")
        let fri = parse("fri review", at: now)
        XCTAssertEqual(fri.title, "Review")
        XCTAssertEqual(fri.due, date(2020, 3, 6))
        XCTAssertFalse(fri.hasTime)
        let thurs = parse("review Thurs", at: now)
        XCTAssertEqual(thurs.title, "Review")
        XCTAssertEqual(thurs.due, date(2020, 3, 5))
        XCTAssertEqual(parse("standup tues 9:30", at: now).due, date(2020, 3, 10, 9, 30))
        XCTAssertEqual(parse("gym mon", at: now).due, date(2020, 3, 9))
        XCTAssertEqual(parse("brunch sun 11am", at: now).due, date(2020, 3, 8, 11))
        XCTAssertEqual(parse("lunch with Ana sat", at: now).due, date(2020, 3, 7, 12))
        XCTAssertEqual(parse("thursday", at: now).title, "Reminder")
        // "sat"/"sun" as words stay text; detector answers without a year or number are discarded.
        XCTAssertNil(parse("sat down with notes", at: now).due)
        XCTAssertNil(parse("buy sun cream", at: now).due)
        XCTAssertNil(parse("plan trip next week", at: now).due, "NSDataDetector's \"next week\" uses the real clock")
        XCTAssertNil(parse("call mom now", at: now).due)
        // Relative phrases all follow the injected 2020 clock.
        XCTAssertEqual(parse("pay rent tomorrow", at: now).due, date(2020, 3, 5))
        XCTAssertEqual(parse("call Priya at 5pm", at: now).due, date(2020, 3, 4, 17))
    }

    func testQuickAddDayWordRules() {
        let now = date(2026, 10, 23, 14)
        XCTAssertEqual(parse("gym tomorrow 9", at: now).due, date(2026, 10, 24, 9))
        XCTAssertEqual(parse("gym tomorrow at 9", at: now).due, date(2026, 10, 24, 9))
        XCTAssertEqual(parse("call Raj tomorrow 5", at: now).due, date(2026, 10, 24, 17), "1–7 mean the afternoon")
        XCTAssertEqual(parse("buy 3 apples tomorrow", at: now).title, "Buy 3 apples")
        let dat = parse("renew visa day after tomorrow", at: now)
        XCTAssertEqual(dat.title, "Renew visa")
        XCTAssertEqual(dat.due, date(2026, 10, 25))
        XCTAssertEqual(parse("call mum day after tomorrow at 6pm", at: now).due, date(2026, 10, 25, 18))
        // Midnight is the end of the day named.
        XCTAssertEqual(parse("submit tomorrow midnight", at: now).due, date(2026, 10, 25, 0))
        XCTAssertEqual(parse("submit tomorrow at midnight", at: now).due, date(2026, 10, 25, 0))
        XCTAssertEqual(parse("submit at midnight", at: now).due, date(2026, 10, 24, 0))
        // "tonight" after 20:00: now + 1 h, rounded up to the quarter hour.
        XCTAssertEqual(parse("dinner tonight", at: date(2026, 10, 23, 19)).due, date(2026, 10, 23, 20))
        XCTAssertEqual(parse("call back tonight", at: date(2026, 10, 23, 21, 10)).due, date(2026, 10, 23, 22, 15))
        XCTAssertEqual(parse("call back tonight", at: date(2026, 10, 23, 20)).due, date(2026, 10, 23, 21))
        XCTAssertEqual(parse("call back tonight at 11pm", at: date(2026, 10, 23, 21)).due, date(2026, 10, 23, 23))
    }

    /// 14 March 2027, New York: 2:00–3:00 does not exist. Both phrasings give 3:30.
    func testQuickAddSpringForwardGap() {
        let now = date(2027, 3, 13, 22)
        let a = parse("feed cat at 2:30am", at: now).due
        let b = parse("feed cat tomorrow at 2:30am", at: now).due
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.map { cal.component(.day, from: $0) }, 14)
        XCTAssertEqual(a.map { cal.component(.hour, from: $0) }, 3)
        XCTAssertEqual(a.map { cal.component(.minute, from: $0) }, 30)
    }

    /// Absolute dates are parsed by the phrase rules alone (no NSDataDetector).
    func testQuickAddAbsoluteDatesWithoutDetector() {
        let now = date(2020, 3, 4, 10)
        XCTAssertEqual(parse("file taxes 1 Dec 2027", at: now).due, date(2027, 12, 1), "phrase rule with a year")
        XCTAssertEqual(parse("renew passport 2027-12-01", at: now).due, date(2027, 12, 1))
    }

    /// ISO dates.
    func testQuickAddISODate() {
        let q = parse("renew passport 2027-12-01", at: date(2026, 10, 23, 14))
        XCTAssertEqual(q.title, "Renew passport")
        XCTAssertEqual(q.due, date(2027, 12, 1))
        XCTAssertFalse(q.hasTime)
    }

    /// The injected calendar's time zone decides what 5pm means, not the Mac's.
    func testQuickAddUsesInjectedTimeZone() {
        var kolkata = Calendar(identifier: .gregorian)
        kolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = date(2026, 10, 23, 9, in: kolkata)
        let q = QuickAddParser.parse("call Priya at 5pm", now: now, calendar: kolkata)
        XCTAssertEqual(q.due, date(2026, 10, 23, 17, in: kolkata))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 9:00 in Kolkata is 12:30 in Tokyo: 5pm is still today there.
        XCTAssertEqual(QuickAddParser.parse("call Priya at 5pm", now: now, calendar: tokyo).due, date(2026, 10, 23, 17, in: tokyo))
        // "tomorrow" follows the injected calendar's day, too (23:30 New York is already Saturday in Tokyo).
        let late = date(2026, 10, 23, 23, 30)
        XCTAssertEqual(QuickAddParser.parse("pay rent tomorrow", now: late, calendar: tokyo).due, date(2026, 10, 25, in: tokyo))
    }

    func testQuickAddDurationOnlyWithDate() {
        let q = parse("deep work tomorrow 9am for 2 hours", at: date(2026, 10, 23, 14))
        XCTAssertTrue(q.isEvent, "a duration phrase makes it an event")
        XCTAssertEqual(q.title, "Deep work")
        XCTAssertEqual(q.eventEnd, date(2026, 10, 24, 11))
    }

    // MARK: - Reminders list and preview

    func testRemindersTodayAndOverdue() {
        let now = date(2026, 10, 23, 14)
        let items = [
            ReminderItem(id: "later", title: "Later today", due: date(2026, 10, 23, 18), hasTime: true),
            ReminderItem(id: "tomorrow", title: "Tomorrow", due: date(2026, 10, 24, 9), hasTime: true),
            ReminderItem(id: "none", title: "No date", due: nil, hasTime: false),
            ReminderItem(id: "late", title: "Missed call", due: date(2026, 10, 23, 11), hasTime: true),
            ReminderItem(id: "day", title: "Pay rent", due: date(2026, 10, 23), hasTime: false),
            ReminderItem(id: "old", title: "Old", due: date(2026, 10, 20), hasTime: false),
        ]
        XCTAssertEqual(RemindersDay.today(items, now: now, calendar: cal).map(\.id), ["old", "late", "day", "later"])
        XCTAssertTrue(RemindersDay.isOverdue(items[3], now: now, calendar: cal))
        XCTAssertFalse(RemindersDay.isOverdue(items[4], now: now, calendar: cal), "a day reminder is not late on its day")
        XCTAssertTrue(RemindersDay.isOverdue(items[5], now: now, calendar: cal))
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(RemindersDay.dueText(items[4], now: now, calendar: cal, locale: us), "Today")
        XCTAssertEqual(RemindersDay.dueText(items[0], now: now, calendar: cal, locale: us), "6:00\u{202F}PM")
        XCTAssertEqual(RemindersDay.dueText(items[5], now: now, calendar: cal, locale: us), "Oct 20")
    }

    func testQuickAddPreview() {
        let now = date(2026, 10, 23, 14)
        let us = Locale(identifier: "en_US")
        func preview(_ s: String) -> String { QuickAddFormat.preview(parse(s, at: now), now: now, calendar: cal, locale: us) }
        XCTAssertEqual(preview("call Priya at 5pm"), "Reminder · Today 5:00\u{202F}PM")
        XCTAssertEqual(preview("meeting with Sam tomorrow 3pm for 30 min"), "Event · Tomorrow 3:00\u{202F}PM – 3:30\u{202F}PM")
        XCTAssertEqual(preview("buy milk"), "Reminder · No date")
        XCTAssertEqual(preview("today 8"), "Reminder · Today 8:00\u{202F}AM (past)")
        XCTAssertEqual(preview("pay rent monday"), "Reminder · Mon")
        XCTAssertEqual(preview("dentist on dec 3"), "Reminder · Dec 3")
    }

    // MARK: - Meeting reminders

    func testMeetingOffsetsFutureOnly() {
        let start = date(2026, 10, 23, 15)
        XCTAssertEqual(MeetingReminderSchedule.fireDates(start: start, now: date(2026, 10, 23, 14)),
                       [date(2026, 10, 23, 14, 50), date(2026, 10, 23, 14, 55), date(2026, 10, 23, 14, 59)])
        XCTAssertEqual(MeetingReminderSchedule.fireDates(start: start, now: date(2026, 10, 23, 14, 52)),
                       [date(2026, 10, 23, 14, 55), date(2026, 10, 23, 14, 59)])
        XCTAssertEqual(MeetingReminderSchedule.fireDates(start: start, now: date(2026, 10, 23, 14, 55)),
                       [date(2026, 10, 23, 14, 59)], "a fire date equal to now is not in the future")
        XCTAssertEqual(MeetingReminderSchedule.fireDates(start: start, now: start), [])
        XCTAssertEqual(MeetingReminderSchedule.fireDates(start: start, offsets: [1, 5, 5], now: date(2026, 10, 23, 14)),
                       [date(2026, 10, 23, 14, 55), date(2026, 10, 23, 14, 59)], "sorted, no duplicates")
    }

    func testMeetingReminderDue() {
        let start = date(2026, 10, 23, 15)
        XCTAssertNil(MeetingReminderSchedule.due(start: start, now: date(2026, 10, 23, 14, 49), shown: []))
        XCTAssertEqual(MeetingReminderSchedule.due(start: start, now: date(2026, 10, 23, 14, 50), shown: []), 10)
        XCTAssertNil(MeetingReminderSchedule.due(start: start, now: date(2026, 10, 23, 14, 52), shown: [10]))
        // Waking at 14:58 shows only the latest reminder (5 min), not 10 then 5.
        XCTAssertEqual(MeetingReminderSchedule.due(start: start, now: date(2026, 10, 23, 14, 58), shown: []), 5)
        XCTAssertEqual(MeetingReminderSchedule.due(start: start, now: date(2026, 10, 23, 14, 59).addingTimeInterval(30), shown: [10, 5]), 1)
        XCTAssertNil(MeetingReminderSchedule.due(start: start, now: start, shown: []), "never once it started")
        XCTAssertEqual(MeetingReminderSchedule.crossed(start: start, now: date(2026, 10, 23, 14, 58)), [10, 5])
    }

    func testMeetingCountdownProgress() {
        let start = date(2026, 10, 23, 15)
        XCTAssertEqual(MeetingReminderSchedule.progress(start: start, now: date(2026, 10, 23, 14, 40)), 0)
        XCTAssertEqual(MeetingReminderSchedule.progress(start: start, now: date(2026, 10, 23, 14, 55)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MeetingReminderSchedule.progress(start: start, now: start.addingTimeInterval(30)), 1)
    }

    private func meeting(_ id: String, _ start: Date, _ minutes: Double = 30, allDay: Bool = false, declined: Bool = false) -> CalendarMeeting {
        CalendarMeeting(id: id, title: id, start: start, end: start.addingTimeInterval(minutes * 60),
                        isAllDay: allDay, declined: declined)
    }

    func testMeetingTimeline() {
        let now = date(2026, 10, 23, 14)
        let ms = [
            meeting("later", date(2026, 10, 23, 16)),
            meeting("now", date(2026, 10, 23, 13, 45)),
            meeting("allday", date(2026, 10, 23), 24 * 60, allDay: true),
            meeting("declined", date(2026, 10, 23, 14, 30), declined: true),
            meeting("soon", date(2026, 10, 23, 14, 30)),
            meeting("tomorrow", date(2026, 10, 24, 9)),
            meeting("ended", date(2026, 10, 23, 12)),
        ]
        XCTAssertEqual(MeetingTimeline.upcoming(ms, now: now).map(\.id), ["now", "soon", "later"])
        XCTAssertEqual(MeetingTimeline.current(ms, now: now)?.id, "now")
        XCTAssertEqual(MeetingTimeline.next(ms, now: now)?.id, "soon")
        // Wake-ups: the end of "now" (14:15), then the 10-minute reminder of "soon" (14:20), then its start.
        XCTAssertEqual(MeetingTimeline.nextWake(ms, now: now), date(2026, 10, 23, 14, 15))
        XCTAssertEqual(MeetingTimeline.nextWake(ms, now: date(2026, 10, 23, 14, 16)), date(2026, 10, 23, 14, 20))
        XCTAssertEqual(MeetingTimeline.nextWake(ms, now: date(2026, 10, 23, 14, 29)), date(2026, 10, 23, 14, 30))
        XCTAssertNil(MeetingTimeline.nextWake([], now: now))
        XCTAssertNil(MeetingTimeline.current([], now: now))
    }

    // MARK: - Join links (C25)

    func testJoinLinksMoreProviders() {
        let links = [
            "https://facetime.apple.com/join#v=1&p=AbCdEf&k=xyz",
            "https://meet.jit.si/PlatyStandup",
            "https://whereby.com/platy-team",
            "https://app.slack.com/huddle/T0123/C0456",
            "https://meet.goto.com/123456789",
            "https://global.gotomeeting.com/join/123456789",
            "https://chime.aws/1234567890",
            "https://bluejeans.com/123456789",
            "https://join.skype.com/AbCdEf123",
            "https://acme.zoomgov.com/j/1612345678",
            "https://teams.microsoft.com/meet/123456?p=abc",
            "https://discord.gg/abcDEF",
            "https://around.co/r/platy",
            "https://cal.com/video/abc123",
            "https://app.gather.town/app/abc/Office",
            "https://us05web.zoom.us/my/jane.doe",
        ]
        for link in links {
            XCTAssertEqual(MeetingLinks.firstJoinURL(in: ["Join here: \(link)"])?.absoluteString, link, link)
        }
        // Home pages are not meetings.
        for home in ["https://facetime.apple.com/", "https://meet.jit.si/", "https://whereby.com/", "https://whereby.com/pricing",
                     "https://bluejeans.com/", "https://chime.aws/", "https://app.slack.com/client/T0/C0", "https://discord.com/"] {
            XCTAssertNil(MeetingLinks.firstJoinURL(in: [home]), home)
        }
    }

    func testJoinLinkInLocationAndNotes() {
        let meet = "https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(MeetingLinks.firstJoinURL(url: nil, location: "Room 4 / \(meet)", notes: nil)?.absoluteString, meet)
        XCTAssertEqual(MeetingLinks.firstJoinURL(url: URL(string: "https://example.com/agenda"), location: "Room 4",
                                                 notes: "Dial in:\n\(meet)\nPIN 1234")?.absoluteString, meet)
        // The event URL wins over notes.
        XCTAssertEqual(MeetingLinks.firstJoinURL(url: URL(string: "https://zoom.us/j/9"), location: nil, notes: meet)?.absoluteString,
                       "https://zoom.us/j/9")
        // Without a scheme (as people type it in Location).
        XCTAssertEqual(MeetingLinks.firstJoinURL(url: nil, location: "zoom.us/j/123456", notes: nil)?.host, "zoom.us")
        XCTAssertNil(MeetingLinks.firstJoinURL(url: nil, location: nil, notes: nil))
    }

    /// Outlook Safe Links and Google redirect wrappers are unwrapped to the meeting link.
    func testJoinLinkUnwrapsSafeLinks() {
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"
        let wrapped = "https://nam12.safelinks.protection.outlook.com/?url="
            + teams.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&data=05%7C01"
        XCTAssertEqual(MeetingLinks.firstJoinURL(in: [wrapped])?.host, "teams.microsoft.com")
        let google = "https://www.google.com/url?q=https%3A%2F%2Fzoom.us%2Fj%2F42&sa=D"
        XCTAssertEqual(MeetingLinks.firstJoinURL(in: [google])?.absoluteString, "https://zoom.us/j/42")
        // A wrapper around something that is not a meeting is not a join link.
        let other = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com%2F"
        XCTAssertNil(MeetingLinks.firstJoinURL(in: [other]))
    }

    // MARK: - Weather (C27)

    private func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/open-meteo.json")
        return try Data(contentsOf: url)
    }

    func testWeatherDecodeFixture() throws {
        let w = try WeatherDecoder.decode(try fixture())
        XCTAssertEqual(w.temperatureC, 13.4, accuracy: 1e-9)
        XCTAssertEqual(w.code, 3)
        XCTAssertTrue(w.isDay)
        // Times are local to the place (timezone=auto, utc_offset_seconds 3600): 14:15 there is 13:15 UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(w.time, date(2026, 10, 23, 13, 15, in: utc))
        XCTAssertEqual(w.hourly.count, 12)
        XCTAssertEqual(w.hourly[1], HourlyPrecip(time: date(2026, 10, 23, 13, in: utc), probability: 5))
        XCTAssertNil(w.hourly[3].probability, "null stays unknown")
        // Next rain: first hour (not already over) at 50% or more → 18:00 local = 17:00 UTC.
        // The 13:00 hour (80%) ended before 14:15 and the 17:00 hour is only 35%.
        XCTAssertEqual(w.nextRain, date(2026, 10, 23, 17, in: utc))
        XCTAssertEqual(w.utcOffsetSeconds, 3600)
    }

    func testNextRainThreshold() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func h(_ i: Int, _ p: Double?) -> HourlyPrecip { HourlyPrecip(time: t0.addingTimeInterval(Double(i) * 3600), probability: p) }
        XCTAssertEqual(WeatherNow.nextRain(in: [h(0, 49), h(1, 50), h(2, 90)], after: t0), h(1, 50).time)
        XCTAssertNil(WeatherNow.nextRain(in: [h(0, 10), h(1, nil), h(2, 49.9)], after: t0))
        // The hour that contains `after` counts; earlier hours do not.
        XCTAssertEqual(WeatherNow.nextRain(in: [h(0, 80), h(1, 60)], after: t0.addingTimeInterval(1800)), t0)
        XCTAssertEqual(WeatherNow.nextRain(in: [h(0, 80), h(1, 60)], after: t0.addingTimeInterval(3600)), h(1, 60).time)
        XCTAssertEqual(WeatherNow.rainThreshold, 50)
    }

    func testWeatherDecodeErrors() {
        XCTAssertThrowsError(try WeatherDecoder.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try WeatherDecoder.decode(Data(#"{"current":{}}"#.utf8)))
        XCTAssertThrowsError(try WeatherDecoder.decode(Data(#"{"error":true,"reason":"Latitude must be in range"}"#.utf8))) { error in
            XCTAssertEqual(error as? WeatherError, .api("Latitude must be in range"))
        }
        // Mismatched hourly arrays are cut to the shorter one.
        let json = #"""
        {"utc_offset_seconds":0,"current":{"time":"2026-10-23T10:00","temperature_2m":1.5,"weather_code":61,"is_day":0},
         "hourly":{"time":["2026-10-23T10:00","2026-10-23T11:00"],"precipitation_probability":[90]}}
        """#
        let w = try? WeatherDecoder.decode(Data(json.utf8))
        XCTAssertEqual(w?.hourly.count, 1)
        XCTAssertEqual(w?.isDay, false)
        XCTAssertEqual(w?.code, 61)
    }

    func testGeocodingDecode() throws {
        let json = #"""
        {"results":[{"id":2643743,"name":"London","latitude":51.50853,"longitude":-0.12574,"elevation":25.0,
          "feature_code":"PPLC","country_code":"GB","timezone":"Europe/London","country":"United Kingdom","admin1":"England"},
          {"id":6058560,"name":"London","latitude":42.98339,"longitude":-81.23304,"country":"Canada","admin1":"Ontario"}],
         "generationtime_ms":0.6}
        """#
        let places = try WeatherDecoder.decodePlaces(Data(json.utf8))
        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places[0].displayName, "London, England, United Kingdom")
        XCTAssertEqual(places[1].latitude, 42.98339, accuracy: 1e-9)
        XCTAssertEqual(try WeatherDecoder.decodePlaces(Data(#"{"generationtime_ms":0.3}"#.utf8)), [], "no results key = none found")
    }

    func testOpenMeteoURLs() throws {
        let f = OpenMeteo.forecastURL(latitude: 51.508_53, longitude: -0.125_74)
        XCTAssertEqual(f.scheme, "https")
        XCTAssertEqual(f.host, "api.open-meteo.com")
        XCTAssertEqual(f.path, "/v1/forecast")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: f, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["latitude"], "51.51", "rounded to about a kilometre")
        XCTAssertEqual(items["longitude"], "-0.13")
        XCTAssertEqual(items["current"], "temperature_2m,weather_code,is_day")
        XCTAssertEqual(items["hourly"], "precipitation_probability")
        XCTAssertEqual(items["forecast_hours"], "12")
        XCTAssertEqual(items["timezone"], "auto")

        let g = try XCTUnwrap(OpenMeteo.geocodingURL(name: "São Paulo & co"))
        XCTAssertEqual(g.host, "geocoding-api.open-meteo.com")
        XCTAssertEqual(g.path, "/v1/search")
        XCTAssertEqual(URLComponents(url: g, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value,
                       "São Paulo & co")
        XCTAssertTrue(g.absoluteString.contains("name=S%C3%A3o%20Paulo%20%26%20co"))
        XCTAssertNil(OpenMeteo.geocodingURL(name: "  "))
        XCTAssertNil(OpenMeteo.geocodingURL(name: "x"), "one letter finds nothing useful")
    }

    func testOnlyOpenMeteoHostsAllowed() {
        XCTAssertTrue(OpenMeteo.isAllowed(URL(string: "https://api.open-meteo.com/v1/forecast?x=1")!))
        XCTAssertTrue(OpenMeteo.isAllowed(URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=a")!))
        XCTAssertFalse(OpenMeteo.isAllowed(URL(string: "http://api.open-meteo.com/v1/forecast")!), "https only")
        XCTAssertFalse(OpenMeteo.isAllowed(URL(string: "https://open-meteo.com/")!))
        XCTAssertFalse(OpenMeteo.isAllowed(URL(string: "https://api.open-meteo.com.evil.com/v1")!))
        XCTAssertFalse(OpenMeteo.isAllowed(URL(string: "https://evil.com/?h=api.open-meteo.com")!))
        XCTAssertFalse(OpenMeteo.isAllowed(URL(string: "https://user@api.open-meteo.com:8443/v1")!), "no other port or user info")
    }

    func testWeatherBackoff() {
        XCTAssertEqual(WeatherRefresh.interval, 30 * 60)
        XCTAssertEqual((1...7).map { WeatherRefresh.retryDelay(afterFailures: $0) }, [60, 120, 240, 480, 960, 1800, 1800])
        XCTAssertEqual(WeatherRefresh.retryDelay(afterFailures: 0), WeatherRefresh.interval)
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Never fetched: now.
        XCTAssertEqual(WeatherRefresh.delay(lastSuccess: nil, lastAttempt: nil, failures: 0, now: t), 0)
        // Fetched 10 min ago: 20 min left.
        XCTAssertEqual(WeatherRefresh.delay(lastSuccess: t.addingTimeInterval(-600), lastAttempt: t.addingTimeInterval(-600),
                                            failures: 0, now: t), 1200)
        // Failed twice, last try 30 s ago: 90 s left of the 2-minute backoff.
        XCTAssertEqual(WeatherRefresh.delay(lastSuccess: nil, lastAttempt: t.addingTimeInterval(-30), failures: 2, now: t), 90)
        // Overdue (e.g. after sleep): now.
        XCTAssertEqual(WeatherRefresh.delay(lastSuccess: t.addingTimeInterval(-7200), lastAttempt: t.addingTimeInterval(-7200),
                                            failures: 0, now: t), 0)
    }

    func testWeatherFormat() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(WeatherRefresh.isStale(fetchedAt: t.addingTimeInterval(-40 * 60), now: t))
        XCTAssertTrue(WeatherRefresh.isStale(fetchedAt: t.addingTimeInterval(-46 * 60), now: t))
        XCTAssertEqual(WeatherFormat.age(since: t.addingTimeInterval(-20), now: t), "just now")
        XCTAssertEqual(WeatherFormat.age(since: t.addingTimeInterval(-50 * 60), now: t), "50 min ago")
        XCTAssertEqual(WeatherFormat.age(since: t.addingTimeInterval(-3 * 3600 - 60), now: t), "3 h ago")
        XCTAssertEqual(WeatherFormat.age(since: t.addingTimeInterval(-50 * 3600), now: t), "2 days ago")
        XCTAssertEqual(WeatherFormat.temperature(13.4, unit: .celsius), "13°")
        XCTAssertEqual(WeatherFormat.temperature(13.6, unit: .fahrenheit), "56°")
        XCTAssertEqual(WeatherFormat.temperature(-0.4, unit: .celsius), "0°", "no minus zero")
        XCTAssertEqual(WeatherCode.describe(0, isDay: true).symbol, "sun.max.fill")
        XCTAssertEqual(WeatherCode.describe(0, isDay: false).symbol, "moon.stars.fill")
        XCTAssertEqual(WeatherCode.describe(63, isDay: true).text, "Rain")
        XCTAssertEqual(WeatherCode.describe(95, isDay: true).text, "Thunderstorm")
        XCTAssertEqual(WeatherCode.describe(1234, isDay: true).text, "Unknown")
    }
}
