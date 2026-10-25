import AppKit
import PlatyNotchKit
import SwiftUI
import UniformTypeIdentifiers

/// Memory: capture on/off, interval, retention, excluded apps, AI providers (API keys
/// go to the Keychain), and MCP install for agents. Edited as a draft and saved
/// together, because saving restarts the core (memory is opened at startup).
struct MemorySection: View {
    let services: SettingsServices
    @State private var draft = ConfigFile.Memory()
    @State private var base = ConfigFile.Memory()
    @State private var error: String?
    @State private var selectedApp: String?

    private var config: ConfigFileStore { services.config }

    var body: some View {
        SettingsPage("Memory", subtitle: "PlatyNotch can remember text from the windows you work in, so you and your agents can search it.") {
            Form {
                Section {
                    Toggle(isOn: $draft.enabled) { SettingLabel("Remember on-screen text", info: storageNote) }
                        .toggleStyle(.switch)
                    if draft.enabled, !services.permissions.accessibility {
                        HStack {
                            Label("Capture needs Accessibility access.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Allow…") { services.permissions.requestAccessibility() }
                        }
                        .font(.callout)
                    }
                    Stepper(value: $draft.captureIntervalSeconds, in: SettingsBounds.captureInterval, step: 5) {
                        LabeledContent("Capture every", value: "\(draft.captureIntervalSeconds) s")
                    }
                    Stepper(value: $draft.retentionDays, in: SettingsBounds.retentionDays, step: 15) {
                        LabeledContent("Keep for", value: "\(draft.retentionDays) days")
                    }
                }
                Section("Never capture these apps") {
                    excludedApps
                }
                Section("Search embeddings") {
                    ProviderEditor(provider: $draft.embedder, savedRef: config.config.memory.embedder.apiKeyRef,
                                   services: services, role: "embedder",
                                   explanation: "Finds related text by meaning. None uses keyword search only.")
                }
                Section("Open-loop extraction") {
                    ProviderEditor(provider: $draft.extractor, savedRef: config.config.memory.extractor.apiKeyRef,
                                   services: services, role: "extractor",
                                   explanation: "Spots promises and requests in what you read and write. None turns open loops off.")
                }
            }
            .settingsForm()

            HStack {
                if !services.store.approvals.isEmpty, draft != base {
                    CoreRestartWarningLabel(action: "Saving")
                }
                Spacer()
                Button("Revert") { load() }.disabled(draft == base)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft == base)
            }
            InlineError(text: error)

            GroupBox("Let agents search your memory (MCP)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Adds PlatyNotch's memory search as an MCP server. Runs `notch mcp install`.")
                        .font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                    HStack {
                        ForEach([("claude-desktop", "Claude Desktop"), ("claude-code", "Claude Code"), ("cursor", "Cursor")], id: \.0) { id, name in
                            Button(name) { Task { await services.agents.run("MCP: \(name)", ["mcp", "install", id]) } }
                                .disabled(services.agents.busy)
                        }
                    }
                    if let out = services.agents.lastOutput {
                        CommandOutputView(output: out) { services.agents.clearOutput() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        .onAppear {
            load()
            services.permissions.refresh()
        }
        .onChange(of: config.config.memory) { _, new in
            if draft == base { draft = new; base = new }
        }
    }

    private var storageNote: String {
        "Text stays on this Mac in \(CorePaths.memoryDB().path). Password managers, private browser windows, password fields and the lock screen are never captured. A cloud provider below receives the text it processes."
    }

    @ViewBuilder private var excludedApps: some View {
        List(selection: $selectedApp) {
            ForEach(draft.excludeApps, id: \.self) { id in
                HStack {
                    Text(verbatim: Self.appName(id))
                    Spacer()
                    Text(verbatim: id).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                }
                .tag(id)
            }
        }
        .frame(minHeight: 110)
        HStack {
            Button { pickApp() } label: { Label("Add app…", systemImage: "plus") }
            Button { draft.excludeApps.removeAll { $0 == selectedApp }; selectedApp = nil } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selectedApp == nil)
            Spacer()
            Button("Restore defaults") {
                for id in CaptureSettings.defaultExcludeApps where !draft.excludeApps.contains(id) {
                    draft.excludeApps.append(id)
                }
            }
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !draft.excludeApps.contains(id) else { continue }
            draft.excludeApps.append(id)
        }
    }

    private func load() {
        draft = config.config.memory
        base = draft
        error = nil
    }

    private func save() {
        let (b, d) = (base, draft)
        do {
            try config.update { $0.memory = ConfigFile.Memory.merge(base: b, edited: d, into: $0.memory) }
            load()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// "<action> restarts the core: pending approvals go back to the agent's terminal."
/// Shown wherever a change restarts the core while approvals are pending.
struct CoreRestartWarningLabel: View {
    let action: String

    var body: some View {
        Label(CoreRestartWarning.text(action: action), systemImage: "exclamationmark.triangle")
            .font(DS.font(TypeScale.caption)).foregroundStyle(.orange)
    }
}

/// Provider name, model, base URL and API key (saved to the Keychain on "Save key").
/// Replacing the key of a provider config.json already uses leaves the config unchanged,
/// so "Save key" itself restarts the core (secrets reach it only at launch).
private struct ProviderEditor: View {
    @Binding var provider: ConfigFile.Provider
    /// This provider's `api_key_ref` as saved in config.json (not the draft).
    let savedRef: String
    let services: SettingsServices
    /// "embedder" or "extractor": each role has its own Keychain account.
    let role: String
    let explanation: String
    @State private var key = ""
    @State private var keyNote: String?

    var body: some View {
        Picker("Provider", selection: $provider.name) {
            ForEach(names, id: \.self) { Text(Self.label($0)).tag($0) }
        }
        Text(explanation).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
        if provider.name != "none" {
            TextField("Model", text: $provider.model, prompt: Text(modelPrompt))
            TextField("Base URL", text: $provider.baseURL, prompt: Text(urlPrompt))
            if provider.name != "ollama" {
                HStack {
                    SecureField("API key", text: $key, prompt: Text(keyPrompt))
                    Button("Save key") { saveKey() }.disabled(key.isEmpty)
                }
                if !key.isEmpty, effect.warnsAboutApprovals(pending: services.store.approvals.count) {
                    CoreRestartWarningLabel(action: "Saving the key")
                }
                if let keyNote { Text(verbatim: keyNote).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary) }
            }
        }
        EmptyView()
            .onChange(of: provider.name) { _, _ in
                // A key saved for another provider must not follow to the new one's host.
                if let a = SecretRef.keychainAccount(provider.apiKeyRef), a != account { provider.apiKeyRef = "" }
                keyNote = nil
            }
    }

    /// Built-in names plus whatever the file has (e.g. a Pro provider).
    private var names: [String] {
        ConfigFile.Provider.builtIn.contains(provider.name) ? ConfigFile.Provider.builtIn
            : ConfigFile.Provider.builtIn + [provider.name]
    }

    static func label(_ name: String) -> String {
        switch name {
        case "none": "None"
        case "ollama": "Ollama (on this Mac)"
        case "openai": "OpenAI-compatible"
        default: name
        }
    }

    private var modelPrompt: String {
        provider.name == "ollama" ? "e.g. nomic-embed-text" : "e.g. text-embedding-3-small"
    }

    private var urlPrompt: String {
        provider.name == "ollama" ? "http://localhost:11434" : "https://api.openai.com/v1"
    }

    private var account: String { SecretRef.account(purpose: role, provider: provider.name) }

    private var keyPrompt: String {
        if let a = SecretRef.keychainAccount(provider.apiKeyRef), Keychain.exists(account: a) { return "Saved in Keychain" }
        if provider.apiKeyRef.hasPrefix("env:") { return "From \(provider.apiKeyRef.dropFirst(4))" }
        return "Stored in your Keychain"
    }

    /// What saving the key now would take before the core uses it.
    private var effect: KeySaveEffect {
        KeySaveEffect.after(savedRef: savedRef, newRef: SecretRef.keychain(account))
    }

    private func saveKey() {
        do {
            let ref = try Keychain.save(key, account: account)
            let effect = KeySaveEffect.after(savedRef: savedRef, newRef: ref)
            provider.apiKeyRef = ref
            key = ""
            keyNote = effect.note(account: account)
            if effect == .restartCore { services.restartCore() }
        } catch {
            keyNote = "Could not save the key: \(error)"
        }
    }
}
