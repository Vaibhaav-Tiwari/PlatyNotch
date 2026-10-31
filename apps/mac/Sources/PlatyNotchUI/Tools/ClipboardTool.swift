import AppKit
import PlatyNotchKit
import SwiftUI

/// What the Clipboard tool asks of the clipboard (the widget; a fake in tests).
@MainActor
protocol ClipboardPasting: AnyObject {
    @discardableResult func copy(_ item: ClipItem) -> Bool
    func paste(_ item: ClipItem, to target: PasteTarget?)
}

extension ClipboardWidget: ClipboardPasting {}

private struct ClosePanelKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// Closes the open panel (a tool that hands the keyboard back, like Clipboard's paste).
    var closePanel: @MainActor () -> Void {
        get { self[ClosePanelKey.self] }
        set { self[ClosePanelKey.self] = newValue }
    }
}

/// The Clipboard tool (Island spec 4): a search field over the history, rows with the kind's
/// symbol, the text and its age; ↑/↓ choose. ↩ (or a click) pastes the chosen row into the
/// app you were in, as the clipboard picker does: the panel closes, that app comes back and
/// gets ⌘V (with Accessibility; otherwise "Copied — press ⌘V"). ⌘↩ or the row's Copy only
/// copies. Anything that looks like a secret shows masked.
struct ClipboardTool: View {
    let clipboard: ClipboardWidget
    var fixedNow: Date?
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool
    @Environment(\.closePanel) private var closePanel

    /// The app to paste into: the frontmost one (the notch panel never activates PlatyNotch).
    static func frontmostTarget() -> PasteTarget? {
        NSWorkspace.shared.frontmostApplication.map { RunningAppTarget(app: $0) }
    }

    /// ↩ / a click: close the panel and paste into `target`. ⌘↩ / Copy: copy only, the panel stays.
    static func choose(_ item: ClipItem, copyOnly: Bool, clipboard: ClipboardPasting, target: PasteTarget?,
                       close: () -> Void) {
        if copyOnly {
            clipboard.copy(item)
            return
        }
        close()
        clipboard.paste(item, to: target)
    }

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
                pick(rows[selected], copyOnly: false)
            }
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command), selected < rows.count else { return .ignored }
                pick(rows[selected], copyOnly: true)
                return .handled
            }
            .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
            .onKeyPress(.downArrow) { selected = min(max(0, rows.count - 1), selected + 1); return .handled }
            .onChange(of: query) { _, _ in selected = 0 }
            if rows.isEmpty {
                ToolEmptyLine(text: clipboard.items.isEmpty ? Self.empty : "Nothing matches \u{201C}\(query)\u{201D}.")
            } else {
                ToolList(items: Array(rows.enumerated())) { pair in
                    Button { pick(pair.element, copyOnly: false) } label: {
                        ToolRow(symbol: Self.symbol(pair.element), icon: nil, title: Self.displayText(pair.element),
                                detail: WeatherFormat.age(since: pair.element.copiedAt, now: now),
                                selected: pair.offset == selected) {
                            if pair.element.pinned {
                                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(DS.tertiary)
                            }
                            if pair.offset == selected {
                                ModeChip(title: "Copy", selected: false, compact: true) { pick(pair.element, copyOnly: true) }
                                    .help("Copy only (\u{2318}\u{21A9})")
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

    private func pick(_ item: ClipItem, copyOnly: Bool) {
        Self.choose(item, copyOnly: copyOnly, clipboard: clipboard, target: Self.frontmostTarget(), close: closePanel)
    }
}
