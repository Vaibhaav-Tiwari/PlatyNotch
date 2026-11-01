import PlatyNotchKit
import ServiceManagement
import SwiftUI

/// Settings › General: launch at login, updates, and the first run again.
struct GeneralSection: View {
    let services: SettingsServices
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?
    /// A setup waiting for a yes.
    @State private var pending: SetupPreset?
    /// The card shown in the preview (nothing is applied until Apply).
    @State private var previewed: SetupPreset?
    /// Bumped after applying, so the "Current" badges are read again.
    @State private var revision = 0

    var body: some View {
        SettingsPage("General", subtitle: "Startup, updates and your setup.") {
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
                    HStack(spacing: 10) {
                        ForEach(SetupPreset.allCases, id: \.self) { p in
                            PresetCard(preset: p, selected: previewed == p, compact: true,
                                       current: services.presetPlan(p).isCurrent) { previewed = p }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .id(revision)
                    if let p = previewed {
                        PresetPreview(preset: p)
                            .padding(.vertical, 4)
                        HStack(alignment: .bottom) {
                            Text(verbatim: Self.changeList(services.presetPlan(p), title: services.presetTitle))
                                .font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Apply \(p.title)\u{2026}") { choose(p) }
                                .disabled(services.presetPlan(p).isCurrent)
                        }
                        .id(revision)
                    }
                    LabeledContent {
                        Button("Start") { services.showOnboarding() }
                    } label: {
                        SettingLabel("Take the tour again",
                                     info: "Replays the first run: meet Platy, pick a setup, permissions, then try the notch. Nothing changes until you confirm.")
                    }
                } header: {
                    SettingLabel("Setup", info: "Everyday, Developer or Minimal set the dock, what the pill shows first, the Agents tab, which widgets are on and whether the notch hides. Pick one to preview it; you see every change and confirm before it applies.")
                }
            }
            .settingsForm()
        }
        .onAppear {
            readLogin()
            // The setup in force shows its preview at once.
            if previewed == nil { previewed = SetupPreset.allCases.first { services.presetPlan($0).isCurrent } }
        }
        .onDisappear { PresetPreview.releaseCache() }
        .confirmationDialog("Apply \(pending?.title ?? "")?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Apply \(pending?.title ?? "")") {
                if let p = pending { apply(p) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(verbatim: pending.map { services.presetSummary(services.presetPlan($0)) } ?? "")
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
                Text(verbatim: AppUpdater.versionLine)
            }
        } else {
            LabeledContent {
                SettingsLink("Releases", destination: UpdaterConfig.releasesURL)
            } label: {
                SettingLabel(AppUpdater.versionLine,
                             info: "This build does not update itself. New versions are on GitHub Releases.")
            }
        }
    }

    /// Asks first, with every change listed (spec 14); a setup that is already current
    /// changes nothing.
    enum SetupAction: Equatable { case ask, alreadyCurrent }

    /// Under the preview: every change Apply would make (widgets turned on for the dock's
    /// tools included), or that the setup is current.
    static func changeList(_ plan: PresetPlan, title: (String) -> String) -> String {
        if plan.isCurrent { return "\(plan.preset.title) is your setup now." }
        return (plan.summary(title: title) + ["Nothing changes until you apply."]).joined(separator: "\n")
    }

    /// Settings never applies a setup straight away: it asks, or there is nothing to change.
    static func action(for plan: PresetPlan) -> SetupAction {
        plan.asks(firstRun: false) ? .ask : .alreadyCurrent
    }

    private func choose(_ p: SetupPreset) {
        if Self.action(for: services.presetPlan(p)) == .ask { pending = p }
    }

    private func apply(_ p: SetupPreset) {
        services.applyPreset(p)
        pending = nil
        revision += 1
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
