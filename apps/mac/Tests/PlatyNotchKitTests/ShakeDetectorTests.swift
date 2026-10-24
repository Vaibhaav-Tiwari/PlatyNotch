import XCTest
@testable import PlatyNotchKit

final class ShakeDetectorTests: DefaultsTestCase {
    /// Feeds `xs` at 0.05 s apart from `start`; returns the indexes that reported a shake.
    private func run(_ d: inout ShakeDetector, _ xs: [Double], start: TimeInterval = 0,
                     step: TimeInterval = 0.05) -> [Int] {
        var hits: [Int] = []
        for (i, x) in xs.enumerated() where d.feed(x: x, time: start + Double(i) * step) {
            hits.append(i)
        }
        return hits
    }

    /// Back and forth 40 pt: one reversal per sample after the first leg.
    private func zigzag(_ n: Int) -> [Double] {
        (0..<n).map { $0 % 2 == 0 ? 0 : 40 }
    }

    func testThresholdFromSensitivity() {
        XCTAssertEqual(ShakeDetector.threshold(sensitivity: 1), 7)
        XCTAssertEqual(ShakeDetector.threshold(sensitivity: 3), 5)
        XCTAssertEqual(ShakeDetector.threshold(sensitivity: 5), 3)
        XCTAssertEqual(ShakeDetector.threshold(sensitivity: 0), 7, "clamped to 1")
        XCTAssertEqual(ShakeDetector.threshold(sensitivity: 9), 3, "clamped to 5")
        XCTAssertEqual(ShakeDetector().threshold, 5)
    }

    func testMostSensitiveNeedsThreeReversals() {
        var d = ShakeDetector(sensitivity: 5)
        // 0→40 (first leg), →0 (1), →40 (2), →0 (3).
        XCTAssertEqual(run(&d, [0, 40, 0, 40, 0]), [4])
    }

    func testLeastSensitiveNeedsSevenReversals() {
        var d = ShakeDetector(sensitivity: 1)
        XCTAssertEqual(run(&d, zigzag(8)), [], "six reversals are not enough")
        d.reset()
        XCTAssertEqual(run(&d, zigzag(9)), [8])
    }

    func testShortLegsNeverCount() {
        var d = ShakeDetector(sensitivity: 5)
        XCTAssertEqual(run(&d, (0..<20).map { $0 % 2 == 0 ? 0 : 29 }), [], "29 pt wiggles")
    }

    func testSlowShakeOutsideTheWindow() {
        var d = ShakeDetector(sensitivity: 5)
        // Reversals 0.3 s apart: never three within 0.5 s.
        XCTAssertEqual(run(&d, zigzag(10), step: 0.3), [])
    }

    func testVerticalMovementIsIgnored() {
        var d = ShakeDetector(sensitivity: 5)
        XCTAssertEqual(run(&d, Array(repeating: 100, count: 20)), [])
    }

    func testTravelAcrossSamplesCounts() {
        var d = ShakeDetector(sensitivity: 5)
        // Each leg spread over several samples, the turn is where it peaked.
        // 35 (first leg), back to 0 (1: 35 pt), 40 (2), 10 (3: 30 pt back from 40).
        let xs: [Double] = [0, 15, 35, 20, 0, 20, 40, 10, -5]
        XCTAssertEqual(run(&d, xs, step: 0.04), [7])
    }

    func testReportsOnceThenStartsOver() {
        var d = ShakeDetector(sensitivity: 5)
        XCTAssertEqual(run(&d, zigzag(5)), [4])
        XCTAssertEqual(run(&d, [0], start: 1), [], "the next shake starts from scratch")
    }

    // MARK: - Gate

    func testGateNeedsADragWithAFileOrURL() {
        XCTAssertTrue(ShakeGate.shouldFeed(isDragging: true, dragTypes: ["public.file-url"]))
        XCTAssertTrue(ShakeGate.shouldFeed(isDragging: true, dragTypes: ["public.url", "public.utf8-plain-text"]))
        XCTAssertTrue(ShakeGate.shouldFeed(isDragging: true, dragTypes: ["com.apple.NSFilePromiseItemMetaData"]))
        XCTAssertFalse(ShakeGate.shouldFeed(isDragging: false, dragTypes: ["public.file-url"]), "not dragging")
    }

    /// A text selection being dragged never feeds the detector.
    func testTextOnlyDragNeverTriggers() {
        let text = ["public.utf8-plain-text", "NSStringPboardType", "public.rtf"]
        XCTAssertFalse(ShakeGate.shouldFeed(isDragging: true, dragTypes: text))
        XCTAssertFalse(ShakeGate.shouldFeed(isDragging: true, dragTypes: []))
        // Fed only through the gate: a full shake of a text drag reports nothing.
        var d = ShakeDetector(sensitivity: 5)
        var hits = 0
        for (i, x) in zigzag(12).enumerated()
        where ShakeGate.shouldFeed(isDragging: true, dragTypes: text) && d.feed(x: x, time: Double(i) * 0.05) {
            hits += 1
        }
        XCTAssertEqual(hits, 0)
    }

    func testConcealedOrTransientDragsAreRefused() {
        XCTAssertFalse(ShakeGate.shouldFeed(isDragging: true,
                                            dragTypes: ["public.file-url", ShelfDropPolicy.concealedType]))
        XCTAssertFalse(ShakeGate.shouldFeed(isDragging: true,
                                            dragTypes: ["public.url", ShelfDropPolicy.transientType]))
    }
}
