import XCTest
@testable import PlatyNotchKit

final class TodayLogicTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)

    private func entry(_ id: String, start: TimeInterval, end: TimeInterval = 1800, allDay: Bool = false,
                       declined: Bool = false) -> CalendarEntry {
        CalendarEntry(id: id, start: now + start, end: now + start + end, isAllDay: allDay, declined: declined)
    }

    func testPicksNextWithinTwelveHours() {
        let entries = [entry("late", start: 13 * 3600), entry("b", start: 3600), entry("a", start: 600)]
        XCTAssertEqual(UpcomingMeeting.pick(entries, now: now)?.id, "a")
        XCTAssertNil(UpcomingMeeting.pick([entry("late", start: 12 * 3600 + 1)], now: now))
    }

    func testSkipsAllDayDeclinedAndOld() {
        let entries = [entry("allday", start: 60, allDay: true), entry("no", start: 120, declined: true),
                       entry("over", start: -3600, end: 1800), entry("started-long-ago", start: -1200, end: 3600),
                       entry("ok", start: 300)]
        XCTAssertEqual(UpcomingMeeting.pick(entries, now: now)?.id, "ok")
    }

    func testJustStartedMeetingStillShown() {
        XCTAssertEqual(UpcomingMeeting.pick([entry("now", start: -300), entry("later", start: 600)], now: now)?.id, "now")
    }

    private func loop(_ id: String, _ status: String, due: TimeInterval? = nil, detected: TimeInterval = 0) -> Loop {
        Loop(id: id, title: id, kind: "promise", status: status, dueAt: due.map { now + $0 },
             detectedAt: now + detected)
    }

    func testOpenLoopsOrder() {
        let loops = [loop("resolved", "resolved"), loop("new", "open", detected: 50), loop("old", "open", detected: 10),
                     loop("due-later", "open", due: 900), loop("due-soon", "open", due: 100)]
        XCTAssertEqual(LoopsFormat.open(loops).map(\.id), ["due-soon", "due-later", "new", "old"])
    }

    func testLoopReply() throws {
        XCTAssertNil(LoopsFormat.errorMessage(in: Envelope.make(.loopSetStatus, id: "1")))
        XCTAssertEqual(LoopsFormat.errorMessage(in: try .make(.error, id: "1", ErrorMsg(message: "memory is off"))),
                       "memory is off")
        XCTAssertEqual(LoopsFormat.errorMessage(in: Envelope.make(.error, id: "1")), "The core refused the change.")
        XCTAssertEqual(LoopsFormat.errorMessage(in: Envelope.make(.pong, id: "1")), "Unexpected reply from the core.")
    }

    func testSetStatusEnvelope() throws {
        let env = try LoopsFormat.setStatus(id: "L1", .resolved)
        XCTAssertEqual(env.type, "loop.set_status")
        XCTAssertEqual(try env.decode(LoopSetStatus.self), LoopSetStatus(id: "L1", status: "resolved"))
        XCTAssertEqual(try LoopsFormat.setStatus(id: "L1", .dismissed).decode(LoopSetStatus.self).status, "dismissed")
    }

    func testMeetingWhen() {
        XCTAssertEqual(TodayFormat.meetingWhen(start: now - 60, now: now), "Now")
        XCTAssertEqual(TodayFormat.meetingWhen(start: now + 20, now: now), "In 1 min")
        XCTAssertEqual(TodayFormat.meetingWhen(start: now + 300, now: now), "In 5 min")
        XCTAssertEqual(TodayFormat.meetingWhen(start: now + 3600, now: now), "In 1 h")
        XCTAssertEqual(TodayFormat.meetingWhen(start: now + 2 * 3600 + 5 * 60, now: now), "In 2 h 5 min")
    }

    func testFocusClock() {
        XCTAssertEqual(TodayFormat.clock(25 * 60), "25:00")
        XCTAssertEqual(TodayFormat.clock(59.2), "1:00")       // rounds up: never shows 0:00 early
        XCTAssertEqual(TodayFormat.clock(0), "0:00")
        XCTAssertEqual(TodayFormat.clock(90 * 60), "1:30:00")
        XCTAssertEqual(TodayFormat.clock(-5), "0:00")
    }
}
