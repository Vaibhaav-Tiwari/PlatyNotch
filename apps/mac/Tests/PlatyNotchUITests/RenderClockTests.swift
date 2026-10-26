import PlatyNotchKit
@testable import PlatyNotchUI
import XCTest

@MainActor
final class RenderClockTests: XCTestCase {
    /// A render at 19:12: the meeting glance and the summary's "Next:" line name the same
    /// meeting at the same time, whatever the real clock says.
    func testGlanceAndNextLineAgreeAtAFixedTime() throws {
        let at = NowRenders.at(hour: 19)
        let rig = NowRenders.builtIns(meeting: false, at: at)
        let meeting = try XCTUnwrap(rig.registry.widget(MeetingWidget.widgetID) as? MeetingWidget)
        let glance = try XCTUnwrap(meeting.glanceMeeting)
        XCTAssertEqual(meeting.now, at)
        let next = try XCTUnwrap(TodaySummaryHero.nextLine(calendar: rig.today.calendar, now: at))
        XCTAssertEqual(next, "Next: \(MeetingWidget.time(glance.start)) \(glance.title)")
        XCTAssertEqual(MeetingGlance.value(glance, now: meeting.now), MeetingWidget.time(glance.start))
        rig.registry.stopAll()
    }

    /// The pond renders put Platy in the mood for their hour: sleepy at night.
    func testNightPondIsSleepy() {
        XCTAssertEqual(NowRenders.pond(hour: 23).mood, .sleepy)
        XCTAssertNotEqual(NowRenders.pond(hour: 8).mood, .sleepy)
    }

    /// A meeting after midnight reads "8:30" over "Tomorrow · Standup" in the glance.
    func testTomorrowMeetingSaysTomorrow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 22))!
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 8, minute: 30))!
        let m = CalendarMeeting(id: "t", title: "Standup", start: start, end: start.addingTimeInterval(900))
        XCTAssertEqual(MeetingGlance.value(m, now: now), MeetingWidget.time(start))
        XCTAssertEqual(MeetingGlance.label(m, now: now, calendar: cal), "Tomorrow · Standup")
        let today = CalendarMeeting(id: "u", title: "Late", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600))
        XCTAssertEqual(MeetingGlance.label(today, now: now, calendar: cal), "Late")
    }
}
