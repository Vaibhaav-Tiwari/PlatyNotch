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

    /// Absolute dates the phrase rules do not cover go through NSDataDetector.
    func testQuickAddDetectorFallback() {
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
        XCTAssertEqual(preview("buy milk"), "Reminder")
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
