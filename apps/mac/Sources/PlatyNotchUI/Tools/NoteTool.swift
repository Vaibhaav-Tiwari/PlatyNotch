import PlatyNotchKit
import SwiftUI

/// The Note pad's behaviour: ↩ appends the line through `QuickNote` (today's note, or the
/// fallback file), clears it and keeps the focus for the next note.
@MainActor @Observable
final class NotePad {
    var text = ""
    /// The pad keeps the keyboard after a note (a quick pad, not a form).
    let keepsFocus = true
    @ObservationIgnored let notes: NotesWidget?
    /// Appends a line; a message when nothing was started.
    @ObservationIgnored let append: (String) -> String?
    private(set) var message: String?

    init(notes: NotesWidget?, append: @escaping (String) -> String?) {
        self.notes = notes
        self.append = append
    }

    @discardableResult
    func submit() -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        message = append(line)
        if message == nil { text = "" }
        return message == nil
    }
}

/// The Note tool (Island spec 4): a quick pad (↩ appends, clears, keeps focus), then the five
/// newest entries of today's note.
struct NoteTool: View {
    let notes: NotesWidget
    @State private var pad: NotePad
    @FocusState private var focused: Bool

    static let empty = "Nothing noted today. Type above and press Return."

    init(notes: NotesWidget) {
        self.notes = notes
        _pad = State(initialValue: NotePad(notes: notes, append: { [weak notes] in notes?.appendNote($0) }))
    }

    static func texts(entries: [String]) -> [String] {
        entries.isEmpty ? [empty] : entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolField(symbol: "note.text", prompt: "Note something…", text: $pad.text, focused: $focused,
                      trailing: pad.text.isEmpty ? nil : "\u{21A9}") {
                pad.submit()
                if pad.keepsFocus { focused = true }
            }
            if let status = pad.message ?? notes.status {
                Text(verbatim: status).font(DS.font(TypeScale.caption)).foregroundStyle(DS.tertiary)
                    .padding(.horizontal, 4)
            }
            if notes.recentEntries.isEmpty {
                ToolEmptyLine(text: Self.empty)
            } else {
                Text(verbatim: "TODAY")
                    .font(DS.font(TypeScale.caption)).tracking(0.6).foregroundStyle(DS.tertiary)
                    .padding(.horizontal, 4)
                ToolList(items: notes.recentEntries) { entry in
                    ToolRow(symbol: "text.alignleft", title: entry, detail: nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            notes.loadRecent()
            focused = true
        }
    }
}
