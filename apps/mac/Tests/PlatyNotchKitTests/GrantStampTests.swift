import XCTest
@testable import PlatyNotchKit

final class GrantStampTests: DefaultsTestCase {
    private var build = "dr:build-1"

    private func stamp() -> GrantStamp {
        GrantStamp(key: "camera.grant", defaults: defaults(), identity: { [unowned self] in self.build })
    }

    func testHolds() {
        XCTAssertFalse(GrantStamp.holds(nil, current: "a"))
        XCTAssertFalse(GrantStamp.holds("", current: "a"))
        XCTAssertFalse(GrantStamp.holds("b", current: "a"))
        XCTAssertTrue(GrantStamp.holds("a", current: "a"))
    }

    func testNoteAndHistory() {
        let s = stamp()
        XCTAssertEqual(s.history, .never)
        XCTAssertFalse(s.holds)
        s.note()
        XCTAssertEqual(s.saved, "dr:build-1")
        XCTAssertEqual(s.history, .thisBuild)
        XCTAssertTrue(s.holds)
        build = "dr:build-2"
        XCTAssertEqual(s.history, .otherBuild)
        XCTAssertFalse(s.holds)
    }

    func testLaunchCheckAfterARebuild() {
        let s = stamp()
        XCTAssertEqual(s.launchCheck(wasOn: false), .off)
        XCTAssertEqual(s.launchCheck(wasOn: true), .turnOnAgain, "on but never stamped")
        s.note()
        XCTAssertEqual(s.launchCheck(wasOn: true), .resume)
        build = "cdhash:rebuilt"
        XCTAssertEqual(s.launchCheck(wasOn: true), .turnOnAgain)
        XCTAssertNil(s.saved, "the old stamp is cleared")
        XCTAssertEqual(s.launchCheck(wasOn: false), .off, "an off feature leaves the stamp alone")
    }
}
