import Observation
import PlatyNotchKit
import SwiftUI

/// Sends Done / Dismiss for open loops and tracks each request until the core acks it.
/// Shared by every display, so a loop being changed shows the same everywhere.
@MainActor @Observable
public final class LoopActions {
    static let timeout: Duration = .seconds(10)

    private(set) var pending: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// Acknowledged changes, hidden until `loops.updated` drops the loop.
    private(set) var hidden: Set<String> = []
    /// Open loop ids at the last `sync`.
    @ObservationIgnored private var open: Set<String> = []
    @ObservationIgnored private let request: @Sendable (Envelope) async throws -> Envelope

    init(request: @escaping @Sendable (Envelope) async throws -> Envelope) {
        self.request = request
    }

    public convenience init(client: CoreClient) {
        self.init(request: { try await client.request($0, timeout: LoopActions.timeout) })
    }

    func set(_ loop: Loop, _ change: LoopStatusChange) {
        let id = loop.id
        guard !pending.contains(id) else { return }
        pending.insert(id)
        errors[id] = nil
        let request = self.request
        Task {
            let message: String?
            do {
                message = LoopsFormat.errorMessage(in: try await request(try LoopsFormat.setStatus(id: id, change)))
            } catch {
                message = Self.describe(error)
            }
            pending.remove(id)
            if let message {
                errors[id] = message
            } else if open.contains(id) {
                hidden.insert(id)   // not if `loops.updated` already dropped it (a reopen must show)
            }
        }
    }

    /// Forgets hidden ids once the store no longer lists them as open (so a reopened loop shows again).
    func sync(open loops: [Loop]) {
        let ids = Set(loops.map(\.id))
        open = ids
        let next = hidden.intersection(ids)
        if next != hidden { hidden = next }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? CoreClientError {
        case .notConnected: "Not connected to the core. Try again."
        case .timeout: "The core did not answer. Try again."
        case .cancelled: "Cancelled. Try again."
        case nil: "Could not send: \(error.localizedDescription)"
        }
    }
}

/// Open loops (promises, follow-ups) found in memory, with Done and Dismiss.
struct LoopsList: View {
    let loops: [Loop]
    let memoryEnabled: Bool
    let actions: LoopActions

    var body: some View {
        let open = LoopsFormat.open(loops)
        let shown = open.filter { !actions.hidden.contains($0.id) }
        VStack(alignment: .leading, spacing: 4) {
            Text(shown.isEmpty ? "Open loops" : "Open loops · \(shown.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if shown.isEmpty {
                Text(memoryEnabled ? "Nothing open. Promises and follow-ups you make show up here."
                                   : "Turn on memory to track promises and follow-ups.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                // The Today tab scrolls; a nested scroll view would collapse to no height.
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { LoopRow(loop: $0, actions: actions) }
                }
            }
        }
        .onChange(of: open.map(\.id), initial: true) { _, _ in actions.sync(open: open) }
    }
}

private struct LoopRow: View {
    let loop: Loop
    let actions: LoopActions

    var body: some View {
        let busy = actions.pending.contains(loop.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: loop.title)
                        .font(.system(size: 12))
                        .lineLimit(2)
                    if let source = loop.sourceApp, !source.isEmpty {
                        Text(verbatim: source)
                            .font(DS.font(TypeScale.caption))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Done") { actions.set(loop, .resolved) }
                        .accessibilityLabel("Mark \(loop.title) done")
                    Button("Dismiss") { actions.set(loop, .dismissed) }
                        .accessibilityLabel("Dismiss \(loop.title)")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            if let error = actions.errors[loop.id] {
                Text(verbatim: error)
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(Theme.color(.attention))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
