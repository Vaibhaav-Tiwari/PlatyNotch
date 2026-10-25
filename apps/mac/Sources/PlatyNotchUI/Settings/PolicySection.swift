import PlatyNotchKit
import SwiftUI

/// Local policy rules (tool, pattern, action, reason), checked by the core before a
/// prompt is shown. Edited as a draft and saved together. There is deliberately no
/// one-click "always allow": allow rules apply only to plain commands, paths and URLs.
struct PolicySection: View {
    let config: ConfigFileStore
    @State private var draft: [ConfigFile.Rule] = []
    @State private var base: [ConfigFile.Rule] = []
    @State private var selection: ConfigFile.Rule.ID?
    @State private var error: String?

    var body: some View {
        SettingsPage("Policy", subtitle: "Rules run first, top to bottom; the first match wins. Patterns are globs: * matches anything, ? one character.") {
            Table($draft, selection: $selection) {
                TableColumn("Tool") { $rule in
                    TextField("Tool", text: $rule.tool).font(.system(.body, design: .monospaced))
                }
                .width(min: 70, ideal: 90)
                TableColumn("Pattern") { $rule in
                    TextField("Pattern", text: $rule.pattern).font(.system(.body, design: .monospaced))
                }
                .width(min: 140, ideal: 200)
                TableColumn("Action") { $rule in
                    Picker("Action", selection: $rule.action) {
                        ForEach(ConfigFile.Rule.actions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                .width(min: 70, ideal: 80)
                TableColumn("Reason") { $rule in
                    TextField("Reason", text: $rule.reason)
                }
                .width(min: 120, ideal: 200)
            }
            .frame(minHeight: 180, idealHeight: 240)

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PolicyRuleCheck.allowNote)
                    Text(PolicyRuleCheck.allowDetail).font(DS.font(TypeScale.caption))
                }
            } icon: { Image(systemName: "info.circle") }
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(Array(draft.enumerated()), id: \.element.id) { i, rule in
                if let w = PolicyRuleCheck.warning(rule) {
                    Label { Text(verbatim: "Rule \(i + 1): \(w)") } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(DS.font(TypeScale.caption)).foregroundStyle(.orange)
                }
            }

            HStack {
                Button { add() } label: { Label("Add rule", systemImage: "plus") }
                Button { remove() } label: { Label("Remove", systemImage: "minus") }
                    .disabled(selection == nil)
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .disabled(selection == nil).help("Move up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .disabled(selection == nil).help("Move down")
                Spacer()
                Button("Restore defaults") { draft = ConfigFile.defaultRules }
                Button("Revert") { load() }.disabled(draft == base)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft == base)
            }
            InlineError(text: error)
        }
        .onAppear(perform: load)
        .onChange(of: config.config.policy) { _, new in
            // Changed on disk while not editing: follow it.
            if draft == base { draft = new.rules; base = new.rules }
        }
    }

    private func load() {
        draft = config.config.policy.rules
        base = draft
        error = nil
    }

    private func add() {
        // New rules ask; allow must be chosen explicitly.
        let r = ConfigFile.Rule(tool: "Bash", pattern: "", action: "ask")
        draft.append(r)
        selection = r.id
    }

    private func remove() {
        draft.removeAll { $0.id == selection }
        selection = nil
    }

    private func move(_ by: Int) {
        guard let i = draft.firstIndex(where: { $0.id == selection }) else { return }
        let j = i + by
        guard draft.indices.contains(j) else { return }
        draft.swapAt(i, j)
    }

    private func save() {
        let rules = draft.map { r -> ConfigFile.Rule in
            var r = r
            r.tool = r.tool.trimmingCharacters(in: .whitespaces)
            r.reason = r.reason.trimmingCharacters(in: .whitespaces)
            return r
        }
        if let problem = PolicyRuleCheck.validate(rules) { error = problem; return }
        do {
            try config.update { $0.policy.rules = rules }
            draft = rules
            base = rules
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }
}
