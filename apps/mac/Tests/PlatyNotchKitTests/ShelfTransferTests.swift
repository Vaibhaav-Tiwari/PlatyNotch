import Foundation
import XCTest
import PlatyNotchKit   // not @testable: the public API baskets will use

/// Bookmarks that are just the path (no file-system lookups).
private struct PathBookmarks: ShelfBookmarks {
    func make(_ url: URL) -> Data? { Data(url.path.utf8) }
    func resolve(_ data: Data) -> (url: URL, isStale: Bool)? { (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false) }
}

final class ShelfTransferTests: DefaultsTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ShelfTransferTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func store(_ name: String, rename: @escaping ShelfStore.FolderRename = ShelfStore.renameExclusive,
                       write: @escaping ShelfStore.IndexWrite = ShelfStore.writeIndexFile) -> ShelfStore {
        ShelfStore(directory: root.appendingPathComponent(name), bookmarks: PathBookmarks(), now: { [t0] in t0 },
                   renameFolder: rename, writeIndex: write)
    }

    /// Task 2 pre-step: the target's index write fails once after writing the file (as a
    /// failed chmod would); the rollback writes it again, so the file matches memory.
    func testFailedTargetWriteIsWrittenAgainAfterRollback() throws {
        let shelf = store("shelf")
        let writes = FlakyWriter()
        let basket = store("basket", write: writes.write)
        let kept = try XCTUnwrap(basket.addText("already there"))
        let owned = try XCTUnwrap(shelf.addOwnedData(Data("png".utf8), filename: "a.png"))
        let text = try XCTUnwrap(shelf.addText("hello"))

        for id in [owned.id, text.id] {
            writes.failNext()
            XCTAssertNil(shelf.transfer(id, to: basket))
            XCTAssertEqual(basket.items.map(\.id), [kept.id], "rolled back in memory")
            XCTAssertEqual(store("basket").items.map(\.id), [kept.id], "and on disk: written again")
        }
        XCTAssertEqual(writes.failures, 2)
        XCTAssertEqual(Set(shelf.items.map(\.id)), [owned.id, text.id])
        XCTAssertTrue(fm.fileExists(atPath: try XCTUnwrap(owned.fileRef?.path)), "the copy did not move")
    }

    /// Fix round 1: several files from disk, one index write, the first ending up first.
    func testAddFilesWritesTheIndexOnce() throws {
        let writes = FlakyWriter()
        let shelf = store("shelf", write: writes.write)
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        for u in [a, b] { try Data("x".utf8).write(to: u) }
        let before = writes.count
        let added = shelf.addFiles([a, b])
        XCTAssertEqual(writes.count - before, 1)
        XCTAssertEqual(added.map(\.fileRef?.name), ["a.txt", "b.txt"])
        XCTAssertEqual(shelf.items.map(\.fileRef?.name), ["a.txt", "b.txt"])
        XCTAssertTrue(shelf.items.allSatisfy { !$0.ownsFile })
        XCTAssertEqual(store("shelf").items.count, 2)
    }

    /// A rename that fails after the target's index listed the item: written again without it.
    func testFailedRenameWritesTheTargetAgain() throws {
        let shelf = store("shelf", rename: { _, _ in EXDEV })
        let writes = FlakyWriter()
        let basket = store("basket", write: writes.write)
        let owned = try XCTUnwrap(shelf.addOwnedData(Data("png".utf8), filename: "a.png"))
        let before = writes.count
        XCTAssertNil(shelf.transfer(owned.id, to: basket))
        XCTAssertEqual(writes.count - before, 2, "listed, then written again without it")
        XCTAssertTrue(store("basket").items.isEmpty)
        XCTAssertEqual(shelf.items.map(\.id), [owned.id])
    }

    func testOwnedCopyMovesWithOneRename() throws {
        let shelf = store("shelf"), basket = store("baskets/b1")
        let item = try XCTUnwrap(shelf.addOwnedData(Data("png".utf8), filename: "a.png"))
        shelf.setPinned(item.id, true)
        let oldFolder = root.appendingPathComponent("shelf/\(item.id.uuidString)")
        XCTAssertTrue(fm.fileExists(atPath: oldFolder.path))

        let moved = try XCTUnwrap(shelf.transfer(item.id, to: basket))
        XCTAssertEqual(moved.id, item.id)
        XCTAssertTrue(moved.pinned)
        XCTAssertEqual(moved.addedAt, item.addedAt, "expiry still counts from the first add")
        XCTAssertTrue(moved.ownsFile)
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertEqual(basket.items.map(\.id), [item.id])
        XCTAssertFalse(fm.fileExists(atPath: oldFolder.path))
        let newPath = try XCTUnwrap(moved.fileRef?.path)
        XCTAssertTrue(newPath.hasPrefix(basket.directory.path + "/\(item.id.uuidString)/"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: newPath)), Data("png".utf8))
        XCTAssertEqual(moved.fileRef?.bookmark, Data(newPath.utf8), "bookmark made again at the new place")

        // Both indexes were saved.
        XCTAssertTrue(store("shelf").items.isEmpty)
        XCTAssertEqual(store("baskets/b1").items.first?.fileRef?.path, newPath)
        // Removing it from the basket deletes the copy there (the basket owns it now).
        basket.remove(item.id)
        XCTAssertFalse(fm.fileExists(atPath: newPath))
    }

    func testRecordsMoveAndTheUsersFileIsUntouched() throws {
        let shelf = store("shelf"), basket = store("basket")
        let userFile = root.appendingPathComponent("user/notes.txt")
        try fm.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: userFile)
        let file = shelf.addFile(userFile)
        let text = try XCTUnwrap(shelf.addText("hello"))
        let link = shelf.add(.url(URL(string: "https://example.com")!))

        for id in [file.id, text.id, link.id] { XCTAssertNotNil(shelf.transfer(id, to: basket)) }
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertEqual(Set(basket.items.map(\.id)), [file.id, text.id, link.id])
        XCTAssertEqual(basket.items.first { $0.id == file.id }?.fileRef?.path, userFile.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: userFile), Data("mine".utf8))
    }

    func testSameContentAlreadyThereMovesToTheFront() throws {
        let shelf = store("shelf"), basket = store("basket")
        let there = try XCTUnwrap(basket.addText("hello"))
        basket.addText("other")
        let here = try XCTUnwrap(shelf.addText("hello"))
        shelf.setPinned(here.id, true)
        let moved = try XCTUnwrap(shelf.transfer(here.id, to: basket))
        XCTAssertEqual(moved.id, there.id, "no duplicate")
        XCTAssertTrue(moved.pinned)
        XCTAssertEqual(basket.items.count, 2)
        XCTAssertEqual(basket.items.first?.id, there.id)
        XCTAssertTrue(shelf.items.isEmpty)
    }

    /// A rename that fails leaves everything where it was: nothing is deleted.
    func testFailedRenameDeletesNothing() throws {
        let shelf = store("shelf"), basket = store("basket")
        let item = try XCTUnwrap(shelf.addOwnedData(Data("png".utf8), filename: "a.png"))
        // Something already sits where the folder would go.
        try fm.createDirectory(at: basket.directory, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: basket.directory.appendingPathComponent(item.id.uuidString))

        XCTAssertNil(shelf.transfer(item.id, to: basket))
        XCTAssertEqual(shelf.items.map(\.id), [item.id])
        XCTAssertEqual(shelf.items.first, item, "unchanged")
        XCTAssertTrue(fm.fileExists(atPath: try XCTUnwrap(item.fileRef?.path)))
        XCTAssertTrue(basket.items.isEmpty)
        XCTAssertTrue(store("basket").items.isEmpty, "the basket's index was put back")
        XCTAssertEqual(try Data(contentsOf: basket.directory.appendingPathComponent(item.id.uuidString)),
                       Data("blocker".utf8))
    }

    /// Fix round 1: a target whose index cannot be written takes nothing; no folder moves.
    func testUnwritableTargetIndexMovesNothing() throws {
        let shelf = store("shelf"), basket = store("basket")
        let owned = try XCTUnwrap(shelf.addOwnedData(Data("png".utf8), filename: "a.png"))
        let text = try XCTUnwrap(shelf.addText("hello"))
        // A folder where the basket's index file would go: every index write fails.
        try fm.createDirectory(at: basket.directory.appendingPathComponent(ShelfStore.indexName),
                               withIntermediateDirectories: true)
        let before = shelf.items

        XCTAssertNil(shelf.transfer(owned.id, to: basket))
        XCTAssertNil(shelf.transfer(text.id, to: basket))
        XCTAssertEqual(shelf.items, before, "the source is unchanged")
        XCTAssertTrue(basket.items.isEmpty, "the target is put back")
        XCTAssertTrue(fm.fileExists(atPath: try XCTUnwrap(owned.fileRef?.path)), "the copy did not move")
        XCTAssertFalse(fm.fileExists(atPath: basket.directory.appendingPathComponent(owned.id.uuidString).path))
        XCTAssertEqual(store("shelf").items.map(\.id), before.map(\.id), "the source index still lists both")
    }

    /// Fix round 1: across volumes the rename fails with EXDEV; nothing is copied or deleted.
    func testCrossVolumeRenameFailsCleanly() throws {
        let calls = RenameLog()
        let shelf = store("shelf", rename: { from, to in calls.add(from, to); return EXDEV })
        let basket = store("basket")
        let item = try XCTUnwrap(shelf.addOwnedData(Data("png".utf8), filename: "a.png"))

        XCTAssertNil(shelf.transfer(item.id, to: basket))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(shelf.items, [item])
        XCTAssertTrue(fm.fileExists(atPath: try XCTUnwrap(item.fileRef?.path)))
        XCTAssertTrue(basket.items.isEmpty)
        XCTAssertTrue(store("basket").items.isEmpty, "the target's index was rolled back")
        XCTAssertFalse(fm.fileExists(atPath: basket.directory.appendingPathComponent(item.id.uuidString).path))
    }

    /// The real rename refuses to replace what is already there (EEXIST), even an empty folder.
    func testExclusiveRenameNeverReplaces() throws {
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        XCTAssertEqual(ShelfStore.renameExclusive(a, b), EEXIST)
        XCTAssertTrue(fm.fileExists(atPath: a.path))
        let c = root.appendingPathComponent("c")
        XCTAssertEqual(ShelfStore.renameExclusive(a, c), 0)
        XCTAssertFalse(fm.fileExists(atPath: a.path))
        XCTAssertTrue(fm.fileExists(atPath: c.path))
    }

    func testRefusals() throws {
        let shelf = store("shelf"), basket = store("basket")
        let item = try XCTUnwrap(shelf.addText("hello"))
        XCTAssertNil(shelf.transfer(UUID(), to: basket), "no such item")
        XCTAssertNil(shelf.transfer(item.id, to: shelf), "the same store")
        let memoryOnly = ShelfStore(directory: root.appendingPathComponent("smoke"), persist: false)
        XCTAssertNil(shelf.transfer(item.id, to: memoryOnly), "a store that never writes")
        XCTAssertEqual(shelf.items.map(\.id), [item.id])

        // The other store already lists the id.
        XCTAssertNotNil(shelf.transfer(item.id, to: basket))
        let back = store("shelf")
        XCTAssertNil(basket.transfer(item.id, to: basket))
        XCTAssertNotNil(basket.transfer(item.id, to: back), "and back again")
        XCTAssertEqual(back.items.map(\.id), [item.id])
    }

    func testReadOnlyStoreNeverTransfers() throws {
        let dir = root.appendingPathComponent("damaged")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let shelf = store("shelf")
        let item = try XCTUnwrap(shelf.addText("hello"))
        // An unreadable index that cannot be moved aside makes the store read-only.
        try Data("{ bad".utf8).write(to: dir.appendingPathComponent(ShelfStore.indexName))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let damaged = ShelfStore(directory: dir, bookmarks: PathBookmarks())
        XCTAssertTrue(damaged.readOnly)
        XCTAssertNil(shelf.transfer(item.id, to: damaged))
        XCTAssertEqual(shelf.items.map(\.id), [item.id])
    }

    // MARK: - Paths

    func testBasketsAndNotesPaths() {
        let env = ["PLATYNOTCH_HOME": "/tmp/pn"]
        XCTAssertEqual(CorePaths.baskets(env: env).path, "/tmp/pn/baskets.noindex")
        XCTAssertEqual(CorePaths.notes(env: env).path, "/tmp/pn/notes.noindex")
        XCTAssertEqual(CorePaths.baskets(env: [:], userHome: URL(fileURLWithPath: "/Users/x")).path,
                       "/Users/x/Library/Application Support/PlatyNotch/baskets.noindex")
    }

    func testEnsureMakesAPrivateFolder() throws {
        let env = ["PLATYNOTCH_HOME": root.appendingPathComponent("home").path]
        for dir in [CorePaths.baskets(env: env), CorePaths.notes(env: env)] {
            XCTAssertFalse(fm.fileExists(atPath: dir.path), "paths never create anything")
            XCTAssertTrue(PrivateFolder.ensure(dir))
            let mode = try XCTUnwrap(fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, 0o700)
            XCTAssertTrue(PrivateFolder.isMarked(dir))
        }
    }
}

/// Writes the index for real, but the next write after `failNext()` throws once it has
/// written the file (a failed permission change after an atomic write).
private final class FlakyWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failPending = false
    private(set) var failures = 0
    private(set) var count = 0

    func failNext() { lock.lock(); failPending = true; lock.unlock() }

    var write: ShelfStore.IndexWrite {
        { [self] data, url in
            try ShelfStore.writeIndexFile(data, url)
            lock.lock(); defer { lock.unlock() }
            count += 1
            if failPending {
                failPending = false
                failures += 1
                throw CocoaError(.fileWriteNoPermission)
            }
        }
    }
}

/// Records rename calls (thread-safe enough for a test's one thread).
private final class RenameLog: @unchecked Sendable {
    private(set) var count = 0
    func add(_ from: URL, _ to: URL) { count += 1 }
}
