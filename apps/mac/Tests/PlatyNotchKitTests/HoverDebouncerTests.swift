import XCTest
@testable import PlatyNotchKit

final class HoverDebouncerTests: XCTestCase {
    func testEnterNeedsDwell() {
        var d = HoverDebouncer(enterDelay: 0.1, exitDelay: 0.3)
        XCTAssertNil(d.update(inside: true, at: 0))
        XCTAssertEqual(d.deadline, 0.1)
        XCTAssertNil(d.update(inside: true, at: 0.05))
        XCTAssertEqual(d.update(inside: true, at: 0.1), true)
        XCTAssertTrue(d.isHovering)
        XCTAssertNil(d.deadline)
    }

    func testPassingThroughDoesNotEnter() {
        var d = HoverDebouncer(enterDelay: 0.1, exitDelay: 0.3)
        XCTAssertNil(d.update(inside: true, at: 0))
        XCTAssertNil(d.update(inside: false, at: 0.05))
        XCTAssertNil(d.deadline)
        XCTAssertNil(d.update(inside: false, at: 1))
        XCTAssertFalse(d.isHovering)
    }

    func testExitGraceAndReturn() {
        var d = HoverDebouncer(enterDelay: 0.1, exitDelay: 0.3)
        _ = d.update(inside: true, at: 0)
        _ = d.update(inside: true, at: 0.2)
        XCTAssertNil(d.update(inside: false, at: 1))
        XCTAssertEqual(d.deadline, 1.3)
        XCTAssertNil(d.update(inside: true, at: 1.2))   // came back within grace
        XCTAssertNil(d.update(inside: false, at: 2))
        XCTAssertNil(d.update(inside: false, at: 2.2))
        XCTAssertEqual(d.update(inside: false, at: 2.3), false)
        XCTAssertFalse(d.isHovering)
    }

    func testResetDropsPending() {
        var d = HoverDebouncer()
        _ = d.update(inside: true, at: 0)
        d.reset(hovering: false)
        XCTAssertNil(d.deadline)
        XCTAssertFalse(d.isHovering)
    }
}
