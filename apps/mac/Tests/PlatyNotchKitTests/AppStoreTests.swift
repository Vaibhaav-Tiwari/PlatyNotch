import XCTest
@testable import PlatyNotchKit

@MainActor
final class AppStoreTests: XCTestCase {
    private func session(_ key: String, _ state: SessionState = .active, at t: TimeInterval) -> Session {
        Session(key: key, agent: "claude", agentName: "Claude", sessionID: key, state: state,
                startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: t))
    }

    private func approval(_ id: String, at t: TimeInterval) -> Approval {
        Approval(id: id, sessionKey: "a", agent: "claude", agentName: "Claude", tool: "Bash",
                 summary: "ls", createdAt: Date(timeIntervalSince1970: t), expiresAt: Date(timeIntervalSince1970: t + 60))
    }

    func testSnapshotThenDeltas() throws {
        let store = AppStore()
        let snap = Snapshot(sessions: [session("a", at: 10), session("b", at: 20)],
                            memory: MemoryStatus(enabled: true), edition: "pro")
        store.apply(try .make(.snapshot, snap))
        XCTAssertEqual(store.sessions.map(\.key), ["b", "a"])
        XCTAssertEqual(store.edition, "pro")
        XCTAssertTrue(store.memory.enabled)

        store.apply(try .make(.sessionUpdated, session("a", .blocked, at: 30)))
        XCTAssertEqual(store.sessions.map(\.key), ["a", "b"])
        XCTAssertEqual(store.sessions.first?.state, .blocked)
        XCTAssertEqual(store.sessions.count, 2)

        store.apply(try .make(.sessionRemoved, SessionRemoved(key: "b")))
        XCTAssertEqual(store.sessions.map(\.key), ["a"])
    }

    func testApprovalResolvedRemoves() throws {
        let store = AppStore()
        store.apply(try .make(.approvalAdded, approval("2", at: 20)))
        store.apply(try .make(.approvalAdded, approval("1", at: 10)))
        XCTAssertEqual(store.approvals.map(\.id), ["1", "2"])
        store.apply(try .make(.approvalResolved, ApprovalResolved(id: "1", behavior: "allow")))
        XCTAssertEqual(store.approvals.map(\.id), ["2"])
    }

    func testDisconnectedMarksReconnecting() {
        let store = AppStore()
        XCTAssertEqual(store.connection, .connecting)
        store.apply(.connected)
        XCTAssertEqual(store.connection, .connected)
        store.apply(.disconnected)
        XCTAssertEqual(store.connection, .reconnecting)
        store.apply(.message(Envelope.make(.pong)))
        XCTAssertEqual(store.connection, .reconnecting)
    }

    func testNoticesKeepLast20AndBadInputIgnored() throws {
        let store = AppStore()
        for i in 0..<25 { store.apply(try .make(.notice, Notice(kind: "info", title: "n\(i)"))) }
        XCTAssertEqual(store.notices.count, 20)
        XCTAssertEqual(store.notices.first?.title, "n5")
        store.apply(Envelope(type: "something.new"))
        store.apply(Envelope(type: "session.updated", data: RawJSON(.string("garbage"))))
        store.apply(Envelope(type: "snapshot"))
        XCTAssertEqual(store.notices.count, 20)
    }

    func testNoticeSequenceCountsEveryNoticeEvenWhenTrimmed() throws {
        let store = AppStore()
        XCTAssertEqual(store.noticeSequence, 0)
        for _ in 0..<25 { store.apply(try .make(.notice, Notice(kind: "info", title: "same"))) }
        XCTAssertEqual(store.noticeSequence, 25)
        store.apply(Envelope(type: "notice", data: RawJSON(.string("garbage"))))
        XCTAssertEqual(store.noticeSequence, 25, "undecodable notices do not count")
    }

    func testUsageLoopsAndMemoryReplace() throws {
        let store = AppStore()
        store.apply(try .make(.memoryStatus, MemoryStatus(enabled: true, threads: 3)))
        XCTAssertEqual(store.memory.threads, 3)
        let loops: [Loop] = []
        store.apply(try .make(.loopsUpdated, loops))
        XCTAssertTrue(store.loops.isEmpty)
        store.apply(try .make(.usageUpdated, Usage()))
        XCTAssertNil(store.usage.claude)
    }

    func testTieOrderingIsDeterministic() throws {
        let store = AppStore()
        store.apply(try .make(.snapshot, Snapshot(
            sessions: [session("b", at: 5), session("a", at: 5), session("c", at: 9)],
            approvals: [approval("y", at: 1), approval("x", at: 1)])))
        XCTAssertEqual(store.sessions.map(\.key), ["c", "a", "b"])
        XCTAssertEqual(store.approvals.map(\.id), ["x", "y"])
        store.apply(try .make(.approvalAdded, approval("w", at: 1)))
        XCTAssertEqual(store.approvals.map(\.id), ["w", "x", "y"])
    }

    func testCanAnswerApprovalsOnlyWhenConnected() throws {
        let store = AppStore()
        XCTAssertFalse(store.canAnswerApprovals)
        store.apply(.connected)
        XCTAssertTrue(store.canAnswerApprovals)
        store.apply(try .make(.approvalAdded, approval("1", at: 1)))
        store.apply(.disconnected)
        XCTAssertFalse(store.canAnswerApprovals)
        XCTAssertEqual(store.approvals.count, 1)
    }
}
