import PlatyNotchKit
import SwiftUI

/// The Clipboard tool (Island spec 4): a search field over the history, rows with the kind's
/// symbol, the text and its age; ↑/↓ choose, ↩ copies and pastes the chosen row. Anything that
/// looks like a secret shows masked.
struct ClipboardTool: View {
    let clipboard: ClipboardWidget
    var fixedNow: Date?
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    static let maskedText = "•••••••• (looks like a secret)"
    static let empty = "Nothing copied yet. What you copy shows here."
    static let limit = 30

    /// Rows matching `query` (text, a link's address, a file's path, or the kind's name).
    static func filtered(_ items: [ClipItem], query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.searchText.localizedCaseInsensitiveContains(q) || kindWords($0).contains(q.lowercased()) }
    }

    static func kindWords(_ item: ClipItem) -> [String] {
        switch item.kind {
        case .text: ["text"]
        case .url: ["url", "link"]
        case .image: ["image", "picture"]
        case .files: ["file", "files"]
        }
    }

    static func symbol(_ item: ClipItem) -> String {
        switch item.kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .files: "doc"
        }
    }

    /// The row's text, masked when it looks like a secret.
    static func displayText(_ item: ClipItem) -> String {
        SecretText.containsSecret(item.searchText) ? maskedText : item.title
    }

    var body: some View {
        let rows = Array(Self.filtered(clipboard.items, query: query).prefix(Self.limit))
        let now: Date = fixedNow ?? Date()
        VStack(alignment: .leading, spacing: 10) {
            ToolField(symbol: "magnifyingglass", prompt: "Search what you copied", text: $query, focused: $focused,
                      trailing: rows.isEmpty ? nil : "\u{21A9}") {
                guard selected < rows.count else { return }
                clipboard.paste(rows[selected], to: nil)
            }
            .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
            .onKeyPress(.downArrow) { selected = min(max(0, rows.count - 1), selected + 1); return .handled }
            .onChange(of: query) { _, _ in selected = 0 }
            if rows.isEmpty {
                ToolEmptyLine(text: clipboard.items.isEmpty ? Self.empty : "Nothing matches \u{201C}\(query)\u{201D}.")
            } else {
                ToolList(items: Array(rows.enumerated())) { pair in
                    Button { clipboard.paste(pair.element, to: nil) } label: {
                        ToolRow(symbol: Self.symbol(pair.element), icon: nil, title: Self.displayText(pair.element),
                                detail: WeatherFormat.age(since: pair.element.copiedAt, now: now),
                                selected: pair.offset == selected) {
                            if pair.element.pinned {
                                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(DS.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { focused = true }
    }
}
