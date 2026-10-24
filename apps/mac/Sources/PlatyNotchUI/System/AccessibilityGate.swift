import AppKit
import PlatyNotchKit

/// Accessibility trust for one feature that needs it (the HUD, window snapping): reads
/// trust without prompting, stamps a working grant with this build, works out the
/// "PlatyNotch was rebuilt" advice, and re-reads trust when it may have changed.
///
/// While started it observes the system's Accessibility change notification, PlatyNotch
/// becoming active or resigning, System Settings being left and the Settings or
/// onboarding window closing; `stop` removes every observer and cancels every recheck.
/// The prompt is shown only from `requestAccess` (an Allow button). `onChange` gets each
/// read's result; the owner does its own work there (a tap, shortcuts).
@MainActor
final class AccessibilityGate {
    typealias Change = @MainActor (_ trusted: Bool, _ advice: PermissionAdvice.AccessibilityAdvice) -> Void

    /// Called after every read while started.
    var onChange: Change = { _, _ in }
    private(set) var isActive = false
    /// The last read (false until the first `evaluate`).
    private(set) var trusted = false
    private(set) var advice: PermissionAdvice.AccessibilityAdvice = .none

    private let trust: AccessibilityTrust
    private let identity: () -> String
    private let pollSleep: @MainActor () async -> Void
    private let allowSleep: @MainActor () async -> Void
    private var defaults: UserDefaults?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The bounded recheck after Allow (a new click replaces it).
    private var recheckTask: Task<Void, Never>?
    private var generation = 0
    /// "Allow" was clicked (this run), and since then the user went away and came back.
    private var allowReturn = AllowReturn()

    init(trust: AccessibilityTrust, identity: @escaping () -> String,
         pollSleep: @escaping @MainActor () async -> Void,
         allowSleep: @escaping @MainActor () async -> Void) {
        self.trust = trust
        self.identity = identity
        self.pollSleep = pollSleep
        self.allowSleep = allowSleep
    }

    /// Installs the observers. Trust is read only on `evaluate` (the owner calls it when
    /// it is ready).
    func start(defaults: UserDefaults) {
        guard !isActive else { return }
        isActive = true
        self.defaults = defaults
        generation += 1
        observeSystem()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        generation += 1
        for (center, o) in observers { center.removeObserver(o) }
        observers = []
        recheckTask?.cancel()
        recheckTask = nil
        defaults = nil
        trusted = false
        advice = .none
        allowReturn.reset()
    }

    /// Reads trust (never prompts) and tells `onChange`.
    func evaluate() {
        guard isActive, let defaults else { return }
        let ok = trust.isTrusted()
        trusted = ok
        if ok {
            recheckTask?.cancel()
            recheckTask = nil
            AccessibilityGrant.note(defaults, identity: identity())
            advice = .none
        } else {
            let history = AccessibilityGrant.history(defaults, identity: identity())
            advice = PermissionAdvice.accessibility(trusted: false, returnedAfterAllow: allowReturn.returned,
                                                    history: history)
        }
        onChange(ok, advice)
    }

    /// The "Allow" button: shows the system prompt, then re-reads trust every second for
    /// a minute, only while `isOnScreen` (the window that shows Allow is visible).
    func requestAccess(isOnScreen: @escaping @MainActor () -> Bool) {
        allowReturn.allowClicked()
        trust.request()
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            for _ in 0..<60 {
                await self?.allowSleep()
                guard !Task.isCancelled, let self, self.isActive else { return }
                guard isOnScreen() else { continue }
                self.evaluate()
                if self.trusted { return }
            }
        }
    }

    /// While the Allow UI is shown: re-reads trust every `pollSleep`, only while
    /// `isOnScreen`, until it is granted, the gate stops or the view goes away.
    func watchTrustWhileVisible(isOnScreen: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled, isActive, !trusted {
            await pollSleep()
            guard !Task.isCancelled else { return }
            if isOnScreen() { evaluate() }
        }
    }

    /// Back in PlatyNotch, or out of System Settings: after Allow, a still-missing trust
    /// now gets the conditional advice.
    func userReturned() {
        allowReturn.appBecameActive()
        trustMayHaveChanged()
    }

    /// Re-reads trust shortly (the notifications arrive before the new state can be read).
    func trustMayHaveChanged() {
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.generation == gen else { return }
            self.evaluate()
        }
    }

    private func observeSystem() {
        // Posted when any app's Accessibility entry changes (granted or revoked).
        let dnc = DistributedNotificationCenter.default()
        observers.append((dnc, dnc.addObserver(forName: Notification.Name("com.apple.accessibility.api"),
                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trustMayHaveChanged() }
        }))
        let nc = NotificationCenter.default
        observers.append((nc, nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userReturned() }
        }))
        observers.append((nc, nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.allowReturn.appResigned() }
        }))
        let ws = NSWorkspace.shared.notificationCenter
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil,
                                             queue: .main) { [weak self] note in
            guard PermissionReturn.leftSystemSettings(note) else { return }
            MainActor.assumeIsolated {
                // The user was in System Settings, whatever the app-active notifications said.
                self?.allowReturn.appResigned()
                self?.userReturned()
            }
        }))
        // The Settings or onboarding window closing (not panels, pickers or alerts).
        observers.append((nc, nc.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                             queue: .main) { [weak self] note in
            // Delivered on the main queue: the window is only looked at there.
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard AppWindowID.isSettingsLike(window) else { return }
                self?.trustMayHaveChanged()
            }
        }))
    }
}
