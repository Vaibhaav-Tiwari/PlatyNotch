import Foundation
import PlatyNotchKit
import XCTest

final class PriorityModelTests: DefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func act(_ id: String, _ priority: Int, widget: String? = nil, expires: Date? = nil,
                     countdown: Date? = nil, started: Date? = nil, title: String? = nil) -> LiveActivity {
        LiveActivity(id: id, widgetID: widget ?? id, priority: priority, glyph: .symbol("circle"),
                     expiresAt: expires, countdownTo: countdown, title: title, startedAt: started)
    }

    private func session(_ key: String, _ state: SessionState, agent: String = "claude-code",
                         project: String? = "proj", started: TimeInterval = 0) -> Session {
        Session(key: key, agent: agent, agentName: "Claude Code", sessionID: key, project: project, state: state,
                startedAt: now.addingTimeInterval(started), updatedAt: now)
    }

    private func finishLog(_ key: String, at: Date) -> AgentFinishLog {
        var log = AgentFinishLog()
        log.record(SessionChanges(finished: [key], enteredNeedsYou: [], allFinished: true), now: at)
        return log
    }

    func testSpecOrder() {
        let soon = now.addingTimeInterval(60)
        let later = now.addingTimeInterval(8 * 60)
        let items: [LiveActivity] = [
            act("music", LivePriority.musicPlaying),
            act("ring", LivePriority.alarmRinging),
            act("download", LivePriority.download),
            act("keepAwake", LivePriority.keepAwake),
            act("timer", LivePriority.timerRunning),
            act("meetSoon", LivePriority.meetingSoon, countdown: later),
            act("meetNow", LivePriority.meetingSoon, countdown: soon),
            act("plugin.agents", LivePriority.agentBlocked),
        ]
        let agents = AgentsLive(rank: .agentsWorking, title: "Claude Code · proj", subtitle: nil, startedAt: now,
                                needsYou: 0, working: 1, total: 1)
        let ranked = PriorityModel.rank(items.shuffled(), agents: agents, now: now)
        XCTAssertEqual(ranked.map(\.rank), [.ringing, .meetingImminent, .agentNeedsYou, .timerRunning, .meetingSoon,
                                            .fileAction, .agentsWorking, .music, .minor])
        XCTAssertEqual(ranked.map(\.id), ["ring", "meetNow", "plugin.agents", "timer", "meetSoon", "download",
                                          "agents", "music", "keepAwake"])
        let finished = AgentsLive(rank: .agentFinished, title: "t", subtitle: nil, startedAt: now,
                                  needsYou: 0, working: 0, total: 1)
        let withFinish = PriorityModel.rank([act("timer", LivePriority.timerRunning), act("ring", 95)],
                                            agents: finished, now: now)
        XCTAssertEqual(withFinish.map(\.rank), [.ringing, .agentFinished, .timerRunning])
        XCTAssertEqual(LiveRank.ringing.rawValue, 2)
        XCTAssertEqual(LiveRank.music.rawValue, 10)
    }

    func testMeetingSplitsAtTwoMinutes() {
        let imminent = act("m", LivePriority.meetingSoon, countdown: now.addingTimeInterval(119))
        let soon = act("m", LivePriority.meetingSoon, countdown: now.addingTimeInterval(181))
        XCTAssertEqual(LiveRank(activity: imminent, now: now), .meetingImminent)
        XCTAssertEqual(LiveRank(activity: soon, now: now), .meetingSoon)
        XCTAssertEqual(LiveRank(activity: act("m", LivePriority.meetingSoon), now: now), .meetingSoon)
        XCTAssertEqual(LiveRank.meetingImminent.notificationKind, .meetingStarting)
        XCTAssertEqual(LiveRank.meetingSoon.notificationKind, .meetingStarting)
        XCTAssertEqual(LiveRank.ringing.notificationKind, .ringing)
        XCTAssertEqual(LiveRank.agentNeedsYou.notificationKind, .agentNeedsYou)
        XCTAssertEqual(LiveRank.agentFinished.notificationKind, .agentFinished)
        XCTAssertEqual(LiveRank.music.notificationKind, .other)
    }

    func testTiesGoToEarlierStart() {
        let a = act("a", LivePriority.timerRunning, started: now.addingTimeInterval(-10))
        let b = act("b", LivePriority.focusSession, started: now.addingTimeInterval(-60))
        XCTAssertEqual(PriorityModel.rank([a, b], agents: nil, now: now).map(\.id), ["b", "a"])
        // Without start dates the input order holds.
        let c = act("c", LivePriority.timerRunning)
        let d = act("d", LivePriority.focusSession)
        XCTAssertEqual(PriorityModel.rank([c, d], agents: nil, now: now).map(\.id), ["c", "d"])
        XCTAssertEqual(PriorityModel.rank([d, c], agents: nil, now: now).map(\.id), ["d", "c"])
    }

    func testExpiredDropped() {
        let ranked = PriorityModel.rank([act("old", 40, expires: now), act("new", 40, expires: now.addingTimeInterval(1))],
                                        agents: nil, now: now)
        XCTAssertEqual(ranked.map(\.id), ["new"])
    }

    func testTitleFallsBack() {
        let titled = act("a", 40, widget: "music", title: "Song")
        let labelled = LiveActivity(id: "b", widgetID: "w", priority: 40, glyph: .musicBars,
                                    accessibilityLabel: "Music playing")
        let bare = act("c", 40, widget: "time")
        XCTAssertEqual(PriorityModel.rank([titled, labelled, bare], agents: nil, now: now).map(\.title),
                       ["Song", "Music playing", "time"])
    }

    func testPluginPriorityIsClamped() {
        XCTAssertEqual(LiveRank(activity: act("p", 1000), now: now), .ringing)
        XCTAssertEqual(LiveRank(activity: act("p", -5), now: now), .ambient)
        XCTAssertEqual(LiveRank(activity: act("p", LivePriority.approval), now: now), .ringing)
    }

    func testAgentsRanks() {
        let empty = AgentFinishLog()
        XCTAssertEqual(AgentsLive.make(sessions: [session("a", .waitingInput)], log: empty, now: now)?.rank, .agentNeedsYou)
        XCTAssertEqual(AgentsLive.make(sessions: [session("a", .blocked)], log: empty, now: now)?.rank, .agentNeedsYou)
        XCTAssertEqual(AgentsLive.make(sessions: [session("a", .active)], log: empty, now: now)?.rank, .agentsWorking)
        XCTAssertNil(AgentsLive.make(sessions: [session("a", .idle)], log: empty, now: now))
        let five = finishLog("a", at: now.addingTimeInterval(-300))
        XCTAssertEqual(AgentsLive.make(sessions: [session("a", .idle)], log: five, now: now)?.rank, .agentFinished)
        let eleven = finishLog("a", at: now.addingTimeInterval(-660))
        XCTAssertNil(AgentsLive.make(sessions: [session("a", .idle)], log: eleven, now: now))

        let mixed = [session("w1", .active, project: "late", started: -10), session("n", .idle),
                     session("w2", .active, project: "early", started: -100), session("x", .exited)]
        let live = AgentsLive.make(sessions: mixed, log: empty, now: now)
        XCTAssertEqual(live?.title, "Claude Code · early")
        XCTAssertEqual(live?.working, 2)
        XCTAssertEqual(live?.needsYou, 0)
        XCTAssertEqual(live?.total, 3)
    }

    func testFailureMeansNeedsYou() {
        var log = AgentFinishLog()
        log.noteFailure(sessionKey: "a", at: now)
        let idle = [session("a", .idle)]
        XCTAssertEqual(AgentAttention.of(idle[0], log: log, now: now), .errored)
        XCTAssertEqual(AgentsLive.make(sessions: idle, log: log, now: now)?.rank, .agentNeedsYou)
        XCTAssertEqual(AgentsLive.make(sessions: idle, log: log, now: now.addingTimeInterval(599))?.rank, .agentNeedsYou)
        XCTAssertNil(AgentsLive.make(sessions: idle, log: log, now: now.addingTimeInterval(601)))
        log.clearFailure(sessionKey: "a")
        XCTAssertNil(AgentsLive.make(sessions: idle, log: log, now: now))
        XCTAssertFalse(log.failed("a", now: now))
    }

    func testWindowsExpireAcrossSleep() {
        let t = now
        var log = finishLog("a", at: t)
        log.noteFailure(sessionKey: "b", at: t)
        let later = t.addingTimeInterval(7200)
        XCTAssertNil(log.lastFinish(now: later))
        XCTAssertFalse(log.failed("b", now: later))
        XCTAssertFalse(log.finished("a", now: later))
        XCTAssertNil(AgentsLive.make(sessions: [session("a", .idle), session("b", .idle)], log: log, now: later))
        // A clock set back before the finish never shows a negative age.
        XCTAssertNil(log.lastFinish(now: t.addingTimeInterval(-30)))
        XCTAssertEqual(log.lastFinish(now: t.addingTimeInterval(30)), t)
    }

    func testExistingConstantsKeepTheirBands() {
        func rank(_ p: Int) -> LiveRank { LiveRank(activity: act("x", p), now: now) }
        XCTAssertEqual(rank(LivePriority.download), .fileAction)
        XCTAssertEqual(rank(LivePriority.fileAction), .fileAction)
        XCTAssertEqual(rank(LivePriority.keepAwake), .minor)
        XCTAssertEqual(rank(LivePriority.batteryLow), .minor)
        XCTAssertEqual(rank(LivePriority.panelActivity), .minor)
        XCTAssertEqual(rank(LivePriority.shelfItems), .ambient)
        XCTAssertEqual(rank(LivePriority.batteryCharging), .ambient)
        XCTAssertEqual(rank(LivePriority.musicPlaying), .music)
        XCTAssertEqual(rank(LivePriority.agentActive), .agentsWorking)
        XCTAssertEqual(rank(LivePriority.stopwatch), .timerRunning)
        XCTAssertEqual(rank(LivePriority.timerRunning), .timerRunning)
        XCTAssertEqual(rank(LivePriority.focusSession), .timerRunning)
        XCTAssertEqual(rank(LivePriority.agentBlocked), .agentNeedsYou)
        XCTAssertEqual(rank(LivePriority.timerFinished), .ringing)
        XCTAssertEqual(rank(LivePriority.alarmRinging), .ringing)
    }

    func testRowActions() {
        XCTAssertEqual(AgentRowAction(.needsYou), .answer)
        XCTAssertEqual(AgentRowAction(.errored), .answer)
        XCTAssertEqual(AgentRowAction(.working), .openTerminal)
        XCTAssertEqual(AgentRowAction(.finished), .openTerminal)
        XCTAssertEqual(AgentRowAction(.idle), .openTerminal)
        XCTAssertEqual(AgentRowAction(.exited), .openTerminal)
        XCTAssertEqual(AgentRowAction.answer.title, "Answer")
        XCTAssertEqual(AgentRowAction.openTerminal.title, "Open terminal")
    }

    func testAttentionFromState() {
        XCTAssertEqual(AgentAttention(state: .blocked), .needsYou)
        XCTAssertEqual(AgentAttention(state: .waitingInput), .needsYou)
        XCTAssertEqual(AgentAttention(state: .active), .working)
        XCTAssertEqual(AgentAttention(state: .idle), .idle)
        XCTAssertEqual(AgentAttention(state: .exited), .exited)
        XCTAssertLessThan(AgentAttention.needsYou, AgentAttention.errored)
        XCTAssertLessThan(AgentAttention.working, AgentAttention.finished)
        XCTAssertEqual(AgentAttention.errored.tone, .error)
        XCTAssertEqual(AgentAttention.finished.tone, .done)
        let log = finishLog("a", at: now.addingTimeInterval(-60))
        XCTAssertEqual(AgentAttention.of(session("a", .idle), log: log, now: now), .finished)
        XCTAssertEqual(AgentAttention.of(session("a", .active), log: log, now: now), .working)
    }
}
