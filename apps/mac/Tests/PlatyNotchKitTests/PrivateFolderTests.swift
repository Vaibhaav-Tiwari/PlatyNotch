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
}
