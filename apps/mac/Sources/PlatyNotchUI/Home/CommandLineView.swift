import AppKit
import PlatyNotchKit
import SwiftUI

/// One row under the command line: a parsed suggestion, or an entry from the list of
/// everything the command line can do (`CommandCatalog`).
enum CommandRow: Equatable {
    case suggestion(CommandSuggestion)
    case entry(CommandCatalog.Entry)

    var entry: CommandCatalog.Entry? {
        if case .entry(let e) = self { return e }
        return nil
    }

    var title: String {
        switch self {
        case .suggestion(let s): s.title
        case .entry(let e): e.title
        }
    }
}

/// The command line's behaviour apart from drawing it: what the text suggests, which row is
/// chosen, and what Return does. Return runs the chosen row and never anything else:
/// nothing runs while typing, and nothing runs while an approval waits (the approval's own
/// keys, ⌘↩ and ⌘⌫, answer it; Return never does). Focused and empty, it lists everything it
/// can do; typing filters that list under the parsed suggestions.
@MainActor
final class CommandLineLogic {
    static let approvalMessage = "Answer the approval first"

    private let model: PanelViewModel
    private let runner: CommandRunner
    private let tools: () -> [CommandTool]
    private let catalog: () -> [CommandCatalog.Entry]
    private let approvalsPending: () -> Bool
    private let clock: () -> Date
    private let calendar: Calendar

    init(model: PanelViewModel, runner: CommandRunner, tools: @escaping () -> [CommandTool] = { [] },
         catalog: @escaping () -> [CommandCatalog.Entry] = { [] },
         approvalsPending: @escaping () -> Bool = { false }, clock: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.model = model
        self.runner = runner
        self.tools = tools
        self.catalog = catalog
        self.approvalsPending = approvalsPending
        self.clock = clock
        self.calendar = calendar
    }

    var suggestions: [CommandSuggestion] {
        CommandParser.suggestions(for: model.commandText, tools: tools(), now: clock(), calendar: calendar)
    }

    /// The list shows (focused, nothing typed).
    var listsEverything: Bool {
        model.commandActive && model.commandText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The rows in order: the whole list while focused and empty; else the parsed
    /// suggestions, then the list's matches that no suggestion already offers.
    var rows: [CommandRow] {
        let text: String = model.commandText
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.commandActive ? catalog().map { .entry($0) } : []
        }
        let parsed: [CommandSuggestion] = suggestions
        let opened: Set<String> = Set(parsed.compactMap { s -> String? in
            if case .open(let tool)? = s.command { return tool }
            return nil
        })
        let matches = CommandCatalog.filter(catalog(), query: text).filter { e in
            if case .open(let tool) = e.action { return !opened.contains(tool) }
            return true
        }
        return parsed.map { .suggestion($0) } + matches.map { .entry($0) }
    }

    /// The chosen row, kept inside the list.
    var selectedIndex: Int {
        let count = rows.count
        return count == 0 ? 0 : min(max(model.commandSelection, 0), count - 1)
    }

    func move(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        model.commandSelection = (selectedIndex + delta + count) % count
    }

    /// Return (or a click on row `index`): runs it. The message to show, if any.
    @discardableResult
    func submit(index: Int? = nil) -> String? {
        let all = rows
        guard !all.isEmpty else { return nil }
        switch all[min(max(index ?? selectedIndex, 0), all.count - 1)] {
        case .suggestion(let row): return run(row)
        case .entry(let entry): return run(entry)
        }
    }

    private func run(_ row: CommandSuggestion) -> String? {
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
            model.commandActive = false   // done: Home comes back, the confirmation under the line
        }
        return message
    }

    private func run(_ entry: CommandCatalog.Entry) -> String? {
        if case .fill(let start) = entry.action {
            model.commandText = start
            model.commandSelection = 0
            return nil
        }
        if approvalsPending() {
            model.commandMessage = Self.approvalMessage
            return Self.approvalMessage
        }
        runner.perform(entry.action)
        model.commandText = ""
        model.commandSelection = 0
        model.commandActive = false
        return nil
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

/// The command line under Home's hairline (spec 3): a field with the global shortcut's
/// keycap and the rows under it (top one chosen). Focused and empty, the rows are everything
/// it can do, grouped Do / Open / Toggle. ↑/↓ move, Return runs, a click runs. Esc is
/// handled by the controller (clear, then leave). A click in the field gives the panel the
/// keyboard and focuses it on the first click.
struct CommandLineView: View {
    let model: PanelViewModel
    let logic: CommandLineLogic
    let memory: MemoryServices?
    @FocusState private var focused: Bool
    @State private var windowBox = WindowBox()

    /// "Type a command, or ⌥⌘K from anywhere" (just "Type a command" without a global shortcut).
    static func placeholder(hint: String) -> String {
        hint == "\u{2318}K" ? "Type a command" : "Type a command, or \(hint) from anywhere"
    }

    /// Shown under the line on the first three opens after the upgrade.
    static func upgradeHint(_ hint: String) -> String {
        "Everything Platy can do is here. Press \(hint) anytime."
    }

    /// Memory hits listed under a `search` row.
    static let hitLimit = 5
    /// The most height the suggestions take beside Home's columns before they scroll: Home
    /// with everything live (chips, music, three Up next rows) still fits the 380 pt panel.
    static let listMaxHeight: CGFloat = 76
    /// With the line focused Home's columns step aside and the rows get this much, inside the
    /// 380 pt panel with the chips above.
    static let focusedListMaxHeight: CGFloat = 196

    /// A click anywhere in the field: the panel takes the keyboard and the field focus.
    static func fieldClicked(_ model: PanelViewModel) {
        model.requestKey()
        model.commandFocused = true
        model.commandActive = true
    }

    var body: some View {
        let rows = logic.rows
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(DS.font(TypeScale.body))
                    .foregroundStyle(DS.tertiary)
                    .accessibilityHidden(true)
                TextField("", text: Binding(get: { model.commandText }, set: { model.commandText = $0 }),
                          prompt: Text(verbatim: Self.placeholder(hint: model.commandHint)).foregroundStyle(DS.tertiary))
                    .textFieldStyle(.plain)
                    .font(DS.font(TypeScale.body))
                    .focused($focused)
                    .onSubmit { logic.submit() }
                    .onKeyPress(.upArrow) { logic.move(by: -1); return .handled }
                    .onKeyPress(.downArrow) { logic.move(by: 1); return .handled }
                    .accessibilityLabel("Command line")
                    .background(CaretWindowReader(box: windowBox))
                Keycap(text: model.commandText.isEmpty ? model.commandHint : "\u{21A9}")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { Self.fieldClicked(model) })
            if !rows.isEmpty {
                // Results take the room Home has left, then scroll inside it (spec 2).
                let selected: Int = logic.selectedIndex
                ViewThatFits(in: .vertical) {
                    rowList(rows, selected: selected)
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) { rowList(rows, selected: selected) }
                            .onChange(of: selected) { _, new in proxy.scrollTo(new) }
                            // The last rows fade out: more is below, scroll for it.
                            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                         .init(color: .black, location: 0.86),
                                                         .init(color: .black.opacity(0.15), location: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                }
                .frame(maxHeight: model.commandActive ? Self.focusedListMaxHeight : Self.listMaxHeight)
            } else if let message = model.commandMessage {
                Text(verbatim: message).font(DS.font(TypeScale.secondary)).foregroundStyle(DS.secondary)
            } else if model.showCommandHint, !model.commandActive {
                Text(verbatim: Self.upgradeHint(model.commandHint))
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(DS.tertiary)
                    .lineLimit(1)
            }
        }
        .onChange(of: model.commandFocused) { _, new in if focused != new { focused = new } }
        .onChange(of: focused) { _, new in
            if model.commandFocused != new { model.commandFocused = new }
            if !new, model.commandActive, model.commandText.isEmpty { model.commandActive = false }
            if new { Self.caretToEnd(in: windowBox) }
        }
        .onChange(of: model.commandText) { _, new in
            model.commandSelection = 0
            // A command that ran empties the line: its confirmation ("Reminder added") stays
            // until the user types again.
            if !new.isEmpty { model.commandMessage = nil }
            searchIfNeeded()
        }
        .onAppear { if model.commandFocused { focused = true } }
    }

    /// A field that takes focus selects its text; the next key would then replace the first
    /// character the user typed to start the line. Puts the caret after the text instead.
    static func caretToEnd(in box: WindowBox) {
        DispatchQueue.main.async {
            guard let editor = box.window?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private func rowList(_ rows: [CommandRow], selected: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if let header = groupHeader(rows, at: index) {
                    ColumnLabel(text: header)
                        .padding(.horizontal, 10)
                        .padding(.top, index == 0 ? 2 : 6)
                }
                Button { logic.submit(index: index) } label: {
                    rowLabel(row, selected: index == selected)
                }
                .buttonStyle(.plain)
                .id(index)
                .accessibilityAddTraits(index == selected ? .isSelected : [])
                if case .suggestion(let s) = row, case .search = s.command, let hits = memoryHits {
                    ForEach(hits, id: \.threadID) { hit in
                        Text(verbatim: hit.title)
                            .font(DS.font(TypeScale.secondary)).foregroundStyle(DS.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.leading, 22)
                    }
                }
            }
            if let message = model.commandMessage {
                Text(verbatim: message).font(DS.font(TypeScale.secondary)).foregroundStyle(DS.secondary).padding(.horizontal, 10)
            }
        }
    }

    /// The group label before a list row that starts a group, while the whole list shows.
    private func groupHeader(_ rows: [CommandRow], at index: Int) -> String? {
        guard logic.listsEverything, let entry = rows[index].entry else { return nil }
        if index > 0, rows[index - 1].entry?.group == entry.group { return nil }
        return entry.group.title
    }

    @ViewBuilder private func rowLabel(_ row: CommandRow, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch row {
            case .suggestion(let s):
                Text(verbatim: s.title)
                    .font(DS.font(TypeScale.body))
                    .foregroundStyle(DS.primary)
                    .lineLimit(1).truncationMode(.tail)
                if let detail = s.detail {
                    Text(verbatim: detail)
                        .font(DS.font(TypeScale.secondary)).foregroundStyle(DS.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            case .entry(let e):
                Image(systemName: e.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(verbatim: e.title)
                    .font(DS.font(TypeScale.body))
                    .foregroundStyle(DS.primary)
                    .lineLimit(1)
                    // One column for the names, so the hints line up.
                    .frame(width: 124, alignment: .leading)
                Text(verbatim: e.hint)
                    .font(DS.font(TypeScale.secondary))
                    .foregroundStyle(DS.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if let shortcut = e.shortcut {
                    Text(verbatim: shortcut)
                        .font(DS.font(TypeScale.caption, design: .monospaced))
                        .foregroundStyle(DS.tertiary)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(selected ? DS.fill : .clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .contentShape(Rectangle())
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

/// The window a view sits in, for the caret fix.
final class WindowBox {
    weak var window: NSWindow?
}

private struct CaretWindowReader: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in box.window = v?.window }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { [weak v] in box.window = v?.window }
    }
}
