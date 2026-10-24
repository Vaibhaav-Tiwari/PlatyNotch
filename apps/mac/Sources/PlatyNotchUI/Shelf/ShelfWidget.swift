import AppKit
import Observation
import os
import PlatyNotchKit
import SwiftUI

/// The file shelf: drag files, images, links or text to the notch to keep them; drag them
/// back out (several at once), AirDrop, share or Quick Look them from the Today tile.
///
/// - Drag detection (`DragDetector`): left-button monitors plus the drag pasteboard's
///   change count, polled only while the button is down. A drag near the notch opens the
///   drop zone through `WidgetContext.dragSession`; the panel's own drag destination
///   (registered when the panel is made) hands drops to `ShelfDropTarget`.
/// - Storage (`ShelfStore`): `~/Library/Application Support/PlatyNotch/shelf` (0700).
///   Files the user drops stay where they are (a bookmark follows renames and moves).
///   Promised files (Photos, Mail) and dropped images are copied in and, with text,
///   expire after 7 days unless pinned. Removing an item deletes only its own copy.
/// - A moved-away, deleted or trashed file shows as missing with Locate… and Remove;
///   dragging it out is refused (a beep), never a broken drag.
/// - Privacy: the drag pasteboard is read only on a drop, never while dragging; nothing
///   marked concealed or transient is kept; a drag's source app is unknown, so Memory's
///   excluded apps do not apply (C20, said in Settings). File contents are read only by
///   Quick Look thumbnails. No network.
///
/// Turning the widget off stops the monitors, polls and expiry timer and keeps the
/// items and owned copies (user data; "Clear Shelf" deletes them). While it is off,
/// copies past their 7 days are removed at app launch (`ShelfStore.expireOnDisk`, one
/// directory pass, no timers; see `NotchApp`). Bookmarks are resolved and images
/// converted off the main thread.
@MainActor @Observable
final class ShelfWidget: NotchWidget {
    static let widgetID = "shelf"
    /// Re-check expiry at least this often (sleep, clock changes).
    static let maxExpirySleep: TimeInterval = 6 * 60 * 60
    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "shelf")

    let id = ShelfWidget.widgetID
    let title = "Shelf"
    let systemImage = "tray.full"
    let defaultEnabled = true

    /// Newest first (a copy of the store's, for observation).
    private(set) var items: [ShelfItem] = []
    /// File items whose file is gone (refreshed when the tile shows, after the user changes
    /// the shelf and after drags; never at start).
    private(set) var missing: Set<UUID> = []
    /// Selected in the tile (a drag of a selected item takes all of them).
    var selection: Set<UUID> = []
    /// A drag over the drop zone that the shelf would take.
    private(set) var dropTargeted = false
    /// Our own drag out of the tile is in progress (the detector's `.began` is ignored).
    private(set) var outgoingDrag = false
    /// A damaged index was set aside: how many copy folders no item lists were kept with
    /// it (Settings: "N kept · Show in Finder · Delete Kept Copies"); nil when none (C2).
    private(set) var keptCopies: Int?

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private let makeSignals: () -> DragSignals
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var store: ShelfStore?
    @ObservationIgnored private(set) var detector: DragDetector?
    @ObservationIgnored private var context: WidgetContext?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// Owned folders a file promise is still being written into.
    @ObservationIgnored private var receiving: Set<UUID> = []
    @ObservationIgnored private var refreshGeneration = 0
    /// How many missing-file checks ran (tests: none at start).
    @ObservationIgnored private(set) var refreshCount = 0
    /// The latest missing-file check (tests await it).
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    /// The latest image conversion from a drop (tests await it).
    @ObservationIgnored private(set) var importTask: Task<Void, Never>?
    @ObservationIgnored private lazy var drop = ShelfDropTarget(shelf: self)
    @ObservationIgnored private(set) lazy var dragSource = ShelfDragSource(shelf: self)
    @ObservationIgnored private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "dev.platynotch.shelf.promises"
        q.qualityOfService = .userInitiated
        return q
    }()

    init(directory: URL = CorePaths.shelf(), persist: Bool = true,
         makeSignals: @escaping () -> DragSignals = { SystemDragSignals() },
         clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.persist = persist
        self.makeSignals = makeSignals
        self.clock = clock
    }

    /// Smoke runs: no monitors, nothing read from or written to disk.
    static func inert() -> ShelfWidget {
        ShelfWidget(persist: false, makeSignals: { NoDragSignals() })
    }

    var isRunning: Bool { context != nil }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard self.context == nil else { return }
        self.context = context
        // The store is opened on first start, so a shelf that was never on reads nothing.
        let store = self.store ?? ShelfStore(directory: directory, persist: persist, now: clock)
        self.store = store
        store.markPrivate()
        store.expireOwned(olderThan: ShelfStore.ownedLifetime, now: clock())
        store.sweepOrphans(keeping: receiving)
        refreshKept()
        sync()
        // No `refreshMissing` here: resolving bookmarks and checking paths of files in
        // Downloads, Desktop or Documents can make macOS ask for access, so it happens
        // only when the tile shows or a drag out ends (B1), never at launch or login.
        scheduleExpiry()
        let detector = DragDetector(signals: makeSignals())
        detector.onEvent = { [weak self] event in self?.dragEvent(event) }
        self.detector = detector
        detector.start()
    }

    func stop() {
        guard let context else { return }
        detector?.stop()   // reports a drag in progress as ended
        detector = nil
        context.dragSession(active: false)
        expiryTask?.cancel()
        expiryTask = nil
        dropTargeted = false
        outgoingDrag = false
        self.context = nil
    }

    // `disabled()`: nothing beyond `stop`. Items and owned copies are the user's; they stay.

    var liveActivities: [LiveActivity] {
        guard !items.isEmpty else { return [] }
        let n = items.count
        return [LiveActivity(id: "shelf", widgetID: id, priority: LivePriority.shelfItems,
                             glyph: .symbol("tray.full.fill"), trailing: "\(n)",
                             accessibilityLabel: n == 1 ? "1 item on the shelf" : "\(n) items on the shelf")]
    }

    func tileView() -> AnyView { AnyView(ShelfTile(shelf: self)) }
    func dropZoneView() -> AnyView? { isRunning ? AnyView(ShelfDropZone(shelf: self)) : nil }
    func dropTarget() -> PanelDropTarget? { isRunning ? drop : nil }
    func settingsView() -> AnyView? { AnyView(ShelfSettings(shelf: self)) }

    // MARK: - Drag detection

    private func dragEvent(_ event: DragEvent) {
        guard let context else { return }
        switch event {
        case .began:
            // Dragging an item out of the open panel is not a drag *to* the shelf.
            guard !outgoingDrag else { return }
            context.dragSession(active: true)
        case .ended:
            context.dragSession(active: false)
        }
    }

    /// The tile starts / ends a drag of shelf items (`ShelfDragSource`).
    func outgoingDragChanged(_ active: Bool) {
        outgoingDrag = active
        if !active { refreshMissing() }
    }

    func setDropTargeted(_ on: Bool) {
        if dropTargeted != on { dropTargeted = on }
    }

    // MARK: - Receiving drops

    /// Adds what `pasteboard` holds (read only now, on the drop): file URLs, else web
    /// URLs, else an image, else text. File promises are taken by `receivePromises`.
    /// Refuses (0) anything marked concealed or transient. Returns how many items were
    /// added; PNG data counts only once written. TIFF data is taken for import (1, so the
    /// drop is accepted while the pasteboard is still valid) and converted off the main
    /// thread; a failed conversion or write is reported (log, beep, `importFailures`).
    @discardableResult
    func receive(pasteboard pb: NSPasteboard) -> Int {
        guard let store, ShelfDropPolicy.accepts(types: (pb.types ?? []).map(\.rawValue)) else { return 0 }
        var added = 0
        let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            for url in files.reversed() { store.addFile(url) }   // the first dragged ends up first
            added = files.count
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
                  case let web = urls.filter({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") }),
                  !web.isEmpty {
            for url in web.reversed() { store.add(.url(url)) }
            added = web.count
        } else if let image = Self.imageData(pb) {
            let name = "Image \(Self.stamp(clock())).png"
            if image.isPNG {
                if store.addOwnedData(image.data, filename: name) != nil { added = 1 } else { importFailed() }
            } else {
                // Read now (the pasteboard is only valid during the drop); TIFF → PNG off main.
                importTask = Task { [weak self] in
                    let png = await Task.detached(priority: .userInitiated) { Self.png(fromTIFF: image.data) }.value
                    guard let self, let store = self.store else { return }
                    if let png, store.addOwnedData(png, filename: name) != nil {
                        self.afterChange()
                    } else {
                        self.importFailed()
                    }
                }
                added = 1
            }
        } else if let text = pb.string(forType: .string), store.addText(text) != nil {
            added = 1
        }
        if added > 0 { afterChange() }
        return added
    }

    /// Starts receiving file promises (Photos, Mail, Safari images) into owned folders.
    /// Returns how many were started.
    func receivePromises(from pb: NSPasteboard) -> Int {
        guard let store, ShelfDropPolicy.accepts(types: (pb.types ?? []).map(\.rawValue)),
              let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]
        else { return 0 }
        var started = 0
        for receiver in receivers {
            guard let (folderID, folder) = store.reserveOwnedFolder() else { continue }
            receiving.insert(folderID)
            started += 1
            var remaining = max(receiver.fileNames.count, 1)
            receiver.receivePromisedFiles(atDestination: folder, options: [:],
                                          operationQueue: Self.promiseQueue) { [weak self] url, error in
                let failed = error != nil
                Task { @MainActor in
                    guard let self else { return }
                    if failed {
                        Self.log.error("file promise failed")
                    } else {
                        self.promiseArrived(url, folderID: folderID)
                    }
                    remaining -= 1
                    if remaining == 0 { self.promiseFinished(folderID) }
                }
            }
        }
        return started
    }

    private func promiseArrived(_ url: URL, folderID: UUID) {
        guard let store else { return }
        if store.addOwnedFile(url, id: folderID) == nil,
           let (id, folder) = store.reserveOwnedFolder() {
            // A second file of the same promise: its own item and folder.
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.moveItem(at: url, to: dest)) != nil {
                store.addOwnedFile(dest, id: id)
            } else {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        afterChange()
    }

    private func promiseFinished(_ folderID: UUID) {
        receiving.remove(folderID)
        store?.discardReserved(folderID)   // a promise that wrote nothing leaves no folder
    }

    /// Dropped image data that could not be converted or written.
    private(set) var importFailures = 0

    private func importFailed() {
        importFailures += 1
        Self.log.error("dropped image could not be kept")
        NSSound.beep()
    }

    private static func imageData(_ pb: NSPasteboard) -> (data: Data, isPNG: Bool)? {
        if let png = pb.data(forType: .png) { return (png, true) }
        return pb.data(forType: .tiff).map { ($0, false) }
    }

    nonisolated static func png(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    // MARK: - Items

    /// Where a file item is now; nil and marked missing when it is gone. Quick (a drag is
    /// starting): the stored path, which `refreshMissing` keeps current, and a full
    /// resolve only when that path is gone.
    func url(for item: ShelfItem) -> URL? {
        guard item.fileRef != nil, let store else { return nil }
        let url = store.currentURL(item.id)
        if url == nil { missing.insert(item.id) } else { missing.remove(item.id) }
        sync()
        return url
    }

    /// Re-checks every file item off the main thread (when the tile shows, after a
    /// change or a drag out). A renamed or moved file's new path and name are saved, so
    /// the tile shows them; a gone one is marked missing.
    func refreshMissing() {
        guard let store else { return }
        refreshCount += 1
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
            guard let self, generation == self.refreshGeneration, let store = self.store else { return }
            let ids = Set(store.items.map(\.id))
            let gone = store.apply(results).intersection(ids)
            self.sync()
            if gone != self.missing { self.missing = gone }
        }
    }

    /// The selected items in shelf order, or just `item` when it is not selected.
    func dragSet(startingAt item: ShelfItem) -> [ShelfItem] {
        guard selection.contains(item.id) else { return [item] }
        return items.filter { selection.contains($0.id) }
    }

    /// What a drag out of `items` writes: file URLs (files that are missing are left
    /// out and marked), web URLs and text. Empty when nothing can be dragged.
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

    /// Adds a file the user picked elsewhere (the System widget's "Add to Shelf", the same as dragging it here). The
    /// file stays where it is; false while the shelf is off.
    @discardableResult
    func addFile(_ url: URL) -> Bool {
        guard isRunning, let store else { return false }
        store.addFile(url)
        afterChange()
        return true
    }

    func remove(_ ids: [UUID]) {
        guard let store else { return }
        for id in ids { store.remove(id) }
        selection.subtract(ids)
        afterChange()
    }

    func clearUnpinned() {
        store?.clearUnpinned()
        selection = selection.intersection(Set(store?.items.map(\.id) ?? []))
        afterChange()
    }

    func togglePin(_ item: ShelfItem) {
        store?.setPinned(item.id, !item.pinned)
        afterChange()
    }

    func move(_ id: UUID, to index: Int) {
        store?.move(id, to: index)
        sync()
    }

    /// "Locate…": points a missing file item at `url`.
    func relocate(_ item: ShelfItem, to url: URL) {
        store?.relocate(item.id, to: url)
        afterChange()
    }

    /// Click: select only this one; ⌘-click: add or remove it.
    func select(_ item: ShelfItem, extend: Bool) {
        if extend {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = selection == [item.id] ? [] : [item.id]
        }
    }

    /// Settings › "Delete Kept Copies": the set-aside index and every copy no item lists.
    func deleteKeptFiles() {
        store?.deleteKeptFiles(keeping: receiving)
        refreshKept()
        scheduleExpiry()
    }

    /// Our own folder only (no file of the user's is touched).
    private func refreshKept() {
        guard let store else { return }
        let kept: Int? = store.hasKeptFiles ? store.keptFolderCount(keeping: receiving) : nil
        if kept != keptCopies { keptCopies = kept }
    }

    private func afterChange() {
        sync()
        refreshMissing()
        scheduleExpiry()
    }

    private func sync() {
        let now = store?.items ?? []
        if now != items { items = now }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard isRunning, let next = store?.nextExpiry(olderThan: ShelfStore.ownedLifetime) else { return }
        let delay = min(max(next.timeIntervalSince(clock()), 1), Self.maxExpirySleep)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.store?.expireOwned(olderThan: ShelfStore.ownedLifetime, now: self.clock())
            // Only owned copies expire: no file of the user's needs checking (B1).
            self.sync()
            self.scheduleExpiry()
        }
    }
}
