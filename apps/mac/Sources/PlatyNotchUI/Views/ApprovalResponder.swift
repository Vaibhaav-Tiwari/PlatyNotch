import AppKit
import Observation
import PlatyNotchKit

/// Sends the user's Allow/Deny and tracks it until `approval.resolved` removes the card.
/// One instance is shared by every display's panel, so "Sending…" shows everywhere and
/// a second answer from another display is refused.
@MainActor @Observable
public final class ApprovalResponder {
    private(set) var decisions = ApprovalDecisions()
    @ObservationIgnored private let send: @Sendable (Envelope) async throws -> Void

    init(send: @escaping @Sendable (Envelope) async throws -> Void) {
        self.send = send
    }

    public convenience init(client: CoreClient) {
        self.init(send: { try await client.send($0) })
    }

    func phase(for id: String) -> DecisionPhase? { decisions.phase(for: id) }

    /// Sends unless reconnecting, already answered, or expired at `now`.
    func decide(_ approval: Approval, _ behavior: ApprovalBehavior, now: Date = Date(), canAnswer: Bool) {
        guard decisions.begin(approval, behavior, now: now, canAnswer: canAnswer) == .send else { return }
        let id = approval.id
        let send = self.send
        Task {
            do {
                try await send(ApprovalFormat.decideEnvelope(id: id, behavior))
            } catch {
                self.decisions.fail(id: id, message: Self.describe(error))
            }
        }
    }

    /// Called whenever the store's approvals or connection change.
    func sync(store: AppStore) {
        var next = decisions
        next.sync(pending: Set(store.approvals.map(\.id)), connected: store.canAnswerApprovals)
        if next != decisions { decisions = next }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? CoreClientError {
        case .notConnected: "Not connected to the core. Try again."
        case .timeout: "The core did not answer. Try again."
        case .cancelled: "Sending was cancelled. Try again."
        case nil: "Could not send: \(error.localizedDescription)"
        }
    }
}

/// Filters the input that triggered Allow / Deny: a held key (auto-repeat) or the
/// second click of a double-click must not answer the approval that slides into place.
enum DecisionInput {
    static func accepts(_ event: NSEvent?) -> Bool {
        guard let event else { return true }
        switch event.type {
        case .keyDown: return !event.isARepeat
        case .leftMouseDown, .leftMouseUp: return event.clickCount <= 1
        default: return true
        }
    }
}
