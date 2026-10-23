import CoreGraphics
import XCTest
@testable import PlatyNotchKit

final class FullScreenPolicyTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testIsFullScreenWithoutNotch() {
        func fs(_ w: [CGRect]) -> Bool {
            FullScreenPolicy.isFullScreen(windowBounds: w, displayBounds: display, topInset: 0, menuBarVisible: false)
        }
        XCTAssertTrue(fs([CGRect(x: 0, y: 0, width: 1512, height: 982)]))
        XCTAssertTrue(fs([CGRect(x: 0.5, y: 0, width: 1511.5, height: 982)]))
        XCTAssertFalse(fs([CGRect(x: 0, y: 32, width: 1512, height: 950)]))   // not up to the top
        XCTAssertFalse(fs([CGRect(x: 0, y: 0, width: 1400, height: 982)]))    // not full width
        XCTAssertFalse(fs([]))
        // Full screen on another display does not count.
        XCTAssertFalse(fs([CGRect(x: 1512, y: 0, width: 1920, height: 1080)]))
    }

    func testIsFullScreenOnNotchedDisplay() {
        // macOS puts full-screen windows below the camera housing (safe-area top inset 32).
        let belowNotch = CGRect(x: 0, y: 32, width: 1512, height: 950)
        XCTAssertTrue(FullScreenPolicy.isFullScreen(windowBounds: [belowNotch], displayBounds: display,
                                                    topInset: 32, menuBarVisible: false))
        XCTAssertTrue(FullScreenPolicy.isFullScreen(windowBounds: [CGRect(x: 0, y: 32.5, width: 1512, height: 949.5)],
                                                    displayBounds: display, topInset: 32, menuBarVisible: false))
        // Same bounds with the menu bar showing is a zoomed window, not full screen.
        XCTAssertFalse(FullScreenPolicy.isFullScreen(windowBounds: [belowNotch], displayBounds: display,
                                                     topInset: 32, menuBarVisible: true))
        // Window reaching the very top (e.g. a borderless game) still counts.
        XCTAssertTrue(FullScreenPolicy.isFullScreen(windowBounds: [display], displayBounds: display,
                                                    topInset: 32, menuBarVisible: true))
        // Not reaching the bottom.
        XCTAssertFalse(FullScreenPolicy.isFullScreen(windowBounds: [CGRect(x: 0, y: 32, width: 1512, height: 900)],
                                                     displayBounds: display, topInset: 32, menuBarVisible: false))
        // Display on the right of the primary: same rule, offset origin.
        let ext = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        XCTAssertTrue(FullScreenPolicy.isFullScreen(windowBounds: [CGRect(x: 1512, y: 32, width: 1512, height: 950)],
                                                    displayBounds: ext, topInset: 32, menuBarVisible: false))
    }

    func testIgnoresMouseOutsideHitRectRegardlessOfHistory() {
        let hit = CGRect(x: 590, y: 950, width: 320, height: 32)
        XCTAssertTrue(PanelLayout.ignoresMouse(visible: true, hitRect: hit, cursor: CGPoint(x: 100, y: 100)))
        XCTAssertFalse(PanelLayout.ignoresMouse(visible: true, hitRect: hit, cursor: CGPoint(x: 700, y: 982)))
        XCTAssertTrue(PanelLayout.ignoresMouse(visible: false, hitRect: hit, cursor: CGPoint(x: 700, y: 960)))
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
