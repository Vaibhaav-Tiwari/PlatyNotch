import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Never a real FSEvents stream: the test sends batches of events.
@MainActor
private final class FakeVaultWatch: FolderWatching {
    let root: String
    let onEvents: @MainActor ([VaultEvent]) -> Void
    var stopped = false
    init(_ root: String, _ onEvents: @escaping @MainActor ([VaultEvent]) -> Void) {
        self.root = root
        self.onEvents = onEvents
    }
    func stop() { stopped = true }
}

/// Counts what the widget asked of the system.
@MainActor
private final class Recorder {
    var watches: [FakeVaultWatch] = []
    var probes: [URL] = []
    var granted = true
    var identity = "build-A"
    var live: FakeVaultWatch? { watches.last.flatMap { $0.stopped ? nil : $0 } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Bookmarks as plain paths, with a count of resolves; `fail` makes none.
private final class PathBookmarks: ShelfBookmarks, @unchecked Sendable {
    let resolves = Counter()
    let makes = Counter()
    var fail = false
    func make(_ url: URL) -> Data? {
        makes.bump()
        return fail ? nil : Data(url.path.utf8)
    }
    func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        resolves.bump()
        return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
}

@MainActor
final class NotesWidgetTests: DefaultsTestCase {
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var vaultDir: URL!
    nonisolated(unsafe) private var fallback: URL!

    /// The tests' clock: 24 Oct 2026, 09:05 UTC.
    nonisolated private static let now: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 5))!
    }()

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let todayNote = "Daily/2026-10-24.md"

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pnnw-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultDir = URL(fileURLWithPath: VaultAccess.canonical(root.path)).appendingPathComponent("Vault", isDirectory: true)
        fallback = root.appendingPathComponent("home/notes.noindex", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultDir.appendingPathComponent("Daily"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A note edited at the tests' clock.
    private func note(_ name: String, _ text: String) {
        let path = vaultDir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        try? FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: path)
    }

    private func read(_ name: String) -> String {
        String(decoding: FileManager.default.contents(atPath: vaultDir.appendingPathComponent(name).path) ?? Data(), as: UTF8.self)
    }

    private func make(_ rec: Recorder, bookmarks: PathBookmarks = PathBookmarks(), scans: Counter = Counter()) -> NotesWidget {
        var s = VaultServices.system()
        s.identity = { [unowned rec] in rec.identity }
        s.bookmarks = bookmarks
        s.probe = { [unowned rec] url in
            rec.probes.append(url)
            return rec.granted
        }
        s.watch = { [unowned rec] root, onEvents in
            let w = FakeVaultWatch(root, onEvents)
            rec.watches.append(w)
            return w
        }
        s.rescanDelay = .milliseconds(30)
        s.periodicRescan = .seconds(3600)
        let scan = s.scan
        s.scan = { url, now in
            scans.bump()
            return scan(url, now)
        }
        s.fallbackFolder = fallback
        let fixed = Self.now
        s.clock = { fixed }
        s.calendar = Self.utc
        return NotesWidget(services: s, defaults: defaults())
    }

    private func context() -> WidgetContext {
        WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                      config: ConfigFileStore(url: root.appendingPathComponent("config.json")),
                      events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(), openPanel: { _ in })
    }

    private func settle(_ w: NotesWidget) async {
        await w.accessTask?.value
        await w.settleWrites()
        while let t = w.scanTask { await t.value }
    }

    private func started(_ rec: Recorder, scans: Counter = Counter()) async -> NotesWidget {
        let w = make(rec, scans: scans)
        w.start(context: context())
        w.chooseVault(vaultDir)
        await settle(w)
        return w
    }

    func testIsAPowerFeatureOffByDefault() {
        let w = make(Recorder())
        XCTAssertEqual(w.category, .power)
        XCTAssertFalse(w.defaultEnabled)
        XCTAssertTrue(w.hasTile)
        XCTAssertTrue(BuiltInWidgets.powerWidgets(persist: false).contains { $0.id == NotesWidget.widgetID })
        XCTAssertEqual(NotchApp.powerSmoke(BuiltInWidgets.powerWidgets(persist: false)), .success(BuiltInWidgets.powerWidgets(persist: false).count))
    }

    func testDoesNothingUntilAVaultIsChosen() async {
        let rec = Recorder()
        let scans = Counter()
        let w = make(rec, scans: scans)
        w.start(context: context())
        w.tileShown()
        await settle(w)
        XCTAssertTrue(rec.watches.isEmpty)
        XCTAssertTrue(rec.probes.isEmpty)
        XCTAssertEqual(scans.value, 0)
        XCTAssertNil(w.vault)
        w.stop()
    }

    func testChoosingAVaultAsksOnceThenWatchesAndListsOpenTasks() async {
        note("a.md", "- [ ] one 📅 2026-01-01\n- [x] done\n")
        note(".obsidian-like.md", "- [ ] hidden\n")
        let rec = Recorder()
        let w = await started(rec)
        XCTAssertEqual(rec.probes, [vaultDir])
        XCTAssertTrue(w.options.vaultOn)
        XCTAssertEqual(w.options.vaultPath, vaultDir.path)
        XCTAssertNotNil(w.options.vaultBookmark)
        XCTAssertEqual(rec.live?.root, vaultDir.path)
        XCTAssertEqual(w.tasks.map(\.title), ["one"])
        XCTAssertEqual(defaults().string(forKey: "notes.vault.grant"), "build-A")
        w.stop()
        XCTAssertNil(rec.live, "stop ends the watch")
    }

    func testDeniedVaultStaysOffAndKeepsNoBookmark() async {
        let rec = Recorder()
        rec.granted = false
        let bookmarks = PathBookmarks()
        let w = make(rec, bookmarks: bookmarks)
        w.start(context: context())
        w.chooseVault(vaultDir)
        await settle(w)
        XCTAssertFalse(w.options.vaultOn)
        XCTAssertTrue(w.options.vaultDenied)
        XCTAssertNil(w.options.vaultBookmark)
        XCTAssertEqual(bookmarks.makes.value, 0, "no bookmark before the grant")
        XCTAssertTrue(rec.watches.isEmpty)
        XCTAssertNil(defaults().string(forKey: "notes.vault.grant"))
        // Try Again asks for the same folder.
        rec.granted = true
        w.turnOnAgain()
        await settle(w)
        XCTAssertEqual(rec.probes, [vaultDir, vaultDir])
        XCTAssertTrue(w.options.vaultOn)
        XCTAssertNotNil(w.options.vaultBookmark)
        w.stop()
    }

    func testNoBookmarkMeansDenied() async {
        let rec = Recorder()
        let bookmarks = PathBookmarks()
        bookmarks.fail = true
        let w = make(rec, bookmarks: bookmarks)
        w.start(context: context())
        w.chooseVault(vaultDir)
        await settle(w)
        XCTAssertFalse(w.options.vaultOn)
        XCTAssertTrue(w.options.vaultDenied)
        XCTAssertTrue(rec.watches.isEmpty)
        XCTAssertNil(defaults().string(forKey: "notes.vault.grant"))
        w.stop()
    }

    func testAnotherBuildsGrantAsksToTurnOnAgainWithoutTouchingTheVault() async {
        let rec = Recorder()
        let first = await started(rec)
        first.stop()
        rec.identity = "build-B"
        rec.probes = []
        let bookmarks = PathBookmarks()
        let scans = Counter()
        let w = make(rec, bookmarks: bookmarks, scans: scans)
        let watchesBefore = rec.watches.count
        w.start(context: context())
        await settle(w)
        XCTAssertFalse(w.options.vaultOn)
        XCTAssertTrue(w.options.vaultNeedReenable)
        XCTAssertEqual(rec.watches.count, watchesBefore)
        XCTAssertTrue(rec.probes.isEmpty)
        XCTAssertEqual(bookmarks.resolves.value, 0)
        XCTAssertEqual(scans.value, 0)
        // Turn On Again (the button) asks and resumes.
        w.turnOnAgain()
        await settle(w)
        XCTAssertEqual(rec.probes.count, 1)
        XCTAssertTrue(w.options.vaultOn)
        XCTAssertNotNil(rec.live)
        w.stop()
    }

    func testThisBuildsGrantResumesWithoutAsking() async {
        let rec = Recorder()
        let first = await started(rec)
        first.stop()
        rec.probes = []
        let w = make(rec)
        w.start(context: context())
        await settle(w)
        XCTAssertTrue(rec.probes.isEmpty)
        XCTAssertNotNil(rec.live)
        XCTAssertEqual(w.vault?.path, vaultDir.path)
        w.stop()
    }

    private func event(_ rel: String, dir: Bool = false, mustScan: Bool = false) -> VaultEvent {
        VaultEvent(path: vaultDir.appendingPathComponent(rel).path, isDirectory: dir, mustScan: mustScan)
    }

    func testDotFolderAndOtherFileEventsScheduleNothing() async {
        let rec = Recorder()
        let scans = Counter()
        let w = await started(rec, scans: scans)
        let walks = scans.value
        let passes = w.rescans
        rec.live?.onEvents([event(".obsidian/workspace.json"), event(".obsidian", dir: true),
                            event(".trash/old.md"), event("image.png")])
        XCTAssertFalse(w.rescanScheduled)
        XCTAssertTrue(w.pending.isEmpty)
        try? await Task.sleep(for: .milliseconds(100))
        await settle(w)
        XCTAssertEqual(w.rescans, passes)
        XCTAssertEqual(scans.value, walks)
        w.stop()
    }

    func testNoteEventsAreCoalescedAndReadOnlyThoseNotes() async {
        note("a.md", "- [ ] a\n")
        let rec = Recorder()
        let scans = Counter()
        let w = await started(rec, scans: scans)
        let walks = scans.value
        let passes = w.rescans
        note("a.md", "- [ ] a\n- [ ] a2\n")
        note("b.md", "- [ ] b\n")
        rec.live?.onEvents([event("a.md")])
        rec.live?.onEvents([event("b.md")])
        rec.live?.onEvents([event("a.md")])
        XCTAssertTrue(w.rescanScheduled)
        _ = await eventually { w.rescans > passes && w.scanTask == nil }
        await settle(w)
        XCTAssertEqual(w.rescans, passes + 1, "three batches, one rescan")
        XCTAssertEqual(scans.value, walks, "note events never walk the vault")
        XCTAssertEqual(Set(w.tasks.map(\.title)), ["a", "a2", "b"])
        w.stop()
    }

    func testFolderEventsWalkOnce() async {
        let rec = Recorder()
        let scans = Counter()
        let w = await started(rec, scans: scans)
        let walks = scans.value
        let passes = w.rescans
        rec.live?.onEvents([event("Projects", dir: true)])
        rec.live?.onEvents([event("x.md")])
        rec.live?.onEvents([VaultEvent(path: vaultDir.path, isDirectory: true, mustScan: true)])
        _ = await eventually { w.rescans > passes && w.scanTask == nil }
        await settle(w)
        XCTAssertEqual(w.rescans, passes + 1)
        XCTAssertEqual(scans.value, walks + 1)
        w.stop()
    }

    func testTickWritesTheLineAndAMovedLineAsksFirst() async {
        note("a.md", "- [ ] one\n- [ ] two\n")
        let rec = Recorder()
        let w = await started(rec)
        guard let one = w.tasks.first(where: { $0.title == "one" }) else { return XCTFail("no task") }
        w.toggle(one)
        await settle(w)
        XCTAssertEqual(read("a.md"), "- [x] one\n- [ ] two\n")
        XCTAssertEqual(w.tasks.map(\.title), ["two"])
        // Edited elsewhere: "two" moved down a line before the tick.
        guard let two = w.tasks.first else { return XCTFail("no task") }
        note("a.md", "- [x] one\n- [ ] new\n- [ ] two\n")
        w.toggle(two)
        await settle(w)
        XCTAssertEqual(read("a.md"), "- [x] one\n- [ ] new\n- [ ] two\n", "nothing written before the answer")
        XCTAssertEqual(w.pendingAsk?.line, 3)
        w.confirmAsk()
        await settle(w)
        XCTAssertEqual(read("a.md"), "- [x] one\n- [ ] new\n- [x] two\n")
        XCTAssertNil(w.pendingAsk)
        w.stop()
    }

    func testRecurringTasksAreNeverTicked() async {
        note("r.md", "- [ ] stretch 🔁 every day\n")
        let rec = Recorder()
        let w = await started(rec)
        guard let t = w.tasks.first else { return XCTFail("no task") }
        XCTAssertTrue(t.isRecurring)
        w.toggle(t)
        await settle(w)
        XCTAssertEqual(read("r.md"), "- [ ] stretch 🔁 every day\n")
        XCTAssertEqual(w.status, NotesWidget.recurringText)
        w.stop()
    }

    func testTwoTicksAndAnAppendInTheSameNoteAllPersist() async {
        note(todayNote, "# Today\n- [ ] a\n- [ ] b\n- [ ] c\n")
        let rec = Recorder()
        let w = await started(rec)
        let open = w.tasks
        XCTAssertEqual(open.count, 3)
        for t in open { w.toggle(t) }
        w.draft = "thought"
        w.addDraft()
        await settle(w)
        XCTAssertEqual(read(todayNote), "# Today\n- [x] a\n- [x] b\n- [x] c\n- 09:05 thought\n")
        XCTAssertTrue(w.tasks.isEmpty)
        w.stop()
    }

    func testQuickNoteGoesToTheFallbackThenTheDailyNote() async throws {
        let rec = Recorder()
        let w = make(rec)
        w.start(context: context())
        w.draft = "first thought"
        w.addDraft()
        await settle(w)
        let fallbackFile = fallback.appendingPathComponent(QuickNote.fallbackName)
        XCTAssertEqual(String(decoding: FileManager.default.contents(atPath: fallbackFile.path) ?? Data(), as: UTF8.self),
                       "- 09:05 first thought\n")
        XCTAssertEqual(w.draft, "")
        let mode = try FileManager.default.attributesOfItem(atPath: fallbackFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        w.chooseVault(vaultDir)
        await settle(w)
        // Today's note is missing: not made (Obsidian's template), the draft stays.
        w.draft = "in the vault"
        w.addDraft()
        await settle(w)
        XCTAssertEqual(w.status, QuickNote.noDailyNote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultDir.appendingPathComponent(todayNote).path))
        XCTAssertEqual(w.draft, "in the vault")
        // Opened in Obsidian (exists now): appended.
        note(todayNote, "# 2026-10-24\n")
        w.addDraft()
        await settle(w)
        XCTAssertEqual(read(todayNote), "# 2026-10-24\n- 09:05 in the vault\n")
        XCTAssertEqual(w.draft, "")
        // With "Create today's note if missing" on, a missing note is made.
        try FileManager.default.removeItem(at: vaultDir.appendingPathComponent(todayNote))
        w.setCreateDailyNote(true)
        w.draft = "made"
        w.addDraft()
        await settle(w)
        XCTAssertEqual(read(todayNote), "- 09:05 made\n")
        // A daily folder that does not exist is never made.
        w.setDailyFolder("Journal")
        w.draft = "nowhere"
        w.addDraft()
        await settle(w)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultDir.appendingPathComponent("Journal").path))
        XCTAssertEqual(w.draft, "nowhere")
        // One outside the vault is refused before anything is touched.
        w.setDailyFolder("../out")
        XCTAssertFalse(w.dailyFolderValid)
        w.addDraft()
        XCTAssertNotNil(w.status)
        w.stop()
    }

    func testChangeKeepsTheOldVaultUntilTheNewOneIsGranted() async {
        let rec = Recorder()
        let bookmarks = PathBookmarks()
        let w = make(rec, bookmarks: bookmarks)
        w.start(context: context())
        w.chooseVault(vaultDir)
        await settle(w)
        let oldBookmark = w.options.vaultBookmark
        let other = vaultDir.deletingLastPathComponent().appendingPathComponent("Other", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        rec.granted = false
        w.chooseVault(other)
        await settle(w)
        XCTAssertEqual(w.options.vaultBookmark, oldBookmark)
        XCTAssertEqual(w.options.vaultPath, vaultDir.path)
        XCTAssertTrue(w.options.vaultOn)
        XCTAssertEqual(defaults().string(forKey: "notes.vault.grant"), "build-A")
        XCTAssertEqual(w.vault?.path, vaultDir.path)
        XCTAssertNotNil(rec.live)
        rec.granted = true
        w.chooseVault(other)
        await settle(w)
        XCTAssertEqual(w.options.vaultPath, other.path)
        XCTAssertEqual(w.vault?.path, VaultAccess.canonical(other.path))
        XCTAssertEqual(rec.live?.root, VaultAccess.canonical(other.path))
        XCTAssertEqual(rec.watches.filter { !$0.stopped }.count, 1)
        w.stop()
    }

    func testPeriodicWalkStartsWhenTheVaultTurnsOnUnderAShownTile() async {
        let rec = Recorder()
        let w = make(rec)
        w.start(context: context())
        w.tileShown()
        XCTAssertFalse(w.periodicWalkRunning, "no vault, no walk")
        w.chooseVault(vaultDir)
        await settle(w)
        XCTAssertTrue(w.periodicWalkRunning)
        w.tileHidden()
        XCTAssertFalse(w.periodicWalkRunning)
        w.stop()
    }

    func testForgetStopsAndClears() async {
        let rec = Recorder()
        let w = await started(rec)
        w.forgetVault()
        XCTAssertNil(rec.live)
        XCTAssertNil(w.options.vaultPath)
        XCTAssertFalse(w.options.vaultOn)
        XCTAssertNil(defaults().string(forKey: "notes.vault.grant"))
        w.stop()
    }

    func testPlanIgnoresPathsOutsideTheVault() {
        let plan = VaultRescan.plan([VaultEvent(path: "/elsewhere/a.md", isDirectory: false, mustScan: false),
                                     VaultEvent(path: vaultDir.path + "x/a.md", isDirectory: false, mustScan: false)],
                                    root: vaultDir.path)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(VaultRescan.plan([event("Sub/a.md")], root: vaultDir.path).paths, [event("Sub/a.md").path])
    }
}
