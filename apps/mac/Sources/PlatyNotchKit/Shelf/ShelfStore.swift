import Foundation

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

/// Makes and resolves file bookmarks (a seam for tests).
public protocol ShelfBookmarks {
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
/// (`~/Library/Application Support/PlatyNotch/shelf`, or under `PLATYNOTCH_HOME`).
/// The index is a file rather than `UserDefaults` because it can hold dropped text (the
/// same rule as clipboard history, C22). Use from the main actor.
public final class ShelfStore {
    /// Owned copies and text expire this long after they were added, unless pinned.
    public static let ownedLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let indexName = "items.json"
    /// Longer dropped text is cut to this many characters.
    public static let maxTextLength = 100_000

    public let directory: URL
    public private(set) var items: [ShelfItem] = []

    private let persist: Bool
    private let bookmarks: ShelfBookmarks
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
        guard persist, ensureDirectory() else { return nil }
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
    public func relocate(_ id: UUID, to url: URL) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].fileRef != nil else { return }
        let std = url.standardizedFileURL
        items[i].kind = .file(ShelfFileRef(path: std.path, bookmark: bookmarks.make(std)))
        save()
    }

    // MARK: - Files on disk

    /// True for a file item whose file is gone or in the Trash (moved or renamed files
    /// are found through the bookmark). Text and URLs are never missing.
    public func isMissing(_ item: ShelfItem, fileManager: FileManager) -> Bool {
        guard let ref = item.fileRef else { return false }
        return locate(ref, fileManager: fileManager) == nil
    }

    /// Where a file item is now, or nil when it is missing (then a drag-out is refused).
    /// A stale bookmark is made again, and a moved file's path is updated and saved.
    public func resolvedURL(_ id: UUID) -> URL? {
        guard let i = items.firstIndex(where: { $0.id == id }), let ref = items[i].fileRef,
              let found = locate(ref, fileManager: fileManager) else { return nil }
        let path = found.url.standardizedFileURL.path
        if found.isStale || path != ref.path {
            let fresh = bookmarks.make(found.url) ?? ref.bookmark
            items[i].kind = .file(ShelfFileRef(path: path, bookmark: fresh))
            save()
        }
        return found.url
    }

    private func locate(_ ref: ShelfFileRef, fileManager: FileManager) -> (url: URL, isStale: Bool)? {
        if let data = ref.bookmark, let r = bookmarks.resolve(data), usable(r.url, fileManager) {
            return r
        }
        return usable(ref.url, fileManager) ? (ref.url, false) : nil
    }

    private func usable(_ url: URL, _ fm: FileManager) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        if parts.contains(".Trash") || parts.contains(".Trashes") { return false }
        return fm.fileExists(atPath: url.path)
    }

    // MARK: - Expiry

    /// Removes owned, unpinned items added at or before `now - olderThan` (their copies
    /// deleted). Returns their ids.
    @discardableResult
    public func expireOwned(olderThan: TimeInterval, now: Date) -> [UUID] {
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
    /// crash or quit), except `keeping` (promises still being received). Other names
    /// in the directory are left alone.
    public func sweepOrphans(keeping: Set<UUID> = []) {
        guard persist, let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let owned = Set(items.filter(\.ownsFile).map(\.id)).union(keeping)
        for name in names {
            guard let id = UUID(uuidString: name), !owned.contains(id) else { continue }
            try? fileManager.removeItem(at: ownedFolder(id))
        }
    }

    // MARK: - Private

    private func ownedFolder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Only ever the item's own `<directory>/<id>/`, never a stored path.
    private func deleteOwned(_ item: ShelfItem) {
        guard persist, item.ownsFile, item.fileRef != nil else { return }
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
            return true
        } catch {
            return false
        }
    }

    private var indexURL: URL { directory.appendingPathComponent(Self.indexName) }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard persist, ensureDirectory(), let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: indexURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            // Best effort: the shelf keeps working in memory.
        }
    }
}
