import Foundation

/// One Markdown task (`- [ ] text`) as it was read from a note.
public struct MarkdownTask: Equatable, Sendable, Identifiable {
    /// The note's path as given to `MarkdownTasks.parse` (the vault scan passes absolute paths).
    public let file: String
    /// 1-based line number, counted the way editors do (`\r\n`, `\n` and a lone `\r` each end a line).
    public let line: Int
    /// What follows the checkbox, trimmed (Tasks-plugin markers such as `📅 2026-10-30` included).
    public let text: String
    /// `[x]` or `[X]`.
    public let done: Bool
    /// The Tasks plugin's due date (`📅 2026-10-30`, also 📆 and 🗓), at the start of that day.
    public let due: Date?
    /// The whole line as read, without its line ending. A toggle writes only when the line
    /// still reads exactly this (R18).
    public let raw: String
    /// `MarkdownTasks.hash` of the whole note as it was parsed (0: unknown). The write-back
    /// knows from it whether the note changed since (R18).
    public let noteHash: UInt64

    public init(file: String, line: Int, text: String, done: Bool, due: Date?, raw: String, noteHash: UInt64 = 0) {
        self.file = file
        self.line = line
        self.text = text
        self.done = done
        self.due = due
        self.raw = raw
        self.noteHash = noteHash
    }

    /// A Tasks-plugin recurring task (`🔁 every week`): ticking it means making the next
    /// one, which only the plugin does, so PlatyNotch never writes it.
    public var isRecurring: Bool { MarkdownTasks.isRecurring(text) }

    public var id: String { file + ":" + String(line) }

    /// `text` without the Tasks plugin's date markers, for display.
    public var title: String { MarkdownTasks.stripMarkers(text) }
}

/// Finds and ticks Markdown tasks. Pure, and byte-exact: a toggle changes the one byte
/// inside the checkbox and nothing else, so line endings (CRLF, LF, CR), a BOM, trailing
/// spaces and every other line stay exactly as they were.
///
/// A task is a list item (`-`, `*`, `+`, `1.` or `1)`, optionally indented with spaces or
/// tabs, optionally inside `>` quotes or callouts) followed by `[ ]`, `[x]` or `[X]` and text.
/// Other statuses (`[/]`, `[-]`, …) are not tasks here. Lines inside YAML frontmatter
/// (`---` on the first line up to the next `---` or `...`) and inside fenced code blocks
/// (``` or ~~~, closed by the same fence at least as long; an unclosed fence runs to the end)
/// are never tasks, nor are lines inside or starting an Obsidian `%% … %%` comment.
/// Recurring tasks (`🔁`) are listed but never toggled.
public enum MarkdownTasks {
    public static func parse(_ md: String, file: String) -> [MarkdownTask] {
        parse(bytes: Array(md.utf8), file: file, calendar: .current)
    }

    public static func parse(_ md: String, file: String, calendar: Calendar) -> [MarkdownTask] {
        parse(bytes: Array(md.utf8), file: file, calendar: calendar)
    }

    public static func parse(bytes: [UInt8], file: String, calendar: Calendar = .current) -> [MarkdownTask] {
        located(bytes, file: file, calendar: calendar).map(\.task)
    }

    /// `md` with the task on `line` (1-based) ticked or unticked; `md` unchanged when that
    /// line is not a task (or is inside frontmatter or a code block).
    public static func toggle(_ md: String, line: Int) -> String {
        guard let out = toggled(bytes: Array(md.utf8), line: line) else { return md }
        return String(decoding: out, as: UTF8.self)
    }

    /// The bytes with the task on `line` toggled, or nil when that line is not a task (or is
    /// a recurring one). Exactly one byte differs (`' '` ↔ `'x'`; `'X'` becomes `' '`).
    public static func toggled(bytes: [UInt8], line: Int) -> [UInt8]? {
        guard let hit = locate(bytes, line: line), !hit.task.isRecurring else { return nil }
        var out = bytes
        out[hit.offset] = hit.task.done ? space : lowerX
        return out
    }

    /// The task on `line` and the offset of its checkbox byte; nil when that line is not a task.
    public static func locate(_ bytes: [UInt8], line: Int, file: String = "",
                              calendar: Calendar = .current) -> (task: MarkdownTask, offset: Int)? {
        guard line >= 1 else { return nil }
        return located(bytes, file: file, calendar: calendar, onlyLine: line).first
    }

    /// FNV-1a (64-bit) of the note's bytes: equal bytes, equal hash.
    public static func hash(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h == 0 ? 1 : h
    }

    public static func isRecurring(_ text: String) -> Bool { text.contains("\u{1F501}") }

    // MARK: - Lines

    /// A line's content `[start, end)` and where the next line starts.
    public struct LineSpan: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let next: Int
    }

    /// The lines of `bytes` (a leading UTF-8 BOM is not part of line 1's content). A file
    /// ending with a line break has no empty last line.
    public static func lines(_ bytes: [UInt8]) -> [LineSpan] {
        var out: [LineSpan] = []
        var i = bytes.starts(with: bom) ? bom.count : 0
        var start = i
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b == lf {
                out.append(LineSpan(start: start, end: i, next: i + 1))
                i += 1
                start = i
            } else if b == cr {
                let next = (i + 1 < n && bytes[i + 1] == lf) ? i + 2 : i + 1
                out.append(LineSpan(start: start, end: i, next: next))
                i = next
                start = i
            } else {
                i += 1
            }
        }
        if start < n { out.append(LineSpan(start: start, end: n, next: n)) }
        return out
    }

    /// The line ending a file mostly uses (`\r\n` when its first break is one), for appends.
    public static func lineEnding(of bytes: [UInt8]) -> String {
        guard let i = bytes.firstIndex(where: { $0 == lf || $0 == cr }) else { return "\n" }
        if bytes[i] == lf { return "\n" }
        return (i + 1 < bytes.count && bytes[i + 1] == lf) ? "\r\n" : "\r"
    }

    // MARK: - Scanning

    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let tab: UInt8 = 0x09
    static let lowerX: UInt8 = 0x78
    static let upperX: UInt8 = 0x58
    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    private struct Fence {
        let char: UInt8
        let count: Int
    }

    private static func located(_ bytes: [UInt8], file: String, calendar: Calendar,
                                onlyLine: Int? = nil) -> [(task: MarkdownTask, offset: Int)] {
        let spans = lines(bytes)
        var out: [(task: MarkdownTask, offset: Int)] = []
        var index = 0
        // YAML frontmatter: `---` alone on the first line, up to the next `---` / `...`.
        if let first = spans.first, trimmedEquals(bytes, first, "---") {
            if let close = spans.dropFirst().firstIndex(where: { trimmedEquals(bytes, $0, "---") || trimmedEquals(bytes, $0, "...") }) {
                index = close + 1
            }
        }
        var fence: Fence?
        var inComment = false
        let noteHash = hash(bytes)
        while index < spans.count {
            let span = spans[index]
            let lineNumber = index + 1
            index += 1
            if let f = fence {
                if closesFence(bytes, span, f) { fence = nil }
                continue
            }
            // Obsidian comments: `%%` opens and closes; a line inside one, or starting one, is skipped.
            let marks = commentMarks(bytes, span)
            if inComment {
                if marks % 2 == 1 { inComment = false }
                continue
            }
            if let f = opensFence(bytes, span) {
                fence = f
                continue
            }
            if marks % 2 == 1 { inComment = true }
            if startsWithComment(bytes, span) { continue }
            if let wanted = onlyLine {
                if lineNumber < wanted { continue }
                if lineNumber > wanted { break }
            }
            guard let hit = task(bytes, span) else { continue }
            let text = String(decoding: bytes[hit.textStart..<span.end], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if onlyLine == nil, text.isEmpty { continue }
            let raw = String(decoding: bytes[span.start..<span.end], as: UTF8.self)
            let t = MarkdownTask(file: file, line: lineNumber, text: text, done: hit.done,
                                 due: dueDate(in: text, calendar: calendar), raw: raw, noteHash: noteHash)
            out.append((t, hit.offset))
        }
        return out
    }

    private static func isBlank(_ b: UInt8) -> Bool { b == space || b == tab }

    private static let percent: UInt8 = 0x25

    private static let backtick: UInt8 = 0x60

    /// How many `%%` the line holds (not overlapping), outside backtick code spans.
    private static func commentMarks(_ bytes: [UInt8], _ span: LineSpan) -> Int {
        var n = 0
        var i = span.start
        while i + 1 < span.end {
            if bytes[i] == backtick {
                // A code span: a run of n backticks up to the next run of exactly n.
                var j = i
                while j < span.end, bytes[j] == backtick { j += 1 }
                let run = j - i
                if let close = closingRun(bytes, from: j, end: span.end, length: run) {
                    i = close
                } else {
                    i = j   // no closing run: the backticks are literal
                }
                continue
            }
            if bytes[i] == percent, bytes[i + 1] == percent {
                n += 1
                i += 2
            } else {
                i += 1
            }
        }
        return n
    }

    /// Where a run of exactly `length` backticks at or after `from` ends, if there is one.
    private static func closingRun(_ bytes: [UInt8], from: Int, end: Int, length: Int) -> Int? {
        var k = from
        while k < end {
            guard bytes[k] == backtick else {
                k += 1
                continue
            }
            var m = k
            while m < end, bytes[m] == backtick { m += 1 }
            if m - k == length { return m }
            k = m
        }
        return nil
    }

    private static func startsWithComment(_ bytes: [UInt8], _ span: LineSpan) -> Bool {
        let i = contentStart(bytes, span)
        return i + 1 < span.end && bytes[i] == percent && bytes[i + 1] == percent
    }

    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    private static func trimmedEquals(_ bytes: [UInt8], _ span: LineSpan, _ s: String) -> Bool {
        var end = span.end
        while end > span.start, isBlank(bytes[end - 1]) { end -= 1 }
        return Array(bytes[span.start..<end]) == Array(s.utf8)
    }

    /// Leading blanks and `>` quote markers skipped.
    private static func contentStart(_ bytes: [UInt8], _ span: LineSpan) -> Int {
        var i = span.start
        while i < span.end {
            if isBlank(bytes[i]) || bytes[i] == 0x3E { i += 1 } else { break }
        }
        return i
    }

    private static func opensFence(_ bytes: [UInt8], _ span: LineSpan) -> Fence? {
        let i = contentStart(bytes, span)
        guard i < span.end, bytes[i] == 0x60 || bytes[i] == 0x7E else { return nil }
        let c = bytes[i]
        var j = i
        while j < span.end, bytes[j] == c { j += 1 }
        let count = j - i
        guard count >= 3 else { return nil }
        // A backtick fence's info string has no backtick (CommonMark).
        if c == 0x60, bytes[j..<span.end].contains(0x60) { return nil }
        return Fence(char: c, count: count)
    }

    private static func closesFence(_ bytes: [UInt8], _ span: LineSpan, _ f: Fence) -> Bool {
        let i = contentStart(bytes, span)
        var j = i
        while j < span.end, bytes[j] == f.char { j += 1 }
        guard j - i >= f.count else { return false }
        return bytes[j..<span.end].allSatisfy(isBlank)
    }

    /// The checkbox byte's offset, its state and where the text starts, when `span` is a task.
    private static func task(_ bytes: [UInt8], _ span: LineSpan) -> (offset: Int, done: Bool, textStart: Int)? {
        var i = contentStart(bytes, span)
        let end = span.end
        guard i < end else { return nil }
        let b = bytes[i]
        if b == 0x2D || b == 0x2A || b == 0x2B {           // - * +
            i += 1
        } else if isDigit(b) {
            var j = i
            while j < end, isDigit(bytes[j]), j - i < 9 { j += 1 }
            guard j < end, bytes[j] == 0x2E || bytes[j] == 0x29 else { return nil }   // . )
            i = j + 1
        } else {
            return nil
        }
        guard i < end, isBlank(bytes[i]) else { return nil }
        while i < end, isBlank(bytes[i]) { i += 1 }
        guard i + 3 <= end, bytes[i] == 0x5B, bytes[i + 2] == 0x5D else { return nil }   // [ ]
        let mark = bytes[i + 1]
        let done: Bool
        switch mark {
        case space: done = false
        case lowerX, upperX: done = true
        default: return nil
        }
        let after = i + 3
        guard after == end || isBlank(bytes[after]) else { return nil }
        return (i + 1, done, after)
    }

    // MARK: - Due dates

    private static let dueRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?:\u{1F4C5}|\u{1F4C6}|\u{1F5D3})\u{FE0F}?\\s*(\\d{4})-(\\d{2})-(\\d{2})")

    private static let markerRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\s*(?:\u{1F4C5}|\u{1F4C6}|\u{1F5D3}|\u{23F3}|\u{1F6EB}|\u{2795}|\u{2705}|\u{274C})\u{FE0F}?\\s*\\d{4}-\\d{2}-\\d{2}")

    /// The first due marker's date (a real calendar date), at the start of that day.
    public static func dueDate(in text: String, calendar: Calendar = .current) -> Date? {
        guard let re = dueRegex else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let parts = (1...3).compactMap { Int(ns.substring(with: m.range(at: $0))) }
        guard parts.count == 3 else { return nil }
        let comps = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == parts[0], back.month == parts[1], back.day == parts[2] else { return nil }
        return date
    }

    /// `text` without Tasks-plugin date markers (due, scheduled, start, created, done, cancelled).
    public static func stripMarkers(_ text: String) -> String {
        guard let re = markerRegex else { return text }
        let ns = text as NSString
        let out = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? text : trimmed
    }
}
