import Foundation

/// Batch rename patterns (Task 2, R10). Tokens:
/// - `{name}`: the file's name without its extension;
/// - `{n}`: its 1-based place in the selection; `{n:3}` zero-pads it to 3 digits (1-9);
/// - `{date:FMT}`: `date` in the `DateFormatter` format FMT (en_US_POSIX), with `/` and
///   `:` removed from the result; `{date}` is `{date:yyyy-MM-dd}`.
/// Anything else is kept as typed. The extension is kept, and the result always goes
/// through `FileNames.safe` (one path component, no separators).
public enum RenamePattern {
    /// `name` is the file's full name ("photo.jpg"); `index` its 1-based place.
    public static func apply(_ pattern: String, name: String, index: Int, date: Date,
                             timeZone: TimeZone = .current) -> String {
        let (base, ext) = FileNames.split(name)
        var out = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let token = String(rest[rest.index(after: open)..<close])
            out += expand(token, base: base, index: index, date: date, timeZone: timeZone) ?? "{\(token)}"
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        let safeBase = FileNames.safe(out)
        let safeExt = ext.isEmpty ? "" : FileNames.safe(ext)
        return FileNames.join(safeBase, String(safeExt.prefix(20)))
    }

    private static func expand(_ token: String, base: String, index: Int, date: Date, timeZone: TimeZone) -> String? {
        if token == "name" { return base }
        if token == "n" { return String(index) }
        if token.hasPrefix("n:"), let width = Int(token.dropFirst(2)), (1...9).contains(width) {
            let digits = String(index)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        if token == "date" { return format(date, "yyyy-MM-dd", timeZone) }
        if token.hasPrefix("date:"), token.count > 5 { return format(date, String(token.dropFirst(5)), timeZone) }
        return nil
    }

    private static func format(_ date: Date, _ fmt: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = fmt
        return f.string(from: date).replacingOccurrences(of: "/", with: "").replacingOccurrences(of: ":", with: "")
    }
}

/// The renames a pattern makes for a selection, checked before anything is touched (R10):
/// a name already taken in the folder, or by another file of the plan, gets " 2", " 3", …
/// A file whose name does not change has no step.
public struct RenamePlan: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        /// The file's place in the selection (0-based).
        public var index: Int
        public var from: URL
        public var to: URL

        public init(index: Int, from: URL, to: URL) {
            self.index = index
            self.from = from
            self.to = to
        }

        /// Only the case of the name changes (one file on a case-insensitive volume).
        public var caseOnly: Bool {
            from.lastPathComponent != to.lastPathComponent
                && from.lastPathComponent.lowercased() == to.lastPathComponent.lowercased()
        }
    }

    public var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    /// `exists(path)`: something is at that path now (the file system). Names are compared
    /// without case, as the default macOS volume does.
    public static func make(_ urls: [URL], pattern: String, date: Date, timeZone: TimeZone = .current,
                            exists: (String) -> Bool) -> RenamePlan {
        var claimed: [String: Set<String>] = [:]   // folder → lowercased names planned
        var steps: [Step] = []
        for (i, url) in urls.enumerated() {
            let from = url.standardizedFileURL
            let dir = from.deletingLastPathComponent()
            let old = from.lastPathComponent
            let wanted = RenamePattern.apply(pattern, name: old, index: i + 1, date: date, timeZone: timeZone)
            guard wanted != old else { continue }
            let planned = claimed[dir.path, default: []]
            let name = FileNames.unique(wanted) { candidate in
                if planned.contains(candidate.lowercased()) { return true }
                if candidate.lowercased() == old.lowercased() { return false }   // the file itself
                return exists(dir.appendingPathComponent(candidate).path)
            }
            guard let name, name != old else { continue }
            claimed[dir.path, default: []].insert(name.lowercased())
            steps.append(Step(index: i, from: from, to: dir.appendingPathComponent(name)))
        }
        return RenamePlan(steps: steps)
    }

    /// What puts the done steps back, last first.
    public static func undo(_ done: [Step]) -> RenamePlan {
        RenamePlan(steps: done.reversed().map { Step(index: $0.index, from: $0.to, to: $0.from) })
    }
}
