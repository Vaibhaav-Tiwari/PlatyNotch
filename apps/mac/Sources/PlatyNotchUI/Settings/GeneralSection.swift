import PlatyNotchKit
import ServiceManagement
import SwiftUI

/// Settings › General: launch at login, updates, and the first run again.
struct GeneralSection: View {
    let services: SettingsServices
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

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
