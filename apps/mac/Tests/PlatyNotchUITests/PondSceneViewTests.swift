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

    /// One ripple per open, within the 2-second rule (spec 9), and again on the next open.
    func testOneShortRipplePerOpen() {
        let view = PondSceneNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 140))
        view.configure(phase: .day, animates: true)
        XCTAssertLessThanOrEqual(view.rippleDuration, 2)
        XCTAssertEqual(view.rippleRepeatCount, 1)
        view.configure(phase: .day, animates: false)
        XCTAssertFalse(view.isAnimating)
        view.configure(phase: .day, animates: true)
        XCTAssertTrue(view.isAnimating)
        XCTAssertEqual(view.rippleRepeatCount, 1)
    }

    /// Morning and day read differently: a low warm sun or a high pale one; no orb at dusk.
    func testOrbFollowsThePhase() {
        let view = PondSceneNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 140))
        for phase in DayPhase.allCases {
            view.configure(phase: phase, animates: false)
            XCTAssertEqual(view.showsOrb, phase != .evening, "\(phase)")
        }
        let morning = PondSceneNSView.orbPlacement(.morning), day = PondSceneNSView.orbPlacement(.day)
        XCTAssertNotNil(morning)
        XCTAssertNotNil(day)
        XCTAssertLessThan(morning?.lift ?? 99, day?.lift ?? 0)
        XCTAssertGreaterThan(morning?.size ?? 0, day?.size ?? 99)
        // Clear of the greeting on the left.
        for phase in DayPhase.allCases { XCTAssertGreaterThan(PondSceneNSView.orbPlacement(phase)?.x ?? 1, 0.45) }
    }
}
