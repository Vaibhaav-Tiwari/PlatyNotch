import PlatyNotchKit
import SwiftUI

/// The Note pad's behaviour. Its text is the widget's `draft`: saved as it is typed, kept
/// when the tool or the panel closes or the app quits, and cleared only after the line is
/// written. ↩ writes it through `QuickNote` (today's note, or the fallback file); a failed
/// write keeps the line and offers Retry.
@MainActor
final class NotePad {
    /// The pad keeps the keyboard after a note (a quick pad, not a form).
    let keepsFocus = true
    let notes: NotesWidget?
    /// Without a widget (previews): where a line goes; a message when it could not.
    let append: (String) -> String?
    private var localText = ""

    init(notes: NotesWidget?, append: @escaping (String) -> String?) {
        self.notes = notes
        self.append = append
    }

    var text: String {
        get { notes?.draft ?? localText }
        set { if let notes { notes.draft = newValue } else { localText = newValue } }
    }

    /// ↩: writes the line. True when a write started (the text clears once it lands).
    @discardableResult
    func submit() -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let notes {
            notes.addDraft()
            return true
        }
        if append(text) == nil { localText = "" }
        return true
    }
}

/// The Note tool (Island spec 4): a quick pad (↩ appends, keeps focus), today's five newest
/// entries, then the vault's open Obsidian tasks with their tick boxes (the old Notes tool's
/// ticking lives here: these tasks are lines in your notes, not Apple Reminders).
struct NoteTool: View {
    @Bindable var notes: NotesWidget
    @State private var token = NotesTileToken()
    @FocusState private var focused: Bool
    @Environment(\.panelTicking) private var shown

    static let empty = "Nothing noted today. Type above and press Return."
    static let tasksHeader = "OPEN TASKS"
    static let retry = "Retry"

    /// What it prints (tests): the entries (or the empty line), then the open tasks.
    static func texts(entries: [String], tasks: [MarkdownTask] = [], writeFailed: Bool = false) -> [String] {
        var out = entries.isEmpty ? [empty] : entries
        if writeFailed { out.append(retry) }
        if !tasks.isEmpty { out.append(tasksHeader); out += tasks.map(\.title) }
        return out
    }

    var body: some View {
        let pad = NotePad(notes: notes, append: { _ in nil })
        VStack(alignment: .leading, spacing: 10) {
            ToolField(symbol: "note.text", prompt: "Note something…", text: $notes.draft, focused: $focused,
                      trailing: notes.draft.isEmpty ? nil : "\u{21A9}") {
                pad.submit()
                if pad.keepsFocus { focused = true }
            }
            if let status = notes.status {
                HStack(spacing: 8) {
                    Text(verbatim: status).font(DS.font(TypeScale.caption))
                        .foregroundStyle(notes.writeFailed ? DS.color(.error) : DS.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if notes.writeFailed {
                        ModeChip(title: Self.retry, selected: false, compact: true) { notes.addDraft() }
                    }
                    if notes.pendingAsk != nil {
                        ModeChip(title: "Tick It", selected: false, compact: true) { notes.confirmAsk() }
                        ModeChip(title: "Cancel", selected: false, compact: true) { notes.cancelAsk() }
                    }
                }
                .padding(.horizontal, 4)
            }
            if notes.recentEntries.isEmpty {
                ToolEmptyLine(text: Self.empty)
            } else {
                caption("TODAY")
                ToolList(items: notes.recentEntries) { entry in
                    ToolRow(symbol: "text.alignleft", title: entry, detail: nil)
                }
            }
            if notes.vault != nil, !notes.tasks.isEmpty {
                caption(Self.tasksHeader).padding(.top, 4)
                ToolList(items: Array(notes.tasks.prefix(40))) { task in taskRow(task) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            notes.loadRecent()
            notes.tileAppeared(token, visible: shown)
            focused = true
        }
        .onDisappear {
            notes.flushDraft()   // closing the tool or the panel keeps the pad's text
            notes.tileDisappeared(token)
        }
        .onChange(of: shown) { notes.tileVisibility(token, visible: shown) }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(DS.font(TypeScale.caption)).tracking(0.6).foregroundStyle(DS.tertiary)
            .padding(.horizontal, 4)
    }

    private func taskRow(_ task: MarkdownTask) -> some View {
        HStack(spacing: 10) {
            if task.isRecurring {
                Image(systemName: "repeat")
                    .font(.system(size: IconSize.symbol))
                    .foregroundStyle(DS.tertiary)
                    .frame(width: 28, height: 28)
                    .help("Tick it in Obsidian")
            } else {
                Button { notes.toggle(task) } label: {
                    Image(systemName: "circle")
                        .font(.system(size: IconSize.header))
                        .foregroundStyle(DS.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(notes.writing.contains(task.id))
                .accessibilityLabel("Complete \(task.title)")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: task.title).font(DS.font(TypeScale.body)).foregroundStyle(DS.primary).lineLimit(1)
                Text(verbatim: NotesWidget.fileName(task.file)).font(DS.font(TypeScale.caption))
                    .foregroundStyle(DS.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let due = notes.dueText(task) {
                Text(verbatim: due).font(DS.font(TypeScale.caption))
                    .foregroundStyle(due == "Overdue" ? DS.color(.error) : DS.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}
