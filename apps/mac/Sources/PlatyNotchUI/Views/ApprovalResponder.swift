import Observation
import PlatyNotchKit

/// Sends the user's Allow/Deny and tracks it until `approval.resolved` removes the card.
@MainActor @Observable
final class ApprovalResponder {
    private(set) var decisions = ApprovalDecisions()
    @ObservationIgnored private let send: @Sendable (Envelope) async throws -> Void

    init(send: @escaping @Sendable (Envelope) async throws -> Void) {
        self.send = send
    }

    convenience init(client: CoreClient) {
        self.init(send: { try await client.send($0) })
    }

    func phase(for id: String) -> DecisionPhase? { decisions.phase(for: id) }

    func decide(_ approval: Approval, _ behavior: ApprovalBehavior) {
        guard decisions.begin(id: approval.id, behavior) else { return }
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
        decisions.sync(pending: Set(store.approvals.map(\.id)), connected: store.canAnswerApprovals)
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
