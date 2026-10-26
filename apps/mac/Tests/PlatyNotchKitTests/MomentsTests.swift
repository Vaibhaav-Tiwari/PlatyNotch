import PlatyNotchKit
import XCTest

final class MomentsTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_000_000)

    func testOncePerEvent() {
        var gate = MomentGate()
        XCTAssertTrue(gate.admit(.newBest(game: "snake", score: 42), approvalsPending: 0))
        XCTAssertFalse(gate.admit(.newBest(game: "snake", score: 42), approvalsPending: 0))
        // A different event is its own moment.
        XCTAssertTrue(gate.admit(.newBest(game: "snake", score: 43), approvalsPending: 0))
        XCTAssertTrue(gate.admit(.focusComplete(endedAt: t), approvalsPending: 0))
        XCTAssertFalse(gate.admit(.focusComplete(endedAt: t), approvalsPending: 0))
        XCTAssertTrue(gate.admit(.allAgentsFinished(at: t), approvalsPending: 0))
        XCTAssertTrue(gate.admit(.allAgentsFinished(at: t.addingTimeInterval(60)), approvalsPending: 0))
    }

    /// An approval waiting drops the moment: it is not played later either.
    func testNeverDuringApproval() {
        var gate = MomentGate()
        XCTAssertFalse(gate.admit(.allAgentsFinished(at: t), approvalsPending: 1))
        XCTAssertFalse(gate.admit(.allAgentsFinished(at: t), approvalsPending: 0))
        XCTAssertFalse(gate.admit(.newBest(game: "2048", score: 1024), approvalsPending: 3))
    }

    func testCelebrationEndsWithinTwoSeconds() {
        var flags = PlatyMoodFlags()
        flags.celebrate(at: t)
        XCTAssertTrue(flags.celebrating(at: t.addingTimeInterval(1.9)))
        XCTAssertFalse(flags.celebrating(at: t.addingTimeInterval(2.1)))
    }

    /// The gate's memory stays small however many moments pass.
    func testGateMemoryIsBounded() {
        var gate = MomentGate()
        for i in 0..<500 { _ = gate.admit(.newBest(game: "snake", score: i), approvalsPending: 0) }
        XCTAssertLessThanOrEqual(gate.remembered, MomentGate.memory)
    }
}
