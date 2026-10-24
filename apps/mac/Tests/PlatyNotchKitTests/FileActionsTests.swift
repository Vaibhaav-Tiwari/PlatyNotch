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
        XCTAssertEqual(FileNames.safe(String(repeating: "x", count: 300)).utf8.count, FileNames.maxBytes)
        // Fix round 1: cut by UTF-8 bytes, never inside a character.
        let cjk = FileNames.safe(String(repeating: "写真", count: 100))   // 3 bytes each
        XCTAssertLessThanOrEqual(cjk.utf8.count, FileNames.maxBytes)
        XCTAssertEqual(cjk.count, 66)
        XCTAssertTrue(cjk.allSatisfy { $0 == "写" || $0 == "真" })
        let emoji = FileNames.safe(String(repeating: "👩‍👩‍👧‍👦", count: 20))   // 25 bytes each, one character
        XCTAssertEqual(emoji.utf8.count, 200, "whole family emoji only")
        XCTAssertEqual(emoji.count, 8)
        let mixed = FileNames.safe(String(repeating: "x", count: 199) + "写真")
        XCTAssertEqual(mixed.utf8.count, 199, "the 3-byte character that would cross 200 is left out")
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
        XCTAssertNil(summary.problem, "a real archive passes every check")
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

    private func inspect(_ entries: [ZipFixture.Entry]) throws -> ZipInspector.Summary? {
        let url = root.appendingPathComponent("\(UUID().uuidString).zip")
        try ZipFixture.build(entries).write(to: url)
        return ZipInspector.summary(of: url)
    }

    /// An archive that declares a 3 GiB entry through zip64 in both headers (no data at all).
    func testZipSummaryReadsZip64Sizes() throws {
        var big = ZipFixture.Entry("big.bin")
        big.zip64 = true
        big.centralSize = 3 << 30
        XCTAssertEqual(try inspect([big]), ZipInspector.Summary(entries: 1, uncompressedBytes: 3 << 30))
    }

    /// Fix round 1: ditto reads the local headers; the directory must say the same.
    func testZipHeadersThatDisagreeAreRefused() throws {
        // The directory declares 9 bytes; the local header (what ditto reads) 52 MB.
        var liar = ZipFixture.Entry("bomb.bin", Data(repeating: 0, count: 9))
        liar.localSize = 52_000_000
        XCTAssertEqual(try inspect([liar])?.problem, .mismatchedHeaders)
        var renamed = ZipFixture.Entry("a.txt")
        renamed.localName = "../../evil.txt"
        XCTAssertEqual(try inspect([renamed])?.problem, .mismatchedHeaders)
        XCTAssertNil(try inspect([ZipFixture.Entry("ok.txt"), ZipFixture.Entry("dir/ok2.txt")])?.problem)
    }

    func testZipDataDescriptors() throws {
        var good = ZipFixture.Entry("streamed.txt", Data("hello".utf8))
        good.descriptor = .matching
        XCTAssertNil(try inspect([good])?.problem)
        var missing = good
        missing.descriptor = .missing
        XCTAssertEqual(try inspect([missing])?.problem, .unknownSizes)
        var lying = good
        lying.centralSize = 1   // the descriptor (and directory) disagree with the data
        lying.descriptor = .matching
        XCTAssertNil(try inspect([lying])?.problem, "descriptor and directory agree: the live watch covers the rest")
    }

    func testZipSymbolicLinks() throws {
        func link(_ target: String) -> ZipFixture.Entry {
            var e = ZipFixture.Entry("link", Data(target.utf8))
            e.mode = 0o120755
            return e
        }
        XCTAssertEqual(try inspect([link("/etc/passwd")])?.problem, .unsafeLink)
        XCTAssertEqual(try inspect([link("../../.ssh")])?.problem, .unsafeLink)
        XCTAssertEqual(try inspect([link("a/../../b")])?.problem, .unsafeLink)
        XCTAssertNil(try inspect([link("sibling.txt")])?.problem)
        var file = ZipFixture.Entry("plain.txt", Data("/etc/passwd".utf8))
        file.mode = 0o100644
        XCTAssertNil(try inspect([file])?.problem, "a file's contents are not a link target")
    }

    /// Fix round 2: links are read from the mode bits whatever the made-by host (ditto
    /// makes links for made-by 0 and 19 too).
    func testZipLinksForEveryHost() throws {
        for host: UInt16 in [0, 3, 19] {
            var abs = ZipFixture.Entry("lnk", Data("/Users/victim".utf8))
            abs.mode = 0o120755
            abs.host = host
            XCTAssertEqual(try inspect([abs, ZipFixture.Entry("lnk/pwned.txt")])?.problem, .unsafeLink, "host \(host)")
            var up = abs
            up.data = Data("../..".utf8)
            XCTAssertEqual(try inspect([up])?.problem, .unsafeLink, "host \(host)")
            var ok = abs
            ok.data = Data("sibling".utf8)
            XCTAssertNil(try inspect([ok])?.problem, "host \(host)")
        }
    }

    /// Fix round 2: ditto streams local headers; every byte before the directory must
    /// belong to a listed entry, in order.
    func testZipHiddenLocalEntriesAreRefused() throws {
        let hidden = ZipFixture.Entry("hidden.bin", Data(repeating: 0, count: 64))
        let shown = ZipFixture.Entry("a.txt")
        func check(_ data: Data) throws -> ZipInspector.Problem? {
            let url = root.appendingPathComponent("\(UUID().uuidString).zip")
            try data.write(to: url)
            return try XCTUnwrap(ZipInspector.summary(of: url)).problem
        }
        XCTAssertEqual(try check(ZipFixture.build([hidden, shown], listed: [1])), .unlistedData, "hidden first")
        XCTAssertEqual(try check(ZipFixture.build([shown, hidden], listed: [0])), .unlistedData, "hidden last")
        XCTAssertEqual(try check(ZipFixture.build([shown, hidden, ZipFixture.Entry("b.txt")], listed: [0, 2])),
                       .unlistedData, "hidden between")
        XCTAssertEqual(try check(ZipFixture.build([shown], prepend: Data("MZ-stub".utf8))), .unlistedData, "prepended")
        XCTAssertNil(try check(ZipFixture.build([shown, hidden])), "both listed: fine")
        var streamed = shown
        streamed.descriptor = .matching
        XCTAssertNil(try check(ZipFixture.build([streamed, ZipFixture.Entry("b.txt")])), "descriptors are part of the tiling")
    }

    /// The reviewer's crafted archives (Tests/PlatyNotchKitTests/Fixtures/zips).
    func testCraftedArchives() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/zips")
        let expected: [(String, ZipInspector.Problem?)] = [
            ("B3_hidden_slip.zip", .unlistedData), ("B4_hidden_abs.zip", .unlistedData),
            ("E_symlink_dos_abs.zip", .unsafeLink), ("E2_symlink_unix_abs.zip", .unsafeLink),
            ("E3_dos_link_writethrough.zip", .unsafeLink), ("E4_osx_madeon19_link.zip", .unsafeLink),
            ("G_bit3_legit.zip", nil),
        ]
        for (name, problem) in expected {
            let summary = try XCTUnwrap(ZipInspector.summary(of: dir.appendingPathComponent(name)), name)
            XCTAssertEqual(summary.problem, problem, name)
        }
    }

    /// A real archive with a relative link (as ditto stores it) passes.
    func testDittoArchiveWithALinkPasses() throws {
        let src = root.appendingPathComponent("linked")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("t".utf8).write(to: src.appendingPathComponent("target.txt"))
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "target.txt")
        let zip = root.appendingPathComponent("linked.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, zip.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertNil(try XCTUnwrap(ZipInspector.summary(of: zip)).problem)
    }

    /// Fix round 1: attacker-chosen zip64 offsets near UInt64.max never trap.
    func testZip64OffsetsCannotOverflow() throws {
        func archive(dirSize: UInt64, dirOffset: UInt64) throws -> URL {
            var b = Bytes()
            b.raw(Data("PK-junk".utf8))
            let record = UInt64(b.count)
            b.u32(0x0606_4B50); b.u64(44); b.u16(45); b.u16(45); b.u32(0); b.u32(0)
            b.u64(1); b.u64(1); b.u64(dirSize); b.u64(dirOffset)
            b.u32(0x0706_4B50); b.u32(0); b.u64(record); b.u32(1)
            b.u32(0x0605_4B50); b.u16(0); b.u16(0); b.u16(0xFFFF); b.u16(0xFFFF)
            b.u32(0xFFFF_FFFF); b.u32(0xFFFF_FFFF); b.u16(0)
            let url = root.appendingPathComponent("\(UUID().uuidString).zip")
            try b.data.write(to: url)
            return url
        }
        XCTAssertNil(ZipInspector.summary(of: try archive(dirSize: 100, dirOffset: .max - 10)))
        XCTAssertNil(ZipInspector.summary(of: try archive(dirSize: .max, dirOffset: 5)))
        XCTAssertNil(ZipInspector.summary(of: try archive(dirSize: 64, dirOffset: .max)))
        // A central record whose local offset says "in zip64" without a zip64 field: unreadable.
        var data = ZipFixture.build([ZipFixture.Entry("far.txt")])
        let cd = try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        data.replaceSubrange((cd + 42)..<(cd + 46), with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        let url = root.appendingPathComponent("far.zip")
        try data.write(to: url)
        XCTAssertNil(ZipInspector.summary(of: url))
        // A plain local offset past the end of the file: refused, not a crash.
        var past = ZipFixture.build([ZipFixture.Entry("past.txt")])
        let cd2 = try XCTUnwrap(past.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        past.replaceSubrange((cd2 + 42)..<(cd2 + 46), with: Data([0x00, 0x00, 0x00, 0x7F]))
        let pastURL = root.appendingPathComponent("past.zip")
        try past.write(to: pastURL)
        XCTAssertEqual(ZipInspector.summary(of: pastURL)?.problem, .mismatchedHeaders)
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

        // Fix round 1: the string-only step decides whether to ask, touching no disk.
        XCTAssertEqual(ShelfAddPolicy.lexical(["/Users/x/a.txt", "rel", "/Users/x/../x/a.txt", "/"], home: home),
                       [URL(fileURLWithPath: "/Users/x/a.txt")], "relative, root and repeats out; .. standardised")
        XCTAssertEqual(ShelfAddPolicy.lexical([home.appendingPathComponent("shelf.noindex/x").path], home: home), [])
        XCTAssertEqual(ShelfAddPolicy.lexical([link.path], home: home)?.map(\.path), [link.standardizedFileURL.path],
                       "a link into the home passes the string check …")
        XCTAssertEqual(ShelfAddPolicy.accept([link.path], home: home, exists: exists), [], "… and is refused after the click")
        XCTAssertNil(ShelfAddPolicy.lexical(Array(repeating: "/a", count: 21), home: home))
    }

    /// Fix round 2: the string step never stats. `standardizedFileURL` would turn an
    /// existing `/private/var/tmp` into `/var/tmp`, and a plain file URL would look up
    /// whether a path is a folder; here both stay exactly as typed, folded by hand.
    func testLexicalNeverTouchesTheDisk() throws {
        let home = URL(filePath: "/nonexistent-pn-home", directoryHint: .isDirectory)
        let out = try XCTUnwrap(ShelfAddPolicy.lexical(["/private/var/tmp", "/private/nonexistent-pn/./x//y/../z.txt",
                                                        "/../etc", "/a/b/../../.."], home: home))
        XCTAssertEqual(out.map(\.path), ["/private/var/tmp", "/private/nonexistent-pn/x/z.txt"],
                       "a .. above / is refused, as is /")
        XCTAssertFalse(out[0].hasDirectoryPath, "no folder lookup for an existing folder")
        XCTAssertEqual(ShelfAddPolicy.normalize("//a///b/./c/.."), "/a/b")
        XCTAssertNil(ShelfAddPolicy.normalize("a/b"))
        XCTAssertEqual(ShelfAddPolicy.lexical(["/nonexistent-pn-home/../nonexistent-pn-home/x"], home: home), [],
                       "under the home after folding")
    }

    func testRenamePolicy() {
        let user = URL(fileURLWithPath: "/Users/me"), app = URL(fileURLWithPath: "/Users/me/Library/Application Support/PlatyNotch")
        func p(_ s: String) -> Bool { RenamePolicy.isProtected(URL(fileURLWithPath: s), userHome: user, appHome: app) }
        for path in ["/", "/Applications", "/Users", "/Users/me", "/Users/me/Desktop", "/Users/me/Downloads",
                     "/Users/me/Library", "/Users/me/.ssh", "/Users/me/.zshrc", app.path, app.path + "/shelf.noindex/x/a.png",
                     "/Users/me/Desktop/../Documents"] {
            XCTAssertTrue(p(path), path)
        }
        for path in ["/Users/me/Desktop/a.png", "/Users/me/Downloads/trip", "/Users/me/Projects", "/Volumes/USB/a.txt"] {
            XCTAssertFalse(p(path), path)
        }
        XCTAssertTrue(p("/users/ME/desktop"), "case variants")
        XCTAssertTrue(p("/Users/me/LIBRARY/application support/platynotch/x"))
    }

    /// Fix round 2: a path through a linked parent is resolved before checking.
    func testRenamePolicyFollowsLinks() throws {
        let home = root.appendingPathComponent("home")
        let app = home.appendingPathComponent("Library/Application Support/PlatyNotch")
        try fm.createDirectory(at: app.appendingPathComponent("shelf.noindex"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: app)
        XCTAssertTrue(RenamePolicy.isProtected(alias.appendingPathComponent("shelf.noindex"), userHome: home, appHome: app))
        let deskLink = root.appendingPathComponent("desk")
        try fm.createSymbolicLink(at: deskLink, withDestinationURL: home.appendingPathComponent("Desktop"))
        XCTAssertTrue(RenamePolicy.isProtected(deskLink, userHome: home, appHome: app), "a link to Desktop is Desktop")
        let file = home.appendingPathComponent("Desktop/a.txt")
        try Data("a".utf8).write(to: file)
        XCTAssertFalse(RenamePolicy.isProtected(file, userHome: home, appHome: app))
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
