import Foundation
import PlatyNotchKit
import XCTest

final class UpNextTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let us = Locale(identifier: "en_US")
    /// 2026-10-31 14:59 UTC.
    private var now: Date { at(14, 59) }

    private func at(_ h: Int, _ m: Int, day: Int = 31) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    private func rows(_ items: [UpNextItem]) -> [UpNextRow] {
        UpNext.rows(items, now: now, calendar: cal, locale: us)
    }

    private func event(_ id: String, _ start: Date, end: Date? = nil, allDay: Bool = false) -> UpNextItem {
        UpNextItem(id: id, title: id, date: start, hasTime: true, isAllDay: allDay, kind: .event, end: end)
    }

    private func reminder(_ id: String, _ due: Date?, hasTime: Bool = true) -> UpNextItem {
        UpNextItem(id: id, title: id, date: due, hasTime: hasTime, isAllDay: false, kind: .reminder)
    }

    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    func testOverdueFirst() {
        let r = rows([reminder("later", at(17, 0)), event("meet", at(15, 44)), reminder("old", at(9, 0))])
        XCTAssertEqual(r.map { plain($0.time) }, ["Overdue", "3:44 PM", "5:00 PM"])
        XCTAssertEqual(r.map(\.id), ["old", "meet", "later"])
        XCTAssertEqual(r.map(\.overdue), [true, false, false])
    }

    func testOverdueOldestFirst() {
        let r = rows([reminder("b", at(10, 0)), reminder("a", at(8, 0), hasTime: true), reminder("y", at(9, 0, day: 30), hasTime: false)])
        XCTAssertEqual(r.map(\.id), ["y", "a", "b"])
    }

    func testEventWithinHourSaysMinutes() {
        XCTAssertEqual(rows([event("e", at(15, 44))]).first?.note, "in 45 m")
        XCTAssertEqual(rows([event("e", at(14, 30), end: at(15, 30))]).first?.note, "now")
        XCTAssertEqual(rows([event("e", at(15, 59))]).first?.note, "in 60 m")
        XCTAssertNil(rows([event("e", at(16, 30))]).first?.note, "beyond the hour says nothing")
        XCTAssertEqual(rows([event("e", at(15, 0, day: 31).addingTimeInterval(30))]).first?.note, "in 2 m", "rounded up")
    }

    func testDropsPastAllDayAndUndated() {
        let r = rows([event("done", at(13, 0), end: at(14, 0)), event("allday", at(0, 0), allDay: true),
                      reminder("nodate", nil), event("keep", at(16, 0))])
        XCTAssertEqual(r.map(\.id), ["keep"])
    }

    func testLimitThree() {
        let items = (0..<6).map { event("e\($0)", at(15 + $0, 30)) }
        XCTAssertEqual(rows(items).count, 3)
        XCTAssertEqual(UpNext.limit, 3)
        XCTAssertEqual(rows(items).map(\.id), ["e0", "e1", "e2"])
    }

    func testReminderNote() {
        XCTAssertEqual(rows([reminder("r", at(17, 0))]).first?.note, "reminder")
        XCTAssertEqual(rows([reminder("r", at(9, 0))]).first?.note, "reminder")
    }

    func testAllDayReminderHasAnEmptyTimeColumn() {
        XCTAssertEqual(rows([reminder("r", at(0, 0), hasTime: false)]).first?.time, "", "an all-day item has no time")
        XCTAssertEqual(rows([reminder("t", at(17, 0))]).first.map { plain($0.time) }, "5:00 PM", "a timed item shows its time")
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0))!
        XCTAssertEqual(rows([reminder("n", tomorrow, hasTime: false)]).first?.time, "Tomorrow")
        XCTAssertEqual(rows([reminder("r", at(0, 0, day: 31), hasTime: false)]).first?.overdue, false)
    }

    func testLaterDayShowsDayWordAndTime() {
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 0))!
        let r = rows([UpNextItem(id: "t", title: "t", date: tomorrow, hasTime: true, isAllDay: false, kind: .event)])
        XCTAssertEqual(r.first?.time, "Tomorrow")
        XCTAssertEqual(r.first?.note.map(plain), "9:00 AM")
    }

    func testEmpty() {
        XCTAssertEqual(rows([]), [])
    }
}
