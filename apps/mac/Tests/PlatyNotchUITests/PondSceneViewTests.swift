import PlatyNotchKit
@testable import PlatyNotchUI
import XCTest

@MainActor
final class PondSceneViewTests: XCTestCase {
    func testStillWhenCollapsed() {
        XCTAssertFalse(PondSceneView.animates(ticking: true, expanded: false, reduceMotion: false))
        XCTAssertFalse(PondSceneView.animates(ticking: false, expanded: true, reduceMotion: false))
        let view = PondSceneNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 140))
        view.configure(phase: .day, animates: false)
        XCTAssertFalse(view.isAnimating)
    }

    func testStillUnderReduceMotion() {
        XCTAssertFalse(PondSceneView.animates(ticking: true, expanded: true, reduceMotion: true))
    }

    func testAnimatesWhenOpen() {
        XCTAssertTrue(PondSceneView.animates(ticking: true, expanded: true, reduceMotion: false))
        let view = PondSceneNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 140))
        view.configure(phase: .evening, animates: true)
        XCTAssertTrue(view.isAnimating)
        // Closing stops it: nothing runs while collapsed.
        view.configure(phase: .evening, animates: false)
        XCTAssertFalse(view.isAnimating)
    }

    func testStarsFollowThePhase() {
        let view = PondSceneNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 140))
        view.configure(phase: .night, animates: false)
        XCTAssertGreaterThan(view.visibleStarCount, 0)
        view.configure(phase: .morning, animates: false)
        XCTAssertEqual(view.visibleStarCount, 0)
    }

    /// The ripple is one bounded animation: never longer than 4 s per cycle, never over the
    /// 2 s rule for one-off motion because it runs only while the panel is open.
    func testRippleDurationIsFourSeconds() {
        let view = PondSceneNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 140))
        view.configure(phase: .day, animates: true)
        XCTAssertEqual(view.rippleDuration, 4, accuracy: 0.001)
    }
}
