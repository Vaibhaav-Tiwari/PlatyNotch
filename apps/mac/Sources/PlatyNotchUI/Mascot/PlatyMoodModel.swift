import Foundation
import Observation
import PlatyNotchKit

/// The timed inputs of Platy's mood, shared by every display: "just finished" (a session
/// went from working to idle or exited: from the app's one `AgentActivityModel` once
/// `follow` is called, else its own `PlatyFinishWatch`), "celebrating" (a game's new
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
    @ObservationIgnored private var calendar: Calendar
    @ObservationIgnored private var zoneObserver: NSObjectProtocol?
    /// The app's one session tracker, once followed.
    @ObservationIgnored private var activity: AgentActivityModel?

    /// `calendar` gives the hour (tests pass a fixed time zone); a system time zone change
    /// re-reads it.
    public init(now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        hour = calendar.component(.hour, from: now())
    }

    /// Takes session changes from the app's one tracker instead of its own watch, and its
    /// finish log for the done pose (Ruling 14: done while an agent finished in the last
    /// 10 minutes and nothing works or needs you).
    func follow(_ activity: AgentActivityModel) {
        guard self.activity == nil else { return }
        self.activity = activity
        activity.observe { [weak self] changes in
            guard let self, !changes.finished.isEmpty else { return }
            self.flags.finish(at: self.now())
            self.refresh()
        }
    }

    /// Follows the store's sessions and the clock (the app calls this once at launch).
    public func start(store: AppStore) {
        self.store = store
        if activity == nil { observeSessions() }
        scheduleHour()
        zoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.timeZoneChanged(to: .current) }
        }
    }

    /// The Mac moved to another time zone: the hour (and night) follow at once.
    func timeZoneChanged(to zone: TimeZone) {
        calendar.timeZone = zone
        scheduleHour()
    }

    public func stop() {
        store = nil
        expiry?.cancel()
        hourTask?.cancel()
        if let zoneObserver { NotificationCenter.default.removeObserver(zoneObserver) }
        zoneObserver = nil
    }

    /// A game ended with a new best.
    public func celebrate() {
        flags.celebrate(at: now())
        refresh()
    }

    /// Platy's mood now. Reads the store and the other inputs, so a view calling it
    /// redraws when any of them changes.
    public func mood(sessions: [Session], approvals: Int, musicPlaying: Bool, focusActive: Bool) -> PlatyMood {
        let states: [SessionState] = sessions.map(\.state)
        var done: Bool = justFinished
        if !done, let activity {
            _ = activity.revision   // re-read when a 10-minute window runs out
            done = PlatyMoodResolver.showsDone(flags: PlatyMoodFlags(), log: activity.log, sessions: states, now: now())
        }
        return PlatyMoodResolver.mood(sessions: states, approvalsPending: approvals, musicPlaying: musicPlaying,
                                      focusActive: focusActive, justFinished: done, hour: hour,
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
