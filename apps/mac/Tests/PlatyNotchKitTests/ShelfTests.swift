import Foundation
import XCTest
import PlatyNotchKit   // not @testable: the UI uses these types as public API (C6)

/// Bookmarks that resolve to whatever the test says (stale, moved, gone).
private final class FakeBookmarks: ShelfBookmarks, @unchecked Sendable {
    var made: [URL] = []
    /// bookmark data (the path as UTF-8) → where it resolves now, and whether it is stale.
    var resolution: [String: (URL, Bool)] = [:]

    func make(_ url: URL) -> Data? {
        made.append(url)
        return Data(url.path.utf8)
    }

    func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        let key = String(decoding: data, as: UTF8.self)
        if let r = resolution[key] { return (r.0, r.1) }
        return (URL(fileURLWithPath: key), false)
    }
}

final class ShelfTests: XCTestCase {
    private var root: URL!
    private var shelfDir: URL { root.appendingPathComponent("home/shelf") }
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, _ text: String = "hello") throws -> URL {
        let url = root.appendingPathComponent("user/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func store(now: Date? = nil, bookmarks: ShelfBookmarks = FileBookmarks()) -> ShelfStore {
        let t = now ?? t0
        return ShelfStore(directory: shelfDir, bookmarks: bookmarks, now: { t })
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Add, dedupe, order

    func testDedupMovesToFront() throws {
        let s = store()
        let a = try file("a.txt"), b = try file("b.txt")
        let first = s.addFile(a)
        s.addFile(b)
        s.add(.text("note"))
        XCTAssertEqual(s.items.count, 3)
        let again = s.addFile(a)
        XCTAssertEqual(again.id, first.id, "the same file is the same item")
        XCTAssertEqual(s.items.count, 3)
        XCTAssertEqual(s.items.first?.id, first.id, "and moves to the front")
        // The same file through another spelling of its path.
        s.addFile(URL(fileURLWithPath: a.deletingLastPathComponent().path + "/./a.txt"))
        XCTAssertEqual(s.items.count, 3)
        // Text and URLs dedupe on their value.
        s.add(.text("note"))
        s.add(.url(URL(string: "https://example.com/x")!))
        s.add(.url(URL(string: "https://example.com/x")!))
        XCTAssertEqual(s.items.count, 4)
        XCTAssertEqual(s.items.first?.kind, .url(URL(string: "https://example.com/x")!))
    }

    func testDedupKeepsPinnedAndRefreshesDate() throws {
        var now = t0
        let s = ShelfStore(directory: shelfDir, now: { now })
        let a = try file("a.txt")
        let item = s.addFile(a)
        s.setPinned(item.id, true)
        now = t0.addingTimeInterval(60)
        let again = s.addFile(a)
        XCTAssertTrue(again.pinned)
        XCTAssertEqual(again.addedAt, now)
    }

    func testTextIsTrimmedCappedAndOwned() {
        let s = store()
        XCTAssertNil(s.addText("   \n "), "blank text is not an item")
        let item = s.addText("  hi  ")
        XCTAssertEqual(item?.kind, .text("hi"))
        XCTAssertEqual(item?.ownsFile, true, "the shelf holds the text itself, so it expires")
        let long = String(repeating: "x", count: ShelfStore.maxTextLength + 10)
        if case .text(let t) = s.addText(long)?.kind {
            XCTAssertEqual(t.count, ShelfStore.maxTextLength)
        } else {
            XCTFail("long text kept")
        }
    }

    func testReorderPinAndClearUnpinned() throws {
        let s = store()
        let a = s.addFile(try file("a.txt"))
        let b = s.addFile(try file("b.txt"))
        let c = s.addFile(try file("c.txt"))
        XCTAssertEqual(s.items.map(\.id), [c.id, b.id, a.id])
        s.move(a.id, to: 0)
        XCTAssertEqual(s.items.map(\.id), [a.id, c.id, b.id])
        s.move(a.id, to: 99)
        XCTAssertEqual(s.items.map(\.id), [c.id, b.id, a.id], "an index past the end moves to the end")
        s.setPinned(b.id, true)
        s.clearUnpinned()
        XCTAssertEqual(s.items.map(\.id), [b.id])
    }

    // MARK: - Remove

    func testRemoveDeletesOwnedOnly() throws {
        let s = store()
        let userFile = try file("mine.txt")
        let user = s.addFile(userFile)
        let owned = try XCTUnwrap(s.addOwnedData(Data("png".utf8), filename: "Image.png"))
        let ownedURL = try XCTUnwrap(owned.fileRef?.url)
        XCTAssertTrue(owned.ownsFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedURL.path))
        XCTAssertTrue(ownedURL.path.hasPrefix(shelfDir.path), "owned copies live in the shelf directory")

        s.remove(user.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path), "a user's file is never deleted")
        s.remove(owned.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path), "the owned copy goes with its item")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.deletingLastPathComponent().path))
        XCTAssertTrue(s.items.isEmpty)
    }

    /// Only a file inside the item's own folder in the shelf directory can be owned.
    func testAddOwnedFileOutsideItsFolderIsRefused() throws {
        let s = store()
        let outside = try file("elsewhere.txt")
        let reserved = try XCTUnwrap(s.reserveOwnedFolder())
        XCTAssertNil(s.addOwnedFile(outside, id: reserved.id))
        let inside = reserved.folder.appendingPathComponent("Photo.heic")
        try Data("x".utf8).write(to: inside)
        let item = try XCTUnwrap(s.addOwnedFile(inside, id: reserved.id))
        XCTAssertEqual(item.id, reserved.id)
        XCTAssertTrue(item.ownsFile)
        s.remove(item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))
    }

    // MARK: - Persistence

    func testPersistenceRoundTripAndPermissions() throws {
        let s = store()
        let a = s.addFile(try file("a.txt"))
        let t = try XCTUnwrap(s.addText("remember this"))
        let u = s.add(.url(URL(string: "https://example.com")!))
        let o = try XCTUnwrap(s.addOwnedData(Data("img".utf8), filename: "x.png"))
        s.setPinned(t.id, true)

        let again = store()
        XCTAssertEqual(again.items, s.items)
        XCTAssertEqual(again.items.map(\.id), [o.id, u.id, t.id, a.id])
        XCTAssertEqual(try mode(shelfDir), 0o700, "the shelf directory is private")
        XCTAssertEqual(try mode(shelfDir.appendingPathComponent(ShelfStore.indexName)), 0o600)
        XCTAssertEqual(try mode(try XCTUnwrap(o.fileRef?.url).deletingLastPathComponent()), 0o700)
    }

    func testExistingDirectoryIsMadePrivate() throws {
        try FileManager.default.createDirectory(at: shelfDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let s = store()
        s.add(.text("x"))
        XCTAssertEqual(try mode(shelfDir), 0o700)
    }

    func testCorruptIndexStartsEmpty() throws {
        try FileManager.default.createDirectory(at: shelfDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: shelfDir.appendingPathComponent(ShelfStore.indexName))
        XCTAssertTrue(store().items.isEmpty)
    }

    func testNotPersistingWritesNothing() throws {
        let s = ShelfStore(directory: shelfDir, persist: false, now: { self.t0 })
        s.add(.text("x"))
        s.addFile(try file("a.txt"))
        XCTAssertNil(s.addOwnedData(Data("x".utf8), filename: "x.png"), "no owned copies without a directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelfDir.path))
    }

    // MARK: - Missing files (Review Focus #2)

    func testMissingDetected() throws {
        let s = store()
        let a = try file("a.txt")
        let item = s.addFile(a)
        XCTAssertFalse(s.isMissing(item, fileManager: .default))
        try FileManager.default.removeItem(at: a)
        XCTAssertTrue(s.isMissing(item, fileManager: .default))
        XCTAssertNil(s.resolvedURL(item.id), "a missing file never resolves (drag-out is refused)")
        XCTAssertFalse(s.isMissing(s.add(.text("t")), fileManager: .default), "text is never missing")
    }

    /// A file moved to the Trash still resolves through its bookmark, but counts as missing.
    func testFileInTrashIsMissing() throws {
        let s = store()
        let a = try file("a.txt")
        let item = s.addFile(a)
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: trash.appendingPathComponent("a.txt"))
        XCTAssertTrue(s.isMissing(item, fileManager: .default))
    }

    /// Renamed or moved in Finder: the bookmark follows it and the stored path is updated.
    func testRenamedFileFollowsBookmark() throws {
        let s = store()
        let a = try file("a.txt")
        let item = s.addFile(a)
        let renamed = a.deletingLastPathComponent().appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: a, to: renamed)
        XCTAssertFalse(s.isMissing(item, fileManager: .default))
        let url = try XCTUnwrap(s.resolvedURL(item.id))
        XCTAssertEqual(url.resolvingSymlinksInPath().path, renamed.resolvingSymlinksInPath().path)
        XCTAssertEqual(s.items.first?.fileRef?.name, "renamed.txt", "the shelf shows the new name")
        XCTAssertEqual(store().items.first?.fileRef?.name, "renamed.txt", "and keeps it")
    }

    func testStaleBookmarkIsRefreshed() throws {
        let fake = FakeBookmarks()
        let s = store(bookmarks: fake)
        let a = try file("a.txt")
        let item = s.addFile(a)
        let moved = try file("b.txt")
        fake.resolution[a.standardizedFileURL.path] = (moved, true)
        fake.made = []
        XCTAssertEqual(s.resolvedURL(item.id)?.path, moved.path)
        XCTAssertEqual(fake.made, [moved], "a stale bookmark is made again from where it resolved")
        XCTAssertEqual(s.items.first?.fileRef?.bookmark, Data(moved.path.utf8))
        XCTAssertEqual(s.items.first?.fileRef?.path, moved.path)
    }

    func testBookmarkFailureFallsBackToPath() throws {
        let fake = FakeBookmarks()
        let s = store(bookmarks: fake)
        let a = try file("a.txt")
        let item = s.addFile(a)
        fake.resolution[a.standardizedFileURL.path] = (root.appendingPathComponent("gone"), false)
        XCTAssertFalse(s.isMissing(item, fileManager: .default), "the last known path still exists")
    }

    func testRelocateKeepsIdAndPin() throws {
        let s = store()
        let a = try file("a.txt")
        let item = s.addFile(a)
        s.setPinned(item.id, true)
        try FileManager.default.removeItem(at: a)
        let found = try file("found.txt")
        s.relocate(item.id, to: found)
        let now = try XCTUnwrap(s.items.first)
        XCTAssertEqual(now.id, item.id)
        XCTAssertTrue(now.pinned)
        XCTAssertFalse(s.isMissing(now, fileManager: .default))
        XCTAssertEqual(now.fileRef?.name, "found.txt")
    }

    /// Fix round 2 (Important): a damaged index never costs the owned copies. It is moved
    /// aside, the shelf starts empty, and neither the launch cleanup nor a shelf start
    /// (expire + sweep) deletes a folder.
    func testCorruptIndexKeepsOwnedFolders() throws {
        let s = store()
        let a = try XCTUnwrap(s.addOwnedData(Data("a".utf8), filename: "a.png"))
        let b = try XCTUnwrap(s.addOwnedData(Data("b".utf8), filename: "b.png"))
        let folders = [a, b].map { $0.fileRef!.url.deletingLastPathComponent() }
        let index = shelfDir.appendingPathComponent(ShelfStore.indexName)
        try Data("{ not json".utf8).write(to: index)
        let farFuture = Date().addingTimeInterval(365 * day)

        // Launch with the shelf off: the index is found damaged and moved aside.
        ShelfStore.expireOnDisk(directory: shelfDir, now: farFuture)
        for f in folders { XCTAssertTrue(FileManager.default.fileExists(atPath: f.path)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: shelfDir.path)
        let asideName = try XCTUnwrap(names.first { $0.hasPrefix(ShelfStore.corruptPrefix) })
        let aside = shelfDir.appendingPathComponent(asideName)

        // A damaged index found at shelf start blocks expiry and the sweep for that run.
        try Data("{ still not json".utf8).write(to: index)
        let started = ShelfStore(directory: shelfDir, now: { farFuture })
        started.expireOwned(olderThan: ShelfStore.ownedLifetime, now: farFuture)
        started.sweepOrphans()
        for f in folders { XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "\(f.lastPathComponent) kept") }
        XCTAssertTrue(started.items.isEmpty)
        XCTAssertNotNil(started.quarantinedIndex)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("items.json.corrupt-"))
        XCTAssertEqual(try mode(aside), 0o600)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ not json", "the bad index is kept, not lost")

        // The shelf keeps working; the folders that lost their item outlive this run.
        started.add(.text("new"))
        started.sweepOrphans()
        for f in folders { XCTAssertTrue(FileManager.default.fileExists(atPath: f.path)) }
        // Later launches, a valid index: still no sweep while a damaged index is kept aside.
        let next = ShelfStore(directory: shelfDir, now: { farFuture })
        XCTAssertEqual(next.items.count, 1)
        next.sweepOrphans()
        for f in folders { XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "never on a lost index's account") }
        // The user deletes the damaged indexes: sweeping (by age) resumes.
        for n in try FileManager.default.contentsOfDirectory(atPath: shelfDir.path) where n.hasPrefix(ShelfStore.corruptPrefix) {
            try FileManager.default.removeItem(at: shelfDir.appendingPathComponent(n))
        }
        next.sweepOrphans()
        for f in folders { XCTAssertFalse(FileManager.default.fileExists(atPath: f.path)) }
    }

    /// Final review C2: what a damaged index kept is counted for Settings and deleted only
    /// by the user's "Delete Kept Copies" (indexes and unlisted folders, any age; listed
    /// items and promises in flight stay).
    func testKeptFilesCountedAndDeletedOnRequest() throws {
        let s = store()
        let lost = try XCTUnwrap(s.addOwnedData(Data("a".utf8), filename: "a.png"))
        let lostFolder = lost.fileRef!.url.deletingLastPathComponent()
        try Data("{ not json".utf8).write(to: shelfDir.appendingPathComponent(ShelfStore.indexName))

        let after = store()   // the index is damaged: moved aside, the shelf starts empty
        XCTAssertTrue(after.hasKeptFiles)
        XCTAssertEqual(after.keptFolderCount(), 1)
        let listed = try XCTUnwrap(after.addOwnedData(Data("b".utf8), filename: "b.png"))
        let inFlight = try XCTUnwrap(after.reserveOwnedFolder())
        XCTAssertEqual(after.keptFolderCount(keeping: [inFlight.id]), 1, "only folders no item lists")
        try FileManager.default.createDirectory(at: shelfDir.appendingPathComponent("not-a-uuid"),
                                                withIntermediateDirectories: false)

        after.deleteKeptFiles(keeping: [inFlight.id])
        XCTAssertFalse(after.hasKeptFiles)
        XCTAssertEqual(after.keptFolderCount(keeping: [inFlight.id]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lostFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: listed.fileRef!.url.path), "a listed copy stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.folder.path), "a promise in flight stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelfDir.appendingPathComponent("not-a-uuid").path))
        XCTAssertNil(after.quarantinedIndex, "expiry and the sweep work again")
        XCTAssertEqual(after.expireOwned(olderThan: 0, now: t0.addingTimeInterval(1)), [listed.id])
    }

    func testNoKeptFilesWithAHealthyIndex() throws {
        let s = store()
        _ = try XCTUnwrap(s.addOwnedData(Data("a".utf8), filename: "a.png"))
        XCTAssertFalse(s.hasKeptFiles)
        XCTAssertEqual(s.keptFolderCount(), 0)
        XCTAssertFalse(ShelfStore(directory: shelfDir, persist: false).hasKeptFiles)
    }

    /// Fix round 2 (2): locating an owned item deletes only its own old folder, never a
    /// promise still being written.
    func testRelocateLeavesOtherFolders() throws {
        let s = store()
        let owned = try XCTUnwrap(s.addOwnedData(Data("x".utf8), filename: "x.png"))
        let inFlight = try XCTUnwrap(s.reserveOwnedFolder())
        s.relocate(owned.id, to: try file("mine.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.fileRef!.url.deletingLastPathComponent().path))
        s.discardReserved(inFlight.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inFlight.folder.path))
        let item = try XCTUnwrap(s.addOwnedData(Data("y".utf8), filename: "y.png"))
        s.discardReserved(item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileRef!.url.path), "an item's folder is never discarded")
    }

    /// Fix round 1 (4): a located file is the user's, never deleted, never expired.
    func testRelocateClearsOwnership() throws {
        let s = store()
        let owned = try XCTUnwrap(s.addOwnedData(Data("x".utf8), filename: "x.png"))
        let folder = try XCTUnwrap(owned.fileRef?.url).deletingLastPathComponent()
        try FileManager.default.removeItem(at: try XCTUnwrap(owned.fileRef?.url))
        let mine = try file("mine.png")
        s.relocate(owned.id, to: mine)
        XCTAssertEqual(s.items.first?.ownsFile, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the old owned folder is swept")
        XCTAssertTrue(s.expireOwned(olderThan: 0, now: t0.addingTimeInterval(30 * day)).isEmpty)
        s.remove(owned.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path))
    }

    /// Fix round 1 (5, 6): resolving runs without the store (off the main thread); applying
    /// saves a renamed file's new path, and skips items changed meanwhile.
    func testResolveElsewhereThenApply() throws {
        let s = store()
        let a = try file("a.txt"), gone = try file("gone.txt")
        let item = s.addFile(a)
        let goneItem = s.addFile(gone)
        let renamed = a.deletingLastPathComponent().appendingPathComponent("b.txt")
        try FileManager.default.moveItem(at: a, to: renamed)
        try FileManager.default.removeItem(at: gone)
        var results: [UUID: (ref: ShelfFileRef, result: ShelfResolution)] = [:]
        for (id, ref) in s.fileRefs { results[id] = (ref, ShelfStore.resolve(ref, bookmarks: s.bookmarks)) }
        XCTAssertEqual(s.apply(results), [goneItem.id])
        XCTAssertEqual(s.items.first { $0.id == item.id }?.fileRef?.name, "b.txt")
        XCTAssertEqual(store().items.first { $0.id == item.id }?.fileRef?.name, "b.txt", "saved")
        // A result for a reference that has changed since is ignored.
        let other = try file("c.txt")
        let stale = results
        s.relocate(goneItem.id, to: other)
        XCTAssertEqual(s.apply(stale), [])
        XCTAssertEqual(s.items.first { $0.id == goneItem.id }?.fileRef?.name, "c.txt")
    }

    func testCurrentURLUsesStoredPathThenResolves() throws {
        let s = store()
        let a = try file("a.txt")
        let item = s.addFile(a)
        XCTAssertEqual(s.currentURL(item.id)?.path, a.standardizedFileURL.path)
        let moved = a.deletingLastPathComponent().appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: a, to: moved)
        XCTAssertEqual(s.currentURL(item.id)?.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: moved)
        XCTAssertNil(s.currentURL(item.id))
    }

    /// Ruling (fix round 1): expired copies are removed at launch even with the shelf off.
    func testExpireOnDiskWhileOff() throws {
        ShelfStore.expireOnDisk(directory: shelfDir, now: t0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelfDir.path), "a never-used shelf reads and writes nothing")
        let s = store()
        let owned = try XCTUnwrap(s.addOwnedData(Data("x".utf8), filename: "x.png"))
        let user = s.addFile(try file("a.txt"))
        ShelfStore.expireOnDisk(directory: shelfDir, now: t0.addingTimeInterval(6 * day))
        XCTAssertEqual(store().items.count, 2)
        ShelfStore.expireOnDisk(directory: shelfDir, now: t0.addingTimeInterval(7 * day))
        XCTAssertEqual(store().items.map(\.id), [user.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.fileRef!.url.deletingLastPathComponent().path))
    }

    // MARK: - Expiry (7 days, owned only, pinned kept)

    func testExpireKeepsPinned() throws {
        var now = t0
        let s = ShelfStore(directory: shelfDir, now: { now })
        let user = s.addFile(try file("a.txt"))
        let owned = try XCTUnwrap(s.addOwnedData(Data("x".utf8), filename: "x.png"))
        let pinned = try XCTUnwrap(s.addOwnedData(Data("y".utf8), filename: "y.png"))
        let text = try XCTUnwrap(s.addText("snippet"))
        s.setPinned(pinned.id, true)
        now = t0.addingTimeInterval(3 * day)
        let fresh = try XCTUnwrap(s.addOwnedData(Data("z".utf8), filename: "z.png"))

        XCTAssertEqual(s.nextExpiry(olderThan: ShelfStore.ownedLifetime), t0.addingTimeInterval(ShelfStore.ownedLifetime))
        XCTAssertTrue(s.expireOwned(olderThan: ShelfStore.ownedLifetime, now: t0.addingTimeInterval(7 * day - 1)).isEmpty)

        let gone = s.expireOwned(olderThan: ShelfStore.ownedLifetime, now: t0.addingTimeInterval(7 * day))
        XCTAssertEqual(Set(gone), [owned.id, text.id])
        XCTAssertEqual(Set(s.items.map(\.id)), [user.id, pinned.id, fresh.id],
                       "user files and pinned items stay; owned copies and text expire")
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.fileRef!.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.fileRef!.url.path))
        XCTAssertEqual(s.nextExpiry(olderThan: ShelfStore.ownedLifetime), t0.addingTimeInterval(10 * day))
    }

    /// A promise that wrote a file but never became an item (crash, quit) is swept.
    func testSweepRemovesOrphanFolders() throws {
        let s = store()
        let kept = try XCTUnwrap(s.addOwnedData(Data("x".utf8), filename: "x.png"))
        let orphan = try XCTUnwrap(s.reserveOwnedFolder())
        try Data("x".utf8).write(to: orphan.folder.appendingPathComponent("lost.jpg"))
        let stray = shelfDir.appendingPathComponent("notes")   // not ours by name: left alone
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        s.sweepOrphans()
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.folder.path),
                      "fix round 2: an orphan younger than the owned lifetime is kept")
        let later = ShelfStore(directory: shelfDir, now: { Date().addingTimeInterval(8 * self.day) })
        later.sweepOrphans()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.fileRef!.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelfDir.appendingPathComponent(ShelfStore.indexName).path))
    }

    func testSweepKeepsReservedFolderInFlight() throws {
        let s = store()
        let reserved = try XCTUnwrap(s.reserveOwnedFolder())
        s.sweepOrphans(keeping: [reserved.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reserved.folder.path))
    }

    // MARK: - Drop policy

    func testDropPolicyRefusesConcealedAndTransient() {
        XCTAssertTrue(ShelfDropPolicy.accepts(types: ["public.file-url"]))
        XCTAssertFalse(ShelfDropPolicy.accepts(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertFalse(ShelfDropPolicy.accepts(types: ["org.nspasteboard.TransientType"]))
    }

    func testOwnedFilenameIsSanitised() throws {
        let s = store()
        let item = try XCTUnwrap(s.addOwnedData(Data("x".utf8), filename: "../../evil/name.png"))
        let url = try XCTUnwrap(item.fileRef?.url)
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path,
                       shelfDir.resolvingSymlinksInPath().path)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertNotNil(s.addOwnedData(Data("x".utf8), filename: ""), "an empty name still gets a file")
    }

    // MARK: - Drag detector

    func testDragPollerBeginEnd() {
        var p = DragPoller(changeCount: 10)
        XCTAssertNil(p.sample(changeCount: 10, mouseDown: true), "a press with nothing on the drag pasteboard")
        XCTAssertEqual(p.sample(changeCount: 11, mouseDown: true), .began)
        XCTAssertTrue(p.isDragging)
        XCTAssertNil(p.sample(changeCount: 11, mouseDown: true))
        XCTAssertNil(p.sample(changeCount: 12, mouseDown: true), "one drag per press")
        XCTAssertEqual(p.sample(changeCount: 12, mouseDown: false), .ended)
        XCTAssertNil(p.sample(changeCount: 12, mouseDown: false))
        XCTAssertFalse(p.isDragging)
    }

    func testDragPollerIgnoresChangesWhileTheButtonIsUp() {
        var p = DragPoller(changeCount: 1)
        XCTAssertNil(p.sample(changeCount: 5, mouseDown: false), "no button, no drag")
        XCTAssertNil(p.sample(changeCount: 5, mouseDown: true), "a change made while up is not a new drag")
        XCTAssertEqual(p.sample(changeCount: 6, mouseDown: true), .began)
    }

    func testDragPollerPressSetsBaseline() {
        var p = DragPoller(changeCount: 1)
        p.pressed(changeCount: 4)   // changed since the last sample, before this press
        XCTAssertNil(p.sample(changeCount: 4, mouseDown: true))
        XCTAssertEqual(p.sample(changeCount: 5, mouseDown: true), .began)
        p.pressed(changeCount: 9)   // a press during a drag does not reset it
        XCTAssertTrue(p.isDragging)
        XCTAssertEqual(p.sample(changeCount: 9, mouseDown: false), .ended)
    }

    func testDragPollerCancel() {
        var p = DragPoller(changeCount: 0)
        XCTAssertEqual(p.sample(changeCount: 1, mouseDown: true), .began)
        XCTAssertEqual(p.cancel(changeCount: 1), .ended)
        XCTAssertNil(p.cancel(changeCount: 1))
        XCTAssertNil(p.sample(changeCount: 1, mouseDown: true), "the same pasteboard is not a new drag")
    }

    // MARK: - Paths

    func testShelfPathUnderHome() {
        XCTAssertEqual(CorePaths.shelf(env: ["PLATYNOTCH_HOME": "/tmp/pn"]).path, "/tmp/pn/shelf")
        XCTAssertEqual(CorePaths.shelf(env: [:], userHome: URL(fileURLWithPath: "/Users/x")).path,
                       "/Users/x/Library/Application Support/PlatyNotch/shelf")
    }
}
