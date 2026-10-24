import Foundation
import os

/// A file on the shelf: where it was last seen and a bookmark that follows it when it is
/// renamed or moved in Finder.
public struct ShelfFileRef: Codable, Equatable, Sendable {
    /// The last known path (shown while the file is missing).
    public var path: String
    /// A plain (not security-scoped) bookmark: PlatyNotch is not sandboxed, so a
    /// security scope would add nothing and needs the app-scope bookmark entitlement.
    public var bookmark: Data?

    public init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
}

/// One thing on the shelf, newest first in `ShelfStore.items`.
public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    /// A dropped image or promised file (Photos, Mail) is a `.file` the shelf owns
    /// (`ownsFile`): it lives in the shelf directory. There is no separate image kind.
    public enum Kind: Codable, Equatable, Sendable {
        case file(ShelfFileRef)
        case text(String)
        case url(URL)
    }

    public var id: UUID
    public var kind: Kind
    public var addedAt: Date
    /// Pinned items survive "Clear" and never expire.
    public var pinned: Bool
    /// The shelf holds the content itself: a file it wrote into its own directory (a
    /// promised file, a dropped image) or a text snippet. Removing the item deletes the
    /// file; unpinned, it expires after `ShelfStore.ownedLifetime`. A file the user
    /// dropped from disk is never owned and never deleted.
    public var ownsFile: Bool

    public init(id: UUID = UUID(), kind: Kind, addedAt: Date, pinned: Bool = false, ownsFile: Bool = false) {
        self.id = id
        self.kind = kind
        self.addedAt = addedAt
        self.pinned = pinned
        self.ownsFile = ownsFile
    }

    public var fileRef: ShelfFileRef? {
        if case .file(let ref) = kind { return ref }
        return nil
    }

    /// What the tile shows under the thumbnail.
    public var title: String {
        switch kind {
        case .file(let ref): ref.name
        case .text(let t): String(t.prefix(80))
        case .url(let u): u.host() ?? u.absoluteString
        }
    }
}

/// Makes and resolves file bookmarks (a seam for tests). Sendable: resolving runs off
/// the main thread (`ShelfStore.resolve`).
public protocol ShelfBookmarks: Sendable {
    func make(_ url: URL) -> Data?
    /// Where the bookmark points now, and whether it should be made again; nil when the
    /// file is gone.
    func resolve(_ data: Data) -> (url: URL, isStale: Bool)?
}

/// Plain file bookmarks (`URL.bookmarkData`), resolved without UI or mounting volumes.
public struct FileBookmarks: ShelfBookmarks {
    public init() {}

    public func make(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}

/// Where a shelf file is now (`ShelfStore.resolve`).
public enum ShelfResolution: Equatable, Sendable {
    case missing
    /// Its reference now (the same one when nothing changed).
    case found(ShelfFileRef)
}

/// What the shelf takes from a drop.
public enum ShelfDropPolicy {
    /// nspasteboard.org markers for passwords and other secrets (never stored).
    public static let concealedType = "org.nspasteboard.ConcealedType"
    public static let transientType = "org.nspasteboard.TransientType"

    /// False when the drag carries a secret or transient marker. The source app of a
    /// drag is unknown, so Memory's excluded apps cannot be honoured here (C20).
    public static func accepts(types: [String]) -> Bool {
        !types.contains(concealedType) && !types.contains(transientType)
    }
}

/// The shelf's items, persisted in `<directory>/items.json` (0600) with owned copies in
/// `<directory>/<item id>/` (0700); the directory itself is 0700
/// (`~/Library/Application Support/PlatyNotch/shelf.noindex`, or under `PLATYNOTCH_HOME`).
/// The index is a file rather than `UserDefaults` because it can hold dropped text (the
/// same rule as clipboard history, C22). Use from the main actor.
public final class ShelfStore {
    /// Owned copies and text expire this long after they were added, unless pinned.
    public static let ownedLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let indexName = "items.json"
    /// A damaged index moved aside: `items.json.corrupt-<date>`.
    public static let corruptPrefix = "items.json.corrupt-"
    /// Longer dropped text is cut to this many characters.
    public static let maxTextLength = 100_000

    public let directory: URL
    public private(set) var items: [ShelfItem] = []
    /// The index existed but could not be read or decoded. It was moved aside to this
    /// file (0600), and for the rest of this store's life nothing is swept or expired, so
    /// no owned copy is deleted on the strength of an index that lost its items.
    public private(set) var quarantinedIndex: URL?
    /// The bad index could not even be moved aside: nothing is written or deleted.
    public private(set) var readOnly = false
    private var deletionsBlocked: Bool { quarantinedIndex != nil || readOnly }
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "shelf")

    private let persist: Bool
    public let bookmarks: ShelfBookmarks
    private let fileManager: FileManager
    private let now: () -> Date

    /// `persist: false` (smoke runs) never touches the disk: nothing is read or written,
    /// and owned copies cannot be made.
    public init(directory: URL, persist: Bool = true, bookmarks: ShelfBookmarks = FileBookmarks(),
                fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.persist = persist
        self.bookmarks = bookmarks
        self.fileManager = fileManager
        self.now = now
        if persist { load() }
    }

    // MARK: - Adding

    /// Adds `kind` at the front. The same file (by path), text or URL already on the
    /// shelf is not added twice: that item moves to the front, keeping its id and pin.
    @discardableResult
    public func add(_ kind: ShelfItem.Kind) -> ShelfItem {
        var kind = kind
        if case .text(let t) = kind { kind = .text(Self.clean(t)) }
        if case .file(var ref) = kind, ref.bookmark == nil {
            ref.bookmark = bookmarks.make(ref.url)
            kind = .file(ref)
        }
        if let i = items.firstIndex(where: { Self.sameContent($0.kind, kind) }) {
            var item = items.remove(at: i)
            item.addedAt = now()
            items.insert(item, at: 0)
            save()
            return item
        }
        let owned: Bool = if case .text = kind { true } else { false }
        let item = ShelfItem(kind: kind, addedAt: now(), ownsFile: owned)
        items.insert(item, at: 0)
        save()
        return item
    }

    /// A file the user dropped from disk (never owned, never deleted by the shelf).
    @discardableResult
    public func addFile(_ url: URL) -> ShelfItem {
        add(.file(ShelfFileRef(path: url.standardizedFileURL.path)))
    }

    /// Dropped text, trimmed and capped at `maxTextLength`; nil when blank.
    @discardableResult
    public func addText(_ text: String) -> ShelfItem? {
        let t = Self.clean(text)
        guard !t.isEmpty else { return nil }
        return add(.text(t))
    }

    /// A fresh `<directory>/<id>/` (0700) for a promised file to be written into; then
    /// call `addOwnedFile(_:id:)`. Nil when not persisting or the folder cannot be made.
    public func reserveOwnedFolder() -> (id: UUID, folder: URL)? {
        guard persist, !readOnly, ensureDirectory() else { return nil }
        let id = UUID()
        let folder = ownedFolder(id)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        return (id, folder)
    }

    /// Adds a file written into the folder `reserveOwnedFolder` gave for `id`. Refused
    /// (nil) for anything outside that folder, so an owned item can only ever delete
    /// what the shelf itself wrote.
    @discardableResult
    public func addOwnedFile(_ url: URL, id: UUID) -> ShelfItem? {
        let folder = ownedFolder(id).resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(folder), fileManager.fileExists(atPath: path),
              !items.contains(where: { $0.id == id }) else { return nil }
        let ref = ShelfFileRef(path: url.standardizedFileURL.path, bookmark: bookmarks.make(url))
        let item = ShelfItem(id: id, kind: .file(ref), addedAt: now(), ownsFile: true)
        items.insert(item, at: 0)
        save()
        return item
    }

    /// Writes dropped data (an image without a file) as an owned file named `filename`.
    @discardableResult
    public func addOwnedData(_ data: Data, filename: String) -> ShelfItem? {
        guard let (id, folder) = reserveOwnedFolder() else { return nil }
        let url = folder.appendingPathComponent(Self.safeName(filename))
        do {
            try data.write(to: url, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: folder)
            return nil
        }
        return addOwnedFile(url, id: id)
    }

    // MARK: - Changing

    /// Removes the item; an owned item's folder (its copy) is deleted with it.
    public func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        deleteOwned(item)
        save()
    }

    /// Removes every unpinned item (owned copies deleted).
    public func clearUnpinned() {
        let gone = items.filter { !$0.pinned }
        guard !gone.isEmpty else { return }
        items.removeAll { !$0.pinned }
        for item in gone { deleteOwned(item) }
        save()
    }

    /// Moves the item to `index` (clamped).
    public func move(_ id: UUID, to index: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        items.insert(item, at: min(max(index, 0), items.count))
        save()
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].pinned != pinned else { return }
        items[i].pinned = pinned
        save()
    }

    /// Points a (missing) file item at `url` ("Locate…"); keeps its id, pin and place.
    /// The chosen file is the user's, so the item is no longer owned: removing it never
    /// deletes that file, and it does not expire. Only this item's old owned folder is
    /// deleted (never another folder, such as a promise still being written).
    public func relocate(_ id: UUID, to url: URL) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].fileRef != nil else { return }
        let std = url.standardizedFileURL
        let old = items[i]
        items[i].kind = .file(ShelfFileRef(path: std.path, bookmark: bookmarks.make(std)))
        items[i].ownsFile = false
        save()
        let folder = ownedFolder(id).resolvingSymlinksInPath().path + "/"
        if !std.resolvingSymlinksInPath().path.hasPrefix(folder) { deleteOwned(old) }
    }

    /// A folder from `reserveOwnedFolder` that never became an item (a promise that
    /// failed or wrote nothing): deleted. Nothing happens when an item owns it.
    public func discardReserved(_ id: UUID) {
        guard persist, !deletionsBlocked, !items.contains(where: { $0.id == id }) else { return }
        try? fileManager.removeItem(at: ownedFolder(id))
    }

    // MARK: - Moving between stores (baskets, R4)

    /// Moves item `id` to `other` (another store, e.g. a basket's), keeping its id, pin
    /// and added date (so an owned copy still expires 7 days after it was first added).
    /// An owned file's folder moves with one atomic rename, `<directory>/<id>/` to
    /// `<other.directory>/<id>/`; text, links and the user's own files move as records.
    ///
    /// Nothing is ever deleted: on any failure (no such item, `other` already lists the
    /// id, either store not persisting or read-only, the rename failing) the item stays
    /// here, unchanged, and nil is returned. The order of writes keeps a crash safe too:
    /// `other`'s index lists the item before the folder moves, and this index drops it
    /// only after, so no index ever lacks an owned folder the other has (a sweep could
    /// otherwise remove it).
    @discardableResult
    public func transfer(_ id: UUID, to other: ShelfStore) -> ShelfItem? {
        guard other !== self, persist, other.persist, !readOnly, !other.readOnly,
              let i = items.firstIndex(where: { $0.id == id }),
              !other.items.contains(where: { $0.id == id }) else { return nil }
        let item = items[i]
        let ownedFolder = item.ownsFile && item.fileRef != nil
        var moved = item
        if ownedFolder, var ref = item.fileRef {
            let from = self.ownedFolder(id)
            let fromPath = from.standardizedFileURL.path + "/"
            guard fileManager.fileExists(atPath: from.path), ref.path.hasPrefix(fromPath),
                  other.ensureDirectory() else { return nil }
            let to = other.ownedFolder(id)
            ref.path = to.standardizedFileURL.path + "/" + ref.path.dropFirst(fromPath.count)
            ref.bookmark = nil   // made again after the move, when the file is there
            moved.kind = .file(ref)
            other.items.insert(moved, at: 0)
            other.save()
            do {
                try fileManager.moveItem(at: from, to: to)
            } catch {
                other.items.removeAll { $0.id == id }   // only the record; no file is touched
                other.save()
                return nil
            }
            if let bookmark = other.bookmarks.make(ref.url), let j = other.items.firstIndex(where: { $0.id == id }) {
                ref.bookmark = bookmark
                other.items[j].kind = .file(ref)
                moved = other.items[j]
                other.save()
            }
        } else if let j = other.items.firstIndex(where: { Self.sameContent($0.kind, item.kind) }) {
            // The same text, link or file is already there: it moves to the front.
            var existing = other.items.remove(at: j)
            existing.pinned = existing.pinned || item.pinned
            other.items.insert(existing, at: 0)
            moved = existing
            other.save()
        } else {
            other.items.insert(moved, at: 0)
            other.save()
        }
        items.removeAll { $0.id == id }   // the record only: its folder (if any) has moved
        save()
        return moved
    }

    // MARK: - Files on disk

    /// True for a file item whose file is gone or in the Trash (moved or renamed files
    /// are found through the bookmark). Text and URLs are never missing.
    public func isMissing(_ item: ShelfItem, fileManager: FileManager) -> Bool {
        guard let ref = item.fileRef else { return false }
        return Self.resolve(ref, bookmarks: bookmarks, fileManager: fileManager) == .missing
    }

    /// Where a file item is now, or nil when it is missing (then a drag-out is refused).
    /// A stale bookmark is made again, and a moved file's path is updated and saved.
    /// Resolves on the calling thread: prefer `currentURL` on the main thread.
    public func resolvedURL(_ id: UUID) -> URL? {
        guard let ref = items.first(where: { $0.id == id })?.fileRef else { return nil }
        let result = Self.resolve(ref, bookmarks: bookmarks, fileManager: fileManager)
        _ = apply([id: (ref, result)])
        if case .found(let now) = result { return now.url }
        return nil
    }

    /// For a drag out (main thread, must be quick): the stored path when the file is
    /// still there (kept current by `resolve` + `apply` off the main thread), else a full
    /// resolve; nil when missing.
    public func currentURL(_ id: UUID) -> URL? {
        guard let ref = items.first(where: { $0.id == id })?.fileRef else { return nil }
        if Self.usable(ref.url, fileManager) { return ref.url }
        return resolvedURL(id)
    }

    /// Every file item's id and reference (to `resolve` elsewhere, then `apply`).
    public var fileRefs: [(id: UUID, ref: ShelfFileRef)] {
        items.compactMap { item in item.fileRef.map { (item.id, $0) } }
    }

    /// Where `ref` is now, without touching any store: safe on any thread. A found
    /// file's reference has its current path, and a fresh bookmark when the old one was
    /// stale or the file moved.
    public static func resolve(_ ref: ShelfFileRef, bookmarks: ShelfBookmarks,
                               fileManager: FileManager = .default) -> ShelfResolution {
        var found: (url: URL, isStale: Bool)?
        if let data = ref.bookmark, let r = bookmarks.resolve(data), usable(r.url, fileManager) {
            found = r
        } else if usable(ref.url, fileManager) {
            found = (ref.url, false)
        }
        guard let found else { return .missing }
        let path = found.url.standardizedFileURL.path
        guard found.isStale || path != ref.path else { return .found(ref) }
        return .found(ShelfFileRef(path: path, bookmark: bookmarks.make(found.url) ?? ref.bookmark))
    }

    /// Applies `resolve` results (id → the reference resolved, and the result). Items
    /// whose reference changed meanwhile are skipped; moved files are saved with their
    /// new path. Returns the ids of the missing ones.
    public func apply(_ results: [UUID: (ref: ShelfFileRef, result: ShelfResolution)]) -> Set<UUID> {
        var missing = Set<UUID>()
        var changed = false
        for (id, r) in results {
            guard let i = items.firstIndex(where: { $0.id == id }), items[i].fileRef == r.ref else { continue }
            switch r.result {
            case .missing:
                missing.insert(id)
            case .found(let now) where now != r.ref:
                items[i].kind = .file(now)
                changed = true
            case .found:
                break
            }
        }
        if changed { save() }
        return missing
    }

    private static func usable(_ url: URL, _ fm: FileManager) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        if parts.contains(".Trash") || parts.contains(".Trashes") { return false }
        return fm.fileExists(atPath: url.path)
    }

    // MARK: - Expiry

    /// The launch cleanup while the shelf widget is off (no timers, no monitors): reads
    /// the index and removes expired owned copies. It never sweeps orphan folders, and
    /// with a bad index it deletes nothing. Reads nothing when the shelf was never used.
    public static func expireOnDisk(directory: URL, now: Date = Date(),
                                    olderThan: TimeInterval = ownedLifetime) {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(indexName).path) else { return }
        let store = ShelfStore(directory: directory, now: { now })
        store.expireOwned(olderThan: olderThan, now: now)
    }

    /// Removes owned, unpinned items added at or before `now - olderThan` (their copies
    /// deleted). Returns their ids.
    @discardableResult
    public func expireOwned(olderThan: TimeInterval, now: Date) -> [UUID] {
        guard !deletionsBlocked else { return [] }
        let cutoff = now.addingTimeInterval(-olderThan)
        let gone = items.filter { $0.ownsFile && !$0.pinned && $0.addedAt <= cutoff }
        guard !gone.isEmpty else { return [] }
        let ids = Set(gone.map(\.id))
        items.removeAll { ids.contains($0.id) }
        for item in gone { deleteOwned(item) }
        save()
        return gone.map(\.id)
    }

    /// When the next owned, unpinned item expires (nil when none will).
    public func nextExpiry(olderThan: TimeInterval) -> Date? {
        items.filter { $0.ownsFile && !$0.pinned }.map { $0.addedAt.addingTimeInterval(olderThan) }.min()
    }

    /// Deletes `<directory>/<uuid>/` folders no item owns (a promise written before a
    /// crash or quit) once they are older than `olderThan` (the owned lifetime), except
    /// `keeping` (promises still being received). The age rule means a folder that lost
    /// its item some other way is kept as long as an owned copy would have been. Other
    /// names are left alone. Nothing is swept while a moved-aside damaged index
    /// (`items.json.corrupt-*`) is in the directory: the folders it listed are unknown, so
    /// they stay until the user deletes that file (it is the only record of their pins).
    public func sweepOrphans(keeping: Set<UUID> = [], olderThan: TimeInterval = ownedLifetime) {
        guard persist, !deletionsBlocked,
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path),
              !names.contains(where: { $0.hasPrefix(Self.corruptPrefix) }) else { return }
        let owned = listedFolders().union(keeping)
        let cutoff = now().addingTimeInterval(-olderThan)
        for name in names {
            guard let id = UUID(uuidString: name), !owned.contains(id) else { continue }
            let folder = ownedFolder(id)
            let modified = (try? fileManager.attributesOfItem(atPath: folder.path)[.modificationDate]) as? Date
            guard let modified, modified <= cutoff else { continue }
            try? fileManager.removeItem(at: folder)
        }
    }

    // MARK: - Kept after a damaged index (C2)

    /// A damaged index was moved aside (`items.json.corrupt-*`) and is still in the
    /// directory: the sweep is off, and Settings offers to show or delete what it kept.
    public var hasKeptFiles: Bool {
        guard persist, let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains { $0.hasPrefix(Self.corruptPrefix) }
    }

    /// Owned-copy folders (`<uuid>/`) that no item lists, except `keeping` (promises being
    /// received): what a damaged index may have listed, kept until the user decides.
    public func keptFolderCount(keeping: Set<UUID> = []) -> Int {
        unlistedFolders(keeping: keeping).count
    }

    /// The user's "Delete Kept Copies": removes the moved-aside indexes and every owned
    /// folder no item lists (whatever its age), except `keeping`. Sweeping and expiry
    /// work again afterwards. Nothing happens on a read-only shelf.
    public func deleteKeptFiles(keeping: Set<UUID> = []) {
        guard persist, !readOnly else { return }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.corruptPrefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        for id in unlistedFolders(keeping: keeping) { try? fileManager.removeItem(at: ownedFolder(id)) }
        quarantinedIndex = nil
    }

    private func unlistedFolders(keeping: Set<UUID>) -> [UUID] {
        guard persist, let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let listed = listedFolders().union(keeping)
        return names.compactMap { name in
            guard let id = UUID(uuidString: name), !listed.contains(id) else { return nil }
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: ownedFolder(id).path, isDirectory: &isDir)
            return exists && isDir.boolValue ? id : nil
        }
    }

    /// The `<uuid>` folders some item still lists: every owned item's own folder, and the
    /// folder of any file item (owned or not) whose path, standardized and with symlinks
    /// resolved, lies inside `<directory>/<uuid>/` (a kept copy dragged back onto the shelf,
    /// or Locate… pointed at a file in one). Such a folder is never swept or deleted.
    func listedFolders() -> Set<UUID> {
        var ids = Set(items.filter(\.ownsFile).map(\.id))
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for item in items {
            guard let ref = item.fileRef else { continue }
            let path = ref.url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { continue }
            let first = path.dropFirst(root.count).split(separator: "/").first.map(String.init) ?? ""
            if let id = UUID(uuidString: first) { ids.insert(id) }
        }
        return ids
    }

    /// Re-applies the backup and Spotlight exclusion to an existing folder (each start).
    public func markPrivate() {
        guard persist else { return }
        PrivateFolder.mark(directory, fileManager: fileManager)
    }

    // MARK: - Private

    private func ownedFolder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Only ever the item's own `<directory>/<id>/`, never a stored path.
    private func deleteOwned(_ item: ShelfItem) {
        guard persist, !readOnly, item.ownsFile, item.fileRef != nil else { return }
        try? fileManager.removeItem(at: ownedFolder(item.id))
    }

    private static func sameContent(_ a: ShelfItem.Kind, _ b: ShelfItem.Kind) -> Bool {
        switch (a, b) {
        case (.file(let x), .file(let y)):
            URL(fileURLWithPath: x.path).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: y.path).resolvingSymlinksInPath().path
        case (.text(let x), .text(let y)): x == y
        case (.url(let x), .url(let y)): x == y
        default: false
        }
    }

    private static func clean(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextLength))
    }

    /// A single path component: no separators, no leading dots, never empty.
    static func safeName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let trimmed = String(last.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Item" : String(trimmed.prefix(200))
    }

    @discardableResult
    private func ensureDirectory() -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if !PrivateFolder.isMarked(directory, fileManager: fileManager) { PrivateFolder.mark(directory, fileManager: fileManager) }
            return true
        } catch {
            return false
        }
    }

    private var indexURL: URL { directory.appendingPathComponent(Self.indexName) }

    /// Reads the index. A missing one is an empty shelf. One that exists but cannot be
    /// read or decoded is moved aside (`items.json.corrupt-<date>`, 0600) and blocks every
    /// sweep and expiry: the shelf starts empty and no folder is deleted.
    /// A file item stored under the shelf's folder before it was renamed to `.noindex`
    /// (`<parent>/shelf/…`): its path is moved to the same place under `directory`, so an
    /// owned copy without a usable bookmark still resolves after the migration.
    private func rebased(_ item: ShelfItem) -> ShelfItem {
        guard var ref = item.fileRef, directory.pathExtension == "noindex" else { return item }
        let oldRoot = directory.deletingPathExtension().standardizedFileURL.path + "/"
        guard ref.path.hasPrefix(oldRoot) else { return item }
        ref.path = directory.standardizedFileURL.path + "/" + ref.path.dropFirst(oldRoot.count)
        var out = item
        out.kind = .file(ref)
        return out
    }

    private func load() {
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = decoded.map(rebased)
            return
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: now()).replacingOccurrences(of: ":", with: "-")
        var aside = directory.appendingPathComponent("\(Self.corruptPrefix)\(stamp)")
        if fileManager.fileExists(atPath: aside.path) {
            aside = directory.appendingPathComponent("\(Self.corruptPrefix)\(stamp)-\(UUID().uuidString.prefix(8))")
        }
        do {
            try fileManager.moveItem(at: indexURL, to: aside)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside.path)
            quarantinedIndex = aside
            Self.log.error("shelf index unreadable; moved aside to \(aside.lastPathComponent, privacy: .public); no copies deleted")
        } catch {
            readOnly = true
            Self.log.error("shelf index unreadable and could not be moved aside; the shelf will not write or delete")
        }
    }

    private func save() {
        guard persist, !readOnly, ensureDirectory(), let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: indexURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            // Best effort: the shelf keeps working in memory.
        }
    }
}
