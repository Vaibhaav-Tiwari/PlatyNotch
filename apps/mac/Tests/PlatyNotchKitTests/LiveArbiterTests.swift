import Foundation
import PlatyNotchKit   // not @testable: the UI uses these types through their public API
import XCTest

final class LiveArbiterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func act(_ id: String, _ priority: Int, expires: Date? = nil, widget: String = "w") -> LiveActivity {
        LiveActivity(id: id, widgetID: widget, priority: priority, glyph: .symbol("circle"), expiresAt: expires)
    }

    func testHighestPriorityWins() {
        let pick = LiveArbiter.pick([act("music", LivePriority.musicPlaying), act("focus", LivePriority.focusSession),
                                     act("timer", LivePriority.timerRunning)], now: now)
        XCTAssertEqual(pick.primary?.id, "focus")
    }

    func testSecondBecomesBubble() {
        let pick = LiveArbiter.pick([act("music", LivePriority.musicPlaying), act("focus", LivePriority.focusSession)],
                                    now: now)
        XCTAssertEqual(pick.primary?.id, "focus")
        XCTAssertEqual(pick.bubble?.id, "music")
        XCTAssertNil(LiveArbiter.pick([act("music", LivePriority.musicPlaying)], now: now).bubble)
        let none = LiveArbiter.pick([], now: now)
        XCTAssertNil(none.primary)
        XCTAssertNil(none.bubble)
    }

    func testExpiredDropped() {
        let pick = LiveArbiter.pick([act("old", 90, expires: now), act("soon", 90, expires: now.addingTimeInterval(1)),
                                     act("music", LivePriority.musicPlaying)], now: now)
        XCTAssertEqual(pick.primary?.id, "soon")   // expiresAt == now counts as expired
        XCTAssertEqual(pick.bubble?.id, "music")
    }

    func testTieKeepsInputOrder() {
        let pick = LiveArbiter.pick([act("a", 50), act("b", 50), act("c", 50)], now: now)
        XCTAssertEqual(pick.primary?.id, "a")
        XCTAssertEqual(pick.bubble?.id, "b")
        let reversed = LiveArbiter.pick([act("c", 50), act("b", 50), act("a", 50)], now: now)
        XCTAssertEqual(reversed.primary?.id, "c")
    }

    /// C9: ambient activities show only when nothing else is live.
    func testAmbientNeverBubblesNextToLive() {
        let shelf = act("shelf", LivePriority.shelfItems)
        let music = act("music", LivePriority.musicPlaying)
        XCTAssertNil(LiveArbiter.pick([music, shelf], now: now).bubble)
        let alone = LiveArbiter.pick([shelf, act("weather", LivePriority.ambient)], now: now)
        XCTAssertEqual(alone.primary?.id, "shelf")
        XCTAssertEqual(alone.bubble?.id, "weather")
    }

    /// C9: Minimal mode's "live" counts only activities above ambient priority.
    func testHasLiveIgnoresAmbientAndExpired() {
        XCTAssertFalse(LiveArbiter.hasLive([], now: now))
        XCTAssertFalse(LiveArbiter.hasLive([act("shelf", LivePriority.shelfItems)], now: now))
        XCTAssertFalse(LiveArbiter.hasLive([act("t", LivePriority.timerFinished, expires: now)], now: now))
        XCTAssertTrue(LiveArbiter.hasLive([act("music", LivePriority.musicPlaying)], now: now))
        XCTAssertTrue(LiveArbiter.hasLive([act("battery", LivePriority.batteryLow)], now: now))
    }

    func testPriorityTable() {
        // Plan table plus C7 (keep-awake, meeting within 10 min).
        let order = [LivePriority.approval, LivePriority.alarmRinging, LivePriority.timerFinished,
                     LivePriority.agentBlocked, LivePriority.meetingSoon, LivePriority.focusSession,
                     LivePriority.timerRunning, LivePriority.stopwatch, LivePriority.musicPlaying,
                     LivePriority.agentActive, LivePriority.download, LivePriority.keepAwake,
                     LivePriority.batteryLow, LivePriority.shelfItems]
        XCTAssertEqual(order, [100, 95, 90, 80, 75, 60, 55, 50, 40, 30, 25, 22, 20, 10])
        XCTAssertEqual(LivePriority.meetingSoonWindow, 10 * 60)
    }

    func testAgentsLiveEmitsBlockedOverActive() {
        func s(_ st: SessionState) -> Session {
            Session(key: UUID().uuidString, agent: "claude-code", agentName: "Claude Code", sessionID: "1", state: st,
                    startedAt: now, updatedAt: now)
        }
        XCTAssertTrue(AgentsLive.activities(sessions: [s(.idle), s(.exited)]).isEmpty)
        XCTAssertEqual(AgentsLive.activities(sessions: [s(.active)]).map(\.priority), [LivePriority.agentActive])
        let both = AgentsLive.activities(sessions: [s(.active), s(.blocked)])
        XCTAssertEqual(both.map(\.priority), [LivePriority.agentBlocked])
        XCTAssertEqual(both.first?.widgetID, AgentsLive.widgetID)
        XCTAssertEqual(both.first?.glyph, .agentDots([.active, .blocked]))
    }

    /// The pill's live ear leaves agents to the agent-dots ear.
    func testEarPickSkipsAgents() {
        let agents = act("agents", LivePriority.agentBlocked, widget: AgentsLive.widgetID)
        let music = act("music", LivePriority.musicPlaying)
        XCTAssertEqual(LiveArbiter.pick([agents, music], now: now).primary?.id, "agents")
        let ear = LiveArbiter.pickForEar([agents, music], now: now)
        XCTAssertEqual(ear.primary?.id, "music")
        XCTAssertNil(ear.bubble)
    }

    func testPanelHasLiveCountsSessionsAndActivities() {
        let idle = Session(key: "k", agent: "a", agentName: "A", sessionID: "1", state: .idle, startedAt: now, updatedAt: now)
        XCTAssertFalse(PanelMode.hasLive(sessions: [idle], activities: [act("shelf", LivePriority.shelfItems)], now: now))
        XCTAssertTrue(PanelMode.hasLive(sessions: [idle], activities: [act("music", LivePriority.musicPlaying)], now: now))
        var active = idle
        active.state = .active
        XCTAssertTrue(PanelMode.hasLive(sessions: [active], activities: [], now: now))
    }
}
