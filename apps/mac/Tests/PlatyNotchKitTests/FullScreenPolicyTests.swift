import CoreGraphics
import XCTest
@testable import PlatyNotchKit

final class FullScreenPolicyTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testIsFullScreen() {
        XCTAssertTrue(FullScreenPolicy.isFullScreen(windowBounds: [CGRect(x: 0, y: 0, width: 1512, height: 982)],
                                                    displayBounds: display))
        XCTAssertTrue(FullScreenPolicy.isFullScreen(windowBounds: [CGRect(x: 0.5, y: 0, width: 1511.5, height: 982)],
                                                    displayBounds: display))
        // Maximised (zoomed) window below the menu bar is not full screen.
        XCTAssertFalse(FullScreenPolicy.isFullScreen(windowBounds: [CGRect(x: 0, y: 32, width: 1512, height: 950)],
                                                     displayBounds: display))
        XCTAssertFalse(FullScreenPolicy.isFullScreen(windowBounds: [], displayBounds: display))
        // Full screen on another display does not count.
        XCTAssertFalse(FullScreenPolicy.isFullScreen(windowBounds: [CGRect(x: 1512, y: 0, width: 1920, height: 1080)],
                                                     displayBounds: display))
    }

    let reveal = CGRect(x: 600, y: 979, width: 300, height: 3)
    let hit = CGRect(x: 590, y: 950, width: 320, height: 32)
    let away = CGPoint(x: 100, y: 400)

    func testNotFullScreenNeverSuppresses() {
        XCTAssertFalse(FullScreenPolicy.shouldSuppress(fullScreen: false, mode: .compact, cursor: away,
                                                       revealRect: reveal, hitRect: hit, wasSuppressed: true))
    }

    func testFullScreenSuppressesUntilTopEdge() {
        XCTAssertTrue(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: .compact, cursor: away,
                                                      revealRect: reveal, hitRect: hit, wasSuppressed: false))
        XCTAssertTrue(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: .hidden, cursor: away,
                                                      revealRect: reveal, hitRect: hit, wasSuppressed: true))
        // Touch the top edge: revealed.
        XCTAssertFalse(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: .compact, cursor: CGPoint(x: 700, y: 982),
                                                       revealRect: reveal, hitRect: hit, wasSuppressed: true))
        // Once revealed, moving down into the panel keeps it.
        XCTAssertFalse(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: .compact, cursor: CGPoint(x: 700, y: 960),
                                                       revealRect: reveal, hitRect: hit, wasSuppressed: false))
        // ...but the same point does not reveal a suppressed panel.
        XCTAssertTrue(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: .compact, cursor: CGPoint(x: 700, y: 960),
                                                      revealRect: reveal, hitRect: hit, wasSuppressed: true))
    }

    func testApprovalAndExpandedAlwaysShow() {
        XCTAssertFalse(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: .peek(.approval), cursor: away,
                                                       revealRect: reveal, hitRect: hit, wasSuppressed: true))
        XCTAssertFalse(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: .expanded, cursor: away,
                                                       revealRect: reveal, hitRect: hit, wasSuppressed: false))
        XCTAssertTrue(FullScreenPolicy.shouldSuppress(fullScreen: true, mode: .peek(.notice), cursor: away,
                                                      revealRect: reveal, hitRect: hit, wasSuppressed: false))
    }
}
