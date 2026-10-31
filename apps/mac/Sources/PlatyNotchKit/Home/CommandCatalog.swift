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
        /// Other names the command line finds this by ("play" for Games).
        public let aliases: [String]
    }

    /// Mirror turns its own widget on when opened; the other tools need theirs on.
    static let alwaysAvailable: Set<String> = ["mirror", "memory"]

    /// The rows, in order. `tools`: the tool ids available now; `shortcuts`: tool id → its
    /// global shortcut ("⌥⇧V").
    public static func entries(tools: Set<String>, shortcuts: [String: String]) -> [Entry] {
        var out: [Entry] = [
            Entry(id: "do.timer", group: .do, title: "Timer", symbol: "timer", hint: "timer 10m", shortcut: nil,
                  action: .fill("timer "), aliases: ["countdown", "alarm"]),
            Entry(id: "do.focus", group: .do, title: "Focus", symbol: "scope", hint: "focus 25", shortcut: nil,
                  action: .fill("focus "), aliases: ["pomodoro", "concentrate"]),
            Entry(id: "do.remind", group: .do, title: "Remind", symbol: "checklist", hint: "remind call Priya at 5pm",
                  shortcut: nil, action: .fill("remind "), aliases: ["reminder", "reminders", "todo"]),
            Entry(id: "do.note", group: .do, title: "Note", symbol: "note.text", hint: "note buy milk", shortcut: nil,
                  action: .fill("note "), aliases: ["notes", "jot", "write"]),
        ]
        let opens: [(String, String, String, String, [String])] = [
            ("clipboard", "Clipboard", "doc.on.clipboard", "what you copied", ["paste", "copied", "history"]),
            ("shelf", "Shelf", "tray", "files you kept", ["files", "drop", "tray"]),
            ("baskets", "Baskets", "basket", "floating file baskets", ["basket", "files"]),
            ("mirror", "Mirror", "video", "a quick look at yourself", ["camera", "webcam", "selfie"]),
            ("memory", "Memory", "brain", "search what you saw", ["recall", "history", "screen"]),
            ("launch", "Sites & Shortcuts", "safari", "pinned sites and Shortcuts",
             ["sites", "shortcuts", "launch", "links", "bookmarks"]),
            ("games", "Games", "gamecontroller", "Snake, Tetris, 2048, Flappy, Chase",
             ["game", "play", "snake", "tetris", "chase", "flappy"]),
            ("notes", "Notes", "note.text", "your notes", ["note", "notepad", "scratchpad"]),
            ("time", "Time", "clock", "clocks, timers and stopwatch", ["clock", "stopwatch", "world clock"]),
        ]
        for (tool, title, symbol, hint, aliases) in opens where tools.contains(tool) || alwaysAvailable.contains(tool) {
            out.append(Entry(id: "open." + tool, group: .open, title: title, symbol: symbol, hint: hint,
                             shortcut: shortcuts[tool], action: .open(tool: tool), aliases: aliases))
        }
        out.append(Entry(id: "toggle.keepAwake", group: .toggle, title: "Keep awake", symbol: "cup.and.saucer",
                         hint: "stop the Mac from sleeping", shortcut: nil, action: .toggleKeepAwake,
                         aliases: ["awake", "sleep", "caffeinate", "coffee"]))
        return out
    }

    /// The rows `query` finds, best first (then in list order): a title word, alias or hint
    /// that starts with it, then (three letters or more) one that has its letters in order
    /// ("gms" finds Games). All rows for an empty query. Case-insensitive.
    public static func filter(_ entries: [Entry], query: String) -> [Entry] {
        let q: String = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        let scored: [(Int, Int, Entry)] = entries.enumerated().compactMap { index, e in
            guard let score = score(e, q) else { return nil }
            return (score, index, e)
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// Lower is better: -3 the title is exactly the text, -2 an alias is, -1 either is once a
    /// plural "s" is dropped from the text; 0 a prefix match, 1 a fuzzy one, nil none.
    private static func score(_ e: Entry, _ q: String) -> Int? {
        let title: String = e.title.lowercased()
        let aliases: [String] = e.aliases.map { $0.lowercased() }
        if title == q { return -3 }
        if aliases.contains(q) { return -2 }
        if q.count > 1, q.hasSuffix("s") {
            let singular: String = String(q.dropLast())
            if title == singular || aliases.contains(singular) { return -1 }
        }
        let names: [String] = [e.title] + e.aliases
        let words: [String] = names.flatMap { name in
            [name.lowercased()] + name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        if words.contains(where: { $0.hasPrefix(q) }) || e.hint.lowercased().hasPrefix(q) { return 0 }
        if q.count >= fuzzyMinLength, words.contains(where: { isSubsequence(q, of: $0) }) { return 1 }
        return nil
    }

    /// Shortest query matched by letters in order.
    static let fuzzyMinLength = 3

    /// `q`'s letters appear in `word` in order, starting with its first letter.
    private static func isSubsequence(_ q: String, of word: String) -> Bool {
        guard q.first == word.first else { return false }
        var rest = q[...]
        for c in word where c == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
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
