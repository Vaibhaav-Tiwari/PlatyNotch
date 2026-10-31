import PlatyNotchKit
@testable import PlatyNotchUI
import XCTest

@MainActor
final class RenderClockTests: XCTestCase {
    /// A render at 19:12: Up next reads the pinned clock, whatever the real clock says.
    func testUpNextUsesThePinnedClock() throws {
        let at = HomeRenders.at(hour: 19)
        let rig = HomeRenders.builtIns(meeting: false, at: at)
        let meeting = try XCTUnwrap(rig.registry.widget(MeetingWidget.widgetID) as? MeetingWidget)
        XCTAssertEqual(meeting.now, at)
        let data = HomeData.make(today: rig.today, widgets: rig.registry, settings: HomeSettings(), tourSample: nil,
                                 now: at, dropping: false)
        XCTAssertEqual(data.rows.count, UpNext.limit)
        XCTAssertEqual(data.rows.first?.time, "", "the seeded tasks are all-day today")
        XCTAssertEqual(data.rows.first?.note, "reminder")
        rig.registry.stopAll()
    }
}
