import Foundation
import XCTest
@testable import PlatyNotchKit

final class PanelFormatTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ key: String, _ state: SessionState, updated: TimeInterval = 0) -> Session {
        Session(key: key, agent: "claude-code", agentName: "Claude Code", sessionID: key, state: state,
                startedAt: now, updatedAt: now.addingTimeInterval(updated))
    }

    private func approval(_ id: String, created: TimeInterval, expires: TimeInterval = 100,
                          summary: String = "ls") -> Approval {
        Approval(id: id, sessionKey: "s", agent: "claude-code", agentName: "Claude Code", tool: "Bash",
                 summary: summary, createdAt: now.addingTimeInterval(created),
                 expiresAt: now.addingTimeInterval(expires))
    }

    // MARK: Relative age

    func testRelativeAge() {
        XCTAssertEqual(PanelFormat.relativeAge(from: now, now: now), "now")
        XCTAssertEqual(PanelFormat.relativeAge(from: now.addingTimeInterval(-59), now: now), "now")
        XCTAssertEqual(PanelFormat.relativeAge(from: now.addingTimeInterval(-60), now: now), "1m")
        XCTAssertEqual(PanelFormat.relativeAge(from: now.addingTimeInterval(-3 * 60 - 20), now: now), "3m")
        XCTAssertEqual(PanelFormat.relativeAge(from: now.addingTimeInterval(-2 * 3600 - 59 * 60), now: now), "2h")
        XCTAssertEqual(PanelFormat.relativeAge(from: now.addingTimeInterval(-3 * 86400), now: now), "3d")
        // Clock skew: a date slightly in the future is still "now".
        XCTAssertEqual(PanelFormat.relativeAge(from: now.addingTimeInterval(30), now: now), "now")
    }

    // MARK: Reset countdown

    func testResetCountdown() {
        XCTAssertNil(PanelFormat.resetCountdown(resetsAt: nil, now: now))
        XCTAssertEqual(PanelFormat.resetCountdown(resetsAt: now.addingTimeInterval(-5), now: now), "resetting")
        XCTAssertEqual(PanelFormat.resetCountdown(resetsAt: now, now: now), "resetting")
        XCTAssertEqual(PanelFormat.resetCountdown(resetsAt: now.addingTimeInterval(30), now: now), "resets in <1m")
        XCTAssertEqual(PanelFormat.resetCountdown(resetsAt: now.addingTimeInterval(14 * 60 + 10), now: now),
                       "resets in 14m")
        XCTAssertEqual(PanelFormat.resetCountdown(resetsAt: now.addingTimeInterval(2 * 3600 + 5 * 60), now: now),
                       "resets in 2h 05m")
        XCTAssertEqual(PanelFormat.resetCountdown(resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600 + 59),
                                                  now: now), "resets in 3d 4h")
    }

    func testUsageFraction() {
        XCTAssertEqual(PanelFormat.usageFraction(42), 0.42, accuracy: 1e-9)
        XCTAssertEqual(PanelFormat.usageFraction(-3), 0)
        XCTAssertEqual(PanelFormat.usageFraction(140), 1)
        XCTAssertEqual(PanelFormat.usageFraction(.nan), 0)
        XCTAssertEqual(PanelFormat.usagePercent(41.6), "42%")
        XCTAssertEqual(PanelFormat.usagePercent(140), "100%")
    }

    func testUsageLevel() {
        XCTAssertEqual(UsageLevel(usedPercent: 0), .normal)
        XCTAssertEqual(UsageLevel(usedPercent: 69.9), .normal)
        XCTAssertEqual(UsageLevel(usedPercent: 70), .high)
        XCTAssertEqual(UsageLevel(usedPercent: 89.9), .high)
        XCTAssertEqual(UsageLevel(usedPercent: 90), .critical)
        XCTAssertEqual(UsageLevel(usedPercent: 250), .critical)
    }

    // MARK: State colors

    func testStateColorMapping() {
        XCTAssertEqual(AgentTone(.active), .active)
        XCTAssertEqual(AgentTone(.blocked), .attention)
        XCTAssertEqual(AgentTone(.waitingInput), .attention)
        XCTAssertEqual(AgentTone(.idle), .idle)
        XCTAssertEqual(AgentTone(.exited), .off)
        let all: [SessionState] = [.active, .idle, .waitingInput, .blocked, .exited]
        XCTAssertEqual(Set(all.map(AgentTone.init)).count, 4)
        XCTAssertTrue(AgentTone.active.pulses)
        XCTAssertFalse(AgentTone.attention.pulses)
    }

    func testStateLabels() {
        XCTAssertEqual(PanelFormat.stateLabel(.waitingInput), "Waiting")
        XCTAssertEqual(PanelFormat.stateLabel(.blocked), "Needs approval")
        XCTAssertEqual(PanelFormat.stateLabel(.active), "Working")
        XCTAssertEqual(PanelFormat.stateLabel(.idle), "Idle")
        XCTAssertEqual(PanelFormat.stateLabel(.exited), "Exited")
    }

    // MARK: Pill dots

    func testPillDotsAttentionFirstThenOverflow() {
        let sessions = [
            session("a", .active, updated: 5), session("b", .idle, updated: 4), session("c", .blocked, updated: 3),
            session("d", .exited, updated: 2), session("e", .waitingInput, updated: 1), session("f", .active, updated: 0),
        ]
        let dots = PillDots(sessions: sessions)
        XCTAssertEqual(dots.dots.map(\.key), ["c", "e", "a"])
        XCTAssertEqual(dots.dots.map(\.tone), [.attention, .attention, .active])
        XCTAssertEqual(dots.overflow, 2)   // b, f; exited sessions are not counted
    }

    func testPillDotsFewSessions() {
        let dots = PillDots(sessions: [session("a", .idle)])
        XCTAssertEqual(dots.dots.map(\.key), ["a"])
        XCTAssertEqual(dots.overflow, 0)
        XCTAssertTrue(PillDots(sessions: []).dots.isEmpty)
    }

    // MARK: Approvals

    func testApprovalOrderingOldestFirst() {
        let a = approval("a", created: 10)
        let b = approval("b", created: 0)
        let c = approval("c", created: 10)
        XCTAssertEqual(ApprovalFormat.ordered([c, a, b]).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(ApprovalFormat.ordered([]).map(\.id), [])
    }

    @MainActor func testStoreUsesSameOrdering() throws {
        let store = AppStore()
        for a in [approval("z", created: 5), approval("y", created: 1), approval("x", created: 5)] {
            store.apply(try Envelope.make(.approvalAdded, a))
        }
        XCTAssertEqual(store.approvals.map(\.id), ["y", "x", "z"])
    }

    func testSummaryLineClamp() {
        XCTAssertEqual(ApprovalFormat.visibleLines(for: "ls"), 1)
        XCTAssertEqual(ApprovalFormat.visibleLines(for: ""), 1)
        XCTAssertEqual(ApprovalFormat.visibleLines(for: "a\nb\nc"), 3)
        XCTAssertEqual(ApprovalFormat.visibleLines(for: "a\r\nb"), 2)
        let long = (1...40).map(String.init).joined(separator: "\n")
        XCTAssertEqual(ApprovalFormat.visibleLines(for: long), ApprovalFormat.maxSummaryLines)
        XCTAssertEqual(ApprovalFormat.maxSummaryLines, 12)
        XCTAssertTrue(ApprovalFormat.needsScroll(long))
        XCTAssertFalse(ApprovalFormat.needsScroll("a\nb"))
    }

    func testExpiryCountdown() {
        let a = approval("a", created: 0, expires: 100)
        XCTAssertEqual(ApprovalFormat.countdown(to: a.expiresAt, now: now), "1:40")
        XCTAssertEqual(ApprovalFormat.countdown(to: a.expiresAt, now: now.addingTimeInterval(99.2)), "0:01")
        XCTAssertNil(ApprovalFormat.countdown(to: a.expiresAt, now: now.addingTimeInterval(100)))
        XCTAssertEqual(ApprovalFormat.countdown(to: now.addingTimeInterval(3725), now: now), "1:02:05")
    }

    // MARK: Card status

    func testCardStatus() {
        let a = approval("a", created: 0, expires: 100)
        typealias S = ApprovalCardStatus
        XCTAssertEqual(S(approval: a, now: now, canAnswer: true, phase: nil), .ready(countdown: "1:40", error: nil))
        XCTAssertEqual(S(approval: a, now: now, canAnswer: false, phase: nil), .reconnecting(countdown: "1:40"))
        XCTAssertEqual(S(approval: a, now: now, canAnswer: true, phase: .sending(.allow)), .sending(.allow))
        XCTAssertEqual(S(approval: a, now: now, canAnswer: true, phase: .failed("boom")),
                       .ready(countdown: "1:40", error: "boom"))
        XCTAssertEqual(S(approval: a, now: now.addingTimeInterval(100), canAnswer: true, phase: nil), .expired)
        XCTAssertEqual(S(approval: a, now: now.addingTimeInterval(200), canAnswer: true, phase: .sending(.deny)),
                       .expired)
        XCTAssertTrue(S.ready(countdown: "1:00", error: "x").canAnswer)
        XCTAssertFalse(S.reconnecting(countdown: "1:00").canAnswer)
        XCTAssertFalse(S.sending(.allow).canAnswer)
        XCTAssertFalse(S.expired.canAnswer)
    }

    // MARK: Decisions

    func testDecisionsLifecycle() throws {
        var d = ApprovalDecisions()
        let a = approval("a", created: 0), b = approval("b", created: 1)
        XCTAssertEqual(d.begin(a, .allow, now: now, canAnswer: true), .send)
        XCTAssertEqual(d.begin(a, .deny, now: now, canAnswer: true), .ignored,
                       "a second answer while one is in flight is ignored")
        XCTAssertEqual(d.phase(for: "a"), .sending(.allow))
        d.fail(id: "a", message: "not connected")
        XCTAssertEqual(d.phase(for: "a"), .failed("not connected"))
        XCTAssertEqual(d.begin(a, .deny, now: now, canAnswer: true), .send, "after a failure the user can answer again")
        XCTAssertEqual(d.begin(b, .allow, now: now, canAnswer: true), .send)
        d.sync(pending: ["b", "c"], connected: true)
        XCTAssertNil(d.phase(for: "a"), "resolved approvals are forgotten")
        XCTAssertEqual(d.phase(for: "b"), .sending(.allow))
        d.sync(pending: ["b"], connected: false)
        XCTAssertNil(d.phase(for: "b"), "a lost connection clears in-flight answers; the next snapshot is the truth")
    }

    func testDecideWhileReconnectingIgnored() {
        var d = ApprovalDecisions()
        XCTAssertEqual(d.begin(approval("a", created: 0), .allow, now: now, canAnswer: false), .ignored)
        XCTAssertNil(d.phase(for: "a"))
    }

    func testDecideChecksExpiryAtDecideTime() {
        var d = ApprovalDecisions()
        let a = approval("a", created: 0, expires: 100)
        XCTAssertEqual(d.begin(a, .allow, now: now.addingTimeInterval(100), canAnswer: true), .expired)
        XCTAssertEqual(d.phase(for: "a"), .expired)
        XCTAssertEqual(ApprovalCardStatus(approval: a, now: now, canAnswer: true, phase: d.phase(for: "a")), .expired,
                       "shows Expired at once, before the next tick")
        XCTAssertEqual(d.begin(a, .allow, now: now, canAnswer: true), .ignored, "an expired approval stays unanswerable")
    }

    func testDecideEnvelope() throws {
        let env = try ApprovalFormat.decideEnvelope(id: "ap1", .deny)
        XCTAssertEqual(env.type, "approval.decide")
        XCTAssertNil(env.id)
        let body: ApprovalDecide = try env.decode()
        XCTAssertEqual(body, ApprovalDecide(id: "ap1", behavior: "deny", source: "notch"))
        XCTAssertEqual(try ApprovalFormat.decideEnvelope(id: "ap1", .allow).decode(ApprovalDecide.self).behavior,
                       "allow")
    }
}
