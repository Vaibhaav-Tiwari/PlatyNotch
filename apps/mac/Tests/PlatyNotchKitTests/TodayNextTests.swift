import Foundation
import PlatyNotchKit
import XCTest

/// The Today card's bottom part (Island spec 3.2): 14:59 on Sat 31 Oct 2026, en_US.
final class TodayNextTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }()
    private let enUS = Locale(identifier: "en_US")

    private func at(_ d: Int, _ h: Int, _ m: Int = 0, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!
    }

    private var now: Date { at(31, 14, 59) }

    private func make(_ meetings: [CalendarMeeting]?, days: Set<Date> = [], now: Date? = nil) -> TodayNext {
        TodayNextModel.make(meetings: meetings, daysWithEvents: days, now: now ?? self.now, calendar: cal, locale: enUS)
    }

    private func meeting(_ title: String = "Design review", from: Date, to: Date, link: String? = nil,
                         allDay: Bool = false, declined: Bool = false) -> CalendarMeeting {
        CalendarMeeting(id: title + "\(from)", title: title, start: from, end: to, isAllDay: allDay, declined: declined,
                        joinURL: link.flatMap(URL.init(string:)))
    }

    func testNextWithinTheHour() {
        let m = meeting(from: at(31, 15, 44), to: at(31, 16, 30), link: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(make([m]), .event(label: "Next · in 45 min", title: "Design review", detail: "3:44 PM · Google Meet"))
    }

    func testInProgress() {
        let m = meeting(from: at(31, 14, 30), to: at(31, 16, 30))
        XCTAssertEqual(make([m]), .event(label: "Now · ends 4:30 PM", title: "Design review", detail: "2:30 PM"))
    }

    func testLaterToday() {
        let m = meeting("Dinner", from: at(31, 18), to: at(31, 19))
        XCTAssertEqual(make([m]), .event(label: "Next · later today", title: "Dinner", detail: "6:00 PM"))
    }

    func testDeclinedAndAllDaySkipped() {
        let skipped = [meeting("Holiday", from: at(31, 0), to: at(1, 0, month: 11), allDay: true),
                       meeting("Nope", from: at(31, 16), to: at(31, 17), declined: true),
                       meeting("Over", from: at(31, 9), to: at(31, 10)),
                       meeting("Tomorrow", from: at(1, 9, month: 11), to: at(1, 10, month: 11))]
        guard case .free = make(skipped) else { return XCTFail("\(make(skipped))") }
    }

    func testFreeTodayAndTonight() {
        guard case .free(let label, _) = make([]) else { return XCTFail() }
        XCTAssertEqual(label, "Free today")
        guard case .free(let night, _) = make([], now: at(31, 21, 10)) else { return XCTFail() }
        XCTAssertEqual(night, "Free tonight")
        guard case .free(let five, _) = make([], now: at(31, 17)) else { return XCTFail() }
        XCTAssertEqual(five, "Free tonight", "from 17:00")
    }

    func testWeekStripMarksNextDayWithEvent() {
        let monday = cal.startOfDay(for: at(2, 9, month: 11))
        let thursday = cal.startOfDay(for: at(5, 9, month: 11))
        guard case .free(_, let days) = make([], days: [monday, thursday]) else { return XCTFail() }
        XCTAssertEqual(days.map(\.weekday), ["Sa", "Su", "Mo", "Tu", "We", "Th", "Fr"])
        XCTAssertEqual(days.map(\.day), ["31", "1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(days.map(\.marked), [false, false, true, false, false, false, false], "only the next one")
        XCTAssertEqual(days[0].date, cal.startOfDay(for: now))
    }

    func testTodayIsNeverTheMarkedDayWhenFree() {
        guard case .free(_, let days) = make([], days: [cal.startOfDay(for: now)]) else { return XCTFail() }
        XCTAssertFalse(days.contains(where: \.marked))
    }

    func testNoCalendarStripMarksToday() {
        guard case .noCalendar(let days) = make(nil, days: [cal.startOfDay(for: at(2, 9, month: 11))]) else {
            return XCTFail()
        }
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map(\.marked), [true, false, false, false, false, false, false])
    }

    /// The week strip's days: declined skipped, the 7-day window, multi-day events span.
    func testDaysWithEvents() {
        let day = { (d: Int, m: Int) in self.cal.startOfDay(for: self.at(d, 9, month: m)) }
        let events: [(start: Date, end: Date, declined: Bool)] = [
            (at(1, 10, month: 11), at(1, 11, month: 11), false),          // Sun 1
            (at(2, 10, month: 11), at(2, 11, month: 11), true),           // declined
            (at(3, 22, month: 11), at(5, 9, month: 11), false),           // Tue 3 … Thu 5
            (at(4, 0, month: 11), at(5, 0, month: 11), false),            // all day Wed 4, ends at midnight
            (at(7, 10, month: 11), at(7, 11, month: 11), false),          // Sat 7: outside the week
            (at(30, 10), at(31, 12), false),                              // started yesterday, runs into today
        ]
        let days = TodayNextModel.daysWithEvents(events, now: now, calendar: cal)
        XCTAssertEqual(days, [day(31, 10), day(1, 11), day(3, 11), day(4, 11), day(5, 11)])
    }
}
