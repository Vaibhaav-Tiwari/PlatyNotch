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

    // Review I1: the lead never hides an urgent live activity.
    private func activity(_ id: String, _ widget: String, _ priority: Int, countdownTo: Date? = nil) -> LiveActivity {
        LiveActivity(id: id, widgetID: widget, priority: priority, glyph: .symbol("bell"), countdownTo: countdownTo)
    }

    func testUrgentActivitiesKeepThePill() {
        let urgent: [LiveActivity] = [
            activity("time:alarm", "time", LivePriority.alarmRinging),
            activity("time:done", "time", LivePriority.timerFinished),
            activity("meeting:next", "meeting", LivePriority.meetingSoon, countdownTo: now.addingTimeInterval(4 * 60)),
            activity("system:battery-low", "system", LivePriority.batteryLow),
            activity("mirror:on", "mirror", LivePriority.panelActivity),
        ]
        for a in urgent {
            XCTAssertTrue(PillLeads.isUrgent(a, now: now), a.id)
            for order in [PillOrder.musicFirst, .agentsFirst] {
                XCTAssertEqual(PillLeads.lead(approvals: 0, sessions: [session("n", .waitingInput)], log: AgentFinishLog(),
                                              timerRemaining: 600, musicPlaying: true, order: order, now: now,
                                              activities: [a]), PillLead.none, "\(a.id) takes the pill as before")
            }
        }
    }

    func testCalmActivitiesLetTheLeadDraw() {
        let calm: [LiveActivity] = [
            activity("meeting:next", "meeting", LivePriority.meetingSoon, countdownTo: now.addingTimeInterval(8 * 60)),
            activity("time:timer:1", "time", LivePriority.timerRunning),
            activity("music:playing", "music", LivePriority.musicPlaying),
            activity("system:charging", "system", LivePriority.batteryCharging),
        ]
        for a in calm { XCTAssertFalse(PillLeads.isUrgent(a, now: now), a.id) }
        XCTAssertEqual(PillLeads.lead(approvals: 0, sessions: [], log: AgentFinishLog(), timerRemaining: nil,
                                      musicPlaying: true, order: .musicFirst, now: now, activities: calm), .music)
    }
}
