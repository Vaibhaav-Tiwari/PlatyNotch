import Foundation

/// A Markdown file the vault scan found.
public struct ScannedNote: Equatable, Sendable {
    public let path: String
    public let modified: Date
    public let size: Int

    public init(path: String, modified: Date, size: Int) {
        self.path = path
        self.modified = modified
        self.size = size
    }
}

/// What one walk of the vault found.
public struct VaultScan: Equatable, Sendable {
    /// Newest first, at most `VaultScanner.maxFiles`.
    public var notes: [ScannedNote]
    /// Notes edited within the window before the cap (`notes.count` when not capped).
    public var matched: Int
    /// The walk stopped at `VaultScanner.maxEntries` entries.
    public var walkCapped: Bool

    public init(notes: [ScannedNote] = [], matched: Int = 0, walkCapped: Bool = false) {
        self.notes = notes
        self.matched = matched
        self.walkCapped = walkCapped
    }

    /// Fewer notes are shown than were edited in the window.
    public var capped: Bool { matched > notes.count || walkCapped }
}

/// Lists the vault's notes edited in the last 30 days (names, dates and sizes only; R18).
/// Hidden files and every dot folder (`.obsidian`, `.trash`, `.git`) are skipped, links are
/// never followed, packages are not entered, and the walk is capped.
public enum VaultScanner {
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    /// The newest this many notes are read for tasks.
    public static let maxFiles = 2_000
    /// The walk stops after this many entries (files and folders).
    public static let maxEntries = 100_000
    /// Larger notes are skipped.
    public static let maxFileBytes = 1_000_000

    public static func scan(root: URL, now: Date, maxAge: TimeInterval = maxAge, maxFiles: Int = maxFiles,
                            maxEntries: Int = maxEntries, fileManager: FileManager = .default) -> VaultScan {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let e = fileManager.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in true }) else { return VaultScan() }
        let oldest = now.addingTimeInterval(-maxAge)
        var found: [ScannedNote] = []
        var seen = 0
        var walkCapped = false
        while let url = e.nextObject() as? URL {
            seen += 1
            if seen > maxEntries {
                walkCapped = true
                break
            }
            guard url.pathExtension.lowercased() == "md", !isHidden(url.path, under: root.path),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isSymbolicLink != true, v.isRegularFile == true,
                  let modified = v.contentModificationDate, modified >= oldest else { continue }
            let size = v.fileSize ?? 0
            guard size <= maxFileBytes else { continue }
            found.append(ScannedNote(path: url.path, modified: modified, size: size))
        }
        found.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
        let matched = found.count
        return VaultScan(notes: Array(found.prefix(maxFiles)), matched: matched, walkCapped: walkCapped)
    }

    /// A path below `root` with a component (below `root`) that starts with a dot. Paths
    /// not below `root` are not judged here (false); the walk skips hidden entries itself.
    public static func isHidden(_ path: String, under root: String) -> Bool {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return false }
        return path.dropFirst(base.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

/// The open tasks of the scanned notes, re-reading only notes whose date or size changed.
public struct TaskIndex: Sendable {
    private struct Entry: Sendable {
        let modified: Date
        let size: Int
        let tasks: [MarkdownTask]
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    public private(set) var capped = false
    public private(set) var noteCount = 0

    public init() {}

    /// Brings the index up to `scan`, reading notes with `read` (nil: unreadable, skipped).
    public mutating func update(_ scan: VaultScan, calendar: Calendar = .current, read: (String) -> Data?) {
        var next: [String: Entry] = [:]
        for note in scan.notes {
            if let old = entries[note.path], old.modified == note.modified, old.size == note.size {
                next[note.path] = old
                continue
            }
            guard let data = read(note.path) else { continue }
            let tasks = MarkdownTasks.parse(bytes: [UInt8](data), file: note.path, calendar: calendar)
            next[note.path] = Entry(modified: note.modified, size: note.size, tasks: tasks)
        }
        entries = next
        order = scan.notes.map(\.path)
        capped = scan.capped
        noteCount = scan.notes.count
    }

    /// One note read again (after a toggle).
    public mutating func replace(_ path: String, tasks: [MarkdownTask], modified: Date, size: Int) {
        guard entries[path] != nil else { return }
        entries[path] = Entry(modified: modified, size: size, tasks: tasks)
    }

    /// Open tasks: those with a due date first (soonest first), then by note (newest note
    /// first) and line.
    public var openTasks: [MarkdownTask] {
        var rank: [String: Int] = [:]
        for (i, p) in order.enumerated() { rank[p] = i }
        let open = order.flatMap { entries[$0]?.tasks.filter { !$0.done } ?? [] }
        return open.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let ra = rank[a.file] ?? 0
                let rb = rank[b.file] ?? 0
                return ra != rb ? ra < rb : a.line < b.line
            }
        }
    }
}
