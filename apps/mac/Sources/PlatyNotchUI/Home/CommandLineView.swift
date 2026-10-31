import PlatyNotchKit
import SwiftUI

/// The command line's behaviour apart from drawing it: what the text suggests, which row is
/// chosen, and what Return does. Return runs the chosen row and never anything else:
/// nothing runs while typing, and nothing runs while an approval waits (the approval's own
/// keys, ⌘↩ and ⌘⌫, answer it; Return never does).
@MainActor
final class CommandLineLogic {
    static let approvalMessage = "Answer the approval first"

    private let model: PanelViewModel
    private let runner: CommandRunner
    private let tools: () -> [CommandTool]
    private let approvalsPending: () -> Bool
    private let clock: () -> Date
    private let calendar: Calendar

    init(model: PanelViewModel, runner: CommandRunner, tools: @escaping () -> [CommandTool] = { [] },
         approvalsPending: @escaping () -> Bool = { false }, clock: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.model = model
        self.runner = runner
        self.tools = tools
        self.approvalsPending = approvalsPending
        self.clock = clock
        self.calendar = calendar
    }

    var suggestions: [CommandSuggestion] {
        CommandParser.suggestions(for: model.commandText, tools: tools(), now: clock(), calendar: calendar)
    }

    /// The chosen row, kept inside the list.
    var selectedIndex: Int {
        let count = suggestions.count
        return count == 0 ? 0 : min(max(model.commandSelection, 0), count - 1)
    }

    func move(by delta: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        model.commandSelection = (selectedIndex + delta + count) % count
    }

    /// Return (or a click on row `index`): runs it. The message to show, if any.
    @discardableResult
    func submit(index: Int? = nil) -> String? {
        let rows = suggestions
        guard !rows.isEmpty else { return nil }
        let row = rows[min(max(index ?? selectedIndex, 0), rows.count - 1)]
        guard row.command != nil else {
            model.commandMessage = row.detail   // an explanation says why; it never runs
            return row.detail
        }
        if approvalsPending() {
            model.commandMessage = Self.approvalMessage
            return Self.approvalMessage
        }
        let message: String? = runner.run(row)
        if let message {
            model.commandMessage = message
        } else {
            model.commandMessage = Self.confirmation(row.command)
            model.commandText = ""
            model.commandSelection = 0
        }
        return message
    }

    /// A line for a command that ran quietly (a reminder, a note).
    static func confirmation(_ command: PanelCommand?) -> String? {
        switch command {
        case .remind: "Reminder added"
        case .note: "Note added"
        case .timer: "Timer started"
        case .focus: "Focus started"
        default: nil
        }
    }
}

/// The command line under Home's hairline (spec 3): a field with a ⌘K keycap and the
/// suggestions under it (top one chosen). ↑/↓ move, Return runs, a click runs. Esc is handled by
/// the controller (clear, then leave).
struct CommandLineView: View {
    let model: PanelViewModel
    let logic: CommandLineLogic
    let memory: MemoryServices?
    @FocusState private var focused: Bool

    static let placeholder = "Add a reminder, start a timer, search memory…"
    /// Memory hits listed under a `search` row.
    static let hitLimit = 5

    var body: some View {
        let rows = logic.suggestions
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("", text: Binding(get: { model.commandText }, set: { model.commandText = $0 }),
                          prompt: Text(verbatim: Self.placeholder).foregroundStyle(.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { logic.submit() }
                    .onKeyPress(.upArrow) { logic.move(by: -1); return .handled }
                    .onKeyPress(.downArrow) { logic.move(by: 1); return .handled }
                    .accessibilityLabel("Command line")
                Text(verbatim: "\u{2318}K")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if !rows.isEmpty {
                suggestionList(rows)
            } else if let message = model.commandMessage {
                Text(verbatim: message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.commandFocused) { _, new in if focused != new { focused = new } }
        .onChange(of: focused) { _, new in if model.commandFocused != new { model.commandFocused = new } }
        .onChange(of: model.commandText) { _, _ in
            model.commandSelection = 0
            model.commandMessage = nil
            searchIfNeeded()
        }
        .onAppear { if model.commandFocused { focused = true } }
    }

    private func suggestionList(_ rows: [CommandSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Button { logic.submit(index: index) } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: row.title)
                            .font(.system(size: 13))
                            .lineLimit(1).truncationMode(.tail)
                        if let detail = row.detail {
                            Text(verbatim: detail)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(index == logic.selectedIndex ? Color.white.opacity(0.07) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == logic.selectedIndex ? .isSelected : [])
                if case .search = row.command, let hits = memoryHits {
                    ForEach(hits, id: \.threadID) { hit in
                        Text(verbatim: hit.title)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.leading, 22)
                    }
                }
            }
            if let message = model.commandMessage {
                Text(verbatim: message).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
        }
    }

    /// Up to five memory hits for a `search` row (read-only; Return opens Memory with them).
    private var memoryHits: [MemoryHit]? {
        guard let memory, case .results(let hits) = memory.search.phase else { return nil }
        return Array(hits.prefix(Self.hitLimit))
    }

    /// Typing `search <query>` fills Memory's own query (a read, debounced); nothing else
    /// is sent, and nothing is run.
    private func searchIfNeeded() {
        guard let memory else { return }
        let text = model.commandText.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("search "), text.count > 7 else { return }
        memory.search.query = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
}
