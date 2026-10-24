import Foundation
import XCTest
@testable import PlatyNotchKit

/// Final review B4: the private folders move to `.noindex` names (Spotlight skips them)
/// with one atomic rename each, never losing a file. Every test uses a temp home.
final class PrivateFolderTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("pn-noindex-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private func write(_ rel: String, _ text: String) throws {
        let url = home.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ rel: String) -> String? {
        (try? Data(contentsOf: home.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testPathsAreNoIndex() {
        let env = ["PLATYNOTCH_HOME": home.path]
        XCTAssertEqual(CorePaths.shelf(env: env).lastPathComponent, "shelf.noindex")
        XCTAssertEqual(CorePaths.clipboard(env: env).lastPathComponent, "clipboard.noindex")
        XCTAssertEqual(CorePaths.favicons(env: env).lastPathComponent, "favicons.noindex")
    }

    func testMovesEveryFolderWithItsContents() throws {
        try write("shelf/items.json", "[1]")
        try write("shelf/0B5C2C7E-0000-4000-8000-000000000001/a.png", "png")
        try write("clipboard/history.json", "{}")
        try write("clipboard/images/x.png", "img")
        try write("favicons/example.com.png", "ico")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.appendingPathComponent("shelf").path)

        let result = PrivateFolder.migrateToNoIndex(home: home)
        XCTAssertEqual(result, ["shelf": .moved, "clipboard": .moved, "favicons": .moved])
        XCTAssertEqual(read("shelf.noindex/items.json"), "[1]")
        XCTAssertEqual(read("shelf.noindex/0B5C2C7E-0000-4000-8000-000000000001/a.png"), "png")
        XCTAssertEqual(read("clipboard.noindex/history.json"), "{}")
        XCTAssertEqual(read("clipboard.noindex/images/x.png"), "img")
        XCTAssertEqual(read("favicons.noindex/example.com.png"), "ico")
        for old in ["shelf", "clipboard", "favicons"] {
            XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(old).path), old)
        }
        let mode = try fm.attributesOfItem(atPath: home.appendingPathComponent("shelf.noindex").path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o700, "a rename keeps the folder's mode")

        // Idempotent: a second launch has nothing to do.
        XCTAssertEqual(PrivateFolder.migrateToNoIndex(home: home),
                       ["shelf": .none, "clipboard": .none, "favicons": .none])
        XCTAssertEqual(read("shelf.noindex/items.json"), "[1]")
    }

    func testNothingToMove() {
        XCTAssertEqual(PrivateFolder.migrateToNoIndex(home: home),
                       ["shelf": .none, "clipboard": .none, "favicons": .none])
        XCTAssertFalse(fm.fileExists(atPath: CorePaths.shelf(env: ["PLATYNOTCH_HOME": home.path]).path),
                       "the migration never creates a folder")
    }

    /// An older build ran after the move and made a fresh old-name folder: both stay
    /// untouched (no merge, no delete), and the new one is used.
    func testBothNamesKeepsBoth() throws {
        try write("shelf/items.json", "old")
        try write("shelf.noindex/items.json", "new")
        let result = PrivateFolder.migrateToNoIndex(home: home)
        XCTAssertEqual(result["shelf"], .keptBoth)
        XCTAssertEqual(read("shelf/items.json"), "old")
        XCTAssertEqual(read("shelf.noindex/items.json"), "new")
    }

    /// A file (not a folder) under the old name is not ours to move.
    func testOldNameThatIsAFileIsLeftAlone() throws {
        try write("clipboard", "a file")
        XCTAssertEqual(PrivateFolder.migrateToNoIndex(home: home)["clipboard"], PrivateFolder.Migration.none)
        XCTAssertEqual(read("clipboard"), "a file")
    }

    /// A failed rename leaves the old folder exactly as it was.
    func testFailedRenameLosesNothing() throws {
        try write("favicons/a.png", "ico")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)   // no renames in home
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path) }
        XCTAssertEqual(PrivateFolder.migrateToNoIndex(home: home)["favicons"], .failed)
        XCTAssertEqual(read("favicons/a.png"), "ico")
    }

    // MARK: - Stores after the move (round 2)

    /// Clipboard: an index written under `clipboard/` still finds its images under
    /// `clipboard.noindex/` (paste reads them; remove deletes them).
    func testClipboardImagesSurviveTheMove() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = ClipboardStore(directory: home.appendingPathComponent("clipboard", isDirectory: true), now: { now })
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let item = try XCTUnwrap(old.recordImage(png: png, width: 2, height: 2, source: nil))
        old.record(.text("hello"), source: nil)
        XCTAssertEqual(PrivateFolder.migrateToNoIndex(home: home)["clipboard"], .moved)

        let store = ClipboardStore(directory: CorePaths.clipboard(env: ["PLATYNOTCH_HOME": home.path]), now: { now })
        let moved = try XCTUnwrap(store.history.items.first { $0.id == item.id })
        let url = try XCTUnwrap(store.imageURL(for: moved), "the image resolves after the move")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "clipboard.noindex")
        XCTAssertEqual(try Data(contentsOf: url), png, "paste reads the same bytes")
        store.remove(item.id)
        XCTAssertFalse(fm.fileExists(atPath: url.path), "removing the item deletes its PNG")
    }

    /// Only the store's own `<id>.png` is ever used, whatever folder the index names.
    func testClipboardImageMustBeTheItemsOwnName() throws {
        let store = ClipboardStore(directory: home.appendingPathComponent("clipboard.noindex", isDirectory: true))
        let id = UUID()
        let other = ClipItem(id: id, kind: .image(fileURL: URL(fileURLWithPath: "/tmp/x/\(UUID().uuidString).png"),
                                                   width: 1, height: 1), sourceBundleID: nil, copiedAt: Date())
        XCTAssertNil(store.imageURL(for: other))
        let renamed = ClipItem(id: id, kind: .image(fileURL: URL(fileURLWithPath: "/elsewhere/images/\(id.uuidString).png"),
                                                     width: 1, height: 1), sourceBundleID: nil, copiedAt: Date())
        XCTAssertEqual(store.imageURL(for: renamed)?.path,
                       home.appendingPathComponent("clipboard.noindex/images/\(id.uuidString).png").path)
    }

    /// Shelf: an owned copy whose bookmark cannot help still resolves after the move (its
    /// stored path is rebased onto the new root), and removing it deletes the copy.
    func testShelfOwnedCopySurvivesTheMove() throws {
        let old = ShelfStore(directory: home.appendingPathComponent("shelf", isDirectory: true), bookmarks: NoBookmarks())
        let item = try XCTUnwrap(old.addOwnedData(Data("png".utf8), filename: "a.png"))
        XCTAssertNil(item.fileRef?.bookmark)
        XCTAssertEqual(PrivateFolder.migrateToNoIndex(home: home)["shelf"], .moved)

        let store = ShelfStore(directory: CorePaths.shelf(env: ["PLATYNOTCH_HOME": home.path]), bookmarks: NoBookmarks())
        let url = try XCTUnwrap(store.currentURL(item.id), "the owned copy resolves")
        XCTAssertTrue(url.path.contains("/shelf.noindex/"), url.path)
        XCTAssertEqual(try Data(contentsOf: url), Data("png".utf8))
        store.sweepOrphans(olderThan: 0)
        XCTAssertTrue(fm.fileExists(atPath: url.path), "still listed: never swept")
        store.remove(item.id)
        XCTAssertFalse(fm.fileExists(atPath: url.deletingLastPathComponent().path))
    }
}

/// Bookmarks that never help (made as nil, never resolve).
private struct NoBookmarks: ShelfBookmarks {
    func make(_ url: URL) -> Data? { nil }
    func resolve(_ data: Data) -> (url: URL, isStale: Bool)? { nil }
}
