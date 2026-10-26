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
        SettingsPage("Policy", subtitle: "Rules run first, top to bottom; the first match wins.", systemImage: "list.bullet.rectangle") {
            Table($draft, selection: $selection) {
                TableColumn("Tool") { $rule in
                    TextField("Tool", text: $rule.tool).font(.system(.body, design: .monospaced))
                }
                .width(64)
                TableColumn("Pattern") { $rule in
                    TextField("Pattern", text: $rule.pattern).font(.system(.body, design: .monospaced))
                }
                .width(min: 110, ideal: 150)
                TableColumn("Action") { $rule in
                    Picker("Action", selection: $rule.action) {
                        ForEach(ConfigFile.Rule.actions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                .width(78)
                TableColumn("Reason") { $rule in
                    TextField("Reason", text: $rule.reason)
                }
                .width(min: 100)
            }
            .frame(minHeight: 180, idealHeight: 240)

            HStack(spacing: 5) {
                Text("Allow rules only auto-approve plain commands, paths and URLs.")
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                InfoButton(PolicyRuleCheck.allowNote + " " + PolicyRuleCheck.allowDetail
                           + " Patterns are globs: * matches anything, ? one character.")
            }

            ForEach(Array(draft.enumerated()), id: \.element.id) { i, rule in
                if let w = PolicyRuleCheck.warning(rule) {
                    Label { Text(verbatim: "Rule \(i + 1): \(w)") } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(DS.font(TypeScale.caption)).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                ControlGroup {
                    Button { add() } label: { Image(systemName: "plus") }
                        .help("Add a rule").accessibilityLabel("Add rule")
                    Button { remove() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil).help("Remove the selected rule").accessibilityLabel("Remove rule")
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }
                        .disabled(selection == nil).help("Move up").accessibilityLabel("Move rule up")
                    Button { move(1) } label: { Image(systemName: "arrow.down") }
                        .disabled(selection == nil).help("Move down").accessibilityLabel("Move rule down")
                }
                .fixedSize()
                Menu {
                    Button("Restore Default Rules") { draft = ConfigFile.defaultRules }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More")
                Spacer()
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
