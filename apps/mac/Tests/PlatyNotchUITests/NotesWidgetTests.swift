import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Never a real FSEvents stream: the test sends batches of paths.
@MainActor
private final class FakeVaultWatch: FolderWatching {
    let folders: [String]
    let onPaths: @MainActor ([String]) -> Void
    var stopped = false
    init(_ folders: [String], _ onPaths: @escaping @MainActor ([String]) -> Void) {
        self.folders = folders
        self.onPaths = onPaths
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

/// Bookmarks as plain paths, with a count of resolves.
private final class PathBookmarks: ShelfBookmarks, @unchecked Sendable {
    let resolves = Counter()
    func make(_ url: URL) -> Data? { Data(url.path.utf8) }
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

    private func note(_ name: String, _ text: String) {
        FileManager.default.createFile(atPath: vaultDir.appendingPathComponent(name).path, contents: Data(text.utf8))
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
        s.watch = { [unowned rec] folders, onPaths in
            let w = FakeVaultWatch(folders, onPaths)
            rec.watches.append(w)
            return w
        }
        let scan = s.scan
        s.scan = { url, now in
            scans.bump()
            return scan(url, now)
        }
        s.fallbackFolder = fallback
        return NotesWidget(services: s, defaults: defaults())
    }

    private func context() -> WidgetContext {
        WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                      config: ConfigFileStore(url: root.appendingPathComponent("config.json")),
                      events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(), openPanel: { _ in })
    }

    private func settle(_ w: NotesWidget) async {
        await w.accessTask?.value
        await w.fileTask?.value
        await w.scanTask?.value
        await w.scanTask?.value
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
        let w = make(rec)
        w.start(context: context())
        w.chooseVault(vaultDir)
        await settle(w)
        XCTAssertEqual(rec.probes, [vaultDir])
        XCTAssertTrue(w.options.vaultOn)
        XCTAssertEqual(w.options.vaultPath, vaultDir.path)
        XCTAssertEqual(rec.live?.folders, [vaultDir.path])
        XCTAssertEqual(w.tasks.map(\.title), ["one"])
        XCTAssertEqual(defaults().string(forKey: "notes.vault.grant"), "build-A")
        w.stop()
        XCTAssertNil(rec.live, "stop ends the watch")
    }

    func testDeniedVaultStaysOff() async {
        let rec = Recorder()
        rec.granted = false
        let w = make(rec)
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
        let first = make(rec)
        first.start(context: context())
        first.chooseVault(vaultDir)
        await settle(first)
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
        let first = make(rec)
        first.start(context: context())
        first.chooseVault(vaultDir)
        await settle(first)
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

    func testEventsInDotFoldersDoNotRescan() async {
        let rec = Recorder()
        let scans = Counter()
        let w = make(rec, scans: scans)
        w.start(context: context())
        w.chooseVault(vaultDir)
        await settle(w)
        let before = scans.value
        rec.live?.onPaths([vaultDir.appendingPathComponent(".obsidian/workspace.json").path,
                           vaultDir.appendingPathComponent("image.png").path])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scans.value, before)
        XCTAssertFalse(VaultAccess.relevant(["/elsewhere/a.md"], root: vaultDir.path))
        XCTAssertTrue(VaultAccess.relevant([vaultDir.appendingPathComponent("Sub/a.md").path], root: vaultDir.path))
        w.stop()
    }

    func testTickWritesTheLineAndAMovedLineAsksFirst() async {
        note("a.md", "- [ ] one\n- [ ] two\n")
        let rec = Recorder()
        let w = make(rec)
        w.start(context: context())
        w.chooseVault(vaultDir)
        await settle(w)
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

    func testQuickNoteGoesToTheFallbackThenTheDailyNote() async throws {
        let rec = Recorder()
        let w = make(rec)
        w.start(context: context())
        w.draft = "first thought"
        w.addDraft()
        await settle(w)
        let fallbackFile = fallback.appendingPathComponent(QuickNote.fallbackName)
        let saved = String(decoding: FileManager.default.contents(atPath: fallbackFile.path) ?? Data(), as: UTF8.self)
        XCTAssertTrue(saved.hasPrefix("- "))
        XCTAssertTrue(saved.hasSuffix(" first thought\n"))
        XCTAssertEqual(w.draft, "")
        let mode = try FileManager.default.attributesOfItem(atPath: fallbackFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        w.chooseVault(vaultDir)
        await settle(w)
        w.draft = "in the vault"
        w.addDraft()
        await settle(w)
        let daily = "Daily/" + QuickNote.dailyNoteName(for: Date())
        XCTAssertTrue(read(daily).hasSuffix(" in the vault\n"))
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

    func testForgetStopsAndClears() async {
        let rec = Recorder()
        let w = make(rec)
        w.start(context: context())
        w.chooseVault(vaultDir)
        await settle(w)
        w.forgetVault()
        XCTAssertNil(rec.live)
        XCTAssertNil(w.options.vaultPath)
        XCTAssertFalse(w.options.vaultOn)
        XCTAssertNil(defaults().string(forKey: "notes.vault.grant"))
        w.stop()
    }
}
