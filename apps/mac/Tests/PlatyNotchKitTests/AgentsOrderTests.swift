import Foundation
import XCTest
@testable import PlatyNotchKit

/// Task 16: the Agents list order, its status lines and when the Agents destination shows.
final class AgentsOrderTests: DefaultsTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ key: String, _ state: SessionState, started: TimeInterval = 0, updated: TimeInterval = 0,
                         title: String? = nil, tool: String? = nil, message: String? = nil) -> Session {
        Session(key: key, agent: "claude-code", agentName: "Claude Code", sessionID: key, project: key, state: state,
                title: title, tool: tool, message: message,
                startedAt: t0.addingTimeInterval(started), updatedAt: t0.addingTimeInterval(updated))
    }

    private func finishLog(_ keys: [String], at: Date) -> AgentFinishLog {
        var log = AgentFinishLog()
        log.record(SessionChanges(finished: keys, enteredNeedsYou: [], allFinished: false), now: at)
        return log
    }

    func testAttentionOrder() {
        let now = t0.addingTimeInterval(120)
        var log = finishLog(["done"], at: t0.addingTimeInterval(60))
        log.noteFailure(sessionKey: "err", at: t0.addingTimeInterval(30))
        let sessions = [
            session("idle", .idle, updated: 100),
            session("done", .idle, updated: 60),
            session("work-old", .active, updated: 10),
            session("err", .idle, updated: 30),
            session("ask", .waitingInput, updated: 5),
            session("work-new", .active, updated: 90),
            session("gone", .exited, updated: 110),
        ]
        let order = AgentsOrder.sorted(sessions, log: log, now: now).map(\.key)
        XCTAssertEqual(order, ["ask", "err", "work-new", "work-old", "done", "idle", "gone"])
    }

    /// Review focus: 12 sessions over four agents, one needing input → that row first.
    func testTwelveSessionsNeedsYouFirst() {
        let agents = ["claude-code", "codex", "gemini", "cursor"]
        var sessions: [Session] = []
        for i in 0..<12 {
            var s = session("s\(i)", .active, updated: TimeInterval(i * 10))
            s.agent = agents[i % 4]
            sessions.append(s)
        }
        sessions[3].state = .waitingInput
        sessions[3].updatedAt = t0   // the oldest update: still first
        let order = AgentsOrder.sorted(sessions, log: AgentFinishLog(), now: t0.addingTimeInterval(200))
        XCTAssertEqual(order.first?.key, "s3")
        XCTAssertEqual(order.count, 12)
        XCTAssertEqual(order[1].key, "s11", "then the newest working session")
    }

    func testStatusLines() {
        let now = t0.addingTimeInterval(4 * 60 + 30)
        func line(_ s: Session, _ a: AgentAttention) -> String { SessionStatusLine.text(s, attention: a, now: now) }
        XCTAssertEqual(line(session("a", .blocked), .needsYou), "Waiting for approval")
        XCTAssertEqual(line(session("a", .waitingInput), .needsYou), "Needs your input")
        XCTAssertEqual(line(session("a", .idle), .errored), "Stopped with an error")
        XCTAssertEqual(line(session("a", .active, title: "Running tests", tool: "Bash"), .working), "Running tests · 4 m")
        XCTAssertEqual(line(session("a", .active, tool: "Bash"), .working), "Bash · 4 m")
        XCTAssertEqual(line(session("a", .active), .working), "Working · 4 m")
        XCTAssertEqual(line(session("a", .idle, updated: 60), .finished), "Finished · 3 m ago")
        XCTAssertEqual(line(session("a", .idle), .idle), "Idle")
        XCTAssertEqual(line(session("a", .exited), .exited), "Ended")
        // A clock that went backwards never shows a negative time.
        XCTAssertEqual(line(session("a", .active, started: 600), .working), "Working · just now")
    }

    /// Under a minute reads "just now", never "0 m".
    func testUnderAMinuteSaysJustNow() {
        let now = Date(timeIntervalSince1970: 10_000)
        let t = now.addingTimeInterval(-45)
        let working = Session(key: "a", agent: "codex", agentName: "Codex", sessionID: "a", state: .active,
                              title: "Running tests", startedAt: t, updatedAt: t)
        XCTAssertEqual(SessionStatusLine.text(working, attention: .working, now: now), "Running tests · just now")
        let done = Session(key: "b", agent: "codex", agentName: "Codex", sessionID: "b", state: .idle,
                           startedAt: t, updatedAt: t)
        XCTAssertEqual(SessionStatusLine.text(done, attention: .finished, now: now), "Finished · just now")
        XCTAssertEqual(SessionStatusLine.text(done, attention: .finished, now: now.addingTimeInterval(60)),
                       "Finished · 1 m ago")
    }

    func testLastActionHidesNothing() {
        XCTAssertEqual(SessionStatusLine.lastAction(session("a", .active, tool: "Bash", message: "rm\u{200B} -rf\nx")),
                       "rm⟨U+200B⟩ -rf⟨U+000A⟩x")
        XCTAssertEqual(SessionStatusLine.lastAction(session("a", .active, tool: "Bash")), "Bash")
        XCTAssertNil(SessionStatusLine.lastAction(session("a", .active)))
    }

    func testVisibilityFirstConnectNotifiesOnce() {
        var v = AgentsVisibility()
        XCTAssertFalse(v.isVisible)
        XCTAssertFalse(v.noteSessions(count: 0))
        XCTAssertFalse(v.isVisible)
        XCTAssertTrue(v.noteSessions(count: 2))
        XCTAssertTrue(v.isVisible)
        XCTAssertFalse(v.noteSessions(count: 3))
        XCTAssertFalse(v.noteSessions(count: 0))
        XCTAssertTrue(v.isVisible, "stays once an agent has connected")
        v.save(to: defaults())
        var loaded = AgentsVisibility.load(from: defaults())
        XCTAssertEqual(loaded, v)
        XCTAssertFalse(loaded.noteSessions(count: 1), "never notifies again after a relaunch")
    }

    func testForcedOn() {
        let v = AgentsVisibility(forcedOn: true)
        XCTAssertTrue(v.isVisible)
        v.save(to: defaults())
        XCTAssertTrue(AgentsVisibility.load(from: defaults()).forcedOn)
        defaults().set(Data("junk".utf8), forKey: AgentsVisibility.key)
        XCTAssertEqual(AgentsVisibility.load(from: defaults()), AgentsVisibility())
    }

    func testDestinationsFollowVisibility() {
        XCTAssertEqual(PanelDestination.shown(agentsVisible: false), [.home])
        XCTAssertEqual(PanelDestination.shown(agentsVisible: true), [.home, .agents])
    }

    /// Fix round 1, M4: "Finished · n m ago" counts from the logged finish when known.
    func testFinishedCountsFromTheLoggedFinish() {
        let log = finishLog(["a"], at: t0.addingTimeInterval(60))
        let now = t0.addingTimeInterval(6 * 60)
        XCTAssertEqual(log.finishedAt("a", now: now), t0.addingTimeInterval(60))
        XCTAssertNil(log.finishedAt("b", now: now))
        XCTAssertNil(log.finishedAt("a", now: t0.addingTimeInterval(60 + 600)), "outside the window")
        let s = session("a", .idle, updated: 300)   // a later update (e.g. a title change)
        XCTAssertEqual(SessionStatusLine.text(s, attention: .finished, now: now, finishedAt: log.finishedAt("a", now: now)),
                       "Finished · 5 m ago")
        XCTAssertEqual(SessionStatusLine.text(s, attention: .finished, now: now), "Finished · 1 m ago")
    }

    /// The dense row's " · status · age" (Quiet Notch wireframe C): lower-case status, a short age.
    func testCompactStatusLine() {
        let now = t0.addingTimeInterval(12 * 60 + 5)
        func line(_ s: Session, _ a: AgentAttention, finishedAt: Date? = nil) -> String {
            SessionStatusLine.compact(s, attention: a, now: now, finishedAt: finishedAt)
        }
        XCTAssertEqual(line(session("a", .active, title: "Running tests"), .working), "running tests · 12 m")
        XCTAssertEqual(line(session("a", .active, tool: "AskUserQuestion"), .working), "AskUserQuestion · 12 m",
                       "a capitalised word is kept as it is")
        XCTAssertEqual(line(session("a", .active), .working), "working · 12 m")
        XCTAssertEqual(line(session("a", .waitingInput, updated: 9 * 60), .needsYou), "waiting for you · 3 m")
        XCTAssertEqual(line(session("a", .blocked, updated: 12 * 60), .needsYou), "waiting for approval · just now")
        XCTAssertEqual(line(session("a", .idle), .finished, finishedAt: now.addingTimeInterval(-3_700)), "finished · 1 h")
        XCTAssertEqual(line(session("a", .idle, updated: 60), .errored), "stopped with an error · 11 m")
        XCTAssertEqual(line(session("a", .idle, updated: -2 * 86_400), .idle), "idle · 2 d")
        XCTAssertEqual(line(session("a", .exited), .exited), "ended")
        XCTAssertEqual(line(session("a", .active, started: 13 * 60), .working), "working · just now",
                       "a clock that went backwards shows just now")
    }
}
