import Foundation
import XCTest
@testable import PlatyNotchKit

/// The closed pill's lead (Island spec 7, wireframe F).
final class PillLeadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_450_000)

    private func session(_ key: String, _ state: SessionState) -> Session {
        Session(key: key, agent: "claude-code", agentName: "claude-code", sessionID: key, state: state,
                startedAt: now, updatedAt: now)
    }

    private func lead(approvals: Int = 0, sessions: [Session] = [], timer: TimeInterval? = nil, music: Bool = false,
                      order: PillOrder) -> PillLead {
        PillLeads.lead(approvals: approvals, sessions: sessions, log: AgentFinishLog(), timerRemaining: timer,
                       musicPlaying: music, order: order, now: now)
    }

    func testApprovalAlwaysWins() {
        for order in [PillOrder.musicFirst, .agentsFirst] {
            XCTAssertEqual(lead(approvals: 1, sessions: [session("a", .waitingInput), session("b", .active)],
                                timer: 600, music: true, order: order), .approval(count: 1), "\(order)")
        }
    }

    func testNeedsYouBeatsEverythingElse() {
        for order in [PillOrder.musicFirst, .agentsFirst] {
            XCTAssertEqual(lead(sessions: [session("w", .active), session("n", .waitingInput)], timer: 600, music: true,
                                order: order), .needsYou(sessionID: "n"))
        }
    }

    func testMusicFirstOrder() {
        let working = [session("w", .active)]
        XCTAssertEqual(lead(sessions: working, timer: 1122, music: true, order: .musicFirst), .music)
        XCTAssertEqual(lead(sessions: working, timer: 1122, order: .musicFirst), .timer(remaining: "18:42"))
        XCTAssertEqual(lead(sessions: working, order: .musicFirst), .agents)
    }

    func testAgentsFirstOrder() {
        XCTAssertEqual(lead(sessions: [session("w", .active)], timer: 1122, music: true, order: .agentsFirst), .agents)
        XCTAssertEqual(lead(timer: 1122, music: true, order: .agentsFirst), .timer(remaining: "18:42"))
        XCTAssertEqual(lead(music: true, order: .agentsFirst), .music)
    }

    func testNothingLive() {
        XCTAssertEqual(lead(order: .musicFirst), PillLead.none)
        XCTAssertEqual(lead(sessions: [session("i", .idle)], timer: 0, order: .agentsFirst), PillLead.none,
                       "an idle session and an ended timer are not live")
    }
}
