import Foundation
import Observation
import PlatyNotchKit

/// The timed inputs of Platy's mood, shared by every display: "just finished" (a session
/// went from active to idle or exited, `PlatyFinishWatch`), "celebrating" (a game's new
/// best, `GamesWidget.onNewBest`) and the hour (night is sleepy). Each wakes once when it
/// changes (a sleeping task, no timer while nothing is pending), so the pill re-reads the
/// mood only then.
@MainActor @Observable
public final class PlatyMoodModel {
    public private(set) var justFinished = false
    public private(set) var celebrating = false
    public private(set) var hour: Int

    @ObservationIgnored private var flags = PlatyMoodFlags()
    @ObservationIgnored private var watch = PlatyFinishWatch()
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var hourTask: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var store: AppStore?

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
        hour = Calendar.current.component(.hour, from: now())
    }

    /// Follows the store's sessions and the clock (the app calls this once at launch).
    public func start(store: AppStore) {
        self.store = store
        observeSessions()
        scheduleHour()
    }

    public func stop() {
        store = nil
        expiry?.cancel()
        hourTask?.cancel()
    }

    /// A game ended with a new best.
    public func celebrate() {
        flags.celebrate(at: now())
        refresh()
    }

    /// Platy's mood now. Reads the store and the other inputs, so a view calling it
    /// redraws when any of them changes.
    public func mood(sessions: [Session], approvals: Int, musicPlaying: Bool, focusActive: Bool) -> PlatyMood {
        PlatyMoodResolver.mood(sessions: sessions.map(\.state), approvalsPending: approvals, musicPlaying: musicPlaying,
                               focusActive: focusActive, justFinished: justFinished, hour: hour,
                               celebrating: celebrating)
    }

    /// Feeds session states (the store observer; tests call it directly).
    func sessionsChanged(_ sessions: [Session]) {
        var states: [String: SessionState] = [:]
        for s in sessions { states[s.key] = s.state }
        if watch.update(states) {
            flags.finish(at: now())
            refresh()
        }
    }

    /// Works the flags out again for now and waits for the next expiry.
    func refresh() {
        let t = now()
        let finished = flags.justFinished(at: t)
        let party = flags.celebrating(at: t)
        if finished != justFinished { justFinished = finished }
        if party != celebrating { celebrating = party }
        expiry?.cancel()
        guard let next = flags.nextChange(after: t) else { expiry = nil; return }
        let wait = next.timeIntervalSince(t)
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func observeSessions() {
        guard let store else { return }
        let sessions = withObservationTracking {
            store.sessions
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSessions() }
        }
        sessionsChanged(sessions)
    }

    /// Wakes at the top of each hour (night starts at 23 and ends at 6).
    private func scheduleHour() {
        hourTask?.cancel()
        let t = now()
        let calendar = Calendar.current
        let current = calendar.component(.hour, from: t)
        if current != hour { hour = current }
        guard let next = calendar.nextDate(after: t, matching: DateComponents(minute: 0, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        let wait = max(next.timeIntervalSince(t), 1)
        hourTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.scheduleHour()
        }
    }
}
