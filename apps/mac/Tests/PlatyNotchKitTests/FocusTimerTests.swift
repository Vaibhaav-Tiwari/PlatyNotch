import XCTest
@testable import PlatyNotchKit

final class FocusTimerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFocusPauseResume() {
        var timer = FocusTimer(minutes: 25)
        timer.start(at: t0)
        timer.pause(at: t0 + 5 * 60)
        XCTAssertEqual(timer.remaining(at: t0 + 10 * 60), 20 * 60)   // paused: time stands still
        timer.resume(at: t0 + 15 * 60)
        XCTAssertEqual(timer.remaining(at: t0 + 15 * 60), 20 * 60)
        XCTAssertEqual(timer.remaining(at: t0 + 16 * 60), 19 * 60)
    }

    func testIdleRunningDone() {
        var timer = FocusTimer(minutes: 25)
        XCTAssertEqual(timer.phase, .idle)
        XCTAssertEqual(timer.remaining(at: t0), 25 * 60)
        XCTAssertFalse(timer.isRunning(at: t0))
        timer.start(at: t0)
        XCTAssertTrue(timer.isRunning(at: t0 + 60))
        XCTAssertEqual(timer.endsAt, t0 + 25 * 60)
        XCTAssertFalse(timer.isDone(at: t0 + 25 * 60 - 1))
        XCTAssertTrue(timer.isDone(at: t0 + 25 * 60))
        XCTAssertFalse(timer.isRunning(at: t0 + 25 * 60))
        XCTAssertEqual(timer.remaining(at: t0 + 40 * 60), 0)
    }

    func testPauseAndResumeAreIdempotent() {
        var timer = FocusTimer(minutes: 50)
        timer.resume(at: t0)                       // not started: nothing
        XCTAssertEqual(timer.phase, .idle)
        timer.start(at: t0)
        timer.pause(at: t0 + 60)
        timer.pause(at: t0 + 600)                  // second pause ignored
        XCTAssertNil(timer.endsAt)
        timer.resume(at: t0 + 700)
        timer.resume(at: t0 + 800)                 // second resume ignored
        XCTAssertEqual(timer.remaining(at: t0 + 760), 50 * 60 - 120)
        XCTAssertEqual(timer.endsAt, t0 + 700 + 50 * 60 - 60)
    }

    func testClockGoingBackwardsNeverAddsTime() {
        var timer = FocusTimer(minutes: 25)
        timer.start(at: t0)
        XCTAssertEqual(timer.remaining(at: t0 - 100), 25 * 60)
        timer.pause(at: t0 - 100)
        XCTAssertEqual(timer.remaining(at: t0), 25 * 60)
    }

    func testCodableRoundTrip() throws {
        var timer = FocusTimer(minutes: 90)
        timer.start(at: t0)
        timer.pause(at: t0 + 30)
        let data = try JSONEncoder().encode(timer)
        XCTAssertEqual(try JSONDecoder().decode(FocusTimer.self, from: data), timer)
    }

    /// Sessions saved by Plan 3 (before FocusTimer wrapped CountdownTimer) still load.
    func testDecodesPlan3Format() throws {
        let since = t0.timeIntervalSinceReferenceDate
        let running = Data(#"{"duration":1500,"elapsedBefore":300,"runningSince":\#(since),"phase":"running"}"#.utf8)
        let r = try JSONDecoder().decode(FocusTimer.self, from: running)
        XCTAssertEqual(r.phase, .running)
        XCTAssertEqual(r.remaining(at: t0 + 60), 1500 - 300 - 60)
        XCTAssertEqual(r.endsAt, t0 + 1200)
        let paused = Data(#"{"duration":1500,"elapsedBefore":300,"phase":"paused"}"#.utf8)
        let p = try JSONDecoder().decode(FocusTimer.self, from: paused)
        XCTAssertEqual(p.phase, .paused)
        XCTAssertEqual(p.remaining(at: t0), 1200)
        let idle = Data(#"{"duration":3000,"elapsedBefore":0,"phase":"idle"}"#.utf8)
        let i = try JSONDecoder().decode(FocusTimer.self, from: idle)
        XCTAssertEqual(i.phase, .idle)
        XCTAssertEqual(i.minutes, 50)
    }

    func testPresets() {
        XCTAssertEqual(FocusTimer.presets, [25, 50, 90])
        XCTAssertEqual(FocusTimer(minutes: 0).duration, 60)   // at least a minute
    }

    func testFeedHoldsNoticesDuringFocus() {
        var f = PanelFeed()
        XCTAssertEqual(f.update(approvalCount: 1, noticeSequence: 1, holdNotices: true), [.approvalsChanged(count: 1)])
        XCTAssertEqual(f.noticeSequence, 1)   // consumed: not replayed when focus ends
        XCTAssertEqual(f.update(approvalCount: 1, noticeSequence: 1), [])
        XCTAssertEqual(f.update(approvalCount: 1, noticeSequence: 2), [.notice])
    }
}
