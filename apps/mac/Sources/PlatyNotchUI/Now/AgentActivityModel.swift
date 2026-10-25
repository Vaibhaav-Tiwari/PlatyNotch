import Foundation
import Observation
import PlatyNotchKit

/// The app's one session tracker (one instance, shared by every display): every session
/// change goes through its `SessionTransitions`, and finishes and failures land in its
/// `AgentFinishLog` (spec 6.3 ranks 4 and 5; Ruling 3). Others subscribe with `observe`
/// instead of keeping their own tracker.
@MainActor @Observable
final class AgentActivityModel {
    private(set) var log = AgentFinishLog()
    /// Bumped when a 10-minute window runs out, so views re-rank then.
    private(set) var revision = 0

    @ObservationIgnored private var transitions = SessionTransitions()
    @ObservationIgnored private var handlers: [@MainActor (SessionChanges) -> Void] = []
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var store: AppStore?
    @ObservationIgnored private var lastNotice = 0

    init() {}

    /// Follows the store's sessions and notices (the app calls this once at launch).
    func start(store: AppStore) {
        self.store = store
        lastNotice = store.noticeSequence
        observeSessions()
        observeNotices()
    }

    func stop() {
        store = nil
        expiry?.cancel()
        expiry = nil
    }

    /// The store's sessions now: finishes are logged; a session active again loses its failure.
    func sessionsChanged(_ sessions: [Session], now: Date) {
        let changes = transitions.update(sessions)
        for s in sessions where s.state == .active && log.failed(s.key, now: now) {
            log.clearFailure(sessionKey: s.key)
        }
        log.record(changes, now: now)
        if changes != .none {
            for h in handlers { h(changes) }
        }
        scheduleExpiry(now: now)
    }

    /// A core notice: "session-failed" marks its session errored for up to 10 minutes.
    func notice(_ n: Notice, now: Date) {
        guard n.kind == "session-failed", let key = n.sessionKey else { return }
        log.noteFailure(sessionKey: key, at: now)
        scheduleExpiry(now: now)
    }

    /// Hears every non-empty change (Platy's moods, the plip, the Agents notice).
    func observe(_ handler: @escaping @MainActor (SessionChanges) -> Void) {
        handlers.append(handler)
    }

    private func scheduleExpiry(now: Date) {
        expiry?.cancel()
        guard store != nil, let next = log.nextExpiry(after: now) else { expiry = nil; return }
        let wait: TimeInterval = max(next.timeIntervalSince(now), 0.5)
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.revision += 1
            self.scheduleExpiry(now: Date())
        }
    }

    private func observeSessions() {
        guard let store else { return }
        let sessions = withObservationTracking {
            store.sessions
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSessions() }
        }
        sessionsChanged(sessions, now: Date())
    }

    private func observeNotices() {
        guard let store else { return }
        let sequence = withObservationTracking {
            store.noticeSequence
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeNotices() }
        }
        // Notices that arrived since the last look (the store keeps the last 20).
        let fresh = min(max(sequence - lastNotice, 0), store.notices.count)
        lastNotice = sequence
        let now = Date()
        for n in store.notices.suffix(fresh) { notice(n, now: now) }
    }
}
