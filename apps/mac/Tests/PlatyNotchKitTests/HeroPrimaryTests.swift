import PlatyNotchKit
import XCTest

final class HeroPrimaryTests: DefaultsTestCase {
    func testPrimaryTitles() {
        XCTAssertEqual(HeroPrimary.title(rank: .ringing, playing: false, hasLink: false), "Stop")
        XCTAssertEqual(HeroPrimary.title(rank: .timerRunning, playing: false, hasLink: false), "Pause")
        XCTAssertEqual(HeroPrimary.title(rank: .music, playing: true, hasLink: false), "Pause")
        XCTAssertEqual(HeroPrimary.title(rank: .music, playing: false, hasLink: false), "Play")
        XCTAssertEqual(HeroPrimary.title(rank: .meetingImminent, playing: false, hasLink: true), "Join")
        XCTAssertEqual(HeroPrimary.title(rank: .meetingSoon, playing: false, hasLink: true), "Join")
        XCTAssertNil(HeroPrimary.title(rank: .meetingSoon, playing: false, hasLink: false))
        for rank in [LiveRank.fileAction, .minor, .ambient, .agentsWorking, .agentNeedsYou, .agentFinished] {
            XCTAssertNil(HeroPrimary.title(rank: rank, playing: true, hasLink: true), "\(rank)")
        }
    }
}
