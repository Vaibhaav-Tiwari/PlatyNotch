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

    /// A session needs you (`session` nil: an approval whose session is not known).
    func agentNeedsYou(_ session: Session?) {
        let settings = PlipSettings.load(from: defaults)
        guard PlipPolicy.shouldPlay(enabled: settings.enabled, session: session,
                                    frontmostBundleID: seams.frontmost(), isRunning: seams.isRunning) else { return }
        let now = seams.now()
        if let lastPlayed, now.timeIntervalSince(lastPlayed) < Self.quietGap { return }
        guard let url = Self.url(for: settings) else { return }
        if seams.play(url, PlipPolicy.volume) { lastPlayed = now }
    }

    /// Follows the app's one session tracker (sessions entering "needs you") and the
    /// store's approvals (each new one once).
    func follow(_ activity: AgentActivityModel, store: AppStore) {
        self.store = store
        seenApprovals = Set(store.approvals.map(\.id))
        activity.observe { [weak self, weak activity] changes in
            guard let self, let activity, !changes.enteredNeedsYou.isEmpty else { return }
            let first = changes.enteredNeedsYou.first.flatMap { key in activity.lastSessions.first { $0.key == key } }
            self.agentNeedsYou(first)
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
        agentNeedsYou(store.sessions.first { $0.key == approval.sessionKey })
    }

    /// The file that plays: the chosen file while its bookmark still leads to it, else
    /// Platy chatter.
    static func url(for settings: PlipSettings) -> URL? {
        if settings.effectiveChoice == .custom, let url = resolve(settings),
           FileManager.default.fileExists(atPath: url.path) {
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

/// Settings › Notifications › Sound.
@MainActor @Observable
final class PlipSoundModel {
    private(set) var settings: PlipSettings
    /// Why the last chosen file was refused.
    private(set) var error: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let play: @MainActor (URL, Float) -> Bool

    init(defaults: UserDefaults = .standard,
         play: @escaping @MainActor (URL, Float) -> Bool = { PlipPlayer.playFile($0, volume: $1) }) {
        self.defaults = defaults
        self.play = play
        settings = PlipSettings.load(from: defaults)
    }

    var enabled: Bool {
        get { settings.enabled }
        set { settings.enabled = newValue; settings.save(to: defaults) }
    }

    /// The picker's value: Platy chatter, or the chosen file once there is one.
    var choice: PlipSettings.Choice {
        get { settings.effectiveChoice }
        set {
            guard newValue != settings.choice else { return }
            settings.choice = newValue == .custom && settings.bookmark == nil ? .chatter : newValue
            settings.save(to: defaults)
        }
    }

    /// Checks `url` plays and lasts at most 5 s; when it does, keeps it as a bookmark
    /// (the file stays where it is) and makes it the sound.
    @discardableResult
    func choose(_ url: URL) -> PlipValidation {
        let verdict = PlipPolicy.validate(duration: PlipPlayer.duration(of: url))
        error = verdict.message
        guard verdict == .ok, let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                                   relativeTo: nil) else {
            return verdict == .ok ? .unreadable : verdict
        }
        settings.bookmark = bookmark
        settings.customName = url.lastPathComponent
        settings.choice = .custom
        settings.save(to: defaults)
        return .ok
    }

    /// Shows why a file was refused (renders).
    func showRefusal(_ verdict: PlipValidation) { error = verdict.message }

    /// Plays the current sound once, on or off.
    func preview() {
        guard let url = PlipPlayer.url(for: settings) else { return }
        if !play(url, PlipPolicy.volume) { error = PlipValidation.unreadable.message }
    }

    /// "Choose sound file…": an open panel for one audio file (not modal, so an approval
    /// in the notch stays clickable).
    func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose a sound of 5 seconds or less. It stays where it is; PlatyNotch only remembers where."
        panel.begin { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            MainActor.assumeIsolated { _ = self?.choose(url) }
        }
    }
}

/// The Sound group under Settings › Notifications: a switch (off by default), the sound
/// (Platy chatter or a chosen file), "Choose sound file…" and Play.
struct PlipSoundSettings: View {
    @State private var model: PlipSoundModel

    init(defaults: UserDefaults = .standard) {
        _model = State(initialValue: PlipSoundModel(defaults: defaults))
    }

    init(model: PlipSoundModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SymbolWell(systemImage: "speaker.wave.2.fill", size: 26)
                SettingLabel("Play a sound when an agent needs you",
                             info: "For approvals and sessions waiting for your input. Muted while that agent's terminal is in front.")
                Spacer(minLength: 8)
                Toggle("Play a sound when an agent needs you", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.vertical, 8)
            Divider().padding(.leading, 36)
            HStack(spacing: 10) {
                SymbolWell(systemImage: "waveform", size: 26)
                Text(verbatim: "Sound")
                Spacer(minLength: 8)
                Picker("Sound", selection: $model.choice) {
                    Text(verbatim: "Platy chatter").tag(PlipSettings.Choice.chatter)
                    if let name = model.settings.customName, model.settings.bookmark != nil {
                        Text(verbatim: name).tag(PlipSettings.Choice.custom)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Choose sound file…") { model.pickFile() }
                Button {
                    model.preview()
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .accessibilityLabel("Play the sound")
            }
            .padding(.vertical, 8)
            .disabled(!model.enabled)
            .opacity(model.enabled ? 1 : 0.55)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Sound file refused: \(error)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}
