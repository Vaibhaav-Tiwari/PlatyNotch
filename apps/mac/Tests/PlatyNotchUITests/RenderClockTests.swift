import PlatyNotchKit
@testable import PlatyNotchUI
import XCTest

@MainActor
final class RenderClockTests: XCTestCase {
    /// A render at 19:12: the Today card reads the pinned clock, whatever the real clock says.
    func testTodayUsesThePinnedClock() throws {
        let at = HomeRenders.at(hour: 19)
        let rig = HomeRenders.builtIns(meeting: false, at: at)
        let meeting = try XCTUnwrap(rig.registry.widget(MeetingWidget.widgetID) as? MeetingWidget)
        XCTAssertEqual(meeting.now, at)
        let data = HomeData.make(today: rig.today, widgets: rig.registry, settings: HomeSettings(), tourSample: nil,
                                 now: at, dropping: false)
        // The seeded meeting is 45 minutes after the pinned 19:12.
        guard case .event(let label, let title, _) = data.next else { return XCTFail("\(data.next)") }
        XCTAssertEqual(label, "Next · in 45 min")
        XCTAssertEqual(title, "Design review")
        rig.registry.stopAll()
    }
}
