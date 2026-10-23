import CoreGraphics
import XCTest
@testable import PlatyNotchKit

final class NotchGeometryTests: XCTestCase {
    func testMacBookPro14() {
        let rect = NotchGeometry.notchRect(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
            auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
        XCTAssertEqual(rect, CGRect(x: 654, y: 950, width: 204, height: 32))
    }

    func testNoNotchReturnsNil() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let aux = CGRect(x: 0, y: 950, width: 654, height: 32)
        XCTAssertNil(NotchGeometry.notchRect(screenFrame: screen, auxLeft: nil, auxRight: nil))
        XCTAssertNil(NotchGeometry.notchRect(screenFrame: screen, auxLeft: aux, auxRight: nil))
        XCTAssertNil(NotchGeometry.notchRect(screenFrame: screen, auxLeft: nil, auxRight: aux))
    }

    func testPanelClampedOnSmallScreen() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Anchor near the right edge: panel would overflow, so it is clamped inside.
        let frame = NotchGeometry.panelFrame(
            anchor: CGRect(x: 760, y: 568, width: 40, height: 32),
            size: CGSize(width: 400, height: 300), screenFrame: screen)
        XCTAssertEqual(frame.maxX, 800)
        XCTAssertEqual(frame.maxY, 600)
        XCTAssertEqual(frame.size, CGSize(width: 400, height: 300))
        // Centered anchor stays centered and top-aligned.
        let centered = NotchGeometry.panelFrame(
            anchor: CGRect(x: 380, y: 568, width: 40, height: 32),
            size: CGSize(width: 400, height: 300), screenFrame: screen)
        XCTAssertEqual(centered, CGRect(x: 200, y: 300, width: 400, height: 300))
        // Oversized panel is limited to the screen.
        let big = NotchGeometry.panelFrame(
            anchor: screen, size: CGSize(width: 2000, height: 2000), screenFrame: screen)
        XCTAssertEqual(big, screen)
    }

    func testPillBelowMenuBar() {
        let pill = NotchGeometry.pillRect(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 957), width: 200)
        XCTAssertEqual(pill.maxY, 957)
        XCTAssertEqual(pill.midX, 756)
        XCTAssertEqual(pill.width, 200)
    }
}
