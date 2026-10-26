import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

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
        .settingsGroup()
    }
}
