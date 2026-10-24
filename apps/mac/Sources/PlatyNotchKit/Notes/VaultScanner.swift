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

    static let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                                         .fileSizeKey, .ubiquitousItemDownloadingStatusKey]

    public static func scan(root: URL, now: Date, maxAge: TimeInterval = maxAge, maxFiles: Int = maxFiles,
                            maxEntries: Int = maxEntries, fileManager: FileManager = .default) -> VaultScan {
        guard let e = fileManager.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in true }) else { return VaultScan() }
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
                  let note = accept(url, now: now, maxAge: maxAge) else { continue }
            found.append(note)
        }
        found.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
        let matched = found.count
        return VaultScan(notes: Array(found.prefix(maxFiles)), matched: matched, walkCapped: walkCapped)
    }

    /// One note, stat'ed afresh (an FSEvents path): nil when it is gone, not a note, in a dot
    /// folder, a link, too large, older than the window or an iCloud item not downloaded.
    public static func note(at path: String, root: String, now: Date, maxAge: TimeInterval = maxAge) -> ScannedNote? {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base), (path as NSString).pathExtension.lowercased() == "md",
              !isHidden(path, under: root) else { return nil }
        return accept(URL(fileURLWithPath: path), now: now, maxAge: maxAge)
    }

    private static func accept(_ url: URL, now: Date, maxAge: TimeInterval) -> ScannedNote? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true, v.isRegularFile == true,
              let modified = v.contentModificationDate, modified >= now.addingTimeInterval(-maxAge) else { return nil }
        // An iCloud placeholder or an old local copy: reading it would download or mislead.
        if let status = v.ubiquitousItemDownloadingStatus, status != .current { return nil }
        let size = v.fileSize ?? 0
        guard size <= maxFileBytes else { return nil }
        return ScannedNote(path: url.path, modified: modified, size: size)
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
/// A full walk (`update`) replaces it; FSEvents note paths (`refresh`) update just those.
public struct TaskIndex: Sendable {
    private struct Entry: Sendable {
        let modified: Date
        let size: Int
        let tasks: [MarkdownTask]
    }

    private var entries: [String: Entry] = [:]
    private var walkCapped = false
    public private(set) var capped = false
    public var noteCount: Int { entries.count }

    public init() {}

    /// Brings the index up to a full walk, reading notes with `read` (nil: unreadable, skipped).
    public mutating func update(_ scan: VaultScan, calendar: Calendar = .current, read: (String) -> Data?) {
        var next: [String: Entry] = [:]
        for note in scan.notes {
            if let e = entry(for: note, calendar: calendar, read: read) { next[note.path] = e }
        }
        entries = next
        walkCapped = scan.walkCapped
        capped = scan.capped
    }

    /// Just these paths, stat'ed afresh with `stat` (nil: gone or no longer a note in the
    /// window); the newest `maxFiles` notes are kept.
    public mutating func refresh(_ paths: [String], maxFiles: Int = VaultScanner.maxFiles, calendar: Calendar = .current,
                                 stat: (String) -> ScannedNote?, read: (String) -> Data?) {
        for path in Set(paths) {
            if let note = stat(path), let e = entry(for: note, calendar: calendar, read: read) {
                entries[path] = e
            } else {
                entries[path] = nil
            }
        }
        if entries.count > maxFiles {
            let keep = entries.sorted { $0.value.modified > $1.value.modified }.prefix(maxFiles)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            capped = true
        }
    }

    private func entry(for note: ScannedNote, calendar: Calendar, read: (String) -> Data?) -> Entry? {
        if let old = entries[note.path], old.modified == note.modified, old.size == note.size { return old }
        guard let data = read(note.path) else { return nil }
        let tasks = MarkdownTasks.parse(bytes: [UInt8](data), file: note.path, calendar: calendar)
        return Entry(modified: note.modified, size: note.size, tasks: tasks)
    }

    /// Open tasks: those with a due date first (soonest first), then by note (newest note
    /// first) and line.
    public var openTasks: [MarkdownTask] {
        let order = entries.sorted { a, b in
            a.value.modified != b.value.modified ? a.value.modified > b.value.modified : a.key < b.key
        }.map(\.key)
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
