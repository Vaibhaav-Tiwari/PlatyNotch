import AppKit
import Observation
import PlatyNotchKit

/// The focus timer, shared by every display. Persists across relaunch (UserDefaults, Codable).
/// While `focusActive`, the controllers consume notices without peeking (approvals still peek).
@MainActor @Observable
public final class FocusModel {
    static let timerKey = "focus.timer"
    /// When the running timer ends (absent when not running), for other readers.
    static let untilKey = "focusUntil"

    public private(set) var timer: FocusTimer?
    public private(set) var focusActive = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private let onFinish: () -> Void

    public convenience init() {
        self.init(defaults: .standard, onFinish: { NSSound(named: "Glass")?.play() })
    }

    init(defaults: UserDefaults, onFinish: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.onFinish = onFinish
        if let data = defaults.data(forKey: Self.timerKey) {
            timer = try? JSONDecoder().decode(FocusTimer.self, from: data)
        }
        reconcile(now: Date(), announce: false)
    }

    public func start(minutes: Int, now: Date = Date()) {
        var t = FocusTimer(minutes: minutes)
        t.start(at: now)
        set(t)
    }

    public func pause(now: Date = Date()) {
        guard var t = timer else { return }
        t.pause(at: now)
        set(t)
    }

    public func resume(now: Date = Date()) {
        guard var t = timer else { return }
        t.resume(at: now)
        set(t)
    }

    /// Ends the session (or clears a finished one).
    public func stop() {
        set(nil)
    }

    private func set(_ t: FocusTimer?) {
        timer = t
        if let t, let data = try? JSONEncoder().encode(t) {
            defaults.set(data, forKey: Self.timerKey)
        } else {
            defaults.removeObject(forKey: Self.timerKey)
        }
        reconcile(now: Date(), announce: true)   // activity follows the real clock
    }

    /// Updates `focusActive` and wakes up when a running timer reaches zero.
    /// Works out whether focus is on at `now`; `announce`: a finish then calls `onFinish`.
    func reconcile(now: Date, announce: Bool) {
        endTask?.cancel()
        endTask = nil
        let active = timer?.isRunning(at: now) ?? false
        if focusActive && !active && announce && timer?.isDone(at: now) == true { onFinish() }
        if focusActive != active { focusActive = active }
        if active, let end = timer?.endsAt {
            defaults.set(end, forKey: Self.untilKey)
            let delay = max(0, end.timeIntervalSince(now)) + 0.05
            endTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.reconcile(now: Date(), announce: true)
            }
        } else {
            defaults.removeObject(forKey: Self.untilKey)
        }
    }
}
