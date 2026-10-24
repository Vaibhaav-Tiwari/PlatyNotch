import Darwin
import Foundation
import XCTest
@testable import PlatyNotchKit

/// The toggle write-back, quick-note appends and the vault scan, on real files in a
/// temporary folder (R18: a toggle must never land on the wrong line).
final class NoteFilesTests: DefaultsTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnnotes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Real paths, as FSEvents reports them (/var is /private/var).
        if let r = realpath(dir.path, nil) {
            dir = URL(fileURLWithPath: String(cString: r), isDirectory: true)
            free(r)
        }
    }

    override func tearDown() {
        // Unlock anything a test locked, then remove the folder.
        if let e = FileManager.default.enumerator(atPath: dir.path) {
            while let p = e.nextObject() as? String {
                let full = dir.appendingPathComponent(p).path
                _ = chflags(full, 0)
                _ = chmod(full, 0o700)
            }
        }
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    @discardableResult
    private func write(_ name: String, _ text: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
        return url
    }

    private func read(_ url: URL) -> String {
        String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    }

    private func tasks(_ url: URL) -> [MarkdownTask] {
        MarkdownTasks.parse(read(url), file: url.path)
    }

    // MARK: - Toggle write-back

    func testToggleWritesOnlyThatLine() {
        let url = write("n.md", "# x\n- [ ] one\n- [ ] two\n")
        let t = tasks(url)[1]
        guard case .toggled(let now) = TaskFileWriter.toggle(t) else { return XCTFail("not toggled") }
        XCTAssertTrue(now.done)
        XCTAssertEqual(now.line, 3)
        XCTAssertEqual(read(url), "# x\n- [ ] one\n- [x] two\n")
        guard case .toggled = TaskFileWriter.toggle(now) else { return XCTFail("not untoggled") }
        XCTAssertEqual(read(url), "# x\n- [ ] one\n- [ ] two\n")
    }

    func testFileChangedSinceParsedFindsTheMovedLineAndAsks() {
        let url = write("n.md", "- [ ] one\n- [ ] two\n")
        let two = tasks(url)[1]
        // A line was added above it in Obsidian: line 2 is now "one".
        write("n.md", "- [ ] zero\n- [ ] one\n- [ ] two\n")
        let before = read(url)
        guard case .moved(let found) = TaskFileWriter.toggle(two) else { return XCTFail("expected moved") }
        XCTAssertEqual(read(url), before, "nothing written before the user confirms")
        XCTAssertEqual(found.line, 3)
        XCTAssertEqual(found.raw, "- [ ] two")
        guard case .toggled = TaskFileWriter.toggle(found) else { return XCTFail("confirmed toggle failed") }
        XCTAssertEqual(read(url), "- [ ] zero\n- [ ] one\n- [x] two\n")
    }

    func testFileChangedAndTaskEditedWritesNothing() {
        let url = write("n.md", "- [ ] one\n- [ ] two\n")
        let two = tasks(url)[1]
        write("n.md", "- [ ] one\n- [ ] two, edited\n")
        guard case .changed(let now) = TaskFileWriter.toggle(two) else { return XCTFail("expected changed") }
        XCTAssertEqual(now.map(\.text), ["one", "two, edited"])
        XCTAssertEqual(read(url), "- [ ] one\n- [ ] two, edited\n")
    }

    func testAlreadyTickedElsewhereWritesNothing() {
        let url = write("n.md", "- [ ] one\n")
        let one = tasks(url)[0]
        write("n.md", "- [x] one\n")
        guard case .changed = TaskFileWriter.toggle(one) else { return XCTFail("expected changed") }
        XCTAssertEqual(read(url), "- [x] one\n")
    }

    func testDuplicateLinesAfterAChangeAreNotGuessed() {
        let url = write("n.md", "- [ ] same\n")
        let t = tasks(url)[0]
        write("n.md", "intro\n- [ ] same\n- [ ] same\n")
        guard case .changed = TaskFileWriter.toggle(t) else { return XCTFail("two candidates must not be guessed") }
        XCTAssertEqual(read(url), "intro\n- [ ] same\n- [ ] same\n")
    }

    func testEditDuringTheWriteWins() {
        let url = write("n.md", "- [ ] one\n- [ ] two\n")
        let two = tasks(url)[1]
        let result = TaskFileWriter.toggle(two, beforeSwap: { [self] in write("n.md", "- [ ] one\n- [ ] two\n- [ ] three\n") })
        XCTAssertEqual(result, .changed(MarkdownTasks.parse("- [ ] one\n- [ ] two\n- [ ] three\n", file: url.path)))
        XCTAssertEqual(read(url), "- [ ] one\n- [ ] two\n- [ ] three\n")
    }

    func testCRLFFileKeepsItsLineEndings() {
        let url = write("n.md", "a\r\n- [ ] one\r\n- [ ] two\r\n")
        guard case .toggled = TaskFileWriter.toggle(tasks(url)[1]) else { return XCTFail("not toggled") }
        XCTAssertEqual(try? Data(contentsOf: url), Data("a\r\n- [ ] one\r\n- [x] two\r\n".utf8))
    }

    func testFrontmatterFileKeepsItsFrontmatter() {
        let text = "---\ntitle: x\n- [ ] yaml\n---\n- [ ] body\n"
        let url = write("n.md", text)
        let t = tasks(url)
        XCTAssertEqual(t.map(\.line), [5])
        guard case .toggled = TaskFileWriter.toggle(t[0]) else { return XCTFail("not toggled") }
        XCTAssertEqual(read(url), "---\ntitle: x\n- [ ] yaml\n---\n- [x] body\n")
        // A forged task pointing into the frontmatter is refused.
        let forged = MarkdownTask(file: url.path, line: 3, text: "yaml", done: false, due: nil, raw: "- [ ] yaml")
        guard case .changed = TaskFileWriter.toggle(forged) else { return XCTFail("frontmatter line written") }
        XCTAssertEqual(read(url), "---\ntitle: x\n- [ ] yaml\n---\n- [x] body\n")
    }

    func testIndentedAndUpperXTasks() {
        let url = write("n.md", "- [ ] parent\n\t- [X] child\n    - [ ] deep\n")
        let t = tasks(url)
        guard case .toggled = TaskFileWriter.toggle(t[1]) else { return XCTFail("not toggled") }
        XCTAssertEqual(read(url), "- [ ] parent\n\t- [ ] child\n    - [ ] deep\n")
        guard case .toggled = TaskFileWriter.toggle(tasks(url)[2]) else { return XCTFail("not toggled") }
        XCTAssertEqual(read(url), "- [ ] parent\n\t- [ ] child\n    - [x] deep\n")
    }

    func testKeepsPermissionsAndExtendedAttributes() {
        let url = write("n.md", "- [ ] one\n")
        // Another group this user is in, when there is one.
        var groups = [gid_t](repeating: 0, count: 64)
        let n = Int(getgroups(Int32(groups.count), &groups))
        let original = (try? FileManager.default.attributesOfItem(atPath: url.path)[.groupOwnerAccountID] as? NSNumber)?.uint32Value
        let other = groups.prefix(max(n, 0)).first { $0 != original } ?? original ?? 0
        XCTAssertEqual(chown(url.path, uid_t.max, other), 0)
        XCTAssertEqual(chmod(url.path, 0o640), 0)
        let value = Array("kept".utf8)
        XCTAssertEqual(setxattr(url.path, "dev.platynotch.test", value, value.count, 0, 0), 0)
        let created = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate]) as? Date
        guard case .toggled = TaskFileWriter.toggle(tasks(url)[0]) else { return XCTFail("not toggled") }
        XCTAssertEqual(read(url), "- [x] one\n")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual((attrs?[.groupOwnerAccountID] as? NSNumber)?.uint32Value, other)
        XCTAssertEqual(attrs?[.creationDate] as? Date, created)
        var buf = [UInt8](repeating: 0, count: 16)
        let got = getxattr(url.path, "dev.platynotch.test", &buf, buf.count, 0, 0)
        XCTAssertEqual(got, value.count)
        XCTAssertEqual(Array(buf.prefix(max(got, 0))), value)
        // Nothing left behind in the vault folder.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["n.md"])
    }

    func testReadOnlyFileIsNotWritten() {
        let url = write("n.md", "- [ ] one\n")
        XCTAssertEqual(chmod(url.path, 0o444), 0)
        XCTAssertEqual(TaskFileWriter.toggle(tasks(url)[0]), .readOnly)
        XCTAssertEqual(read(url), "- [ ] one\n")
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o444)
    }

    func testLockedFileIsNotWritten() {
        let url = write("n.md", "- [ ] one\n")
        let t = tasks(url)[0]
        XCTAssertEqual(chflags(url.path, UInt32(UF_IMMUTABLE)), 0)
        XCTAssertEqual(TaskFileWriter.toggle(t), .readOnly)
        _ = chflags(url.path, 0)
        XCTAssertEqual(read(url), "- [ ] one\n")
    }

    func testLinksAreNeverWritten() {
        let real = write("real.md", "- [ ] one\n")
        let link = dir.appendingPathComponent("link.md")
        XCTAssertNoThrow(try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real))
        guard case .failed = TaskFileWriter.toggle(tasks(link)[0]) else { return XCTFail("wrote through a symlink") }
        let hard = dir.appendingPathComponent("hard.md")
        XCTAssertEqual(Darwin.link(real.path, hard.path), 0)
        guard case .failed = TaskFileWriter.toggle(tasks(real)[0]) else { return XCTFail("wrote a hard-linked file") }
        XCTAssertEqual(read(real), "- [ ] one\n")
    }

    func testEditInPlaceDuringTheSwapIsSwappedBack() {
        let url = write("n.md", "- [ ] one\n- [ ] two\n")
        let two = tasks(url)[1]
        // Same inode, new bytes (an editor writing in place) just before the swap.
        let result = TaskFileWriter.toggle(two, beforeSwap: {
            let h = FileHandle(forWritingAtPath: url.path)
            h?.write(Data("- [ ] ONE\n".utf8))
            try? h?.close()
        })
        guard case .changed = result else { return XCTFail("expected changed, got \(result)") }
        XCTAssertEqual(read(url), "- [ ] ONE\n- [ ] two\n")
    }

    func testSameTextOnSeveralLinesAfterAChangeAsks() {
        let url = write("n.md", "- [ ] same\n- [ ] x\n")
        let t = tasks(url)[0]
        write("n.md", "- [ ] same\n- [ ] same\n- [ ] x\n")
        guard case .moved(let found) = TaskFileWriter.toggle(t) else { return XCTFail("expected moved") }
        XCTAssertEqual(found.line, 1)
        XCTAssertEqual(read(url), "- [ ] same\n- [ ] same\n- [ ] x\n")
        // Unchanged since that answer: written.
        guard case .toggled = TaskFileWriter.toggle(found) else { return XCTFail("confirmed toggle failed") }
        XCTAssertEqual(read(url), "- [x] same\n- [ ] same\n- [ ] x\n")
    }

    func testRecurringTasksAreNeverWritten() {
        let url = write("n.md", "- [ ] water plants 🔁 every week 📅 2026-10-30\n")
        let t = tasks(url)[0]
        XCTAssertTrue(t.isRecurring)
        XCTAssertEqual(TaskFileWriter.toggle(t), .recurring)
        XCTAssertEqual(read(url), "- [ ] water plants 🔁 every week 📅 2026-10-30\n")
    }

    func testWriterRefusesNonUTF8AndLargeNotes() {
        let latin = dir.appendingPathComponent("latin.md")
        FileManager.default.createFile(atPath: latin.path, contents: Data([0x2D, 0x20, 0x5B, 0x20, 0x5D, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A]))
        let t = MarkdownTask(file: latin.path, line: 1, text: "café", done: false, due: nil, raw: "- [ ] caf\u{FFFD}")
        guard case .failed = TaskFileWriter.toggle(t) else { return XCTFail("wrote Latin-1") }
        let big = write("big.md", "- [ ] big\n" + String(repeating: "x", count: TaskFileWriter.maxBytes))
        guard case .failed = TaskFileWriter.toggle(tasks(big)[0]) else { return XCTFail("wrote a huge note") }
        XCTAssertEqual(try? Data(contentsOf: latin), Data([0x2D, 0x20, 0x5B, 0x20, 0x5D, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A]))
    }

    func testWriterKeepsBOMAndMissingTrailingNewline() {
        let url = dir.appendingPathComponent("bom.md")
        FileManager.default.createFile(atPath: url.path, contents: Data([0xEF, 0xBB, 0xBF] + Array("- [ ] a\n- [ ] b".utf8)))
        let t = MarkdownTasks.parse(bytes: [UInt8]((try? Data(contentsOf: url)) ?? Data()), file: url.path)
        guard case .toggled = TaskFileWriter.toggle(t[1]) else { return XCTFail("not toggled") }
        XCTAssertEqual(try? Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF] + Array("- [ ] a\n- [x] b".utf8)))
    }

    // MARK: - One writer

    func testConcurrentTogglesInOneNoteAllPersist() async {
        let count = 40
        let url = write("n.md", (0..<count).map { "- [ ] task \($0)\n" }.joined())
        let all = tasks(url)
        let writer = NoteWriter()
        let results = await withTaskGroup(of: TaskWriteResult.self) { group in
            for t in all { group.addTask { await writer.run { TaskFileWriter.toggle(t) } } }
            return await group.reduce(into: [TaskWriteResult]()) { $0.append($1) }
        }
        let ok = results.filter { if case .toggled = $0 { return true } else { return false } }.count
        XCTAssertEqual(ok, count)
        XCTAssertEqual(read(url), (0..<count).map { "- [x] task \($0)\n" }.joined())
    }

    func testConcurrentTogglesAndAppendsAllPersist() async {
        let count = 30
        let url = write("n.md", (0..<count).map { "- [ ] task \($0)\n" }.joined())
        let all = tasks(url)
        let writer = NoteWriter()
        let outcomes = await withTaskGroup(of: (String, Bool).self) { group in
            for (i, t) in all.enumerated() {
                group.addTask {
                    let r = await writer.run { TaskFileWriter.toggle(t) }
                    if case .toggled = r { return ("t", true) }
                    return ("t", false)
                }
                group.addTask {
                    let r = await writer.run { QuickNote.append("- 09:00 note \(i)", to: url) }
                    return ("a", r == .appended)
                }
            }
            return await group.reduce(into: [(String, Bool)]()) { $0.append($1) }
        }
        XCTAssertTrue(outcomes.allSatisfy(\.1), "every write reported success")
        let text = read(url)
        for i in 0..<count {
            XCTAssertTrue(text.contains("- [x] task \(i)\n"), "tick \(i) lost")
            XCTAssertTrue(text.contains("- 09:00 note \(i)\n"), "append \(i) lost")
        }
        XCTAssertFalse(text.contains("- [ ] task"))
    }

    func testMissingFileFails() {
        let t = MarkdownTask(file: dir.appendingPathComponent("gone.md").path, line: 1, text: "a", done: false, due: nil, raw: "- [ ] a")
        guard case .failed = TaskFileWriter.toggle(t) else { return XCTFail("expected failure") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.file))
    }

    // MARK: - Quick note

    func testEntryFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9, minute: 5))!
        XCTAssertEqual(QuickNote.entry("  buy milk\nand eggs ", at: date, calendar: cal), "- 09:05 buy milk and eggs")
        XCTAssertNil(QuickNote.entry(" \n ", at: date, calendar: cal))
        XCTAssertEqual(QuickNote.dailyNoteName(for: date, calendar: cal), "2026-03-04.md")
        XCTAssertEqual(QuickNote.dailyNote(vault: dir, folder: "Daily", date: date, calendar: cal)?.path,
                       dir.appendingPathComponent("Daily/2026-03-04.md").path)
    }

    func testDailyFolderMustStayInTheVault() {
        XCTAssertEqual(QuickNote.cleanFolder("Daily"), "Daily")
        XCTAssertEqual(QuickNote.cleanFolder(" Journal/Daily/ "), "Journal/Daily")
        XCTAssertEqual(QuickNote.cleanFolder(""), "")
        XCTAssertNil(QuickNote.cleanFolder("../outside"))
        XCTAssertNil(QuickNote.cleanFolder("/etc"))
        XCTAssertNil(QuickNote.cleanFolder("~/x"))
        XCTAssertNil(QuickNote.cleanFolder(".obsidian"))
        XCTAssertNil(QuickNote.cleanFolder("a/./b"))
    }

    func testAppendAddsALineAndKeepsTheRest() {
        let url = write("d.md", "# Day\nno trailing break")
        XCTAssertEqual(QuickNote.append("- 09:00 hi", to: url, createMode: 0o644), .appended)
        XCTAssertEqual(read(url), "# Day\nno trailing break\n- 09:00 hi\n")
        XCTAssertEqual(QuickNote.append("- 09:01 again", to: url, createMode: 0o644), .appended)
        XCTAssertEqual(read(url), "# Day\nno trailing break\n- 09:00 hi\n- 09:01 again\n")
    }

    func testAppendUsesCRLFInACRLFNote() {
        let url = write("d.md", "# Day\r\n")
        XCTAssertEqual(QuickNote.append("- 09:00 hi", to: url, createMode: nil), .appended)
        XCTAssertEqual(try? Data(contentsOf: url), Data("# Day\r\n- 09:00 hi\r\n".utf8))
    }

    func testAppendCreatesTodaysNoteButNeverItsFolder() {
        let daily = dir.appendingPathComponent("Daily", isDirectory: true)
        let note = daily.appendingPathComponent("2026-03-04.md")
        guard case .failed = QuickNote.append("- 09:00 hi", to: note, createMode: 0o644) else { return XCTFail("made a folder") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: daily.path))
        try? FileManager.default.createDirectory(at: daily, withIntermediateDirectories: false)
        XCTAssertEqual(QuickNote.append("- 09:00 hi", to: note, createMode: 0o644), .appended)
        XCTAssertEqual(read(note), "- 09:00 hi\n")
    }

    func testAppendRefusesReadOnlyAndLinks() {
        let url = write("d.md", "x\n")
        XCTAssertEqual(chmod(url.path, 0o444), 0)
        guard case .failed = QuickNote.append("- 1", to: url, createMode: nil) else { return XCTFail("wrote read-only") }
        XCTAssertEqual(read(url), "x\n")
        let target = write("t.md", "t\n")
        let link = dir.appendingPathComponent("l.md")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        guard case .failed = QuickNote.append("- 1", to: link, createMode: 0o644) else { return XCTFail("wrote through a link") }
        XCTAssertEqual(read(target), "t\n")
        // Without createMode a missing note is not made.
        XCTAssertEqual(QuickNote.append("- 1", to: dir.appendingPathComponent("none.md")), .noNote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("none.md").path))
    }

    func testAppendRefusesNotesThatAreNotUTF8Text() {
        let cases: [(String, [UInt8])] = [
            ("utf16bom.md", [0xFF, 0xFE] + Array("hi\n".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            ("utf16.md", Array("hi\n".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            ("latin1.md", [0x63, 0x61, 0x66, 0xE9, 0x0A]),
        ]
        for (name, bytes) in cases {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
            guard case .failed = QuickNote.append("- 09:00 x", to: url) else { return XCTFail("appended to \(name)") }
            XCTAssertEqual(try? Data(contentsOf: url), Data(bytes), name)
        }
        let big = write("big.md", String(repeating: "x", count: TaskFileWriter.maxBytes + 1))
        guard case .failed = QuickNote.append("- 09:00 x", to: big) else { return XCTFail("appended to a huge note") }
    }

    func testAppendNeverFollowsALinkedFolderOutOfTheVault() {
        let vault = dir.appendingPathComponent("vault", isDirectory: true)
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside.appendingPathComponent("2026-03-04.md").path, contents: Data("x\n".utf8))
        try? FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("Daily"), withDestinationURL: outside)
        guard case .failed = QuickNote.append("- 09:00 x", root: vault, path: "Daily/2026-03-04.md", createMode: 0o644) else {
            return XCTFail("followed a linked folder")
        }
        XCTAssertEqual(read(outside.appendingPathComponent("2026-03-04.md")), "x\n")
        guard case .failed = QuickNote.append("- 09:00 x", root: vault, path: "../outside/2026-03-04.md") else {
            return XCTFail("left the vault")
        }
    }

    func testFallbackFileIsPrivate() {
        let folder = dir.appendingPathComponent(CorePaths.notesName, isDirectory: true)
        XCTAssertEqual(QuickNote.appendToFallback("- 09:00 hi", folder: folder), .appended)
        let file = folder.appendingPathComponent(QuickNote.fallbackName)
        XCTAssertEqual(read(file), "- 09:00 hi\n")
        let fileMode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        let dirMode = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertTrue(PrivateFolder.isMarked(folder))
    }

    func testNotesPathIsUnderHome() {
        let home = CorePaths.notes(env: ["PLATYNOTCH_HOME": "/tmp/pnh"])
        XCTAssertEqual(home.path, "/tmp/pnh/notes.noindex")
    }

    // MARK: - Vault scan

    private func setModified(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testScanSkipsDotFoldersOldFilesAndLinks() {
        let now = Date()
        write("a.md", "- [ ] a")
        write("Sub/b.MD", "- [ ] b")
        write(".obsidian/c.md", "- [ ] c")
        write("Sub/.trash/d.md", "- [ ] d")
        write(".hidden.md", "- [ ] e")
        write("notes.txt", "- [ ] f")
        setModified(write("old.md", "- [ ] g"), now.addingTimeInterval(-31 * 24 * 3600))
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnout-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        FileManager.default.createFile(atPath: outside.appendingPathComponent("x.md").path, contents: Data("- [ ] x".utf8))
        try? FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("linked"), withDestinationURL: outside)
        try? FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("l.md"),
                                                    withDestinationURL: outside.appendingPathComponent("x.md"))
        let scan = VaultScanner.scan(root: dir, now: now)
        let names = scan.notes.map { ($0.path as NSString).lastPathComponent }.sorted()
        XCTAssertEqual(names, ["a.md", "b.MD"])
        XCTAssertFalse(scan.capped)
    }

    func testScanCapsNewestFirst() {
        let now = Date()
        for i in 0..<5 { setModified(write("n\(i).md", "- [ ] \(i)"), now.addingTimeInterval(TimeInterval(-i * 60))) }
        let scan = VaultScanner.scan(root: dir, now: now, maxFiles: 3)
        XCTAssertEqual(scan.notes.map { ($0.path as NSString).lastPathComponent }, ["n0.md", "n1.md", "n2.md"])
        XCTAssertEqual(scan.matched, 5)
        XCTAssertTrue(scan.capped)
        XCTAssertTrue(VaultScanner.scan(root: dir, now: now, maxEntries: 2).walkCapped)
    }

    func testIndexRefreshesOnlyTheGivenNotes() {
        let now = Date()
        let a = write("a.md", "- [ ] a1\n")
        let b = write("b.md", "- [ ] b1\n")
        var index = TaskIndex()
        index.update(VaultScanner.scan(root: dir, now: now), read: { FileManager.default.contents(atPath: $0) })
        XCTAssertEqual(Set(index.openTasks.map(\.title)), ["a1", "b1"])
        write("a.md", "- [ ] a1\n- [ ] a2 longer\n")
        write("c.md", "- [ ] c1\n")
        try? FileManager.default.removeItem(at: b)
        var reads: [String] = []
        index.refresh([a.path, b.path, dir.appendingPathComponent("c.md").path, dir.appendingPathComponent(".obsidian/x.md").path],
                      stat: { VaultScanner.note(at: $0, root: self.dir.path, now: now) },
                      read: { reads.append($0); return FileManager.default.contents(atPath: $0) })
        XCTAssertEqual(Set(index.openTasks.map(\.title)), ["a1", "a2 longer", "c1"])
        XCTAssertEqual(Set(reads), [a.path, dir.appendingPathComponent("c.md").path])
        index.refresh([a.path], maxFiles: 1, stat: { VaultScanner.note(at: $0, root: self.dir.path, now: now) },
                      read: { FileManager.default.contents(atPath: $0) })
        XCTAssertEqual(index.noteCount, 1)
        XCTAssertTrue(index.capped)
    }

    func testIndexRereadsOnlyChangedNotesAndSortsByDue() {
        let now = Date()
        let a = write("a.md", "- [ ] later\n- [x] done\n- [ ] due 📅 2026-01-02")
        let b = write("b.md", "- [ ] soon 📅 2026-01-01")
        setModified(a, now)
        setModified(b, now.addingTimeInterval(-60))
        var index = TaskIndex()
        var reads: [String] = []
        let reader: (String) -> Data? = { reads.append($0); return FileManager.default.contents(atPath: $0) }
        index.update(VaultScanner.scan(root: dir, now: now), read: reader)
        XCTAssertEqual(index.openTasks.map(\.title), ["soon", "due", "later"])
        XCTAssertEqual(reads.count, 2)
        reads = []
        index.update(VaultScanner.scan(root: dir, now: now), read: reader)
        XCTAssertEqual(reads, [], "unchanged notes are not read again")
        XCTAssertTrue(VaultScanner.isHidden("/v/.obsidian/x.md", under: "/v"))
        XCTAssertFalse(VaultScanner.isHidden("/v/a/x.md", under: "/v"))
        XCTAssertFalse(VaultScanner.isHidden("/.x/v/a.md", under: "/.x/v"))
    }
}
