import CoreGraphics
import Darwin
import Foundation
import os

/// A basket's color (six, one per basket while they last).
public enum BasketColor: String, Codable, CaseIterable, Sendable {
    case blue, green, orange, pink, purple, teal

    /// The `index`-th color, wrapping (a new basket takes the first one not in use).
    public init(index: Int) {
        let all = Self.allCases
        self = all[((index % all.count) + all.count) % all.count]
    }

    /// What menus and VoiceOver say.
    public var title: String { rawValue.capitalized }
}

/// A floating basket: a small list of shelf items (its own `ShelfStore`) that sits where
/// the user shook a drag. `items` is a snapshot of that store, newest first.
public struct Basket: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: BasketColor
    public var items: [ShelfItem]
    /// A pinned basket (or one holding a pinned item) is kept after quit; any other is
    /// cleared then, its own copies deleted.
    public var pinned: Bool
    /// Its window's bottom-left corner (AppKit screen coordinates).
    public var origin: CGPoint

    public init(id: UUID = UUID(), name: String, color: BasketColor, items: [ShelfItem] = [],
                pinned: Bool = false, origin: CGPoint = .zero) {
        self.id = id
        self.name = name
        self.color = color
        self.items = items
        self.pinned = pinned
        self.origin = origin
    }

    /// Kept after quit: pinned, or holding a pinned item (never drop what the user pinned).
    public var isKept: Bool { pinned || items.contains(where: \.pinned) }
}

/// What is saved in defaults for a kept basket: never its items (they are in its own
/// folder's index, which can hold dropped text, C22).
public struct BasketRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: BasketColor
    public var pinned: Bool
    public var origin: CGPoint

    public init(_ basket: Basket) {
        id = basket.id
        name = basket.name
        color = basket.color
        pinned = basket.pinned
        origin = basket.origin
    }
}

/// Up to `maxBaskets` baskets of up to `maxItems` items each (R4). Each basket is its own
/// `ShelfStore` at `<directory>/<basket id>/` (`CorePaths.baskets()`, 0700), so its owned
/// copies live in its own folder and no store's sweep ever sees another's. Items move
/// between stores only with `ShelfStore.transfer` (one atomic folder rename; nothing is
/// deleted on failure).
///
/// The list is kept in memory. Only kept baskets (pinned, or holding a pinned item) are
/// recorded in defaults (`recordsKey`: id, name, color, pin, place; never items) and come
/// back at the next start; every other basket is cleared when the feature stops (quit or
/// turned off).
@MainActor
public final class BasketStore {
    public static let maxBaskets = 6
    public static let maxItems = 50
    public static let recordsKey = "baskets.kept"
    private nonisolated static let log = Logger(subsystem: "dev.platynotch.app", category: "baskets")

    public let directory: URL
    /// Where `close(_:keepItems: true)` and `moveAllToShelf` put items (nil: the shelf is off).
    public var shelf: @MainActor () -> ShelfStore? = { nil }
    /// Items arrived on the shelf (it re-reads its store).
    public var shelfChanged: @MainActor () -> Void = {}

    private struct Entry {
        var meta: Basket   // `items` is filled from the store when read
        let store: ShelfStore
    }

    private var entries: [Entry] = []
    private let persist: Bool
    /// Where kept baskets are recorded (nil: nowhere). Set before `restore`.
    public var defaults: UserDefaults?
    private let bookmarks: ShelfBookmarks
    private let now: () -> Date
    private let renameFolder: ShelfStore.FolderRename
    private let fileManager = FileManager.default

    /// `persist: false` (smoke runs, tests of the window logic) never touches the disk.
    /// `defaults` nil: nothing is recorded.
    public init(directory: URL, persist: Bool = true, defaults: UserDefaults? = nil,
                bookmarks: ShelfBookmarks = FileBookmarks(), now: @escaping () -> Date = Date.init,
                renameFolder: @escaping ShelfStore.FolderRename = ShelfStore.renameExclusive) {
        self.directory = directory
        self.persist = persist
        self.defaults = defaults
        self.bookmarks = bookmarks
        self.now = now
        self.renameFolder = renameFolder
    }

    // MARK: - Reading

    /// Every basket, oldest first, with its items now.
    public var baskets: [Basket] { entries.map(snapshot) }

    public func basket(_ id: UUID) -> Basket? {
        entries.first { $0.meta.id == id }.map(snapshot)
    }

    /// The basket's own store (its host reads and changes items through it).
    public func store(for id: UUID) -> ShelfStore? {
        entries.first { $0.meta.id == id }?.store
    }

    public var isFull: Bool { entries.count >= Self.maxBaskets }

    /// How many more items basket `id` takes.
    public func room(in id: UUID) -> Int {
        guard let s = store(for: id) else { return 0 }
        return max(0, Self.maxItems - s.items.count)
    }

    private func snapshot(_ e: Entry) -> Basket {
        var b = e.meta
        b.items = e.store.items
        return b
    }

    // MARK: - Making and changing baskets

    /// A new, empty basket whose window goes at `origin`; nil when `maxBaskets` exist.
    /// It takes the first color and the lowest "Basket N" not in use.
    @discardableResult
    public func create(at origin: CGPoint) -> Basket? {
        guard !isFull else { return nil }
        let usedColors = Set(entries.map(\.meta.color))
        let color = BasketColor.allCases.first { !usedColors.contains($0) } ?? BasketColor(index: entries.count)
        let names = Set(entries.map(\.meta.name))
        let n = (1...).first { !names.contains("Basket \($0)") } ?? 1
        let meta = Basket(name: "Basket \(n)", color: color, origin: origin)
        entries.append(Entry(meta: meta, store: openStore(meta.id)))
        return meta
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) { change(id) { $0.pinned = pinned } }
    public func setColor(_ id: UUID, _ color: BasketColor) { change(id) { $0.color = color } }
    public func setOrigin(_ id: UUID, _ origin: CGPoint) { change(id) { $0.origin = origin } }

    /// Blank names are refused; long ones are cut to 40 characters.
    public func rename(_ id: UUID, to name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty else { return }
        change(id) { $0.name = clean }
    }

    private func change(_ id: UUID, _ edit: (inout Basket) -> Void) {
        guard let i = entries.firstIndex(where: { $0.meta.id == id }) else { return }
        edit(&entries[i].meta)
        saveRecords()
    }

    // MARK: - Moving items

    /// Moves `itemIDs` (from any other basket) into basket `basketID`, each with one
    /// `ShelfStore.transfer`, while it has room. Returns the ids moved; anything that
    /// could not move stays where it was, unchanged.
    @discardableResult
    public func move(itemIDs: [UUID], to basketID: UUID) -> [UUID] {
        guard let target = store(for: basketID) else { return [] }
        var moved: [UUID] = []
        // Oldest first, so the moved items keep their order at the front of the target.
        for id in itemIDs.reversed() {
            guard target.items.count < Self.maxItems,
                  let source = entries.first(where: { $0.meta.id != basketID && $0.store.items.contains { $0.id == id } })?.store,
                  source.transfer(id, to: target) != nil else { continue }
            moved.append(id)
        }
        return moved.reversed()
    }

    /// Drags basket `source` onto basket `target`: every item that fits moves; the source
    /// closes once empty. Returns how many moved.
    @discardableResult
    public func merge(_ source: UUID, into target: UUID) -> Int {
        guard source != target, let s = store(for: source), store(for: target) != nil else { return 0 }
        let moved = move(itemIDs: s.items.map(\.id), to: target)
        if s.items.isEmpty { close(source, keepItems: false) }
        return moved.count
    }

    /// "Move All to Shelf": every item into the shelf's store (each with
    /// `ShelfStore.transfer`). Returns the ids moved; none while the shelf is off.
    @discardableResult
    public func moveAllToShelf(_ id: UUID) -> [UUID] {
        guard let source = store(for: id), let shelf = shelf() else { return [] }
        var moved: [UUID] = []
        for item in source.items.reversed() where source.transfer(item.id, to: shelf) != nil {
            moved.append(item.id)
        }
        if !moved.isEmpty { shelfChanged() }
        return moved.reversed()
    }

    /// Closes basket `id`. `keepItems`: its items go to the shelf first, and when any of
    /// them cannot (the shelf is off, a transfer failed) the basket stays open with them and
    /// false is returned. Otherwise its items are removed: its own copies are deleted, the
    /// user's files never are.
    @discardableResult
    public func close(_ id: UUID, keepItems: Bool) -> Bool {
        guard let i = entries.firstIndex(where: { $0.meta.id == id }) else { return false }
        let store = entries[i].store
        if keepItems, !store.items.isEmpty {
            moveAllToShelf(id)
            guard store.items.isEmpty else { return false }
        }
        entries.remove(at: i)
        discard(store)
        saveRecords()
        return true
    }

    /// The feature stops (quit, or turned off): every basket that is not kept is closed
    /// (items removed, own copies deleted), and the kept ones are recorded.
    public func clearUnkept() {
        for e in entries where !snapshot(e).isKept { close(e.meta.id, keepItems: false) }
        saveRecords()
    }

    // MARK: - Start

    /// Brings back the kept baskets recorded in defaults (owned copies past 7 days
    /// expire), and clears folders of baskets that were not kept (left by a crash): their
    /// items are removed and own copies deleted, unless the folder's index is damaged
    /// (then nothing in it is deleted, and it counts in `damagedCount`) or it holds a
    /// pinned item (then it comes back as a basket). When the record list itself is there
    /// but unreadable, nothing is cleared: every leftover folder holding items comes back
    /// as a pinned "Recovered Basket" instead. At most `maxBaskets` come back; folders
    /// beyond that are left alone.
    public func restore() {
        guard persist, entries.isEmpty else { return }
        let read = Self.readRecords(from: defaults)
        let recordsReadable = read != nil
        var seen = Set<UUID>()
        for r in read ?? [] where entries.count < Self.maxBaskets && seen.insert(r.id).inserted {
            let store = openStore(r.id)
            prepare(store)
            let meta = Basket(id: r.id, name: r.name, color: r.color, pinned: r.pinned, origin: r.origin)
            entries.append(Entry(meta: meta, store: store))
        }
        damagedFolders = []
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() {
            guard let id = UUID(uuidString: name), !seen.contains(id) else { continue }
            let store = openStore(id)
            if Self.isDamaged(store) {
                damagedFolders.append(store.directory)
                continue
            }
            let adopt = recordsReadable ? store.items.contains(where: \.pinned) : !store.items.isEmpty
            if adopt, entries.count < Self.maxBaskets {
                prepare(store)
                let usedColors = Set(entries.map(\.meta.color))
                let color = BasketColor.allCases.first { !usedColors.contains($0) } ?? .blue
                let title = recordsReadable ? "Kept Basket" : "Recovered Basket"
                entries.append(Entry(meta: Basket(id: id, name: title, color: color, pinned: true), store: store))
                seen.insert(id)
            } else if recordsReadable, !store.items.contains(where: \.pinned) {
                discard(store)
            }
        }
        saveRecords()
    }

    // MARK: - Damaged indexes (kept until the user decides, like the shelf's C2)

    /// Leftover basket folders whose index is damaged: nothing in them was deleted.
    public private(set) var damagedFolders: [URL] = []

    /// Basket folders holding copies a damaged index may have listed (open baskets and
    /// leftovers): Settings shows the count with Delete Kept Copies.
    public var damagedCount: Int {
        damagedFolders.count + entries.filter { Self.isDamaged($0.store) }.count
    }

    /// The user's "Delete Kept Copies" (after a confirming click): leftover damaged folders
    /// are deleted; an open basket keeps its items and loses only the set-aside index and
    /// the copies no item lists.
    public func deleteDamaged() {
        guard persist else { return }
        for dir in damagedFolders { try? fileManager.removeItem(at: dir) }
        damagedFolders = []
        for e in entries where Self.isDamaged(e.store) { e.store.deleteKeptFiles() }
    }

    private static func isDamaged(_ store: ShelfStore) -> Bool {
        store.quarantinedIndex != nil || store.readOnly || store.hasKeptFiles
    }

    /// Owned copies past 7 days go; then folders no item lists (a promise cut short).
    private func prepare(_ store: ShelfStore) {
        store.markPrivate()
        store.expireOwned(olderThan: ShelfStore.ownedLifetime, now: now())
        store.sweepOrphans()
    }

    /// Owned copies past 7 days in every basket (the widget's expiry wake-up).
    public func expireOwned() {
        for e in entries { e.store.expireOwned(olderThan: ShelfStore.ownedLifetime, now: now()) }
    }

    /// When the next owned copy in any basket expires.
    public func nextExpiry() -> Date? {
        entries.compactMap { $0.store.nextExpiry(olderThan: ShelfStore.ownedLifetime) }.min()
    }

    // MARK: - Folders

    private func openStore(_ id: UUID) -> ShelfStore {
        ShelfStore(directory: directory.appendingPathComponent(id.uuidString, isDirectory: true),
                   persist: persist, bookmarks: bookmarks, now: now, renameFolder: renameFolder)
    }

    /// Removes a closed basket's items (own copies deleted, the user's files untouched)
    /// and then its folder, only if nothing else is left in it. A damaged index (set
    /// aside, or unreadable) means nothing is deleted.
    private func discard(_ store: ShelfStore) {
        guard persist, store.quarantinedIndex == nil, !store.readOnly, !store.hasKeptFiles else { return }
        for item in store.items { store.remove(item.id) }
        // Folders no item lists (a promise cut short): this basket is going.
        store.sweepOrphans(olderThan: 0)
        let dir = store.directory
        // Then only files of our own making (the index, the Spotlight marker, Finder's).
        for name in [ShelfStore.indexName, PrivateFolder.neverIndexName, ".DS_Store"] {
            try? fileManager.removeItem(at: dir.appendingPathComponent(name))
        }
        if Darwin.rmdir(dir.path) != 0, errno != ENOENT {
            Self.log.info("basket folder kept: not empty")
        }
    }

    // MARK: - Records

    public static func loadRecords(from defaults: UserDefaults?) -> [BasketRecord] {
        readRecords(from: defaults) ?? []
    }

    /// The records; nil when they are there but cannot be read (none saved is `[]`).
    public static func readRecords(from defaults: UserDefaults?) -> [BasketRecord]? {
        guard let defaults, let value = defaults.object(forKey: recordsKey) else { return [] }
        guard let data = value as? Data,
              let records = try? JSONDecoder().decode([BasketRecord].self, from: data) else { return nil }
        return records
    }

    /// Records the kept baskets (only those).
    private func saveRecords() {
        guard persist, let defaults else { return }
        let kept = entries.map(snapshot).filter(\.isKept).map(BasketRecord.init)
        if kept.isEmpty {
            defaults.removeObject(forKey: Self.recordsKey)
        } else if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: Self.recordsKey)
        }
    }

    /// Re-records after items changed (a pin on an item can make a basket kept).
    public func itemsChanged() { saveRecords() }
}

/// The basket switcher's shortcut (rebindable from presets; R6: none is the clipboard's
/// or window snapping's) and the shake sensitivity, as saved in defaults.
public enum BasketSettings {
    /// `HotKeyCatalog` feature id.
    public static let switcherFeature = "baskets.switcher"
    public static let switcherKey = "baskets.switcherKey"
    public static let sensitivityKey = "baskets.shakeSensitivity"
    /// ⌃⌥B (the default), ⌃⇧B, ⌃⌥⌘B.
    public static let switcherPresets: [KeyCombo] = [
        KeyCombo(keyCode: 11, modifiers: KeyCombo.control | KeyCombo.option),
        KeyCombo(keyCode: 11, modifiers: KeyCombo.control | KeyCombo.shift),
        KeyCombo(keyCode: 11, modifiers: KeyCombo.control | KeyCombo.option | KeyCombo.command),
    ]
    private static let off = "off"

    /// The chosen shortcut: the default until changed; nil when turned off. A saved combo
    /// that is not a preset reads as the default.
    public static func switcherCombo(_ defaults: UserDefaults) -> KeyCombo? {
        if defaults.string(forKey: switcherKey) == off { return nil }
        guard let data = defaults.data(forKey: switcherKey),
              let combo = try? JSONDecoder().decode(KeyCombo.self, from: data),
              switcherPresets.contains(combo) else { return switcherPresets[0] }
        return combo
    }

    public static func setSwitcherCombo(_ combo: KeyCombo?, _ defaults: UserDefaults) {
        guard let combo else { return defaults.set(off, forKey: switcherKey) }
        guard switcherPresets.contains(combo), let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: switcherKey)
    }

    /// 1…5, default 3 (`ShakeDetector`).
    public static func sensitivity(_ defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: sensitivityKey) != nil else { return ShakeDetector.defaultSensitivity }
        let v = defaults.integer(forKey: sensitivityKey)
        return min(max(v, ShakeDetector.sensitivityRange.lowerBound), ShakeDetector.sensitivityRange.upperBound)
    }

    public static func setSensitivity(_ value: Int, _ defaults: UserDefaults) {
        let v = min(max(value, ShakeDetector.sensitivityRange.lowerBound), ShakeDetector.sensitivityRange.upperBound)
        defaults.set(v, forKey: sensitivityKey)
    }
}
