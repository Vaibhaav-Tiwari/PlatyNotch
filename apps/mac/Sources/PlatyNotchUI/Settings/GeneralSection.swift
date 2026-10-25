import PlatyNotchKit
import ServiceManagement
import SwiftUI

/// Settings › General: launch at login, updates, and the first run again.
struct GeneralSection: View {
    let services: SettingsServices
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?
    /// A setup that would turn widgets off, waiting for a yes.
    @State private var pending: SetupPreset?
    @State private var applied: SetupPreset?

    var body: some View {
        SettingsPage("General") {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { loginEnabled }, set: { on in setLogin(on) })) {
                        SettingLabel("Launch at login")
                    }
                    .toggleStyle(.switch)
                    if let loginNote {
                        Text(verbatim: loginNote).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                    }
                }
                Section("Updates") { updateRows }
                Section {
                    HStack(spacing: 8) {
                        ForEach(SetupPreset.allCases, id: \.self) { p in
                            Button(p.title) { choose(p) }
                                .help(p.summary)
                        }
                        Spacer(minLength: 0)
                        if let applied {
                            Label("\(applied.title) applied", systemImage: "checkmark.circle.fill")
                                .font(DS.font(TypeScale.caption))
                                .foregroundStyle(SettingsTint.accent)
                        }
                    }
                } header: {
                    SettingLabel("Setup", info: "Everyday, Developer or Minimal turn widgets on or off and choose the four glances. You are asked before anything is turned off.")
                }
                Section("Getting started") {
                    LabeledContent {
                        Button("Start") { services.showOnboarding() }
                    } label: {
                        SettingLabel("Take the tour again",
                                     info: "Replays the first run: meet Platy, pick a setup, permissions, then try the notch. Nothing changes until you choose.")
                    }
                }
            }
            .settingsForm()
        }
        .onAppear(perform: readLogin)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Turn Off and Apply", role: .destructive) {
                if let p = pending { apply(p) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(verbatim: confirmMessage)
        }
    }

    @ViewBuilder private var updateRows: some View {
        let updater = services.updater
        if updater.isEnabled {
            Toggle(isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 })) {
                SettingLabel("Check for updates automatically")
            }
            .toggleStyle(.switch)
            LabeledContent {
                Button("Check Now") { updater.checkForUpdates() }
            } label: {
                Text(verbatim: "Version \(AppUpdater.versionDescription)")
            }
        } else {
            LabeledContent {
                SettingsLink("Releases", destination: UpdaterConfig.releasesURL)
            } label: {
                SettingLabel("Version \(AppUpdater.versionDescription)",
                             info: "This build does not update itself. New versions are on GitHub Releases.")
            }
        }
    }

    /// Applies `p`, asking first when it would turn anything off (spec 14).
    private func choose(_ p: SetupPreset) {
        if services.presetChange(p).needsConfirmation { pending = p } else { apply(p) }
    }

    private func apply(_ p: SetupPreset) {
        services.applyPreset(p)
        applied = p
        pending = nil
    }

    private var offTitles: [String] {
        guard let p = pending else { return [] }
        return services.presetChange(p).turnOff.compactMap { services.widgets.widget($0)?.title }
    }

    private var confirmTitle: String { "Turn off \(offTitles.count == 1 ? "1 widget" : "\(offTitles.count) widgets")?" }

    private var confirmMessage: String {
        "\(pending?.title ?? "") turns off \(offTitles.joined(separator: ", ")). You can turn them on again in Settings › Widgets."
    }

    private func readLogin() {
        let s = SMAppService.mainApp.status
        loginEnabled = s == .enabled
        loginNote = s == .requiresApproval ? "Allow PlatyNotch in System Settings › General › Login Items." : nil
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            readLogin()
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            let bundled = Bundle.main.bundleURL.pathExtension == "app"
            loginNote = bundled
                ? "Could not change the login item: \(error.localizedDescription)"
                : "Launch at login works only from the installed PlatyNotch.app (\(error.localizedDescription))."
        }
    }
}
