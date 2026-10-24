import PlatyNotchKit
import XCTest

/// What the mirror tile shows (v0.2 R17).
final class MirrorStateTests: DefaultsTestCase {
    func testLiveWins() {
        XCTAssertEqual(MirrorTileState.decide(auth: .authorized, history: .thisBuild, live: true, noCamera: false), .live)
        XCTAssertEqual(MirrorTileState.live.buttonTitle, "Hide")
    }

    func testAuthorizedIsReady() {
        for h in [GrantHistory.never, .thisBuild, .otherBuild] {
            XCTAssertEqual(MirrorTileState.decide(auth: .authorized, history: h, live: false, noCamera: false), .ready)
        }
        XCTAssertEqual(MirrorTileState.decide(auth: .authorized, history: .thisBuild, live: false, noCamera: true), .noCamera)
    }

    func testNeverAskedAsksFromTheButton() {
        let s = MirrorTileState.decide(auth: .notDetermined, history: .never, live: false, noCamera: false)
        XCTAssertEqual(s, .allow)
        XCTAssertEqual(s.buttonTitle, "Show Mirror")
    }

    func testRebuiltAsksAgain() {
        let s = MirrorTileState.decide(auth: .notDetermined, history: .otherBuild, live: false, noCamera: false)
        XCTAssertEqual(s, .turnOnAgain)
        XCTAssertEqual(s.buttonTitle, "Turn On Again")
    }

    func testDeniedAndRestrictedHaveNoShowButton() {
        XCTAssertEqual(MirrorTileState.decide(auth: .denied, history: .never, live: false, noCamera: false),
                       .denied(rebuilt: false))
        XCTAssertEqual(MirrorTileState.decide(auth: .denied, history: .otherBuild, live: false, noCamera: false),
                       .denied(rebuilt: true))
        XCTAssertNil(MirrorTileState.denied(rebuilt: false).buttonTitle)
        XCTAssertEqual(MirrorTileState.decide(auth: .restricted, history: .never, live: false, noCamera: false), .restricted)
        XCTAssertNil(MirrorTileState.restricted.buttonTitle)
    }
}
