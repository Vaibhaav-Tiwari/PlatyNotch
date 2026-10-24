import Foundation
import os

/// Clipboard history on disk (C22): `<directory>/history.json` (0600, written atomically)
/// and copied images as `<directory>/images/<item id>.png` (0600); both folders are 0700
/// (`~/Library/Application Support/PlatyNotch/clipboard`, or under `PLATYNOTCH_HOME`).
/// Never `UserDefaults`, never a log: history holds whatever the user copied.
///
/// Mirrors the shelf's data-safety rules: an unreadable index is moved aside
/// (`history.json.corrupt-<date>`, 0600) and never causes a delete. While such a file is
/// in the directory no orphan image is swept, so the next start does not wipe the images
/// the lost index listed; only "Delete kept files" (`deleteKeptFiles`) removes them.
/// An item that is removed, cleared or trimmed takes its own image file with it.
/// Use from the main actor.
public final class ClipboardStore {
    public static let indexName = "history.json"
    public static let corruptPrefix = "history.json.corrupt-"
    public static let imagesFolder = "images"
    /// Larger images are not kept.
    public static let maxImageBytes = 10 * 1024 * 1024
    /// Longer text is not kept (a truncated copy would paste the wrong thing).
    public static let maxTextLength = 200_000

    public let directory: URL
    public private(set) var history: ClipboardHistory
    public var items: [ClipItem] { history.items }
    /// The index existed but could not be read; it was moved here.
    public private(set) var quarantinedIndex: URL?
    /// The bad index could not even be moved aside: nothing is written or deleted.
    public private(set) var readOnly = false

    private static let log = Logger(subsystem: "dev.platynotch.app", category: "clipboard")
    private let persist: Bool
    private let fileManager: FileManager
    private let now: () -> Date

    /// `persist: false` (smoke runs) never touches the disk and keeps no images.
    public init(directory: URL, persist: Bool = true, limit: Int = ClipboardHistory.defaultLimit,
                maxAge: TimeInterval = ClipboardHistory.defaultMaxAge,
                fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.persist = persist
        self.fileManager = fileManager
        self.now = now
        history = ClipboardHistory(limit: limit, maxAge: maxAge)
        if persist { load() }
    }

    private var imagesDirectory: URL { directory.appendingPathComponent(Self.imagesFolder, isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent(Self.indexName) }

    // MARK: - Recording

    /// Records text, a URL or files (not images: `recordImage`). Blank text, text over
    /// `maxTextLength` and an empty file list are refused (nil). Returns the item now at
    /// the top (an existing one when the content was already there).
    @discardableResult
    public func record(_ kind: ClipItem.Kind, source: String?) -> ClipItem? {
        switch kind {
        case .text(let t):
            guard t.count <= Self.maxTextLength,
                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        case .files(let urls):
            guard !urls.isEmpty else { return nil }
        case .url:
            break
        case .image:
            return nil
        }
        return add(ClipItem(kind: kind, sourceBundleID: source, copiedAt: now()))
    }

    /// Records PNG data (at most `maxImageBytes`). The same picture already in history
    /// moves to the top and nothing is written. Nil when too large, not persisting, or
    /// the file cannot be written.
    @discardableResult
    public func recordImage(png: Data, width: Int, height: Int, source: String?) -> ClipItem? {
        guard png.count <= Self.maxImageBytes else { return nil }
        let hash = ClipHash.image(png)
        if let existing = history.items.first(where: { $0.hash == hash }) {
            return add(ClipItem(kind: existing.kind, sourceBundleID: source, copiedAt: now(), hash: hash))
        }
        guard persist, !readOnly, ensureDirectories() else { return nil }
        let id = UUID()
        let url = imageFile(id)
        do {
            try png.write(to: url, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return add(ClipItem(id: id, kind: .image(fileURL: url, width: width, height: height),
                            sourceBundleID: source, copiedAt: now(), hash: hash))
    }

    private func add(_ item: ClipItem) -> ClipItem? {
        let removed = history.record(item, now: now())
        deleteImages(removed)
        save()
        return history.items.first { $0.hash == item.hash }
    }

    // MARK: - Changing

    public func remove(_ id: UUID) {
        guard let item = history.remove(id) else { return }
        deleteImages([item])
        save()
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard history.items.contains(where: { $0.id == id && $0.pinned != pinned }) else { return }
        history.setPinned(id, pinned)
        save()
    }

    /// Moves an item to the top (pasted from the picker).
    public func touch(_ id: UUID) {
        history.touch(id, now: now())
        save()
    }

    /// "Clear history" (keeps pinned) or everything; images deleted with their items.
    public func clear(keepingPinned: Bool) {
        let gone = history.clear(keepingPinned: keepingPinned)
        guard !gone.isEmpty else { return }
        deleteImages(gone)
        save()
    }

    /// New limit and age (Settings); trims at once.
    public func setRetention(limit: Int, maxAge: TimeInterval) {
        history.limit = max(1, limit)
        history.maxAge = max(1, maxAge)
        trim()
    }

    /// Removes what is past the age or limit (images deleted).
    public func trim() {
        let gone = history.trim(now: now())
        guard !gone.isEmpty else { return }
        deleteImages(gone)
        save()
    }

    /// When the oldest unpinned item expires (nil when none will).
    public var nextExpiry: Date? {
        history.items.filter { !$0.pinned }.map { $0.copiedAt.addingTimeInterval(history.maxAge) }.min()
    }

    /// The image file of an `.image` item, only when it is this store's own
    /// `images/<item id>.png` (never a path from elsewhere).
    public func imageURL(for item: ClipItem) -> URL? {
        guard case .image(let stored, _, _) = item.kind else { return nil }
        let own = imageFile(item.id)
        guard stored.standardizedFileURL.path == own.standardizedFileURL.path else { return nil }
        return own
    }

    // MARK: - Files the index does not list

    /// Re-applies the backup and Spotlight exclusion to an existing folder (each start).
    public func markPrivate() {
        guard persist else { return }
        PrivateFolder.mark(directory, fileManager: fileManager)
    }

    /// A damaged index was moved aside and is still in the directory.
    public var hasKeptFiles: Bool {
        guard persist, let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains { $0.hasPrefix(Self.corruptPrefix) }
    }

    /// Deletes `images/<uuid>.png` files no item lists once they are older than
    /// `olderThan` (default: the history's age), e.g. an image written just before a
    /// crash. Does nothing while a damaged index is kept (`hasKeptFiles`).
    public func sweepOrphanImages(olderThan: TimeInterval? = nil) {
        guard persist, !readOnly, !hasKeptFiles,
              let names = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        let listed = Set(history.items.map(\.id))
        let cutoff = now().addingTimeInterval(-(olderThan ?? history.maxAge))
        for name in names {
            guard name.hasSuffix(".png"), let id = UUID(uuidString: String(name.dropLast(4))),
                  !listed.contains(id) else { continue }
            let url = imageFile(id)
            let modified = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            guard let modified, modified <= cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// The user's "Delete kept files": removes moved-aside indexes and every image no
    /// current item lists, whatever its age.
    public func deleteKeptFiles() {
        guard persist, !readOnly else { return }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.corruptPrefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        quarantinedIndex = nil
        sweepOrphanImages(olderThan: -.greatestFiniteMagnitude)
    }

    /// The launch cleanup while the clipboard widget is off (no timers): trims history by
    /// age and limit, deleting those images. Reads nothing when history was never used;
    /// deletes nothing with a damaged index.
    public static func expireOnDisk(directory: URL, limit: Int, maxAge: TimeInterval, now: Date = Date()) {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(indexName).path) else { return }
        let store = ClipboardStore(directory: directory, limit: limit, maxAge: maxAge, now: { now })
        guard store.quarantinedIndex == nil else { return }
        store.trim()
    }

    // MARK: - Private

    private func imageFile(_ id: UUID) -> URL {
        imagesDirectory.appendingPathComponent("\(id.uuidString).png")
    }

    /// Only ever each item's own `images/<id>.png`.
    private func deleteImages(_ items: [ClipItem]) {
        guard persist, !readOnly else { return }
        for item in items {
            if let url = imageURL(for: item) { try? fileManager.removeItem(at: url) }
        }
    }

    @discardableResult
    private func ensureDirectories() -> Bool {
        do {
            for dir in [directory, imagesDirectory] {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
            if !PrivateFolder.isMarked(directory, fileManager: fileManager) { PrivateFolder.mark(directory, fileManager: fileManager) }
            return true
        } catch {
            return false
        }
    }

    private struct IndexFile: Codable {
        var version = 1
        var items: [ClipItem]
    }

    private func load() {
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode(IndexFile.self, from: data) {
            history.items = decoded.items
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
            Self.log.error("clipboard index unreadable; moved aside to \(aside.lastPathComponent, privacy: .public); no images deleted")
        } catch {
            readOnly = true
            Self.log.error("clipboard index unreadable and could not be moved aside; history will not write or delete")
        }
    }

    private func save() {
        guard persist, !readOnly, ensureDirectories(),
              let data = try? JSONEncoder().encode(IndexFile(items: history.items)) else { return }
        do {
            try data.write(to: indexURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            // Best effort: history keeps working in memory.
        }
    }
}
