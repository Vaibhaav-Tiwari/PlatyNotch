import Foundation

/// What a command-line entry does (spec 3). Nothing runs until the user presses Return.
public enum PanelCommand: Equatable, Sendable {
    case timer(duration: TimeInterval, label: String?)
    case focus(minutes: Int)
    case remind(QuickAdd)
    case note(String)
    case search(String)
    case play(GameKind?)
    case open(tool: String)
}

/// One row under the command line. A nil `command` is an explanation that never runs.
public struct CommandSuggestion: Equatable, Sendable {
    public let command: PanelCommand?
    public let title: String
    public let detail: String?

    public init(command: PanelCommand?, title: String, detail: String?) {
        self.command = command
        self.title = title
        self.detail = detail
    }
}

/// A feature the command line can open ("Open Clipboard").
public struct CommandTool: Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Turns what the user typed into suggestions (spec 3). Pure: the keyword is the first word,
/// case-insensitive; dates in `remind` text come from `QuickAddParser`, durations from
/// `DurationParser`. Odd input never runs: the row explains instead.
public enum CommandParser {
    /// Most `Open <feature>` rows shown for free text.
    static let maxOpenMatches = 3
    /// `focus` minutes accepted.
    static let focusRange = 1...240
    static let defaultFocusMinutes = 25
    /// A duration is at most this many leading tokens ("1 h 30 min").
    static let maxDurationTokens = 3

    public static func suggestions(for text: String, tools: [CommandTool], now: Date,
                                   calendar: Calendar) -> [CommandSuggestion] {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokens: [String] = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let keyword: String = tokens[0].lowercased()
        let rest: [String] = Array(tokens.dropFirst())
        switch keyword {
        case "timer": return [timer(rest)]
        case "focus": return [focus(rest)]
        case "remind", "reminder": return [remind(rest, now: now, calendar: calendar)]
        case "note": return [note(rest)]
        case "search": return [search(rest)]
        case "play": return [play(rest)]
        case "open": return openFeature(rest, tools: tools)
        default: return freeText(trimmed, tools: tools, now: now, calendar: calendar)
        }
    }

    // MARK: - Commands

    private static func timer(_ rest: [String]) -> CommandSuggestion {
        let hint = "Try: timer 10m tea, timer 1h 30m or timer 5:00"
        guard !rest.isEmpty else { return explain("Timer", "How long? " + hint) }
        var n: Int = min(maxDurationTokens, rest.count)
        while n >= 1 {
            let candidate: String = rest.prefix(n).joined(separator: " ")
            if let seconds = DurationParser.parse(candidate) {
                let label: String? = cleanLabel(rest.dropFirst(n).joined(separator: " "))
                var detail: String = DurationParser.describe(seconds)
                if let label { detail += " · \"\(label)\"" }
                return CommandSuggestion(command: .timer(duration: seconds, label: label), title: "Timer", detail: detail)
            }
            n -= 1
        }
        return explain("Timer", "Not a duration (1 s to 24 h). " + hint)
    }

    private static func focus(_ rest: [String]) -> CommandSuggestion {
        let hint = "Focus takes 1 to 240 minutes, like focus 50"
        var minutes: Int = defaultFocusMinutes
        if !rest.isEmpty {
            var arg: String = rest.joined(separator: " ").lowercased()
            for suffix in [" minutes", " min", "min", "m"] where arg.hasSuffix(suffix) {
                arg = String(arg.dropLast(suffix.count))
                break
            }
            guard let value = Int(arg.trimmingCharacters(in: .whitespaces)), focusRange.contains(value) else {
                return explain("Focus", hint)
            }
            minutes = value
        }
        return CommandSuggestion(command: .focus(minutes: minutes), title: "Focus",
                                 detail: "\(minutes) min focus session")
    }

    private static func remind(_ rest: [String], now: Date, calendar: Calendar) -> CommandSuggestion {
        let text: String = rest.joined(separator: " ")
        guard !text.isEmpty else { return explain("Remind", "What should it remind you of? Try: remind call Priya at 5pm") }
        let quick: QuickAdd = QuickAddParser.parse(text, now: now, calendar: calendar)
        guard !quick.title.isEmpty else { return explain("Remind", "Add a few words about what to remember") }
        let preview: String = QuickAddFormat.preview(quick, now: now, calendar: calendar)
        return CommandSuggestion(command: .remind(quick), title: "Remind", detail: "\(quick.title) · \(preview)")
    }

    private static func note(_ rest: [String]) -> CommandSuggestion {
        let text: String = rest.joined(separator: " ")
        guard !text.isEmpty else { return explain("Note", "What should the note say? Try: note buy milk") }
        return CommandSuggestion(command: .note(text), title: "Note", detail: "Add to today's note: \(text)")
    }

    private static func search(_ rest: [String]) -> CommandSuggestion {
        let text: String = rest.joined(separator: " ")
        guard !text.isEmpty else { return explain("Search memory", "What are you looking for? Try: search budget") }
        return CommandSuggestion(command: .search(text), title: "Search memory", detail: "\"\(text)\"")
    }

    private static func play(_ rest: [String]) -> CommandSuggestion {
        guard !rest.isEmpty else { return CommandSuggestion(command: .play(nil), title: "Games", detail: "Open the games") }
        let name: String = rest.joined(separator: " ").lowercased()
        let match: GameKind? = GameKind.allCases.first { kind in
            [kind.title, kind.shortTitle, kind.rawValue].contains { $0.lowercased() == name }
        }
        guard let match else {
            let names: String = GameKind.allCases.map(\.shortTitle).joined(separator: ", ")
            return explain("Games", "No game called \"\(rest.joined(separator: " "))\". Try: \(names)")
        }
        return CommandSuggestion(command: .play(match), title: "Play \(match.title)", detail: nil)
    }

    /// `open <feature>`: up to three features whose title (or a word of it) starts with what
    /// was typed, so `open sites` finds "Sites & Shortcuts".
    private static func openFeature(_ rest: [String], tools: [CommandTool]) -> [CommandSuggestion] {
        guard !rest.isEmpty else { return [explain("Open", "Open what? Try: open clipboard")] }
        let name: String = rest.joined(separator: " ").lowercased()
        let matches: [CommandTool] = tools.filter { titleMatches($0.title, name) }.prefix(maxOpenMatches).map { $0 }
        guard !matches.isEmpty else { return [explain("Open", "No feature called \"\(rest.joined(separator: " "))\"")] }
        return matches.map { CommandSuggestion(command: .open(tool: $0.id), title: "Open \($0.title)", detail: nil) }
    }

    /// Whether `title` starts with `name`, or any of its words does.
    private static func titleMatches(_ title: String, _ name: String) -> Bool {
        let lower: String = title.lowercased()
        if lower.hasPrefix(name) { return true }
        return lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(name) }
    }

    // MARK: - Free text

    private static func freeText(_ text: String, tools: [CommandTool], now: Date,
                                 calendar: Calendar) -> [CommandSuggestion] {
        var out: [CommandSuggestion] = []
        let lower: String = text.lowercased()
        let matches: [CommandTool] = tools.filter { $0.title.lowercased().hasPrefix(lower) }.prefix(maxOpenMatches).map { $0 }
        for tool in matches {
            out.append(CommandSuggestion(command: .open(tool: tool.id), title: "Open \(tool.title)", detail: nil))
        }
        // A reminder needs a date or time that QuickAddParser understood: a bare word (or a
        // date alone, which leaves no title) is not one. "remind …" is its own keyword.
        let quick: QuickAdd = QuickAddParser.parse(text, now: now, calendar: calendar)
        if !quick.title.isEmpty, quick.due != nil {
            out.append(CommandSuggestion(command: .remind(quick), title: "Remind me: \(text)", detail: nil))
        }
        out.append(CommandSuggestion(command: .search(text), title: "Search memory for \"\(text)\"", detail: nil))
        return out
    }

    // MARK: - Helpers

    private static func explain(_ title: String, _ detail: String) -> CommandSuggestion {
        CommandSuggestion(command: nil, title: title, detail: detail)
    }

    /// The label with its surrounding quotes removed; nil when nothing is left.
    private static func cleanLabel(_ raw: String) -> String? {
        let quotes = CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}")
        let cleaned: String = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: quotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
