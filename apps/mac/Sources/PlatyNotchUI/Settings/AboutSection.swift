import PlatyNotchKit
import SwiftUI

/// Version and license (updates live in General).
struct AboutSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        SettingsPage("About") {
            HStack(spacing: 14) {
                PlatyView(mood: .idle, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PlatyNotch").font(.system(size: 17, weight: .semibold))
                    Text(verbatim: "Version \(AppUpdater.versionDescription)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
            Form {
                Section {
                    LabeledContent("License") { Text("Apache-2.0") }
                    LabeledContent("Source") {
                        SettingsLink("github.com/Vaibhaav-Tiwari/PlatyNotch",
                             destination: URL(string: "https://github.com/Vaibhaav-Tiwari/PlatyNotch")!)
                    }
                    LabeledContent("Releases") {
                        SettingsLink("GitHub Releases", destination: UpdaterConfig.releasesURL)
                    }
                } footer: {
                    Text("The bundled mediaremote-adapter is BSD-3-Clause and Sparkle is MIT. License texts are in the app's Resources folder.")
                        .font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                }
            }
            .settingsForm()
        }
    }
}
