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

    private func store(_ name: String) -> ShelfStore {
        ShelfStore(directory: root.appendingPathComponent(name), bookmarks: PathBookmarks(), now: { [t0] in t0 })
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
