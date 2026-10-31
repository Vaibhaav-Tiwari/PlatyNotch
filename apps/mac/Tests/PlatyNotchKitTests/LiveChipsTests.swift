import Foundation
import PlatyNotchKit
import XCTest

final class LiveChipsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_448_000)

    private func focus(left: TimeInterval, paused: Bool = false) -> FocusTimer {
        var f = FocusTimer(minutes: 25)
        f.start(at: now.addingTimeInterval(-(25 * 60 - left)))
        if paused { f.pause(at: now) }
        return f
    }

    private func timer(_ label: String = "", left: TimeInterval, paused: Bool = false) -> CountdownTimer {
        let total: TimeInterval = max(3600, left)
        var t = CountdownTimer(label: label, duration: total)
        t.startedAt = now.addingTimeInterval(left - total)
        if paused { t.startedAt = nil; t.pausedRemaining = left }
        return t
    }

    func testOrderFocusTimersShelf() {
        let c = LiveChips.chips(focus: focus(left: 18 * 60 + 42), timers: [timer("tea", left: 300), timer(left: 120)],
                                shelfCount: 3, now: now)
        XCTAssertEqual(c.shown.map(\.text), ["Focus 18:42", "Timer 2:00", "Tea timer 5:00", "Shelf · 3"])
        XCTAssertEqual(c.overflow, 0)
        XCTAssertEqual(c.shown[0].kind, .focus)
        XCTAssertEqual(c.shown[0].tone, .needsYou)
        XCTAssertNil(c.shown[1].tone)
        XCTAssertEqual(c.shown[3].kind, .shelf)
    }

    func testOverflowAfterFour() {
        let timers = (1...4).map { timer(left: TimeInterval($0 * 60)) }
        let c = LiveChips.chips(focus: focus(left: 600), timers: timers, shelfCount: 1, now: now)
        XCTAssertEqual(c.shown.count, 4)
        XCTAssertEqual(c.overflow, 2)
        XCTAssertEqual(LiveChips.maxShown, 4)
    }

    func testPausedTimerNotShown() {
        let c = LiveChips.chips(focus: focus(left: 600, paused: true), timers: [timer(left: 100, paused: true)],
                                shelfCount: 0, now: now)
        XCTAssertEqual(c.shown, [])
    }

    func testNothingLiveIsEmpty() {
        let c = LiveChips.chips(focus: nil, timers: [], shelfCount: 0, now: now)
        XCTAssertEqual(c.shown, [])
        XCTAssertEqual(c.overflow, 0)
    }

    func testHourTimerUsesHours() {
        let c = LiveChips.chips(focus: nil, timers: [timer(left: 3600 + 5 * 60 + 9)], shelfCount: 0, now: now)
        XCTAssertEqual(c.shown.first?.text, "Timer 1:05:09")
        XCTAssertEqual(LiveChips.chips(focus: nil, timers: [timer(left: 59.2)], shelfCount: 0, now: now).shown.first?.text,
                       "Timer 1:00", "a part-second counts whole")
    }

    func testTimerChipCarriesItsID() {
        let t = timer("tea", left: 90)
        XCTAssertEqual(LiveChips.chips(focus: nil, timers: [t], shelfCount: 0, now: now).shown.first?.kind, .timer(t.id))
    }

    func testFinishedAndLongLabels() {
        XCTAssertEqual(LiveChips.chips(focus: nil, timers: [timer(left: 0)], shelfCount: 0, now: now).shown, [])
        let long = String(repeating: "x", count: 200)
        XCTAssertTrue(LiveChips.chips(focus: nil, timers: [timer(long, left: 60)], shelfCount: 0, now: now).shown[0].text
            .hasPrefix("X"), "the view truncates; the model passes the label through")
    }
}
