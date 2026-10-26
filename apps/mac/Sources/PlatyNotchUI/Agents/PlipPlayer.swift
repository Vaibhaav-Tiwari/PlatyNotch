import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Plays the optional sound when an agent needs you or an approval arrives (spec 8.5,
/// `PlipPolicy`): only when Settings › Notifications › Sound is on, never while the
/// agent's terminal is in front, at a moderate volume, and once for a burst of events.
@MainActor
final class PlipPlayer {
    /// What the player reads from the system (tests pass fakes).
    struct Seams {
        var frontmost: @MainActor () -> String?
        var isRunning: @MainActor (String) -> Bool
        /// Plays a file at a volume; false when it could not.
        var play: @MainActor (URL, Float) -> Bool
        var now: @MainActor () -> Date

        static var system: Seams { Seams(
            frontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
            play: { PlipPlayer.playFile($0, volume: $1) },
            now: { Date() }) }
    }

    /// Events closer together than this make one sound.
    static let quietGap: TimeInterval = 2

    private let defaults: UserDefaults
    private let seams: Seams
    private var lastPlayed: Date?
    private var seenApprovals: Set<String> = []
    private weak var store: AppStore?

    init(defaults: UserDefaults = .standard, seams: Seams = .system) {
        self.defaults = defaults
        self.seams = seams
    }

    /// A PlatyNotch focus session is running (the app passes the Focus widget's state).
    var focusActive: @MainActor () -> Bool = { false }

    /// Sessions that started needing you (nil: unknown). Plays unless every one of them is
    /// muted by its terminal being in front, or the "Agent needs you" row is quiet in focus.
    func agentNeedsYou(_ sessions: [Session?]) {
        play(.agentNeedsYou, sessions: sessions)
    }

    /// One session needs you.
    func agentNeedsYou(_ session: Session?) {
        agentNeedsYou([session])
    }

    /// A new approval (its session when known). Approvals are never quiet in focus.
    func approvalArrived(_ session: Session?) {
        play(.approval, sessions: [session])
    }

    private func play(_ kind: NotificationKind, sessions: [Session?]) {
        let settings = PlipSettings.load(from: defaults)
        guard settings.enabled, !sessions.isEmpty else { return }
        let policy = NotificationPolicy.load(from: defaults)
        guard !PlipPolicy.quietForFocus(kind, policy: policy, focusActive: focusActive()) else { return }
        let front: String? = seams.frontmost()
        let audible: Bool = sessions.contains { s in
            PlipPolicy.shouldPlay(enabled: true, session: s, frontmostBundleID: front, isRunning: seams.isRunning)
        }
        guard audible else { return }
        let now = seams.now()
        if let lastPlayed, now.timeIntervalSince(lastPlayed) < Self.quietGap { return }
        guard let url = Self.url(for: settings) else { return }
        if seams.play(url, PlipPolicy.volume) { lastPlayed = now }
    }

    /// Follows the app's one session tracker (sessions entering "needs you") and the
    /// store's approvals (each new one once; those already there make no sound).
    func follow(_ activity: AgentActivityModel, store: AppStore) {
        self.store = store
        seenApprovals = Set(store.approvals.map(\.id))
        activity.observe { [weak self, weak activity] changes in
            guard let self, let activity, !changes.enteredNeedsYou.isEmpty else { return }
            let entering: [Session?] = changes.enteredNeedsYou.map { key in activity.lastSessions.first { $0.key == key } }
            self.agentNeedsYou(entering)
        }
        observeApprovals()
    }

    private func observeApprovals() {
        guard let store else { return }
        let approvals = withObservationTracking {
            store.approvals
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeApprovals() }
        }
        let fresh = approvals.filter { !seenApprovals.contains($0.id) }
        seenApprovals = Set(approvals.map(\.id))
        guard let approval = fresh.first else { return }
        approvalArrived(store.sessions.first { $0.key == approval.sessionKey })
    }

    /// The file that plays: the chosen file while its bookmark still leads to it and it
    /// still plays and lasts 5 s or less (it may have been replaced since), else Platy chatter.
    static func url(for settings: PlipSettings) -> URL? {
        if settings.effectiveChoice == .custom, let url = resolve(settings),
           FileManager.default.fileExists(atPath: url.path),
           PlipPolicy.validate(duration: duration(of: url)) == .ok {
            return url
        }
        return CueSound.plip.url
    }

    /// The chosen file from its bookmark (nil when there is none or it cannot be found).
    static func resolve(_ settings: PlipSettings) -> URL? {
        guard let data = settings.bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// The file's length in seconds, nil when it does not open as audio.
    static func duration(of url: URL) -> TimeInterval? {
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        return sound.duration
    }

    /// Plays one file once (the sound object is kept until it ends).
    static func playFile(_ url: URL, volume: Float) -> Bool {
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return false }
        sound.volume = volume
        playing = sound
        return sound.play()
    }

    private static var playing: NSSound?
}
