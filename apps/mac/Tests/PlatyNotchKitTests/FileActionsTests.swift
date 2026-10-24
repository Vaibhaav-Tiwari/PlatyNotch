import Foundation
import UniformTypeIdentifiers
import XCTest
import PlatyNotchKit

/// Task 2: conversions, rename patterns, the actions a selection gets, ZIP sizes and the
/// `platynotch://` routes.
final class FileActionsTests: DefaultsTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("FileActionsTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - ConversionMatrix

    func testImageTargets() {
        XCTAssertEqual(ConversionMatrix.targets(for: .jpeg), [.png, .heic, .tiff, .pdf])
        XCTAssertEqual(ConversionMatrix.targets(for: .heic), [.png, .jpeg, .tiff, .pdf])
        XCTAssertEqual(ConversionMatrix.targets(for: .png), [.jpeg, .heic, .tiff, .pdf])
        // WebP is read, never written.
        XCTAssertEqual(ConversionMatrix.targets(for: .webP), ConversionMatrix.imageTargets)
        XCTAssertFalse(ConversionMatrix.imageTargets.contains(.webP))
        XCTAssertEqual(ConversionMatrix.targets(for: .gif), ConversionMatrix.imageTargets)
        XCTAssertEqual(ConversionMatrix.targets(for: .svg), [], "not a raster image")
        XCTAssertEqual(ConversionMatrix.targets(for: .pdf), [], "a PDF is not converted")
        XCTAssertEqual(ConversionMatrix.targets(for: .plainText), [])
    }

    func testVideoTargets() {
        XCTAssertEqual(ConversionMatrix.targets(for: .quickTimeMovie), [.mpeg4Movie])
        XCTAssertEqual(ConversionMatrix.targets(for: .mpeg4Movie), [.quickTimeMovie])
        XCTAssertEqual(ConversionMatrix.targets(for: .avi), [.mpeg4Movie, .quickTimeMovie])
        XCTAssertEqual(ConversionMatrix.family(of: .mpeg4Movie), .video)
        XCTAssertEqual(VideoCodec.allCases.map(\.exportPreset),
                       ["AVAssetExportPresetHighestQuality", "AVAssetExportPresetHEVCHighestQuality"])
        XCTAssertEqual(VideoQuality.p720.exportPreset, "AVAssetExportPreset1280x720")
    }

    func testAudioTargets() {
        XCTAssertEqual(ConversionMatrix.targets(for: .mp3), [.mpeg4Audio, .wav])
        XCTAssertEqual(ConversionMatrix.targets(for: .wav), [.mpeg4Audio])
        XCTAssertEqual(ConversionMatrix.targets(for: .mpeg4Audio), [.wav])
        XCTAssertEqual(ConversionMatrix.family(of: .aiff), .audio)
    }

    func testCombineToPDF() {
        XCTAssertTrue(ConversionMatrix.canCombineToPDF([.png, .jpeg, .heic]))
        XCTAssertFalse(ConversionMatrix.canCombineToPDF([.png]), "one image is Convert › PDF")
        XCTAssertFalse(ConversionMatrix.canCombineToPDF([.png, .mpeg4Movie]))
        XCTAssertFalse(ConversionMatrix.canCombineToPDF([.png, .pdf]))
    }

    // MARK: - Which actions a selection gets

    func testActionsPerKind() {
        func actions(_ s: [FileSubject], bg: Bool = true) -> [FileActionKind] {
            FileActionMenu.actions(for: s, removeBackgroundAvailable: bg)
        }
        XCTAssertEqual(actions([.file(.png)]), [.convert, .zip, .copyText, .removeBackground, .rename])
        XCTAssertEqual(actions([.file(.png)], bg: false), [.convert, .zip, .copyText, .rename], "hidden when unavailable")
        XCTAssertEqual(actions([.file(.pdf)]), [.zip, .copyText, .rename])
        XCTAssertEqual(actions([.file(.quickTimeMovie)]), [.convert, .compressVideo, .zip, .rename])
        XCTAssertEqual(actions([.file(.zip)]), [.zip, .unzip, .rename])
        XCTAssertEqual(actions([.folder]), [.zip, .rename])
        XCTAssertEqual(actions([.file(.png), .file(.jpeg)]), [.combinePDF, .zip, .rename])
        XCTAssertEqual(actions([.text]), [], "text gets nothing")
        XCTAssertEqual(actions([.url]), [])
        XCTAssertEqual(actions([.file(.png), .text]), [], "a mixed selection: nothing that needs files only")
        XCTAssertEqual(actions([]), [])
    }

    // MARK: - FileNames

    func testSafeNames() {
        XCTAssertEqual(FileNames.safe("a/b:c.txt"), "b-c.txt", "the last component, separators replaced")
        XCTAssertEqual(FileNames.safe("..hidden"), "hidden")
        XCTAssertEqual(FileNames.safe("  "), "Item")
        XCTAssertEqual(FileNames.safe(String(repeating: "x", count: 300)).count, FileNames.maxLength)
        XCTAssertEqual(FileNames.split("photo.jpg").base, "photo")
        XCTAssertEqual(FileNames.split("archive.tar.gz").ext, "gz")
        XCTAssertEqual(FileNames.split("README").ext, "")
        XCTAssertEqual(FileNames.unique("a.txt") { $0 == "a.txt" || $0 == "a 2.txt" }, "a 3.txt")
        XCTAssertEqual(FileNames.unique("a.txt") { _ in false }, "a.txt")
        XCTAssertNil(FileNames.unique("a.txt") { _ in true }, "gives up rather than overwrite")
    }

    // MARK: - RenamePattern

    /// 2026-06-15 12:00 UTC.
    private let june = Date(timeIntervalSince1970: 1_781_524_800)
    private let utc = TimeZone(identifier: "UTC")!

    func testRenameTokens() {
        XCTAssertEqual(RenamePattern.apply("{date:yyyy}-{name}-{n:3}", name: "photo", index: 7, date: june, timeZone: utc),
                       "2026-photo-007")
        XCTAssertEqual(RenamePattern.apply("{date:yyyy}-{name}-{n:3}", name: "photo.JPG", index: 7, date: june, timeZone: utc),
                       "2026-photo-007.JPG", "the extension is kept")
        XCTAssertEqual(RenamePattern.apply("{name} {n}", name: "a.png", index: 1, date: june), "a 1.png", "{n} is 1-based as given")
        XCTAssertEqual(RenamePattern.apply("{date}", name: "a.png", index: 1, date: june, timeZone: utc), "2026-06-15.png")
        XCTAssertEqual(RenamePattern.apply("{n:2}", name: "a", index: 123, date: june), "123", "padding never cuts")
        XCTAssertEqual(RenamePattern.apply("{x} {n:0}", name: "a", index: 1, date: june), "{x} {n-0}", "unknown tokens stay (made safe)")
        XCTAssertEqual(RenamePattern.apply("{name", name: "a", index: 1, date: june), "{name", "an open brace stays")
    }

    /// R10: a date format cannot put a separator into the name, nor can the pattern.
    func testRenameNeverEscapesTheFolder() {
        XCTAssertEqual(RenamePattern.apply("{date:yyyy/MM/dd HH:mm}", name: "a.txt", index: 1, date: june, timeZone: utc),
                       "20260615 1200.txt")
        XCTAssertEqual(RenamePattern.apply("../../{name}", name: "a.txt", index: 1, date: june), "a.txt", "one component")
        XCTAssertFalse(RenamePattern.apply("x/y/{name}", name: "a.txt", index: 1, date: june).contains("/"))
        XCTAssertEqual(RenamePattern.apply("", name: "a.txt", index: 1, date: june), "Item.txt", "never empty")
    }

    func testRenamePlanAddsNumbersOnCollisions() throws {
        let dir = root.appendingPathComponent("photos")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["b.jpg", "c.jpg", "trip.jpg", "Trip 2.JPG"]
        for n in names { try Data(n.utf8).write(to: dir.appendingPathComponent(n)) }
        let urls = names.prefix(2).map { dir.appendingPathComponent($0) }
        let plan = RenamePlan.make(urls, pattern: "trip", date: june) { self.fm.fileExists(atPath: $0) }
        // "trip.jpg" and "Trip 2.JPG" exist (case does not matter): b becomes "trip 3", c "trip 4".
        XCTAssertEqual(plan.steps.map(\.to.lastPathComponent), ["trip 3.jpg", "trip 4.jpg"])
        XCTAssertEqual(plan.steps.map(\.index), [0, 1])

        // A name that does not change has no step; a case-only change is allowed.
        let same = RenamePlan.make([dir.appendingPathComponent("trip.jpg")], pattern: "{name}", date: june) { self.fm.fileExists(atPath: $0) }
        XCTAssertTrue(same.steps.isEmpty)
        let upper = RenamePlan.make([dir.appendingPathComponent("trip.jpg")], pattern: "TRIP", date: june) { self.fm.fileExists(atPath: $0) }
        XCTAssertEqual(upper.steps.map(\.to.lastPathComponent), ["TRIP.jpg"])
        XCTAssertTrue(upper.steps[0].caseOnly)

        let undo = RenamePlan.undo(plan.steps)
        XCTAssertEqual(undo.steps.map(\.to.lastPathComponent), ["c.jpg", "b.jpg"], "last first")
    }

    // MARK: - ZipInspector

    /// A small archive made by ditto (as the Zip action makes them).
    func testZipSummaryOfARealArchive() throws {
        let src = root.appendingPathComponent("folder")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 10_000).write(to: src.appendingPathComponent("a.txt"))
        try Data(repeating: 0x42, count: 2_345).write(to: src.appendingPathComponent("b.txt"))
        let zip = root.appendingPathComponent("folder.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", src.path, zip.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let summary = try XCTUnwrap(ZipInspector.summary(of: zip))
        // Both files, plus any extended attributes ditto stores beside them (AppleDouble).
        XCTAssertGreaterThanOrEqual(summary.uncompressedBytes, 12_345)
        XCTAssertLessThan(summary.uncompressedBytes, 12_345 + 16_384)
        XCTAssertGreaterThanOrEqual(summary.entries, 3, "the folder and both files")
        XCTAssertFalse(summary.hasUnsafeNames)
    }

    func testZipSlipNames() {
        XCTAssertTrue(ZipInspector.isUnsafe("../evil.sh"))
        XCTAssertTrue(ZipInspector.isUnsafe("a/../../evil.sh"))
        XCTAssertTrue(ZipInspector.isUnsafe("/etc/passwd"))
        XCTAssertTrue(ZipInspector.isUnsafe("a\\..\\..\\evil"))
        XCTAssertFalse(ZipInspector.isUnsafe("folder/a..b.txt"))
        XCTAssertFalse(ZipInspector.isUnsafe("folder/"))
    }

    func testZipSummaryRefusesWhatIsNotAZip() throws {
        let junk = root.appendingPathComponent("junk.zip")
        try Data("not a zip at all, just some text that is long enough".utf8).write(to: junk)
        XCTAssertNil(ZipInspector.summary(of: junk))
        XCTAssertNil(ZipInspector.summary(of: root.appendingPathComponent("nothing.zip")))
    }

    /// A hand-made archive that declares a 3 GiB entry through zip64 (no data at all).
    func testZipSummaryReadsZip64Sizes() throws {
        var dir = Data()
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let name = Data("big.bin".utf8)
        let extra = le(UInt16(1)) + le(UInt16(8)) + le(UInt64(3 << 30))
        dir += le(UInt32(0x0201_4B50)) + Data(count: 16) + le(UInt32(0)) + le(UInt32(0xFFFF_FFFF))
        dir += le(UInt16(name.count)) + le(UInt16(extra.count)) + le(UInt16(0)) + Data(count: 12)
        dir += name + extra
        var file = dir
        file += le(UInt32(0x0605_4B50)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(1)) + le(UInt16(1))
        file += le(UInt32(dir.count)) + le(UInt32(0)) + le(UInt16(0))
        let url = root.appendingPathComponent("big.zip")
        try file.write(to: url)
        XCTAssertEqual(ZipInspector.summary(of: url), ZipInspector.Summary(entries: 1, uncompressedBytes: 3 << 30))
    }

    // MARK: - platynotch:// routes (R7)

    func testURLRouteParsing() {
        func route(_ s: String) -> AppURL? { AppURL.route(URL(string: s)!) }
        XCTAssertEqual(route("platynotch://shelf/add?path=%2FUsers%2Fme%2Fa%20b.txt&path=/tmp/c"),
                       .shelfAdd(["/Users/me/a b.txt", "/tmp/c"]))
        XCTAssertNil(route("platynotch://shelf/add"), "no path")
        XCTAssertNil(route("platynotch://shelf/remove?path=/tmp/a"), "the shelf host is the app's, never a plugin's")
        XCTAssertEqual(route("platynotch://timer/start?d=25m"), .timerStart(25 * 60))
        XCTAssertEqual(route("platynotch://timer/start?d=90s"), .timerStart(90))
        XCTAssertEqual(route("platynotch://timer/start?d=1h"), .timerStart(3600))
        XCTAssertEqual(route("platynotch://timer/start?d=1h30m"), .timerStart(5400))
        XCTAssertNil(route("platynotch://timer/start?d=25h"), "more than 24 h")
        XCTAssertNil(route("platynotch://timer/start?d=0m"))
        XCTAssertNil(route("platynotch://timer/start?d=-5m"))
        XCTAssertNil(route("platynotch://timer/start"))
        XCTAssertEqual(route("platynotch://clipboard/open"), .clipboardOpen)
        XCTAssertNil(route("platynotch://clipboard/clear"))
        XCTAssertEqual(route("platynotch://other/thing"), .plugin(URL(string: "platynotch://other/thing")!))
        XCTAssertEqual(route("platynotch://settings/Widgets"), .settings(section: "widgets"))
    }

    func testShelfAddPolicy() throws {
        let home = root.appendingPathComponent("home")
        let inside = home.appendingPathComponent("shelf.noindex/x")
        let mine = root.appendingPathComponent("mine.txt")
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data("m".utf8).write(to: mine)
        // A link outside the home that points into it.
        let link = root.appendingPathComponent("sneaky")
        try fm.createSymbolicLink(at: link, withDestinationURL: inside)
        let exists: (String) -> Bool = { self.fm.fileExists(atPath: $0) }

        let ok = ShelfAddPolicy.accept([mine.path, "relative.txt", root.appendingPathComponent("gone").path,
                                        inside.path, home.path, link.path, mine.path, "/"], home: home, exists: exists)
        XCTAssertEqual(ok, [mine.standardizedFileURL], "absolute, existing, outside the home, once")
        let dotted = root.appendingPathComponent("home/../mine.txt").path
        XCTAssertEqual(ShelfAddPolicy.accept([dotted], home: home, exists: exists), [mine.standardizedFileURL])
        XCTAssertNil(ShelfAddPolicy.accept(Array(repeating: mine.path, count: 21), home: home, exists: exists), "more than 20")
        XCTAssertEqual(ShelfAddPolicy.accept(Array(repeating: mine.path, count: 20), home: home, exists: exists)?.count, 1)
    }

    func testPromptTexts() {
        XCTAssertEqual(AppURLPrompt.addFiles(2), "Add 2 files to the shelf?")
        XCTAssertEqual(AppURLPrompt.addFiles(1), "Add 1 file to the shelf?")
        XCTAssertEqual(AppURLPrompt.startTimer(25 * 60), "Start a 25 minute timer?")
        XCTAssertEqual(AppURLPrompt.startTimer(5400), "Start a 1 hour 30 minute timer?")
        XCTAssertEqual(AppURLPrompt.startTimer(8 * 60), "Start an 8 minute timer?")
        XCTAssertEqual(AppURLPrompt.startTimer(90), "Start a 1 minute 30 second timer?")
    }

    // MARK: - Renamed owned copies stay owned (R10 + relocate)

    func testRelocateInsideItsOwnFolderKeepsOwnership() throws {
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        let owned = try XCTUnwrap(store.addOwnedData(Data("x".utf8), filename: "x.png"))
        let old = try XCTUnwrap(owned.fileRef?.url)
        let renamed = old.deletingLastPathComponent().appendingPathComponent("renamed.png")
        try fm.moveItem(at: old, to: renamed)
        store.relocate(owned.id, to: renamed)
        XCTAssertEqual(store.items.first?.ownsFile, true, "still the shelf's copy")
        XCTAssertEqual(store.items.first?.fileRef?.name, "renamed.png")
        XCTAssertTrue(fm.fileExists(atPath: renamed.path), "its folder is kept")
        store.remove(owned.id)
        XCTAssertFalse(fm.fileExists(atPath: renamed.deletingLastPathComponent().path), "and deleted with it")
    }
}
