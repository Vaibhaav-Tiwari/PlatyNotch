import PlatyNotchKit
import SwiftUI

/// Detected coding agents: hooks install/uninstall (through `notch hooks`), approvals
/// per agent, and Claude Code's status line. The app never edits agent configs itself.
struct AgentsSection: View {
    let services: SettingsServices

    var body: some View {
        let agents = services.agents
        SettingsPage("Agents", subtitle: "PlatyNotch listens to your coding agents through their hooks.") {
            AgentList(services: services, compact: false)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { agents.statuslineInstalled },
                        set: { on in
                            Task { await agents.run(on ? "Status line installed" : "Status line removed",
                                                    ["statusline", on ? "install" : "uninstall"]) }
                        })) {
                        Text("Claude Code status line")
                    }
                    .disabled(agents.busy)
                    Text("Shows Claude's 5-hour and weekly limits in the notch. Your own status line keeps running after ours.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button("Run diagnostics") { Task { await agents.run("notch doctor", ["doctor"]) } }
                    .disabled(agents.busy)
                Button("Refresh") { Task { await agents.refresh() } }
                    .disabled(agents.busy)
                if agents.busy { ProgressView().controlSize(.small) }
            }
            if let out = agents.lastOutput {
                CommandOutputView(output: out) { agents.clearOutput() }
            }
        }
        .task { await agents.refresh() }
    }
}

/// The agent rows, shared with onboarding (`compact` hides the approvals toggles).
struct AgentList: View {
    let services: SettingsServices
    let compact: Bool

    var body: some View {
        let agents = services.agents
        VStack(alignment: .leading, spacing: 0) {
            if let error = agents.loadError {
                InlineError(text: error)
            } else if !agents.loaded {
                ProgressView().controlSize(.small)
            } else if agents.rows.isEmpty {
                Text("No agents known to this core.").foregroundStyle(.secondary)
            }
            ForEach(sorted(agents.rows)) { row in
                AgentRow(row: row, services: services, compact: compact)
                Divider()
            }
        }
    }

    /// Detected agents first, then by name.
    private func sorted(_ rows: [AgentHookStatus]) -> [AgentHookStatus] {
        rows.sorted { ($0.detected ? 0 : 1, $0.name) < ($1.detected ? 0 : 1, $1.name) }
    }
}

private struct AgentRow: View {
    let row: AgentHookStatus
    let services: SettingsServices
    let compact: Bool

    var body: some View {
        let agents = services.agents
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: row.name).font(.body.weight(.medium))
                    if row.approvalsExperimental { Badge(text: "experimental") }
                }
                Text(verbatim: status).font(.caption).foregroundStyle(row.error == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .help(row.configPath)
            }
            Spacer(minLength: 8)
            if !compact, row.supportsApprovals, row.installed {
                Toggle("Approvals", isOn: approvalsBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(row.approvalsExperimental
                          ? "Experimental: this agent's permission hook is not fully verified."
                          : "Answer this agent's permission prompts from the notch.")
            }
            if row.installed {
                Button("Uninstall") { Task { await agents.run("\(row.name): hooks removed", ["hooks", "uninstall", row.id]) } }
                    .disabled(agents.busy)
            } else {
                Button("Install") { Task { await agents.run("\(row.name): hooks installed", ["hooks", "install", row.id]) } }
                    .disabled(agents.busy || !row.detected)
                    .help(row.detected ? "" : "\(row.name) was not found on this Mac.")
            }
        }
        .padding(.vertical, 6)
    }

    private var status: String {
        if let e = row.error { return "Error: \(e)" }
        if !row.detected { return "Not detected" }
        return row.installed ? "Hooks installed" : "Detected, hooks not installed"
    }

    private var approvalsBinding: Binding<Bool> {
        let config = services.config
        let id = row.id
        return Binding(
            get: { config.config.approvals.agents[id] ?? false },
            set: { on in config.set { $0.approvals.agents[id] = on } })
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
    }
}
