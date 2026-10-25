import PlatyNotchKit
import SwiftUI

/// Approvals on/off and how long an agent waits for a click.
struct ApprovalsSection: View {
    let config: ConfigFileStore

    var body: some View {
        let a = config.config.approvals
        SettingsPage("Approvals", subtitle: "Answer agents' permission prompts from the notch.") {
            Form {
                Toggle(isOn: Binding(get: { a.enabled }, set: { on in config.set { $0.approvals.enabled = on } })) {
                    SettingLabel("Answer permission prompts in the notch",
                                 info: "Per-agent switches are under Agents. With this off, agents ask in their own terminal as usual.")
                }
                .toggleStyle(.switch)
                LabeledContent {
                    Stepper(value: Binding(get: { a.timeoutSeconds },
                                           set: { v in config.set { $0.approvals.timeoutSeconds = v } }),
                            in: SettingsBounds.timeout, step: 5) {
                        Text(verbatim: "\(a.timeoutSeconds) s").monospacedDigit()
                    }
                } label: {
                    SettingLabel("Wait for an answer",
                                 info: "After this the agent falls back to asking in its terminal. At most \(ConfigFile.maxTimeoutSeconds) s: agents stop waiting for hooks after 120 s.")
                }
                .disabled(!a.enabled)
            }
            .settingsForm()
        }
    }
}
