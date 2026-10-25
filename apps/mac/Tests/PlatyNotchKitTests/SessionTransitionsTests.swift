import Foundation
import PlatyNotchKit
import XCTest

final class SessionTransitionsTests: DefaultsTestCase {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func s(_ key: String, _ state: SessionState) -> Session {
        Session(key: key, agent: "codex", agentName: "Codex", sessionID: key, state: state, startedAt: t0, updatedAt: t0)
    }

    func testFirstCallOnlyLooks() {
        var tr = SessionTransitions()
        let first = tr.update([s("a", .idle), s("b", .waitingInput)])
        XCTAssertEqual(first, SessionChanges(finished: [], enteredNeedsYou: [], allFinished: false))
    }

    func testActiveToIdleIsFinished() {
        var tr = SessionTransitions()
        _ = tr.update([s("a", .active), s("b", .active)])
        XCTAssertEqual(tr.update([s("a", .idle), s("b", .active)]).finished, ["a"])
        XCTAssertEqual(tr.update([s("a", .idle), s("b", .exited)]).finished, ["b"])
        XCTAssertEqual(tr.update([s("a", .idle), s("b", .exited)]).finished, [], "once")
        _ = tr.update([s("a", .blocked)])
        XCTAssertEqual(tr.update([s("a", .idle)]).finished, [], "blocked → idle is not a finish")
    }

    func testRemovalIsNotFinished() {
        var tr = SessionTransitions()
        _ = tr.update([s("a", .active), s("b", .idle)])
        XCTAssertEqual(tr.update([s("b", .idle)]).finished, [])
        XCTAssertEqual(tr.update([]).finished, [])
    }

    func testEnteredNeedsYou() {
        var tr = SessionTransitions()
        _ = tr.update([s("a", .active)])
        XCTAssertEqual(tr.update([s("a", .waitingInput)]).enteredNeedsYou, ["a"])
        XCTAssertEqual(tr.update([s("a", .waitingInput)]).enteredNeedsYou, [])
        XCTAssertEqual(tr.update([s("a", .blocked)]).enteredNeedsYou, [], "still needs you")
        _ = tr.update([s("a", .active)])
        XCTAssertEqual(tr.update([s("a", .blocked), s("n", .waitingInput)]).enteredNeedsYou, ["a", "n"])
    }

    func testAllFinishedOnlyWhenLastEnds() {
        var tr = SessionTransitions()
        _ = tr.update([s("a", .active), s("b", .active)])
        let one = tr.update([s("a", .idle), s("b", .active)])
        XCTAssertEqual(one.finished, ["a"])
        XCTAssertFalse(one.allFinished)
        let both = tr.update([s("a", .idle), s("b", .idle)])
        XCTAssertTrue(both.allFinished)
        _ = tr.update([s("a", .active), s("b", .waitingInput)])
        XCTAssertFalse(tr.update([s("a", .idle), s("b", .waitingInput)]).allFinished, "b still needs you")
    }

    func testFinishWatchWrapperKeepsBehaviour() {
        var watch = PlatyFinishWatch()
        XCTAssertFalse(watch.update(["a": .active]))
        XCTAssertTrue(watch.update(["a": .idle]))
    }
}
