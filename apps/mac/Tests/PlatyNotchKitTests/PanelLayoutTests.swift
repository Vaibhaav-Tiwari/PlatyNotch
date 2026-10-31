import CoreGraphics
import XCTest
@testable import PlatyNotchKit

final class PanelLayoutTests: XCTestCase {
    // 14-inch MacBook Pro (notch 654...858 x 950...982).
    let mbpScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let mbpVisible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    var mbp: PanelLayout {
        PanelLayout(screenFrame: mbpScreen, visibleFrame: mbpVisible,
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }
    // External 1920x1080 display, menu bar 25 pt, no notch.
    let extScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    var ext: PanelLayout {
        PanelLayout(screenFrame: extScreen, visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                    auxLeft: nil, auxRight: nil)
    }

    func testNotchAnchorAndCompact() {
        let l = mbp
        XCTAssertTrue(l.hasNotch)
        XCTAssertEqual(l.anchor, CGRect(x: 654, y: 950, width: 204, height: 32))
        let c = l.contentRect(for: .compact)
        XCTAssertEqual(c, CGRect(x: 654 - PanelLayout.compactEar, y: 950,
                                 width: 204 + 2 * PanelLayout.compactEar, height: 32))
        XCTAssertEqual(l.hitRect(for: .compact), c)
        // Hidden: hovering the notch itself reveals.
        XCTAssertEqual(l.hitRect(for: .hidden), l.anchor)
    }

    func testPillAnchorBelowMenuBar() {
        let l = ext
        XCTAssertFalse(l.hasNotch)
        XCTAssertEqual(l.anchor.maxY, 1055)
        XCTAssertEqual(l.anchor.width, PanelLayout.pillWidth)
        XCTAssertEqual(l.anchor.midX, 960)
        XCTAssertEqual(l.contentRect(for: .compact), l.anchor)
        // Hidden: a strip touching the top edge of the screen over the pill.
        let h = l.hitRect(for: .hidden)
        XCTAssertEqual(h.maxY, 1080)
        XCTAssertEqual(h.height, PanelLayout.revealDepth)
        XCTAssertEqual(h.minX, l.anchor.minX)
        XCTAssertEqual(h.width, l.anchor.width)
    }

    func testExpandedTopAlignedOnNotchAndBelowMenuBarOtherwise() {
        let e = mbp.contentRect(for: .expanded)
        XCTAssertEqual(e.maxY, 982)
        XCTAssertEqual(e.size, PanelLayout.expandedSize)
        XCTAssertEqual(e.width, 640)
        XCTAssertEqual(e.midX, 756)
        let p = ext.contentRect(for: .peek(.approval))
        XCTAssertEqual(p.maxY, 1055)
        // Without a notch the approval peek gets a header strip (ringing chip) on top of its card room.
        XCTAssertEqual(p.size, CGSize(width: PanelLayout.peekSize.width,
                                      height: PanelLayout.peekSize.height + PanelLayout.headerStripExtra))
        XCTAssertEqual(ext.contentRect(for: .expanded).height, PanelLayout.expandedSize.height + PanelLayout.headerStripExtra)
        XCTAssertEqual(ext.hitRect(for: .expanded), ext.contentRect(for: .expanded))
    }

    /// Island spec 2: the open panel is 640 pt wide.
    func testExpandedIsSixHundredFortyWide() {
        XCTAssertEqual(mbp.contentRect(for: .expanded).width, 640)
        XCTAssertEqual(ext.contentRect(for: .expanded).width, 640)
        XCTAssertEqual(mbp.windowFrame.width, 640)
    }

    func testExpandedHeightIsClamped() {
        var l = mbp
        l.expandedContentHeight = 90
        XCTAssertEqual(l.expandedContentHeight, 160)
        XCTAssertEqual(l.contentRect(for: .expanded).height, 160)
        XCTAssertEqual(l.hitRect(for: .expanded).height, 160)
        l.expandedContentHeight = 500
        XCTAssertEqual(l.contentRect(for: .expanded).height, 380)
        l.expandedContentHeight = 224
        XCTAssertEqual(l.hitRect(for: .expanded).height, 224)
        XCTAssertEqual(l.contentRect(for: .expanded).maxY, 982, "still hangs from the top")
        var e = ext
        e.expandedContentHeight = 200
        XCTAssertEqual(e.contentRect(for: .expanded).height, 200 + PanelLayout.headerStripExtra)
        XCTAssertEqual(l.contentRect(for: .peek(.drop)).height, 224, "the drop view hugs its content like Home")
        XCTAssertLessThan(l.contentRect(for: .peek(.drop)).height, PanelLayout.expandedHeights.upperBound)
        XCTAssertLessThanOrEqual(l.contentRect(for: .peek(.drop)).height, l.windowFrame.height)
    }

    func testBodyHeightMapsToPanelHeight() {
        // Inset above, the bottom padding below; a no-notch screen adds its strip inside contentRect.
        XCTAssertEqual(mbp.expandedHeight(forBody: 150), mbp.contentInset(for: .expanded) + 150 + Space.panelBottom)
        var e = ext
        e.expandedContentHeight = e.expandedHeight(forBody: 150)
        XCTAssertEqual(e.contentRect(for: .expanded).height, e.contentInset(for: .expanded) + 150 + Space.panelBottom)
    }

    func testNoticePeekIsShortAndClearsTheNotch() {
        let n = mbp.contentRect(for: .peek(.notice))
        XCTAssertEqual(n.maxY, 982)
        XCTAssertEqual(n.width, PanelLayout.peekSize.width)
        XCTAssertEqual(n.height, mbp.anchor.height + PanelLayout.noticeHeight)
        XCTAssertEqual(n.midX, 756)
        let e = ext.contentRect(for: .peek(.notice))
        XCTAssertEqual(e.maxY, 1055)
        XCTAssertEqual(e.height, PanelLayout.noticeHeight)
        XCTAssertLessThan(n.height, mbp.contentRect(for: .peek(.approval)).height)
    }

    func testWindowContainsEveryModeContent() {
        for l in [mbp, ext] {
            for m: PanelMode in [.hidden, .compact, .peek(.approval), .peek(.notice), .expanded] {
                XCTAssertTrue(l.windowFrame.contains(l.contentRect(for: m)), "\(m)")
            }
        }
    }

    func testLocalRectFlipsToTopLeftOrigin() {
        let window = CGRect(x: 100, y: 500, width: 400, height: 300)
        let r = PanelLayout.localRect(CGRect(x: 150, y: 700, width: 100, height: 100), in: window)
        XCTAssertEqual(r, CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    func testContainsIncludesTopEdge() {
        let r = CGRect(x: 0, y: 979, width: 10, height: 3)
        XCTAssertTrue(PanelLayout.contains(r, CGPoint(x: 5, y: 982)))
        XCTAssertTrue(PanelLayout.contains(r, CGPoint(x: 10, y: 980)))
        XCTAssertFalse(PanelLayout.contains(r, CGPoint(x: 11, y: 980)))
        XCTAssertFalse(PanelLayout.contains(r, CGPoint(x: 5, y: 978)))
    }

    func testAppKitToCGFlip() {
        // Secondary display above the primary (primary height 982).
        let r = PanelLayout.cgRect(fromAppKit: CGRect(x: 0, y: 982, width: 1920, height: 1080), primaryHeight: 982)
        XCTAssertEqual(r, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    func testFullScreenHoldRectBridgesTopEdgeAndPill() {
        let l = ext
        let hold = l.fullScreenHoldRect(for: .compact)
        // Covers the menu-bar gap between the top-edge strip and the pill below it.
        XCTAssertTrue(PanelLayout.contains(hold, CGPoint(x: 960, y: 1080)))
        XCTAssertTrue(PanelLayout.contains(hold, CGPoint(x: 960, y: 1065)))
        XCTAssertTrue(PanelLayout.contains(hold, CGPoint(x: 960, y: 1040)))
        XCTAssertFalse(PanelLayout.contains(hold, CGPoint(x: 960, y: 1000)))
        XCTAssertEqual(mbp.fullScreenHoldRect(for: .compact), mbp.contentRect(for: .compact))
    }

    func testHoverPeekRect() {
        let l = mbp
        XCTAssertEqual(PanelLayout.hoverPeekHeight, 176)
        let r = l.contentRect(for: .peek(.hover))
        XCTAssertEqual(r.width, PanelLayout.peekSize.width)
        XCTAssertEqual(r.width, 420)
        XCTAssertEqual(r.height, l.anchor.height + 176)
        XCTAssertEqual(r.maxY, l.anchor.maxY, "grows down from the notch")
        XCTAssertEqual(r.midX, l.anchor.midX)
        XCTAssertTrue(l.windowFrame.contains(r))
        XCTAssertEqual(l.hitRect(for: .peek(.hover)), r)
        XCTAssertEqual(ext.contentRect(for: .peek(.hover)).height, 176)
    }
}
