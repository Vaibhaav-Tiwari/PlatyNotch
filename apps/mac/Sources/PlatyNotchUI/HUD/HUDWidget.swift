import AppKit
import Observation
import os
import PlatyNotchKit
import SwiftUI

/// The controls the HUD changes, made when the widget starts (so the private frameworks
/// are only loaded while it is on) and dropped when it stops.
@MainActor
struct HUDControls {
    var volume: VolumeControl
    var brightness: LevelControl
    var backlight: LevelControl

    static func system() -> HUDControls {
        HUDControls(volume: SystemVolume(), brightness: DisplayBrightness(), backlight: KeyboardBacklight())
    }

    /// Nothing available, nothing changed (smoke runs).
    static var inert: HUDControls {
        HUDControls(volume: NoVolume(), brightness: NoLevel(), backlight: NoLevel())
    }
}

@MainActor
private final class NoVolume: VolumeControl {
    var canSetVolume: Bool { false }
    var canMute: Bool { false }
    var outputName: String? { nil }
    func state() -> VolumeChange.State? { nil }
    func set(_ state: VolumeChange.State) -> Bool { false }
    func startObserving(_ onChange: @escaping @MainActor () -> Void) {}
    func stopObserving() {}
}

@MainActor
private final class NoLevel: LevelControl {
    var controlledDisplay: CGDirectDisplayID? { nil }
    var isAvailable: Bool { false }
    func level() -> Float? { nil }
    func setLevel(_ value: Float) -> Bool { false }
}

/// Volume, brightness and keyboard-backlight HUDs that replace the system HUD.
///
/// Off by default (it needs Accessibility). While it runs and Accessibility is allowed,
/// an event tap (`SystemMediaKeyTap`) takes a media key only when PlatyNotch can do the
/// whole job: the control exists on this Mac and our HUD would show on the display under
/// the cursor (`MediaKeyGate`). Everything else, and everything while the permission is
/// missing, the tap failed or the widget is off, goes to the system as usual.
/// A disabled widget has no tap, no CoreAudio listener and no notification observers.
@MainActor @Observable
final class HUDWidget: NotchWidget {
    static let widgetID = "hud"
    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "HUDWidget")

    enum Status: Equatable {
        /// Not running (widget off).
        case stopped
        /// No Accessibility: the system HUD shows.
        case needsAccessibility
        /// Accessibility is allowed but macOS refused the tap.
        case tapRefused
        case on
    }

    let id = HUDWidget.widgetID
    let title = "Volume & brightness HUD"
    let systemImage = "speaker.wave.2"
    let defaultEnabled = false

    private(set) var status: Status = .stopped
    /// The keys PlatyNotch handles on this Mac (the rest go to the system).
    private(set) var available: Set<MediaKeyKind> = []
    private(set) var outputName: String?
    /// Still not trusted after a grant seen for another build (definite), or after Allow and
    /// coming back (conditional): what the tile adds (feedback 7).
    private(set) var advice: PermissionAdvice.AccessibilityAdvice = .none
    /// The display whose brightness we set (the built-in one), if any.
    @ObservationIgnored private var brightnessDisplay: CGDirectDisplayID?
    /// Controls whose set failed (cleared on a device / screen change and on stop).
    @ObservationIgnored private var failedSets: Set<HUDKind> = []

    @ObservationIgnored private let makeTap: () -> MediaKeyTapping
    @ObservationIgnored private let makeControls: () -> HUDControls
    @ObservationIgnored private let trust: AccessibilityTrust
    @ObservationIgnored private var context: WidgetContext?
    @ObservationIgnored private var controls: HUDControls?
    @ObservationIgnored private var tap: MediaKeyTapping?
    @ObservationIgnored private var router: MediaKeyRouter?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let identity: () -> String
    /// Waits between trust reads while the Allow UI is on screen (tests inject their own).
    @ObservationIgnored private let pollSleep: @MainActor () async -> Void
    /// "Allow Accessibility…" was clicked (this run), and since then the user came back
    /// (PlatyNotch active again, or System Settings left).
    @ObservationIgnored private var allowClicked = false
    @ObservationIgnored private var returnedAfterAllow = false

    static let pollInterval: Duration = .seconds(2)

    init(makeTap: @escaping () -> MediaKeyTapping = { SystemMediaKeyTap() },
         makeControls: @escaping () -> HUDControls = { HUDControls.system() },
         trust: AccessibilityTrust = .system,
         identity: @escaping () -> String = { CodeIdentity.current },
         pollSleep: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: HUDWidget.pollInterval) }) {
        self.makeTap = makeTap
        self.makeControls = makeControls
        self.trust = trust
        self.identity = identity
        self.pollSleep = pollSleep
    }

    /// Smoke runs: no tap, no prompt, controls that change nothing.
    static func inert() -> HUDWidget {
        HUDWidget(makeTap: { NoMediaKeyTap() }, makeControls: { .inert }, trust: .never)
    }

    var isRunning: Bool { context != nil }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard self.context == nil else { return }
        self.context = context
        generation += 1
        let controls = makeControls()
        self.controls = controls
        controls.volume.startObserving { [weak self] in self?.controlsChanged(.volume) }
        observeSystem()
        context.surfaces.onHUDReadinessChange(owner: self) { [weak self] _ in self?.pushGate() }
        refreshControls()
        connect()
    }

    func stop() {
        guard context != nil else { return }
        generation += 1
        disconnectTap()
        controls?.volume.stopObserving()
        controls = nil
        context?.surfaces.onHUDReadinessChange(owner: self, nil)
        for (center, o) in observers { center.removeObserver(o) }
        observers = []
        recheckTask?.cancel()
        recheckTask = nil
        context = nil
        failedSets = []
        status = .stopped
        advice = .none
        allowClicked = false
        returnedAfterAllow = false
        available = []
        outputName = nil
    }

    /// Creates the tap when Accessibility is allowed and drops it when not.
    private func connect() {
        guard let context else { return }
        guard trust.isTrusted() else {
            disconnectTap()
            status = .needsAccessibility
            let history = AccessibilityGrant.history(context.defaults, identity: identity())
            let next = PermissionAdvice.accessibility(trusted: false, returnedAfterAllow: returnedAfterAllow,
                                                      history: history)
            if advice != next { advice = next }
            return
        }
        AccessibilityGrant.note(context.defaults, identity: identity())
        if advice != .none { advice = .none }
        if tap == nil {
            let t = makeTap()
            // The router hands taken keys to the main queue (never waited on).
            let r = MediaKeyRouter { [weak self] action, display in self?.perform(action, display: display) }
            guard t.start(router: r) else {
                status = .tapRefused
                return
            }
            tap = t
            router = r
        }
        status = .on
        pushGate()
    }

    private func disconnectTap() {
        router?.update { $0.active = false }
        tap?.stop()
        tap = nil
        router = nil
    }

    // MARK: - Permission

    /// The "Allow" button: shows the system Accessibility prompt, then picks the grant up
    /// (the distributed notification below, and a bounded recheck for a minute).
    func requestAccess() {
        allowClicked = true
        returnedAfterAllow = false
        trust.request()
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.connect()
                if self.status != .needsAccessibility { return }
            }
        }
    }

    /// Re-reads trust now (and the advice that goes with it).
    func recheckTrust() { connect() }

    /// While the Allow UI is shown (the tile's or Settings' `.task`): re-reads trust every
    /// `pollInterval`, but only while `isOnScreen` (its window visible and not covered),
    /// until it is granted or the view goes away.
    func watchTrustWhileVisible(isOnScreen: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled, isRunning, status == .needsAccessibility {
            await pollSleep()
            guard !Task.isCancelled else { return }
            if isOnScreen() { connect() }
        }
    }

    /// Back in PlatyNotch, or out of System Settings: after Allow, a still-missing trust now
    /// gets the conditional advice.
    func userReturned() {
        if allowClicked { returnedAfterAllow = true }
        trustMayHaveChanged()
    }

    /// Retry after macOS refused the tap.
    func retry() { connect() }

    private func observeSystem() {
        // Posted when any app's Accessibility entry changes (granted or revoked).
        let dnc = DistributedNotificationCenter.default()
        observers.append((dnc, dnc.addObserver(forName: Notification.Name("com.apple.accessibility.api"),
                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trustMayHaveChanged() }
        }))
        let nc = NotificationCenter.default
        // Back in PlatyNotch, or out of System Settings: read trust again.
        observers.append((nc, nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userReturned() }
        }))
        let ws = NSWorkspace.shared.notificationCenter
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil,
                                             queue: .main) { [weak self] note in
            guard PermissionReturn.leftSystemSettings(note) else { return }
            MainActor.assumeIsolated { self?.userReturned() }
        }))
        // The Settings or onboarding window closing (not panels, pickers or alerts).
        observers.append((nc, nc.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                             queue: .main) { [weak self] note in
            // Delivered on the main queue: the window is only looked at there.
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard AppWindowID.isSettingsLike(window) else { return }
                self?.trustMayHaveChanged()
            }
        }))
        // Displays come and go (clamshell): brightness availability changes.
        observers.append((nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controlsChanged(.brightness) }
        }))
    }

    func trustMayHaveChanged() {
        // The notification arrives before the new state can be read.
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.generation == gen else { return }
            self.connect()
        }
    }

    // MARK: - Gate

    /// The output device or the displays changed: a control whose set failed gets
    /// another chance (the keyboard backlight too, on a screen change).
    private func controlsChanged(_ kind: HUDKind) {
        failedSets.remove(kind)
        if kind == .brightness { failedSets.remove(.keyboardBacklight) }
        refreshControls()
    }

    private func refreshControls() {
        guard let controls else { return }
        // A key is ours only if it can change something and we can read the result back.
        // Volume also needs a settable main mute: without it a muted output (e.g. muted
        // per channel) could not be unmuted by volume up, and our HUD could not tell.
        var keys: Set<MediaKeyKind> = []
        let volume = controls.volume
        if volume.canSetVolume, volume.canMute, volume.state() != nil { keys.formUnion([.volumeUp, .volumeDown, .mute]) }
        if controls.brightness.isAvailable, controls.brightness.level() != nil {
            keys.formUnion([.brightnessUp, .brightnessDown])
        }
        if controls.backlight.isAvailable, controls.backlight.level() != nil {
            keys.formUnion([.backlightUp, .backlightDown])
        }
        // A control whose set failed stays with the system until the device or the
        // displays change, or the widget restarts: never swallow presses that do nothing.
        for kind in failedSets { keys.subtract(MediaKeyKind.handled.filter { $0.hud == kind }) }
        if keys != available { available = keys }
        brightnessDisplay = controls.brightness.controlledDisplay
        let name = controls.volume.outputName
        if name != outputName { outputName = name }
        pushGate()
    }

    /// Copies what the tap needs into its lock-protected gate.
    private func pushGate() {
        guard let router else { return }
        let active = status == .on
        let keys = available
        let brightness = brightnessDisplay
        let readiness = context?.surfaces.hudReadiness ?? HUDReadiness()
        router.update { gate in
            gate.active = active
            gate.available = keys
            gate.readyDisplays = readiness.displays
            gate.readyOnAnyDisplay = readiness.anyDisplay
            gate.brightnessDisplay = brightness
        }
    }

    // MARK: - Keys

    private enum StepOutcome {
        /// The level read back after the set.
        case level(Float)
        case readFailed, setFailed
    }

    /// A key the tap took: change the level, read it back and show that in our HUD on
    /// `display`. A failed read refreshes the gate; a failed set also takes that control
    /// off the gate until the device or displays change, so the next press goes to the system.
    func perform(_ action: MediaKeyAction, display: CGDirectDisplayID) {
        guard let controls, let context, let hud = action.kind.hud else { return }
        let outcome: StepOutcome
        switch hud {
        case .volume:
            outcome = stepVolume(controls.volume, action)
        case .brightness:
            outcome = step(controls.brightness, action)
        case .keyboardBacklight:
            outcome = step(controls.backlight, action)
        }
        let level: Float
        switch outcome {
        case .level(let l):
            level = l
        case .readFailed:
            Self.log.error("\(hud.rawValue, privacy: .public) key taken but reading the level failed")
            refreshControls()
            return
        case .setFailed:
            Self.log.error("\(hud.rawValue, privacy: .public) key taken but setting the level failed; leaving it to the system")
            failedSets.insert(hud)
            refreshControls()
            return
        }
        if !context.showHUD(kind: hud, level: Double(level), display: display) {
            // The panel changed between the tap's check and now (rare): the change applied, no HUD.
            Self.log.notice("HUD not shown after a taken key")
        }
    }

    /// `set` fails only when the volume itself did not apply; a failed mute write still
    /// shows the HUD, with the state read back (so it never claims a mute change that
    /// did not happen).
    private func stepVolume(_ volume: VolumeControl, _ action: MediaKeyAction) -> StepOutcome {
        guard let now = volume.state() else { return .readFailed }
        let next = VolumeChange.apply(action.kind, fine: action.fine, to: now)
        guard volume.set(next) else { return .setFailed }
        guard let after = volume.state() else { return .readFailed }
        return .level(after.shownLevel)
    }

    private func step(_ control: LevelControl, _ action: MediaKeyAction) -> StepOutcome {
        guard let now = control.level() else { return .readFailed }
        let next = LevelStep.next(now, up: action.kind.isUp, fine: action.fine)
        guard control.setLevel(next) else { return .setFailed }
        guard let after = control.level() else { return .readFailed }
        return .level(after)
    }

    // MARK: - Views

    func hudView(kind: HUDKind, level: Double) -> AnyView? {
        AnyView(HUDView(kind: kind, level: level, output: kind == .volume ? outputName : nil))
    }

    func tileView() -> AnyView { AnyView(HUDTile(widget: self)) }

    func settingsView() -> AnyView? { AnyView(HUDSettingsView(widget: self)) }

    /// Why the system HUD is still showing, for Settings and the tile; nil when ours is on.
    var explanation: String? {
        switch status {
        case .on, .stopped: nil
        case .needsAccessibility where advice != .none:
            "Off: Accessibility is not allowed for this PlatyNotch yet. " + (advice.text ?? "")
                + " The system HUD shows meanwhile."
        case .needsAccessibility:
            """
            Off: needs Accessibility. macOS lets an app take the volume and brightness keys \
            only with Accessibility allowed. Until then the system HUD shows as usual.
            """
        case .tapRefused:
            """
            Off: macOS refused the key tap although Accessibility looks allowed. Remove \
            PlatyNotch from System Settings › Privacy & Security › Accessibility, add it \
            again, then Retry. The system HUD shows meanwhile.
            """
        }
    }

    /// Keys this Mac cannot change through PlatyNotch (left to the system HUD).
    var unavailableNote: String? {
        guard status == .on else { return nil }
        var missing: [String] = []
        if !available.contains(.volumeUp) { missing.append("volume (this output has no volume or mute control)") }
        if !available.contains(.brightnessUp) { missing.append("brightness (no built-in display)") }
        if !available.contains(.backlightUp) { missing.append("keyboard backlight (none on this keyboard)") }
        guard !missing.isEmpty else { return nil }
        return "The system HUD still shows for " + missing.joined(separator: ", ") + "."
    }
}

/// The `CodeIdentity` of the last build seen trusted for Accessibility (HUD, clipboard
/// paste, memory capture), so a rebuilt app's lost grant can be recognised (feedback 7).
@MainActor
enum AccessibilityGrant {
    static let key = "accessibilityGrant"

    static func history(_ defaults: UserDefaults, identity: String) -> GrantHistory {
        GrantHistory(savedStamp: defaults.string(forKey: key), current: identity)
    }

    static func note(_ defaults: UserDefaults, identity: String) {
        if defaults.string(forKey: key) != identity { defaults.set(identity, forKey: key) }
    }
}
