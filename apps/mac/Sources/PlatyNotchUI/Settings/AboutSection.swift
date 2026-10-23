import PlatyNotchKit
import SwiftUI

/// Version, updates and license.
struct AboutSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        SettingsPage("About") {
            Form {
                LabeledContent("Version") { Text(verbatim: AppUpdater.versionDescription).textSelection(.enabled) }
                if updater.isEnabled {
                    Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                    Button("Check for Updates…") { updater.checkForUpdates() }
                } else {
                    Text("Updates: download new versions from GitHub Releases")
                    Link("github.com/Vaibhaav-Tiwari/PlatyNotch/releases", destination: UpdaterConfig.releasesURL)
                }
                Text("PlatyNotch is open source under the Apache-2.0 license. The bundled mediaremote-adapter is BSD-3-Clause; Sparkle is MIT. License texts are in the app's Resources folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }
}
