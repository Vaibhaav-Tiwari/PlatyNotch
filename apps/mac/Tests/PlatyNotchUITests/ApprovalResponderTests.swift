import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class ApprovalResponderTests: XCTestCase {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var envs: [Envelope] = []
        func add(_ e: Envelope) { lock.withLock { envs.append(e) } }
        var all: [Envelope] { lock.withLock { envs } }
    }

    let approval = Approval(id: "ap1", sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                            tool: "Bash", summary: "rm -rf build", createdAt: Date(),
                            expiresAt: Date().addingTimeInterval(100))

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testDecideSendsOnceAndStaysSending() async throws {
        let sent = Sent()
        let r = ApprovalResponder { sent.add($0) }
        r.decide(approval, .allow, canAnswer: true)
        r.decide(approval, .deny, canAnswer: true)   // ignored while the first is in flight (e.g. another display)
        await waitUntil { sent.all.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(sent.all.count, 1)
        let body: ApprovalDecide = try sent.all[0].decode()
        XCTAssertEqual(body, ApprovalDecide(id: "ap1", behavior: "allow", source: "notch"))
        XCTAssertEqual(r.phase(for: "ap1"), .sending(.allow))
    }

    func testSendErrorReenablesWithMessage() async {
        let r = ApprovalResponder { _ in throw CoreClientError.notConnected }
        r.decide(approval, .deny, canAnswer: true)
        await waitUntil { r.phase(for: "ap1") != .sending(.deny) }
        guard case .failed(let message) = r.phase(for: "ap1") else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("Not connected"))
        let status = ApprovalCardStatus(approval: approval, now: Date(), canAnswer: true, phase: r.phase(for: "ap1"))
        XCTAssertTrue(status.canAnswer)
    }

    func testExpiredAtDecideTimeSendsNothing() async throws {
        let sent = Sent()
        let r = ApprovalResponder { sent.add($0) }
        r.decide(approval, .allow, now: approval.expiresAt, canAnswer: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(sent.all.isEmpty)
        XCTAssertEqual(r.phase(for: "ap1"), .expired)
    }

    func testReconnectingSendsNothing() async throws {
        let sent = Sent()
        let r = ApprovalResponder { sent.add($0) }
        r.decide(approval, .allow, canAnswer: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(sent.all.isEmpty)
        XCTAssertNil(r.phase(for: "ap1"))
    }

    func testResolvedApprovalIsForgotten() async throws {
        let store = AppStore()
        store.apply(.connected)
        store.apply(try Envelope.make(.approvalAdded, approval))
        let r = ApprovalResponder { _ in }
        r.decide(approval, .allow, canAnswer: true)
        r.sync(store: store)
        XCTAssertEqual(r.phase(for: "ap1"), .sending(.allow))
        store.apply(try Envelope.make(.approvalResolved, ApprovalResolved(id: "ap1", behavior: "allow", source: "notch")))
        r.sync(store: store)
        XCTAssertNil(r.phase(for: "ap1"))
    }
}
