import AppKit
import Observation
import os
import PlatyNotchKit

/// One basket's items as the shelf's cards see them (`ItemListHost`, R4): its own
/// `ShelfStore` at `baskets.noindex/<basket id>/`, a selection, drags out, Locate… and,
/// while File actions runs, every shelf action (`FileActionResults`: results are owned
/// items in this basket's folder). Takes drops on its window like the shelf does, up to
/// `BasketStore.maxItems`: the drag pasteboard is read only on the drop, and nothing
/// marked concealed or transient is kept.
@MainActor @Observable
final class BasketHost: ItemListHost, FileActionResults, Identifiable {
    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "baskets")

    let id: UUID
    private(set) var items: [ShelfItem] = []
    private(set) var missing: Set<UUID> = []
    var selection: Set<UUID> = []
    private(set) var name: String
    private(set) var color: BasketColor
    private(set) var pinned: Bool
    /// A drag the basket would take is over its window.
    private(set) var dropTargeted = false
    /// Briefly true after the switcher brings it forward.
    var highlighted = false
    /// A drag of this basket's items is in progress.
    private(set) var outgoingDrag = false
    /// The close question shown inside the basket (`BasketController.requestClose`).
    var closeAsk: BasketCloseAsk?

    @ObservationIgnored let store: ShelfStore
    @ObservationIgnored weak var owner: BasketController?
    /// Owned folders a file promise is still being written into (the basket waits to close).
    @ObservationIgnored private(set) var receiving: Set<UUID> = []
    /// Folders reserved for a file action's result, not yet an item.
    @ObservationIgnored private(set) var reserved: Set<UUID> = []
    /// Each receiving folder's timeout (cancelled when it finishes or the basket stops).
    @ObservationIgnored private var receiveTimeouts: [UUID: Task<Void, Never>] = [:]
    var pendingTimeouts: Int { receiveTimeouts.count }
    /// A promise still unfinished after this long no longer holds the basket open (M4).
    static let promiseTimeout: TimeInterval = 60
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async -> Void
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    @ObservationIgnored private(set) var importTask: Task<Void, Never>?
    @ObservationIgnored private(set) lazy var dragSource: NSDraggingSource = ShelfDragSource(host: self)
    @ObservationIgnored var fileActionsOn: @MainActor () -> Bool = { false }
    @ObservationIgnored private let makeActionCenter: @MainActor () -> FileActionCenter
    @ObservationIgnored private(set) lazy var actionCenter: FileActionCenter = {
        let c = makeActionCenter()
        c.results = self
        return c
    }()
    @ObservationIgnored private var actionCenterMade = false
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "dev.platynotch.baskets.promises"
        q.qualityOfService = .userInitiated
        return q
    }()

    init(basket: Basket, store: ShelfStore, clock: @escaping () -> Date = Date.init,
         actions: @escaping @MainActor () -> FileActionCenter = { FileActionCenter() },
         sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
        id = basket.id
        name = basket.name
        color = basket.color
        pinned = basket.pinned
        self.store = store
        self.clock = clock
        makeActionCenter = actions
        items = store.items
    }

    /// Name, color and pin from the store's record.
    func update(from basket: Basket) {
        if name != basket.name { name = basket.name }
        if color != basket.color { color = basket.color }
        if pinned != basket.pinned { pinned = basket.pinned }
        sync()
    }

    /// How many more items it takes: promises still arriving and results still being made
    /// count too (M3).
    var room: Int {
        let ids = Set(store.items.map(\.id))
        let pending = receiving.subtracting(ids).count + reserved.subtracting(ids).count
        return max(0, BasketStore.maxItems - store.items.count - pending)
    }

    /// A file promise is still being written into it, or a file action runs on one of its
    /// items: it is not closed or merged until that ends (its folders must stay).
    var isBusy: Bool {
        !receiving.isEmpty || (actionCenterMade && !actionCenter.running.isEmpty)
    }

    /// Anything still running for this basket stops (the feature stops or it closes).
    func cancelWork() {
        refreshTask?.cancel()
        importTask?.cancel()
        for t in receiveTimeouts.values { t.cancel() }
        receiveTimeouts = [:]
        if actionCenterMade { actionCenter.cancelAll() }
    }

    // MARK: - ItemListHost

    func url(for item: ShelfItem) -> URL? {
        guard item.fileRef != nil else { return nil }
        let url = store.currentURL(item.id)
        if url == nil { missing.insert(item.id) } else { missing.remove(item.id) }
        sync()
        return url
    }

    func refreshMissing() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let refs = store.fileRefs
        let bookmarks = store.bookmarks
        refreshTask = Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                var out: [UUID: (ref: ShelfFileRef, result: ShelfResolution)] = [:]
                for (id, ref) in refs { out[id] = (ref, ShelfStore.resolve(ref, bookmarks: bookmarks)) }
                return out
            }.value
            guard let self, generation == self.refreshGeneration else { return }
            let ids = Set(self.store.items.map(\.id))
            let gone = self.store.apply(results).intersection(ids)
            self.sync()
            if gone != self.missing { self.missing = gone }
        }
    }

    func dragSet(startingAt item: ShelfItem) -> [ShelfItem] {
        guard selection.contains(item.id) else { return [item] }
        return items.filter { selection.contains($0.id) }
    }

    func pasteboardWriters(for items: [ShelfItem]) -> [(ShelfItem, NSPasteboardWriting)] {
        items.compactMap { item in
            switch item.kind {
            case .file:
                guard let url = url(for: item) else { return nil }
                return (item, url as NSURL)
            case .url(let u): return (item, u as NSURL)
            case .text(let t): return (item, t as NSString)
            }
        }
    }

    func select(_ item: ShelfItem, extend: Bool) {
        if extend {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = selection == [item.id] ? [] : [item.id]
        }
    }

    func remove(_ ids: [UUID]) {
        for id in ids { store.remove(id) }
        selection.subtract(ids)
        afterChange()
    }

    func relocate(_ item: ShelfItem, to url: URL) {
        store.relocate(item.id, to: url)
        afterChange()
    }

    func togglePin(_ item: ShelfItem) {
        store.setPinned(item.id, !item.pinned)
        afterChange()
    }

    func clearUnpinned() {
        store.clearUnpinned()
        selection = selection.intersection(Set(store.items.map(\.id)))
        afterChange()
    }

    func outgoingDragChanged(_ active: Bool) {
        outgoingDrag = active
        if !active { refreshMissing() }
    }

    /// Nil while File actions is off, and while the close question shows (N1: nothing may
    /// start writing into a basket that is about to close).
    var fileActions: FileActionCenter? {
        guard fileActionsOn(), closeAsk == nil else { return nil }
        actionCenterMade = true
        return actionCenter
    }

    // MARK: - FileActionResults (Task 2: every shelf action works here)

    func reserveResultFolder() -> (id: UUID, folder: URL)? {
        guard closeAsk == nil, room > 0, let r = store.reserveOwnedFolder() else { return nil }
        reserved.insert(r.id)
        return r
    }

    func addResult(_ url: URL, id: UUID, after source: UUID) -> Bool {
        reserved.remove(id)
        guard store.addOwnedFile(url, id: id) != nil else { return false }
        if let i = store.items.firstIndex(where: { $0.id == source }) { store.move(id, to: i) }
        afterChange()
        return true
    }

    func discardResult(_ id: UUID) {
        reserved.remove(id)
        store.discardReserved(id)
    }

    func renamed(_ id: UUID, to url: URL) {
        store.relocate(id, to: url)
        afterChange()
    }

    func ownedFolder(of id: UUID) -> URL? {
        guard store.items.contains(where: { $0.id == id && $0.ownsFile && $0.fileRef != nil }) else { return nil }
        return store.directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Drops (the basket's window)

    func setDropTargeted(_ on: Bool) {
        if dropTargeted != on { dropTargeted = on }
    }

    /// Adds what `pb` holds (read now, on the drop): file URLs, else web URLs, else an
    /// image, else text; at most `room` items. Refuses anything concealed or transient.
    /// Returns how many were added (a TIFF counts once taken for conversion).
    @discardableResult
    func receive(pasteboard pb: NSPasteboard) -> Int {
        let room = self.room
        guard closeAsk == nil, room > 0, ShelfDropPolicy.accepts(types: (pb.types ?? []).map(\.rawValue)) else { return 0 }
        var added = 0
        let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            let taken = Array(files.prefix(room))
            store.addFiles(taken)
            added = taken.count
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
                  case let web = urls.filter({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") }),
                  !web.isEmpty {
            for url in web.prefix(room).reversed() { store.add(.url(url)) }
            added = min(web.count, room)
        } else if let png = pb.data(forType: .png) {
            if store.addOwnedData(png, filename: imageName()) != nil { added = 1 } else { importFailed() }
        } else if let tiff = pb.data(forType: .tiff) {
            let name = imageName()
            importTask = Task { [weak self] in
                let png = await Task.detached(priority: .userInitiated) { ShelfWidget.png(fromTIFF: tiff) }.value
                guard let self else { return }
                if let png, self.room > 0, self.store.addOwnedData(png, filename: name) != nil {
                    self.afterChange()
                } else {
                    self.importFailed()
                }
            }
            added = 1
        } else if let text = pb.string(forType: .string), store.addText(text) != nil {
            added = 1
        }
        if added > 0 { afterChange() }
        return added
    }

    /// File promises (Photos, Mail) into owned folders, up to `room`. Returns how many started.
    func receivePromises(from pb: NSPasteboard) -> Int {
        guard closeAsk == nil, ShelfDropPolicy.accepts(types: (pb.types ?? []).map(\.rawValue)),
              let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]
        else { return 0 }
        var started = 0
        for receiver in receivers.prefix(room) {
            guard let (folderID, folder) = store.reserveOwnedFolder() else { continue }
            beginReceiving(folderID)
            started += 1
            var remaining = max(receiver.fileNames.count, 1)
            receiver.receivePromisedFiles(atDestination: folder, options: [:],
                                          operationQueue: Self.promiseQueue) { [weak self] url, error in
                let failed = error != nil
                Task { @MainActor in
                    guard let self else { return }
                    if failed {
                        Self.log.error("file promise failed")
                    } else if self.store.addOwnedFile(url, id: folderID) != nil {
                        self.afterChange()
                    }
                    // A second file of one promise stays in its folder, unlisted (swept later).
                    remaining -= 1
                    if remaining == 0 {
                        self.endReceiving(folderID)
                        self.store.discardReserved(folderID)
                    }
                }
            }
        }
        return started
    }

    /// A promise is being written into `folderID`. One that never finishes stops holding
    /// the basket (room, close) after `promiseTimeout`; its folder is then swept like any
    /// unlisted one.
    func beginReceiving(_ folderID: UUID) {
        receiving.insert(folderID)
        let sleep = self.sleep
        receiveTimeouts[folderID]?.cancel()
        receiveTimeouts[folderID] = Task { [weak self] in
            await sleep(Self.promiseTimeout)
            guard !Task.isCancelled else { return }
            self?.receiving.remove(folderID)
            self?.receiveTimeouts[folderID] = nil
        }
    }

    /// The promise into `folderID` finished: its timeout is cancelled.
    func endReceiving(_ folderID: UUID) {
        receiving.remove(folderID)
        receiveTimeouts.removeValue(forKey: folderID)?.cancel()
    }

    private func imageName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Image \(f.string(from: clock())).png"
    }

    private func importFailed() {
        Self.log.error("dropped image could not be kept in a basket")
        NSSound.beep()
    }

    // MARK: - Changes

    func afterChange() {
        sync()
        refreshMissing()
        owner?.itemsChanged(in: self)
    }

    func sync() {
        let now = store.items
        if now != items { items = now }
    }
}
