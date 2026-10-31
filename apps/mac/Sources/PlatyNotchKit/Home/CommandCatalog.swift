import Foundation

/// Everything the command line can do, listed while it is focused and empty (user feedback:
/// with the Library gone nothing showed the features), like Spotlight or Raycast with no
/// query. Grouped Do / Open / Toggle; each row has a monochrome symbol, a name, a short hint
/// and a shortcut where one exists.
public enum CommandCatalog {
    public enum Group: String, CaseIterable, Sendable {
        case `do`, open, toggle

        public var title: String {
            switch self {
            case .do: "Do"
            case .open: "Open"
            case .toggle: "Toggle"
            }
        }
    }

    /// What choosing a row does.
    public enum Action: Equatable, Sendable {
        /// Puts the command's start in the field, ready for its argument ("timer ").
        case fill(String)
        /// Opens a tool inside the panel.
        case open(tool: String)
        case toggleKeepAwake
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        public let group: Group
        public let title: String
        public let symbol: String
        public let hint: String
        public let shortcut: String?
        public let action: Action
    }

    /// Mirror turns its own widget on when opened; the other tools need theirs on.
    static let alwaysAvailable: Set<String> = ["mirror", "memory"]

    /// The rows, in order. `tools`: the tool ids available now; `shortcuts`: tool id → its
    /// global shortcut ("⌥⇧V").
    public static func entries(tools: Set<String>, shortcuts: [String: String]) -> [Entry] {
        var out: [Entry] = [
            Entry(id: "do.timer", group: .do, title: "Timer", symbol: "timer", hint: "timer 10m", shortcut: nil,
                  action: .fill("timer ")),
            Entry(id: "do.focus", group: .do, title: "Focus", symbol: "scope", hint: "focus 25", shortcut: nil,
                  action: .fill("focus ")),
            Entry(id: "do.remind", group: .do, title: "Remind", symbol: "checklist", hint: "remind call Priya at 5pm",
                  shortcut: nil, action: .fill("remind ")),
            Entry(id: "do.note", group: .do, title: "Note", symbol: "note.text", hint: "note buy milk", shortcut: nil,
                  action: .fill("note ")),
        ]
        let opens: [(String, String, String, String)] = [
            ("clipboard", "Clipboard", "doc.on.clipboard", "what you copied"),
            ("shelf", "Shelf", "tray", "files you kept"),
            ("baskets", "Baskets", "basket", "floating file baskets"),
            ("mirror", "Mirror", "video", "a quick look at yourself"),
            ("memory", "Memory", "brain", "search what you saw"),
            ("launch", "Sites & Shortcuts", "safari", "pinned sites and Shortcuts"),
            ("games", "Games", "gamecontroller", "Snake, Tetris, 2048, Flappy, Chase"),
        ]
        for (tool, title, symbol, hint) in opens where tools.contains(tool) || alwaysAvailable.contains(tool) {
            out.append(Entry(id: "open." + tool, group: .open, title: title, symbol: symbol, hint: hint,
                             shortcut: shortcuts[tool], action: .open(tool: tool)))
        }
        out.append(Entry(id: "toggle.keepAwake", group: .toggle, title: "Keep awake", symbol: "cup.and.saucer",
                         hint: "stop the Mac from sleeping", shortcut: nil, action: .toggleKeepAwake))
        return out
    }

    /// The rows whose title (any word) starts with `query`, or whose hint does; all rows for
    /// an empty query. Case-insensitive.
    public static func filter(_ entries: [Entry], query: String) -> [Entry] {
        let q: String = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { e in
            let words: [Substring] = e.title.lowercased().split(whereSeparator: { $0 == " " })
            return words.contains { $0.hasPrefix(q) } || e.hint.lowercased().hasPrefix(q)
        }
    }

    // MARK: - The upgrade hint

    /// Opens counted for the one-line hint under the command line.
    public static let hintCountKey = "commandLine.hintShown"
    public static let hintOpens = 3

    /// The hint shows on the first three opens of the panel after the upgrade.
    public static func showsHint(_ defaults: UserDefaults) -> Bool {
        defaults.integer(forKey: hintCountKey) < hintOpens
    }

    /// Counts one open (stops at three).
    public static func notePanelOpened(_ defaults: UserDefaults) {
        let n: Int = defaults.integer(forKey: hintCountKey)
        if n < hintOpens { defaults.set(n + 1, forKey: hintCountKey) }
    }
}
