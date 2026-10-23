import PlatyNotchKit
import SwiftUI

/// Approvals on/off and how long an agent waits for a click.
struct ApprovalsSection: View {
    let config: ConfigFileStore

    var body: some View {
        let a = config.config.approvals
        SettingsPage("Approvals", subtitle: "Answer agents' permission prompts from the notch.") {
            Form {
                Toggle("Answer permission prompts in the notch", isOn: Binding(
                    get: { a.enabled }, set: { on in config.set { $0.approvals.enabled = on } }))
                Text("Per-agent switches are under Agents. With this off, agents ask in their own terminal as usual.")
                    .font(.caption).foregroundStyle(.secondary)

                Stepper(value: Binding(get: { a.timeoutSeconds },
                                       set: { v in config.set { $0.approvals.timeoutSeconds = v } }),
                        in: SettingsBounds.timeout, step: 5) {
                    LabeledContent("Wait for an answer", value: "\(a.timeoutSeconds) s")
                }
                .disabled(!a.enabled)
                Text("After this the agent falls back to asking in its terminal. At most \(ConfigFile.maxTimeoutSeconds) s: agents stop waiting for hooks after 120 s.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }
}
