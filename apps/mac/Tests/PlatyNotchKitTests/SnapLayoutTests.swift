import CoreGraphics
import XCTest
@testable import PlatyNotchKit

final class SnapLayoutTests: DefaultsTestCase {
    /// A 1440×900 primary display with a 25 pt menu bar (AppKit: y up from its bottom).
    private let primary = SnapScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
    /// A 1920×1080 display above and left of the primary: negative x in AppKit, negative
    /// x and y in Accessibility coordinates.
    private let upperLeft = SnapScreen(frame: CGRect(x: -1920, y: 900, width: 1920, height: 1080),
                                       visible: CGRect(x: -1920, y: 900, width: 1920, height: 1055))
    private let primaryHeight: CGFloat = 900

    func testHalves() {
        let v = CGRect(x: 0, y: 0, width: 1440, height: 875)
        XCTAssertEqual(SnapLayout.frame(for: .leftHalf, in: v, gap: 0), CGRect(x: 0, y: 0, width: 720, height: 875))
        XCTAssertEqual(SnapLayout.frame(for: .rightHalf, in: v, gap: 0), CGRect(x: 720, y: 0, width: 720, height: 875))
        XCTAssertEqual(SnapLayout.frame(for: .topHalf, in: v, gap: 0), CGRect(x: 0, y: 437.5, width: 1440, height: 437.5),
                       "AppKit's y goes up: the top half has the larger y")
        XCTAssertEqual(SnapLayout.frame(for: .bottomHalf, in: v, gap: 0), CGRect(x: 0, y: 0, width: 1440, height: 437.5))
        XCTAssertEqual(SnapLayout.frame(for: .maximize, in: v, gap: 0), v)
        XCTAssertEqual(SnapLayout.frame(for: .topLeft, in: v, gap: 0), CGRect(x: 0, y: 437.5, width: 720, height: 437.5))
        XCTAssertEqual(SnapLayout.frame(for: .bottomRight, in: v, gap: 0), CGRect(x: 720, y: 0, width: 720, height: 437.5))
    }

    func testThirdsCoverWidth() {
        let v = CGRect(x: -1920, y: 900, width: 1920, height: 1055)
        for gap in [CGFloat(0), CGFloat(4), CGFloat(8), CGFloat(12)] {
            let l = SnapLayout.frame(for: .leftThird, in: v, gap: gap)
            let c = SnapLayout.frame(for: .centerThird, in: v, gap: gap)
            let r = SnapLayout.frame(for: .rightThird, in: v, gap: gap)
            XCTAssertEqual(l.minX - v.minX, gap, accuracy: 0.0001)
            XCTAssertEqual(c.minX - l.maxX, gap, accuracy: 0.0001)
            XCTAssertEqual(r.minX - c.maxX, gap, accuracy: 0.0001)
            XCTAssertEqual(v.maxX - r.maxX, gap, accuracy: 0.0001, "three thirds and four gaps are the width")
            XCTAssertEqual(l.width, c.width, accuracy: 0.0001)
            XCTAssertEqual(c.width, r.width, accuracy: 0.0001)
            let lt = SnapLayout.frame(for: .leftTwoThirds, in: v, gap: gap)
            let rt = SnapLayout.frame(for: .rightTwoThirds, in: v, gap: gap)
            XCTAssertEqual(lt.minX, l.minX, accuracy: 0.0001)
            XCTAssertEqual(lt.maxX, c.maxX, accuracy: 0.0001, "two thirds span the gap between them")
            XCTAssertEqual(rt.minX, c.minX, accuracy: 0.0001)
            XCTAssertEqual(rt.maxX, r.maxX, accuracy: 0.0001)
        }
    }

    func testGapApplied() {
        let v = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let g: CGFloat = 8
        XCTAssertEqual(SnapLayout.frame(for: .maximize, in: v, gap: g), v.insetBy(dx: 8, dy: 8))
        let left = SnapLayout.frame(for: .leftHalf, in: v, gap: g)
        let right = SnapLayout.frame(for: .rightHalf, in: v, gap: g)
        XCTAssertEqual(left, CGRect(x: 8, y: 8, width: 708, height: 859))
        XCTAssertEqual(right.minX - left.maxX, 8)
        XCTAssertEqual(v.maxX - right.maxX, 8)
        let tl = SnapLayout.frame(for: .topLeft, in: v, gap: g)
        let bl = SnapLayout.frame(for: .bottomLeft, in: v, gap: g)
        XCTAssertEqual(tl.minY - bl.maxY, 8, "a gap between the top and bottom quarters")
        XCTAssertEqual(v.maxY - tl.maxY, 8)
        XCTAssertEqual(bl.minY, 8)
        XCTAssertEqual(SnapLayout.frame(for: .leftHalf, in: v, gap: -5), SnapLayout.frame(for: .leftHalf, in: v, gap: 0),
                       "a negative gap is none")
    }

    func testCoordinateFlip() {
        // The primary's top-left 720×450: AppKit y 450…900, AX y 0…450.
        let cocoa = CGRect(x: 0, y: 450, width: 720, height: 450)
        let ax = SnapLayout.axFrame(from: cocoa, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(ax, CGRect(x: 0, y: 0, width: 720, height: 450))
        XCTAssertEqual(SnapLayout.axFrame(from: ax, primaryScreenHeight: primaryHeight), cocoa, "its own inverse")
        // R15: a display above and left of the primary flips with the primary's height.
        let upperLeftAX = SnapLayout.axFrame(from: upperLeft.frame, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(upperLeftAX, CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
    }

    func testPlanOnASecondDisplayAboveAndLeft() throws {
        // A window on the upper-left display, AX coordinates (both negative).
        let window = CGRect(x: -1500, y: -800, width: 600, height: 400)
        let plan = try XCTUnwrap(SnapLayout.plan(.leftHalf, windowAX: window, resizable: true,
                                                 screens: [primary, upperLeft], primaryScreenHeight: primaryHeight, gap: 0))
        // Visible AppKit y 900…1955 → AX y -1055…0 (menu bar at the top, -1080…-1055).
        XCTAssertEqual(plan.position, CGPoint(x: -1920, y: -1055))
        XCTAssertEqual(plan.size, CGSize(width: 960, height: 1055))
    }

    func testPlanOnThePrimary() throws {
        let window = CGRect(x: 100, y: 100, width: 500, height: 300)
        let plan = try XCTUnwrap(SnapLayout.plan(.rightHalf, windowAX: window, resizable: true,
                                                 screens: [primary, upperLeft], primaryScreenHeight: primaryHeight, gap: 0))
        XCTAssertEqual(plan.position, CGPoint(x: 720, y: 25), "below the menu bar")
        XCTAssertEqual(plan.size, CGSize(width: 720, height: 875))
    }

    func testFixedSizeWindowOnlyMoves() throws {
        let window = CGRect(x: 900, y: 500, width: 400, height: 300)
        let plan = try XCTUnwrap(SnapLayout.plan(.leftHalf, windowAX: window, resizable: false,
                                                 screens: [primary], primaryScreenHeight: primaryHeight, gap: 0))
        XCTAssertNil(plan.size, "a window whose size cannot be set is never resized")
        // Centered in the left half (AX x 0…720, y 25…900).
        XCTAssertEqual(plan.position, CGPoint(x: 160, y: 313))

        // Larger than the screen: its top-left corner stays reachable.
        let huge = CGRect(x: 50, y: 60, width: 2000, height: 1200)
        let big = try XCTUnwrap(SnapLayout.plan(.maximize, windowAX: huge, resizable: false,
                                                screens: [primary], primaryScreenHeight: primaryHeight, gap: 0))
        XCTAssertNil(big.size)
        XCTAssertEqual(big.position, CGPoint(x: 0, y: 25))
    }

    func testCenterKeepsSizeAndShrinksOnlyWhenTooLarge() throws {
        let window = CGRect(x: 10, y: 40, width: 600, height: 400)
        let plan = try XCTUnwrap(SnapLayout.plan(.center, windowAX: window, resizable: true,
                                                 screens: [primary], primaryScreenHeight: primaryHeight, gap: 0))
        XCTAssertNil(plan.size)
        XCTAssertEqual(plan.position, CGPoint(x: 420, y: 263))  // 25 + (875 - 400) / 2 = 262.5

        let tall = CGRect(x: 10, y: 40, width: 600, height: 2000)
        let shrunk = try XCTUnwrap(SnapLayout.plan(.center, windowAX: tall, resizable: true,
                                                   screens: [primary], primaryScreenHeight: primaryHeight, gap: 0))
        XCTAssertEqual(shrunk.size, CGSize(width: 600, height: 875))
        XCTAssertEqual(shrunk.position, CGPoint(x: 420, y: 25))
    }

    func testMostlyOffScreenWindowGoesToTheDisplayItOverlaps() throws {
        // Center far right of the primary (off every display); its left 100 pt are on it.
        let window = CGRect(x: 1340, y: 200, width: 1000, height: 400)
        XCTAssertEqual(SnapLayout.screenIndex(for: SnapLayout.axFrame(from: window, primaryScreenHeight: primaryHeight),
                                              in: [upperLeft, primary]), 1)
        let plan = try XCTUnwrap(SnapLayout.plan(.maximize, windowAX: window, resizable: true,
                                                 screens: [upperLeft, primary], primaryScreenHeight: primaryHeight, gap: 0))
        XCTAssertEqual(plan.position, CGPoint(x: 0, y: 25))
        XCTAssertEqual(plan.size, CGSize(width: 1440, height: 875))

        // Nowhere near any display: the first one (the primary in `NSScreen.screens`).
        let lost = CGRect(x: 9000, y: 9000, width: 100, height: 100)
        XCTAssertEqual(SnapLayout.screenIndex(for: lost, in: [primary, upperLeft]), 0)
        XCTAssertNil(SnapLayout.plan(.maximize, windowAX: lost, resizable: true, screens: [],
                                     primaryScreenHeight: primaryHeight, gap: 0))
    }

    /// Fix round 1: edges are rounded, not origin and size apart, so neighbours share an
    /// edge exactly (no 1 pt seam or overlap) on odd-sized screens.
    func testRoundedNeighboursShareEdges() throws {
        let odd = SnapScreen(frame: CGRect(x: 0, y: 0, width: 1441, height: 901),
                             visible: CGRect(x: 0, y: 0, width: 1441, height: 876))
        let window = CGRect(x: 100, y: 100, width: 300, height: 200)
        for gap in [CGFloat(0), CGFloat(4), CGFloat(8)] {
            func plan(_ t: SnapTarget) throws -> (x: CGFloat, maxX: CGFloat, y: CGFloat, maxY: CGFloat) {
                let p = try XCTUnwrap(SnapLayout.plan(t, windowAX: window, resizable: true, screens: [odd],
                                                      primaryScreenHeight: 901, gap: gap))
                let size = try XCTUnwrap(p.size)
                XCTAssertEqual(p.position.x, p.position.x.rounded())
                XCTAssertEqual(size.width, size.width.rounded())
                return (p.position.x, p.position.x + size.width, p.position.y, p.position.y + size.height)
            }
            let l = try plan(.leftHalf), r = try plan(.rightHalf)
            XCTAssertEqual(r.x - l.maxX, gap)
            XCTAssertEqual(1441 - r.maxX, gap)
            let a = try plan(.leftThird), b = try plan(.centerThird), c = try plan(.rightThird)
            XCTAssertEqual(b.x - a.maxX, gap)
            XCTAssertEqual(c.x - b.maxX, gap)
            XCTAssertEqual(1441 - c.maxX, gap, "the last third ends on the screen edge (minus the gap)")
            let top = try plan(.topHalf), bottom = try plan(.bottomHalf)
            XCTAssertEqual(bottom.y - top.maxY, gap)
            XCTAssertEqual(901 - bottom.maxY, gap)
        }
    }

    func testCentringAKeptSize() throws {
        let p = try XCTUnwrap(SnapLayout.plan(.leftHalf, windowAX: CGRect(x: 0, y: 0, width: 10, height: 10),
                                              resizable: true, screens: [primary], primaryScreenHeight: primaryHeight,
                                              gap: 0))
        XCTAssertEqual(p.area, CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(p.bounds, CGRect(x: 0, y: 25, width: 1440, height: 875))
        XCTAssertEqual(SnapLayout.position(centering: CGSize(width: 400, height: 300), in: p), CGPoint(x: 160, y: 313))
        XCTAssertEqual(SnapLayout.position(centering: CGSize(width: 2000, height: 1000), in: p), CGPoint(x: 0, y: 25),
                       "too large: top-left corner on screen")
        XCTAssertEqual(SnapLayout.position(centering: CGSize(width: 1000, height: 300), in: p), CGPoint(x: 0, y: 313),
                       "wider than the half: kept inside the screen")
    }

    func testDefaultShortcutsNeverClash() {
        var presets: [String: [KeyCombo]] = [:]
        for t in SnapTarget.allCases { presets[t.hotKeyFeature] = [t.defaultCombo] }
        XCTAssertEqual(presets.count, 15)
        XCTAssertTrue(HotKeyCatalog.clashes(in: presets).isEmpty, "not each other's nor the clipboard's")
        var catalog = HotKeyCatalog()
        for t in SnapTarget.allCases { XCTAssertNil(catalog.assign(t.defaultCombo, to: t.hotKeyFeature)) }
        XCTAssertEqual(SnapTarget.leftHalf.defaultCombo.display, "⌃⌥←")
        XCTAssertEqual(SnapTarget.maximize.defaultCombo.display, "⌃⌥↩")
        XCTAssertEqual(SnapTarget.center.defaultCombo.display, "⌃⌥C")
        XCTAssertEqual(SnapTarget.allCases.map { $0.defaultCombo.display }.joined(separator: " "),
                       "⌃⌥← ⌃⌥→ ⌃⌥↑ ⌃⌥↓ ⌃⌥D ⌃⌥F ⌃⌥G ⌃⌥E ⌃⌥T ⌃⌥↩ ⌃⌥C ⌃⌥U ⌃⌥I ⌃⌥J ⌃⌥K")
    }
}
