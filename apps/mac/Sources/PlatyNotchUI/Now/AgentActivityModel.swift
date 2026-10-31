import AppKit
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
    @ObservationIgnored private var clockObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Whether the Agents destination shows (spec 6.7): hidden until a session first
    /// appears or Settings › Agents turns it on.
    private(set) var agentsVisibility = AgentsVisibility()
    /// Where `agentsVisibility` is saved (nil: kept in memory, as in smoke runs and renders).
    @ObservationIgnored private var visibilityDefaults: UserDefaults?
    /// Called once, the first time a session appears (the one-time notice).
    @ObservationIgnored var onAgentsFirstShown: (@MainActor () -> Void)?

    init() {}

    /// Follows the store's sessions and notices, and re-ranks after a wake or a clock
    /// change. Idempotent: a second call (or one for the same store) does nothing.
    func start(store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        lastNotice = store.noticeSequence
        observeSessions()
        observeNotices()
        observeClock()
    }

    func stop() {
        store = nil
        expiry?.cancel()
        expiry = nil
        for (center, token) in clockObservers { center.removeObserver(token) }
        clockObservers = []
    }

    /// After a wake or a clock change: re-rank now (a window may have run out while
    /// asleep) and wait for the next expiry afresh.
    func clockChanged(now: Date) {
        revision += 1
        scheduleExpiry(now: now)
    }

    private func observeClock() {
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockChanged(now: Date()) }
        }
        let center = NotificationCenter.default
        let change = center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockChanged(now: Date()) }
        }
        clockObservers = [(workspace, wake), (center, change)]
    }

    /// Reads the saved visibility and keeps saving it there.
    func loadVisibility(from defaults: UserDefaults) {
        visibilityDefaults = defaults
        agentsVisibility = AgentsVisibility.load(from: defaults)
    }

    /// Settings › Agents changed the saved visibility ("Show Agents before an agent connects").
    func reloadVisibility() {
        guard let visibilityDefaults else { return }
        let saved = AgentsVisibility.load(from: visibilityDefaults)
        if saved != agentsVisibility { agentsVisibility = saved }
    }

    /// The store's sessions now: finishes are logged; a session active again loses its failure.
    func sessionsChanged(_ sessions: [Session], now: Date) {
        var visibility = agentsVisibility
        if visibility.noteSessions(count: sessions.count) {
            agentsVisibility = visibility
            if let visibilityDefaults { visibility.save(to: visibilityDefaults) }
            onAgentsFirstShown?()
        }
        lastSessions = sessions
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

    /// The sessions of the last change (what `observe` handlers' keys refer to).
    @ObservationIgnored private(set) var lastSessions: [Session] = []

    /// A session that starts waiting for your input posts a "needs-input" notice, which
    /// Settings › Notifications governs as "Agent needs you or stopped". Approvals have
    /// their own card and post nothing here.
    func postNeedsInputNotices(to store: AppStore) {
        observe { [weak self, weak store] changes in
            guard let self, let store else { return }
            for n in Self.needsInputNotices(changes, sessions: self.lastSessions) { store.postLocalNotice(n) }
        }
    }

    /// "Claude Code needs your input" (body: the project) for each session that entered
    /// waiting-for-input in `changes`.
    static func needsInputNotices(_ changes: SessionChanges, sessions: [Session]) -> [Notice] {
        changes.enteredNeedsYou.compactMap { key in
            guard let s = sessions.first(where: { $0.key == key }), s.state == .waitingInput else { return nil }
            return Notice(kind: "needs-input", title: "\(s.agentName) needs your input", body: s.project, sessionKey: s.key)
        }
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
