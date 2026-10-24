import Foundation

/// A file in a downloads folder, by its name alone (contents are never read).
public enum DownloadFileState: Equatable, Sendable {
    /// A browser's temporary name: `.crdownload` (Chrome, Edge, Arc, Brave), `.download`
    /// (Safari's bundle), `.part` (Firefox), `.partial` (older Edge), `.opdownload` (Opera).
    case inProgress
    /// Anything else.
    case done
}

/// What a `stat` says about a path (metadata only, never contents).
public struct FileStat: Equatable, Sendable {
    public var isDirectory: Bool
    public var size: Int64

    public init(isDirectory: Bool = false, size: Int64) {
        self.isDirectory = isDirectory
        self.size = size
    }

    /// A bundle (Safari, an .app) or a non-empty file.
    public var hasContent: Bool { isDirectory || size > 0 }
}

/// Names and paths only; pure.
public enum DownloadDetector {
    public static let inProgressSuffixes = ["crdownload", "download", "part", "partial", "opdownload"]

    public static func state(fileName: String) -> DownloadFileState {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let stem = (fileName as NSString).deletingPathExtension
        return !stem.isEmpty && inProgressSuffixes.contains(ext) ? .inProgress : .done
    }

    /// The name a download will have when done ("report.pdf.crdownload" → "report.pdf").
    public static func finalName(for fileName: String) -> String {
        state(fileName: fileName) == .inProgress ? (fileName as NSString).deletingPathExtension : fileName
    }

    /// Hidden files (`.DS_Store`, browsers' dot-temporaries) never count.
    public static func isIgnored(fileName: String) -> Bool {
        fileName.hasPrefix(".") || fileName.isEmpty
    }

    /// For the pill: at most `max` characters, with an ellipsis.
    public static func shortName(_ name: String, max: Int = 18) -> String {
        name.count <= max ? name : String(name.prefix(max - 1)) + "…"
    }

    /// The watched-folder entry an FSEvents path belongs to: a direct child of one of
    /// `folders`, or the in-progress bundle (Safari's `.download`) a deeper path is inside.
    /// nil for anything else (subfolders, other places, the folder itself).
    /// Nested folders (`~/Downloads/Browser` beside `~/Downloads`): the deepest match wins.
    public static func entry(path: String, folders: [String]) -> String? {
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            guard path.hasPrefix(base + "/") else { continue }
            let rest = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            guard let first = rest.first else { return nil }
            let child = base + "/" + first
            if rest.count == 1 { return child }
            return state(fileName: String(first)) == .inProgress ? child : nil
        }
        return nil
    }
}

/// Follows downloads from coalesced FSEvents batches of paths, by name and existence only.
///
/// A download starts when an in-progress name appears and finishes when the final name
/// exists after (or in the same batch as) the in-progress one went: Chrome renames
/// `x.crdownload` → `x`, Safari moves `x` out of `x.download` then removes the bundle,
/// Firefox keeps an empty `x` beside `x.part` until it renames over it. A file that appears
/// with no download before it (copied, unzipped) is not a download. A cancelled download
/// ends with no notice.
public struct DownloadTracker: Sendable {
    /// How long after its in-progress name went the final file may still show up.
    public static let finishGrace: TimeInterval = 10
    /// An in-progress name with no writes for this long is no longer shown (a paused or
    /// abandoned download).
    public static let staleAfter: TimeInterval = 10 * 60
    /// Above this many entries in one batch only known downloads are followed.
    public static let maxBatchEntries = 500

    public struct Active: Equatable, Sendable {
        /// The in-progress path.
        public let path: String
        /// What the user will get ("report.pdf").
        public let name: String
        public var lastSeen: Date
    }

    public struct Event: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case started, ended, finished }
        public let kind: Kind
        /// For `.finished` the final file, otherwise the in-progress path.
        public let path: String

        public init(kind: Kind, path: String) {
            self.kind = kind
            self.path = path
        }
    }

    public let folders: [String]
    /// Oldest first.
    public private(set) var active: [Active] = []
    /// Final paths of in-progress names that went, and when.
    private var ended: [String: Date] = [:]
    /// Final paths seen while their download was still in progress.
    private var awaiting: Set<String> = []

    public init(folders: [String]) {
        self.folders = folders
    }

    /// Entries of one batch: watched-folder entries, each once, hidden names dropped. A
    /// batch with more than `maxBatchEntries` (a big unzip or copy) keeps only the
    /// downloads already in progress and their final names.
    public func entries(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for p in paths {
            guard let e = DownloadDetector.entry(path: p, folders: folders), seen.insert(e).inserted,
                  !DownloadDetector.isIgnored(fileName: (e as NSString).lastPathComponent) else { continue }
            out.append(e)
        }
        guard out.count > Self.maxBatchEntries else { return out }
        let known = Set(active.map(\.path))
        let finals = Set(active.map { Self.finalPath($0.path) })
        return out.filter { known.contains($0) || finals.contains($0) }
    }

    /// Every path `apply` may stat for this batch (to stat them off the main thread).
    public func pathsToStat(_ paths: [String]) -> [String] {
        let e = entries(paths)
        let finals = e.filter { Self.isInProgress($0) }.map(Self.finalPath)
        return Array(Set(e + finals))
    }

    /// One coalesced batch. `stat` answers for paths in the batch (metadata, never a read).
    public mutating func apply(paths: [String], stat: (String) -> FileStat?, now: Date) -> [Event] {
        let entries = entries(paths)
        var events: [Event] = []
        var endedNow: [String] = []
        for p in entries where Self.isInProgress(p) {
            let final = Self.finalPath(p)
            let index = active.firstIndex { $0.path == p }
            if stat(p) != nil {
                if let index {
                    active[index].lastSeen = now
                } else {
                    active.append(Active(path: p, name: (final as NSString).lastPathComponent, lastSeen: now))
                    events.append(Event(kind: .started, path: p))
                }
            } else {
                // Gone: renamed to its final name, or cancelled. Also when it came and went
                // within this one batch (a fast download).
                if let index {
                    active.remove(at: index)
                    events.append(Event(kind: .ended, path: p))
                }
                ended[final] = now
                endedNow.append(final)
            }
        }
        for p in entries where !Self.isInProgress(p) {
            guard let info = stat(p) else {
                awaiting.remove(p)
                continue
            }
            if active.contains(where: { Self.finalPath($0.path) == p }) {
                awaiting.insert(p)
            } else if let when = ended[p], now.timeIntervalSince(when) <= Self.finishGrace, info.hasContent {
                ended[p] = nil
                awaiting.remove(p)
                events.append(Event(kind: .finished, path: p))
            }
        }
        // The final file was already there (Safari moved it out, Firefox's placeholder).
        // An empty file is not finished (Firefox's placeholder left by a cancel): it waits
        // for content within the grace, or goes.
        for final in endedNow where awaiting.contains(final) && ended[final] != nil {
            guard let info = stat(final) else {
                awaiting.remove(final)
                continue
            }
            guard info.hasContent else { continue }
            awaiting.remove(final)
            ended[final] = nil
            events.append(Event(kind: .finished, path: final))
        }
        ended = ended.filter { now.timeIntervalSince($0.value) <= Self.finishGrace }
        return events
    }

    /// Drops in-progress names with no writes for `staleAfter`.
    public mutating func pruneStale(now: Date) -> [Event] {
        let stale = active.filter { now.timeIntervalSince($0.lastSeen) >= Self.staleAfter }
        active.removeAll { now.timeIntervalSince($0.lastSeen) >= Self.staleAfter }
        for s in stale { awaiting.remove(Self.finalPath(s.path)) }
        return stale.map { Event(kind: .ended, path: $0.path) }
    }

    /// When `pruneStale` should run next (nil: nothing in progress).
    public var nextStaleCheck: Date? {
        active.map(\.lastSeen).min().map { $0.addingTimeInterval(Self.staleAfter) }
    }

    static func isInProgress(_ path: String) -> Bool {
        DownloadDetector.state(fileName: (path as NSString).lastPathComponent) == .inProgress
    }

    static func finalPath(_ inProgress: String) -> String {
        let dir = (inProgress as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent(DownloadDetector.finalName(for: (inProgress as NSString).lastPathComponent))
    }
}
