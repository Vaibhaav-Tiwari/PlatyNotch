import Foundation
import PlatyNotchKit
import XCTest

/// The Timer tool's presets and running list (Island spec 4).
final class TimerPresetsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_450_000)

    func testPresetTitles() {
        XCTAssertEqual(TimerPresets.timer.map(TimerPresets.chipTitle), ["1 min", "5 min", "10 min", "25 min"])
        XCTAssertEqual(TimerPresets.focus.map(TimerPresets.chipTitle), ["15 min", "25 min", "50 min"])
        XCTAssertEqual(TimerPresets.timerDefault, 600)
        XCTAssertEqual(TimerPresets.focusDefault, 1500)
        XCTAssertEqual(TimerPresets.chipTitle(3900), "1 h 5 min")
        XCTAssertEqual(TimerMode.allCases.map(\.title), ["Timer", "Focus", "Stopwatch"])
    }

    func testRunningRows() {
        let tea = CountdownTimer(label: "Tea", duration: 190, startedAt: now)
        let laundry = CountdownTimer(label: "Laundry", duration: 1325, startedAt: now)
        let plain = CountdownTimer(label: DurationParser.describe(600), duration: 600, startedAt: now.addingTimeInterval(-30))
        let done = CountdownTimer(label: "Done", duration: 60, startedAt: now.addingTimeInterval(-120))
        let rows = RunningTimers.rows([laundry, done, tea, plain], now: now)
        XCTAssertEqual(rows.map(\.text), ["Tea · 3:10 left", "Timer · 9:30 left", "Laundry · 22:05 left"])
        XCTAssertEqual(rows.map(\.soonest), [true, false, false])
        XCTAssertEqual(rows.first?.id, tea.id)
    }
}
