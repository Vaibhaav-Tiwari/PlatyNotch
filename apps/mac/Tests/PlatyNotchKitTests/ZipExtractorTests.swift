import Foundation
import XCTest
@testable import PlatyNotchKit

/// Fix round 3: PlatyNotch's own unzip. Bad archives are refused with nothing left;
/// good ones extract to exactly what `ditto -x -k` writes.
final class ZipExtractorTests: DefaultsTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private let cap: UInt64 = 2 << 30
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/zips")
    }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ZipExtractorTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func fresh(_ name: String = UUID().uuidString) throws -> URL {
        let url = root.appendingPathComponent("out-\(name)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contents(_ dir: URL) -> [String] {
        (try? fm.subpathsOfDirectory(atPath: dir.path).sorted()) ?? []
    }

    /// Every file, folder and link under `dir`: path → kind and bytes (or link target).
    private func tree(_ dir: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for path in contents(dir) {
            let url = dir.appendingPathComponent(path)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            switch attrs[.type] as? FileAttributeType {
            case .typeSymbolicLink?: out[path] = "link:" + (try fm.destinationOfSymbolicLink(atPath: url.path))
            case .typeDirectory?: out[path] = "dir"
            default: out[path] = "file:" + (try Data(contentsOf: url)).base64EncodedString()
            }
        }
        return out
    }

    private func ditto(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Extracts with ours and with ditto, and compares the trees.
    private func assertMatchesDitto(_ zip: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let ours = try fresh(), theirs = try fresh()
        XCTAssertNoThrow(try ZipExtractor.extract(zip, into: ours, cap: cap), zip.lastPathComponent, file: file, line: line)
        XCTAssertEqual(try ditto(["-x", "-k", zip.path, theirs.path]), 0, file: file, line: line)
        XCTAssertEqual(try tree(ours), try tree(theirs), zip.lastPathComponent, file: file, line: line)
        XCTAssertFalse(contents(ours).isEmpty, file: file, line: line)
    }

    private func assertRefused(_ zip: URL, _ expected: ZipExtractor.Failure? = nil,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let out = try fresh()
        do {
            try ZipExtractor.extract(zip, into: out, cap: cap)
            XCTFail("extracted \(zip.lastPathComponent)", file: file, line: line)
        } catch let e as ZipExtractor.Failure {
            if let expected { XCTAssertEqual(e, expected, zip.lastPathComponent, file: file, line: line) }
        }
        XCTAssertEqual(contents(out).filter { fileExists(out, $0) }, [],
                       "no file left: \(zip.lastPathComponent)", file: file, line: line)
    }

    /// A file (not a folder) at `path` under `dir`.
    private func fileExists(_ dir: URL, _ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: dir.appendingPathComponent(path).path, isDirectory: &isDir) && !isDir.boolValue
    }

    // MARK: - The reviewer's archives (rv2probe)

    func testReviewerBadArchivesAreRefused() throws {
        let bad: [(String, ZipExtractor.Failure)] = [
            ("B3_hidden_slip", .unsafe(.unlistedData)), ("B4_hidden_abs", .unsafe(.unlistedData)),
            ("E_symlink_dos_abs", .unsafe(.unsafeLink)), ("E2_symlink_unix_abs", .unsafe(.unsafeLink)),
            ("E3_dos_link_writethrough", .unsafe(.unsafeLink)), ("E4_osx_madeon19_link", .unsafe(.unsafeLink)),
            // Honest headers, a stream that inflates far past its 9 declared bytes.
            ("D_deflate_decl9_real200M", .damaged),
            // A short deflate stream whose declared size also covers a hidden entry.
            ("S1_stream_end_smuggle", .damaged),
            ("S2_descriptor_smuggle", .damaged),
        ]
        for (name, failure) in bad {
            try assertRefused(fixtures.appendingPathComponent(name + ".zip"), failure)
        }
    }

    func testReviewerGoodArchivesMatchDitto() throws {
        for name in ["G_bit3_legit", "L1_py_stream", "L2_py_stream_zip64", "L4_ditto_empty", "L5_infozip_fz",
                     "L6_infozip_stdout", "L7_bsdtar"] {
            try assertMatchesDitto(fixtures.appendingPathComponent(name + ".zip"))
        }
    }

    /// An unsigned data descriptor (allowed by the format; ditto itself fails on it).
    func testUnsignedDescriptor() throws {
        let out = try fresh()
        XCTAssertEqual(try ZipExtractor.extract(fixtures.appendingPathComponent("L3_bit3_nosig.zip"), into: out, cap: cap), 1)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("g.txt"), encoding: .utf8), "hello1234")
    }

    /// The large probes (50 MB to 1 GiB) are not checked in: run when the reviewer's
    /// folder is on this machine (PLATYNOTCH_RV2PROBE), skipped otherwise.
    func testLargeReviewerArchivesWhenPresent() throws {
        guard let dir = ProcessInfo.processInfo.environment["PLATYNOTCH_RV2PROBE"] else {
            throw XCTSkip("set PLATYNOTCH_RV2PROBE to the rv2probe folder to run the large probes")
        }
        let base = URL(fileURLWithPath: dir)
        for name in ["zips/A_central9_local50M", "zips/B_hidden_local", "zips/C_stored_c50M_u9", "zips/F_bit3_local50M_central9",
                     "zips/I_prepended_raw", "zips/I2_prepended_adjusted", "zips/H_finder_like", "zips2/B2_hidden_1GiB_deflate"] {
            try assertRefused(base.appendingPathComponent(name + ".zip"))
        }
        for name in ["zips/H2_finder_noup", "zips/J_comment", "zips/K_infozip_symlink"] {
            try assertMatchesDitto(base.appendingPathComponent(name + ".zip"))
        }
    }

    // MARK: - Archives made here by the system's tools

    private func sampleFolder() throws -> URL {
        let src = root.appendingPathComponent("src/Sample Folder")
        try fm.createDirectory(at: src.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent("emptydir"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data().write(to: src.appendingPathComponent("empty.txt"))
        var bytes = [UInt8](repeating: 0, count: 300_000)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) }
        try Data(bytes).write(to: src.appendingPathComponent("sub/deeper/r.bin"))
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        return src
    }

    private func run(_ tool: String, _ args: [String], in dir: URL, stdout: URL? = nil) throws -> Bool {
        guard fm.isExecutableFile(atPath: tool) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        if let stdout {
            fm.createFile(atPath: stdout.path, contents: nil)
            p.standardOutput = try FileHandle(forWritingTo: stdout)
        }
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func testSystemToolArchivesMatchDitto() throws {
        let src = try sampleFolder()
        let parent = src.deletingLastPathComponent()
        let name = src.lastPathComponent
        var made: [URL] = []
        let a = root.appendingPathComponent("ditto.zip")
        if try ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, a.path]) == 0 { made.append(a) }
        let b = root.appendingPathComponent("infozip.zip")
        if try run("/usr/bin/zip", ["-r", "-y", "-q", b.path, name], in: parent) { made.append(b) }
        let c = root.appendingPathComponent("infozip-fz.zip")
        if try run("/usr/bin/zip", ["-r", "-y", "-q", "-fz", c.path, name], in: parent) { made.append(c) }
        let d = root.appendingPathComponent("infozip-stdout.zip")
        if try run("/usr/bin/zip", ["-r", "-y", "-q", "-", name], in: parent, stdout: d) { made.append(d) }
        let e = root.appendingPathComponent("bsdtar.zip")
        if try run("/usr/bin/tar", ["--format", "zip", "-cf", e.path, name], in: parent) { made.append(e) }
        XCTAssertGreaterThanOrEqual(made.count, 1)
        for zip in made { try assertMatchesDitto(zip) }
    }

    // MARK: - Damaged and unsupported entries

    private func archive(_ entries: [ZipFixture.Entry]) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).zip")
        try ZipFixture.build(entries).write(to: url)
        return url
    }

    func testStoredAndDeflatedExtract() throws {
        var deflated = ZipFixture.Entry("dir/b.txt", Data(String(repeating: "platypus ", count: 1000).utf8))
        deflated.method = 8
        var folder = ZipFixture.Entry("dir/empty/", Data())
        folder.mode = 0o040755
        let out = try fresh()
        try ZipExtractor.extract(try archive([ZipFixture.Entry("a.txt", Data("A".utf8)), deflated, folder]), into: out, cap: cap)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8), "A")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("dir/b.txt")), deflated.data)
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("dir/empty").path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertFalse(contents(out).contains { $0.contains(".partial-") }, "no partials left")
    }

    func testCRCMismatch() throws {
        var e = ZipFixture.Entry("a.txt", Data("hello".utf8))
        e.crc = 0xDEAD_BEEF
        try assertRefused(try archive([e]), .crcMismatch)
        var d = ZipFixture.Entry("b.txt", Data("hello hello hello".utf8))
        d.method = 8
        d.crc = 1
        try assertRefused(try archive([d]), .crcMismatch)
    }

    /// A deflate stream cut short (declared sizes honest about the short data).
    func testTruncatedStream() throws {
        var e = ZipFixture.Entry("a.txt", Data(String(repeating: "abcdefgh", count: 4000).utf8))
        e.method = 8
        let full = ZipFixture.deflate(e.data)
        e.payload = full.prefix(full.count / 2)
        try assertRefused(try archive([e]), .damaged)
    }

    /// The stream ends before its declared compressed bytes do (trailing bytes): refused.
    func testTrailingBytesAfterTheStream() throws {
        var e = ZipFixture.Entry("a.txt", Data("hello1234".utf8))
        e.method = 8
        e.payload = ZipFixture.deflate(e.data) + Data("hidden local header here".utf8)
        try assertRefused(try archive([e]), .damaged)
    }

    /// A truncated archive file (the end cut off) is not readable at all.
    func testTruncatedArchiveFile() throws {
        let good = ZipFixture.build([ZipFixture.Entry("a.txt", Data(repeating: 7, count: 1000))])
        let url = root.appendingPathComponent("cut.zip")
        try good.prefix(good.count - 30).write(to: url)
        try assertRefused(url, .unreadable)
    }

    func testEncryptedAndUnknownMethods() throws {
        var enc = ZipFixture.Entry("secret.txt", Data("x".utf8))
        enc.flags = 1
        try assertRefused(try archive([enc]), .encrypted)
        var bzip = ZipFixture.Entry("b.bz", Data("x".utf8))
        bzip.method = 12
        bzip.payload = Data("x".utf8)
        try assertRefused(try archive([bzip]), .unsupportedMethod(12))
    }

    func testStoredSizeMustMatch() throws {
        var e = ZipFixture.Entry("a.txt", Data("hello".utf8))
        e.centralSize = 3   // stored: compressed 5, uncompressed 3
        e.localSize = nil
        let url = root.appendingPathComponent("s.zip")
        var data = ZipFixture.build([e])
        // Make the local header agree, so only the stored-size rule can refuse it.
        data.replaceSubrange(22..<26, with: Data([3, 0, 0, 0]))
        try data.write(to: url)
        try assertRefused(url)
    }

    // MARK: - Names, modes, links

    func testNamesAndModes() throws {
        var setuid = ZipFixture.Entry("tool", Data("#!/bin/sh\n".utf8))
        setuid.mode = 0o104755
        var locked = ZipFixture.Entry("locked.txt", Data("x".utf8))
        locked.mode = 0o100000
        let slash = ZipFixture.Entry("win\\path.txt", Data("w".utf8))
        let mac = ZipFixture.Entry("__MACOSX/._tool", Data("apple double".utf8))
        let out = try fresh()
        try ZipExtractor.extract(try archive([setuid, locked, slash, mac]), into: out, cap: cap)
        let mode = { (p: String) in (try? self.fm.attributesOfItem(atPath: out.appendingPathComponent(p).path)[.posixPermissions] as? Int) ?? -1 }
        XCTAssertEqual(mode("tool"), 0o755, "set-user-ID dropped")
        XCTAssertEqual(mode("locked.txt"), 0o644, "no bits: a plain readable file")
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("win/path.txt").path), "\\ read as /")
        XCTAssertFalse(fm.fileExists(atPath: out.appendingPathComponent("__MACOSX").path), "AppleDouble skipped")
        XCTAssertEqual(ZipExtractor.safeParts("/abs/./x//y"), ["abs", "x", "y"], "a leading / dropped")
        XCTAssertNil(ZipExtractor.safeParts("a/../b"))
        XCTAssertNil(ZipExtractor.safeParts("a\0b"))
        XCTAssertEqual(ZipExtractor.fileMode(0o106777), 0o777)
        XCTAssertEqual(ZipExtractor.folderMode(0o1000), 0o755)
    }

    func testDuplicateNamesAreRefused() throws {
        try assertRefused(try archive([ZipFixture.Entry("a.txt"), ZipFixture.Entry("A.TXT")]), .unsafeName)
    }

    /// Links are made last, so a file can never be written through one.
    func testLinksComeLast() throws {
        var link = ZipFixture.Entry("ln", Data("a.txt".utf8))
        link.mode = 0o120755
        let out = try fresh()
        try ZipExtractor.extract(try archive([link, ZipFixture.Entry("a.txt", Data("A".utf8))]), into: out, cap: cap)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out.appendingPathComponent("ln").path), "a.txt")
        // A file listed "inside" a link would be written before the link exists: as a
        // folder of its own, never through the link.
        var dirLink = ZipFixture.Entry("d", Data("elsewhere".utf8))
        dirLink.mode = 0o120755
        let out2 = try fresh()
        XCTAssertThrowsError(try ZipExtractor.extract(try archive([dirLink, ZipFixture.Entry("d/x.txt")]), into: out2, cap: cap))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("elsewhere").path))
    }

    func testCapAndCancellation() throws {
        let big = ZipFixture.Entry("big.bin", Data(repeating: 1, count: 1 << 20))
        let url = try archive([big])
        XCTAssertThrowsError(try ZipExtractor.extract(url, into: try fresh(), cap: 1000)) {
            XCTAssertEqual($0 as? ZipExtractor.Failure, .tooLarge)
        }
        // Cancelled after the first chunk: stops mid-entry, no partial left.
        var calls = 0
        let out = try fresh()
        XCTAssertThrowsError(try ZipExtractor.extract(url, into: out, cap: cap, isCancelled: { calls += 1; return calls > 2 })) {
            XCTAssertEqual($0 as? ZipExtractor.Failure, .cancelled)
        }
        XCTAssertEqual(contents(out), [], "the partial is deleted")
    }
}
