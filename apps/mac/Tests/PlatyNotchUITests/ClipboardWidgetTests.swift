import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Stands in for NSPasteboard: counts every content read, never touches the real one.
@MainActor
private final class FakePasteboard: ClipboardPasteboard {
    var changeCount = 0
    var changeCountReads = 0
    var typeReads = 0
    var contentReads = 0
    private var entries: [String: Any] = [:]
    var written: [ClipContent] = []

    var types: [String] { typeReads += 1; return Array(entries.keys) }

    func string(forType type: String) -> String? {
        if type != ClipFilter.sourceType { contentReads += 1 }
        return entries[type] as? String
    }

    func data(forType type: String) -> Data? { contentReads += 1; return entries[type] as? Data }
    func fileURLs() -> [URL] { contentReads += 1; return entries[NSPasteboard.PasteboardType.fileURL.rawValue] as? [URL] ?? [] }
    func webURL() -> URL? { contentReads += 1; return entries[NSPasteboard.PasteboardType.URL.rawValue] as? URL }

    func write(_ content: ClipContent) -> Int {
        written.append(content)
        entries = [ClipFilter.sourceType: "dev.platynotch.app"]
        changeCount += 1
        return changeCount
    }

    /// Another app copies.
    func copy(_ entries: [String: Any]) {
        self.entries = entries
        changeCount += 1
    }

    func copyText(_ text: String, extra: [String: Any] = [:]) {
        copy([NSPasteboard.PasteboardType.string.rawValue: text].merging(extra) { a, _ in a })
    }
}

@MainActor
private final class FakeFrontmost: FrontmostApp {
    var bundleID: String? = "com.apple.TextEdit"
    var processID: pid_t? = 100
    var weAreActive = false
    var handlers: [Int: @MainActor (String?) -> Void] = [:]
    private var next = 0

    func observeActivations(_ handler: @escaping @MainActor (String?) -> Void) -> () -> Void {
        let id = next
        next += 1
        handlers[id] = handler
        return { [weak self] in MainActor.assumeIsolated { _ = self?.handlers.removeValue(forKey: id) } }
    }

    /// An app comes to the front (the workspace notification).
    func activate(_ bundleID: String, pid: pid_t = 200) {
        self.bundleID = bundleID
        processID = pid
        for h in Array(handlers.values) { h(bundleID) }
    }
}

@MainActor
private final class FakeTimer {
    var ticks: [Int: @MainActor () -> Void] = [:]
    var intervals: [TimeInterval] = []
    private var next = 0
    var polling: Bool { !ticks.isEmpty }

    lazy var schedule: ClipboardWatcher.Schedule = { [unowned self] interval, tick in
        let id = self.next
        self.next += 1
        self.intervals.append(interval)
        self.ticks[id] = tick
        return { [weak self] in MainActor.assumeIsolated { _ = self?.ticks.removeValue(forKey: id) } }
    }

    func tick() { for t in Array(ticks.values) { t() } }
}

@MainActor
private final class FakeHotKeys {
    final class Reg: HotKeyRegistration {
        let keyCode: UInt32, modifiers: UInt32
        let handler: @MainActor () -> Void
        var active = true
        init(_ k: UInt32, _ m: UInt32, _ h: @escaping @MainActor () -> Void) { keyCode = k; modifiers = m; handler = h }
        func unregister() { active = false }
    }
    var all: [Reg] = []
    var active: [Reg] { all.filter(\.active) }

    lazy var make: HotKeyMaker = { [unowned self] k, m, h in
        let r = Reg(k, m, h)
        self.all.append(r)
        return r
    }
}

@MainActor
private final class FakePoster: PasteEventPosting {
    var posts = 0
    func postCommandV() -> Bool { posts += 1; return true }
}

@MainActor
private final class FakeTarget: PasteTarget {
    let isOurs: Bool
    let processID: pid_t = 4242
    var activations = 0
    /// Activating brings it to the front (nil: it never comes back, e.g. it quit).
    let front: FakeFrontmost?
    init(isOurs: Bool = false, front: FakeFrontmost?) { self.isOurs = isOurs; self.front = front }
    func activate() {
        activations += 1
        front?.activate("com.apple.TextEdit", pid: processID)
    }
}

@MainActor
final class ClipboardWidgetTests: XCTestCase {
    nonisolated(unsafe) private var suites: [String] = []
    nonisolated(unsafe) private var dirs: [URL] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []
        dirs = []
        super.tearDown()
    }

    private struct Rig {
        let registry: WidgetRegistry
        let widget: ClipboardWidget
        let pb: FakePasteboard
        let front: FakeFrontmost
        let timer: FakeTimer
        let keys: FakeHotKeys
        let poster: FakePoster
        let defaults: UserDefaults
        let surfaces: PanelSurfaces
        let root: URL
        var trusted: TrustBox
        let clock: ClockBox
        @MainActor var dir: URL { widget.directory }
    }

    final class ClockBox: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    }

    final class TrustBox: @unchecked Sendable {
        var trusted = false
        var requests = 0
    }

    private func rig(enabled: Bool = true, excludeApps: [String]? = nil, trusted: Bool = false,
                     focusTimeout: Duration = .milliseconds(100)) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardWidgetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dirs.append(root)
        let configURL = root.appendingPathComponent("config.json")
        if let excludeApps {
            let json = try JSONSerialization.data(withJSONObject: ["memory": ["exclude_apps": excludeApps]])
            try json.write(to: configURL)
        }
        let suite = "ClipboardWidgetTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let pb = FakePasteboard(), front = FakeFrontmost(), timer = FakeTimer(), keys = FakeHotKeys()
        let poster = FakePoster()
        let box = TrustBox()
        box.trusted = trusted
        let trust = AccessibilityTrust(isTrusted: { box.trusted }, request: { box.requests += 1 })
        let clock = ClockBox()
        let widget = ClipboardWidget(directory: root.appendingPathComponent("home/clipboard"), pasteboard: pb,
                                     frontmost: front, schedule: timer.schedule, makeHotKey: keys.make,
                                     poster: poster, trust: trust, focusTimeout: focusTimeout,
                                     clock: { clock.now })
        let registry = WidgetRegistry(defaults: defaults, persist: false)
        let surfaces = PanelSurfaces(registry: registry)
        registry.register(widget)
        if enabled { registry.setEnabled(ClipboardWidget.widgetID, true) }
        registry.start(context: WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                              config: ConfigFileStore(url: configURL), events: CoreEventHub(),
                                              defaults: defaults, notify: NoopNotifier(), surfaces: surfaces,
                                              openPanel: { _ in }))
        return Rig(registry: registry, widget: widget, pb: pb, front: front, timer: timer, keys: keys, poster: poster,
                   defaults: defaults, surfaces: surfaces, root: root, trusted: box, clock: clock)
    }

    /// Every byte under the clipboard folder, to prove a secret never reached disk.
    private func diskContains(_ r: Rig, _ needle: String) -> Bool {
        guard let e = FileManager.default.enumerator(at: r.root, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in e {
            if let d = try? Data(contentsOf: url), d.range(of: Data(needle.utf8)) != nil { return true }
        }
        return false
    }

    // MARK: - Off by default, off does nothing

    func testOffByDefaultAndDisabledDoesNoWork() throws {
        let r = try rig(enabled: false)
        XCTAssertFalse(r.widget.defaultEnabled, "C22: off by default")
        XCTAssertFalse(r.registry.isEnabled(ClipboardWidget.widgetID))
        XCTAssertFalse(r.widget.isRunning)
        XCTAssertFalse(r.timer.polling, "no poll timer")
        XCTAssertTrue(r.keys.all.isEmpty, "no hot key")
        r.pb.copyText("hello")
        r.timer.tick()
        XCTAssertEqual(r.pb.typeReads + r.pb.contentReads, 0, "no pasteboard reads")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.dir.path), "nothing read or written")
        XCTAssertNil(r.widget.peekView(id: ClipboardWidget.copiedPeekID))
    }

    func testEnabledPollsHalfASecondAndRegistersOptionShiftV() throws {
        let r = try rig()
        XCTAssertEqual(r.timer.intervals, [0.5])
        XCTAssertEqual(r.keys.active.count, 1)
        XCTAssertEqual(r.keys.active[0].keyCode, 9)
        XCTAssertEqual(r.keys.active[0].modifiers, ClipHotKey.optionShiftV.carbonModifiers)
        XCTAssertTrue(r.widget.hotKeyActive)
        // Nothing changed: only the change count is looked at.
        r.timer.tick()
        XCTAssertEqual(r.pb.typeReads + r.pb.contentReads, 0)
    }

    func testRecordsTextLinksAndFiles() throws {
        let r = try rig()
        r.pb.copyText("first note")
        r.timer.tick()
        r.pb.copyText("  https://example.com/a  ")
        r.timer.tick()
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        r.pb.copy([NSPasteboard.PasteboardType.fileURL.rawValue: [file]])
        r.timer.tick()
        XCTAssertEqual(r.widget.items.map(\.kind), [.files([file]), .url(URL(string: "https://example.com/a")!),
                                                    .text("first note")])
        XCTAssertEqual(r.widget.items.first?.sourceBundleID, "com.apple.TextEdit")
        let index = r.dir.appendingPathComponent(ClipboardStore.indexName)
        let mode = try FileManager.default.attributesOfItem(atPath: index.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertNil(UserDefaults.standard.object(forKey: "clipboard.items"))
        XCTAssertFalse(r.defaults.dictionaryRepresentation().values.contains { "\($0)".contains("first note") },
                       "never in UserDefaults")
    }

    // MARK: - Review Focus #3: passwords never enter history

    func testPasswordManagerCopyIsNeverReadOrStored() throws {
        let r = try rig()
        for app in ["com.1password.1password", "com.apple.keychainaccess", "com.bitwarden.desktop", "com.apple.Passwords"] {
            r.front.bundleID = app
            r.pb.copyText("hunter2-\(app)")
            r.timer.tick()
        }
        XCTAssertTrue(r.widget.items.isEmpty)
        XCTAssertEqual(r.pb.typeReads + r.pb.contentReads, 0, "an excluded app's copy is not even read")
        XCTAssertFalse(diskContains(r, "hunter2"))
    }

    func testConcealedAndTransientItemsNeverReachDisk() throws {
        let r = try rig()
        r.pb.copyText("s3cret-concealed", extra: [ClipFilter.concealedType: ""])
        r.timer.tick()
        r.pb.copyText("s3cret-transient", extra: [ClipFilter.transientType: ""])
        r.timer.tick()
        r.pb.copyText("s3cret-auto", extra: [ClipFilter.autoGeneratedType: ""])
        r.timer.tick()
        XCTAssertTrue(r.widget.items.isEmpty)
        XCTAssertEqual(r.pb.contentReads, 0, "marked items: types read, content never")
        XCTAssertFalse(diskContains(r, "s3cret"))
    }

    func testNSPasteboardSourceAndMemoryExcludeApps() throws {
        let r = try rig(excludeApps: ["com.example.vault"])
        // The browser is in front but the helper says 1Password wrote it.
        r.front.bundleID = "com.apple.Safari"
        r.pb.copyText("from-helper", extra: [ClipFilter.sourceType: "com.1password.1password"])
        r.timer.tick()
        // memory.exclude_apps from config.json.
        r.front.bundleID = "com.example.vault"
        r.pb.copyText("from-vault")
        r.timer.tick()
        r.front.bundleID = "com.apple.Safari"
        r.pb.copyText("from-other", extra: [ClipFilter.sourceType: "com.example.vault"])
        r.timer.tick()
        XCTAssertTrue(r.widget.items.isEmpty)
        XCTAssertFalse(diskContains(r, "from-"))
        r.pb.copyText("fine")
        r.timer.tick()
        XCTAssertEqual(r.widget.items.map(\.title), ["fine"])
    }

    // MARK: - Fix round 1: the app that copied may not be in front at the poll

    func testCopyInExcludedAppThenFocusHandedBackIsNotRecorded() throws {
        let r = try rig()
        XCTAssertEqual(r.front.handlers.count, 1, "activations observed while running")
        // 1Password comes forward, copies, and hands focus back to Safari before the poll.
        r.front.activate("com.1password.1password")
        r.pb.copyText("hunter2-quick-access")
        r.front.activate("com.apple.Safari")
        r.timer.tick()
        XCTAssertTrue(r.widget.items.isEmpty)
        XCTAssertEqual(r.pb.typeReads + r.pb.contentReads, 0, "not even read")
        XCTAssertFalse(diskContains(r, "hunter2"))
        // The window is cleared after that change: the next copy in Safari records.
        r.pb.copyText("public text")
        r.timer.tick()
        XCTAssertEqual(r.widget.items.map(\.title), ["public text"])
    }

    /// The app in front at the last processed change stays in the window (the ruling), so
    /// the first copy after leaving Keychain Access is skipped too; the next one records.
    func testAppInFrontAtTheLastChangeStaysInTheWindow() throws {
        let r = try rig()
        r.front.activate("com.apple.keychainaccess")
        r.pb.copyText("secret"); r.timer.tick()          // skipped; window = {Keychain Access}
        r.front.activate("com.apple.Notes")
        r.pb.copyText("note 1"); r.timer.tick()          // window had Keychain Access: skipped
        r.pb.copyText("note 2"); r.timer.tick()          // window = {Notes}
        XCTAssertEqual(r.widget.items.map(\.title), ["note 2"])
        XCTAssertFalse(diskContains(r, "secret"))
    }

    func testUnrelatedAppSwitchesStillRecord() throws {
        let r = try rig()
        r.front.activate("com.apple.Notes")
        r.front.activate("com.apple.Safari")
        r.pb.copyText("hello")
        r.front.activate("com.apple.TextEdit")
        r.timer.tick()
        XCTAssertEqual(r.widget.items.map(\.title), ["hello"])
    }

    func testMemoryExcludedAppInTheWindowBlocks() throws {
        let r = try rig(excludeApps: ["com.example.vault"])
        r.front.activate("com.example.vault")
        r.pb.copyText("vault item")
        r.front.activate("com.apple.Safari")
        r.timer.tick()
        XCTAssertTrue(r.widget.items.isEmpty)
    }

    // Fix round 2: the window ages out.

    func testExcludedAppLeftLongAgoNoLongerBlocks() throws {
        let r = try rig()
        r.front.activate("com.1password.1password")      // opened, nothing copied
        r.clock.advance(3)
        r.front.activate("com.apple.Safari")
        r.clock.advance(2.5)                               // left 1Password more than 2 s ago
        r.pb.copyText("unrelated")
        r.timer.tick()
        XCTAssertEqual(r.widget.items.map(\.title), ["unrelated"])
    }

    func testCopyThenSwitchWithinAFractionOfASecondIsNotRecorded() throws {
        let r = try rig()
        r.front.activate("com.1password.1password")
        r.clock.advance(20)                                // in use for a while
        r.pb.copyText("hunter2-fast-switch")
        r.clock.advance(0.3)
        r.front.activate("com.apple.Safari")
        r.clock.advance(0.2)
        r.timer.tick()
        XCTAssertTrue(r.widget.items.isEmpty)
        XCTAssertFalse(diskContains(r, "hunter2"))
    }

    func testStopEndsActivationObserving() throws {
        let r = try rig()
        r.registry.setEnabled(ClipboardWidget.widgetID, false)
        XCTAssertTrue(r.front.handlers.isEmpty, "no observers while off")
        r.registry.setEnabled(ClipboardWidget.widgetID, true)
        r.widget.setPaused(true)
        XCTAssertTrue(r.front.handlers.isEmpty, "no observers while paused")
    }

    // MARK: - Pause and disable

    func testPauseStopsReadsAtOnceAndSkipsWhatWasCopiedMeanwhile() throws {
        let r = try rig()
        r.widget.setPaused(true)
        XCTAssertFalse(r.timer.polling, "no timer while paused")
        XCTAssertTrue(r.defaults.bool(forKey: ClipboardWidget.Keys.paused), "survives a relaunch")
        r.pb.copyText("while paused")
        r.timer.tick()
        XCTAssertEqual(r.pb.typeReads + r.pb.contentReads, 0)
        r.widget.setPaused(false)
        XCTAssertTrue(r.timer.polling)
        r.timer.tick()
        XCTAssertTrue(r.widget.items.isEmpty, "copied while paused: never recorded")
        r.pb.copyText("after")
        r.timer.tick()
        XCTAssertEqual(r.widget.items.map(\.title), ["after"])
    }

    func testDisableStopsTimerAndHotKeyButKeepsHistory() throws {
        let r = try rig()
        r.pb.copyText("keep me")
        r.timer.tick()
        r.registry.setEnabled(ClipboardWidget.widgetID, false)
        XCTAssertFalse(r.timer.polling)
        XCTAssertTrue(r.keys.active.isEmpty, "hot key released")
        XCTAssertFalse(r.widget.isRunning)
        r.pb.copyText("while off")
        r.timer.tick()
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.dir.appendingPathComponent(ClipboardStore.indexName).path))
        r.registry.setEnabled(ClipboardWidget.widgetID, true)
        XCTAssertEqual(r.widget.items.map(\.title), ["keep me"], "history kept; the copy made while off is not")
        XCTAssertEqual(r.keys.active.count, 1)
    }

    func testClearDeletesHistory() throws {
        let r = try rig()
        r.pb.copyText("a"); r.timer.tick()
        r.pb.copyText("b"); r.timer.tick()
        r.widget.togglePin(r.widget.items[0])
        r.widget.clear(keepingPinned: true)
        XCTAssertEqual(r.widget.items.map(\.title), ["b"])
        r.widget.clear(keepingPinned: false)
        XCTAssertTrue(r.widget.items.isEmpty)
        XCTAssertFalse(diskContains(r, "\"a\""))
    }

    func testHotKeyChoiceReregisters() throws {
        let r = try rig()
        r.widget.setHotKey(.controlOptionV)
        XCTAssertEqual(r.keys.active.count, 1)
        XCTAssertEqual(r.keys.active[0].modifiers, ClipHotKey.controlOptionV.carbonModifiers)
        XCTAssertEqual(r.defaults.string(forKey: ClipHotKey.defaultsKey), "controlOptionV")
    }

    // MARK: - Images

    func testImageCopiedAsPNGFile() async throws {
        let r = try rig()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let tiff = try XCTUnwrap(rep.tiffRepresentation)
        r.pb.copy([NSPasteboard.PasteboardType.tiff.rawValue: tiff])
        r.timer.tick()
        await r.widget.imageTask?.value
        let item = try XCTUnwrap(r.widget.items.first)
        guard case .image(_, 3, 2) = item.kind else { return XCTFail("\(item.kind)") }
        let url = try XCTUnwrap(r.widget.imageURL(for: item))
        XCTAssertEqual(try Data(contentsOf: url).prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        r.widget.remove(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Paste

    func testOwnWriteIsNotRecordedAgain() throws {
        let r = try rig()
        r.pb.copyText("one"); r.timer.tick()
        r.pb.copyText("two"); r.timer.tick()
        let reads = r.pb.contentReads
        XCTAssertTrue(r.widget.copy(r.widget.items[1]))
        XCTAssertEqual(r.pb.written, [.text("one")])
        r.timer.tick()
        XCTAssertEqual(r.pb.contentReads, reads, "our own write is skipped")
        XCTAssertEqual(r.widget.items.map(\.title), ["one", "two"], "picked item moves to the top")
    }

    func testPasteWithAccessibilityPostsCommandV() async throws {
        let r = try rig(trusted: true)
        r.pb.copyText("paste me"); r.timer.tick()
        let target = FakeTarget(front: r.front)
        r.widget.paste(r.widget.items[0], to: target)
        await r.widget.pasteTask?.value
        XCTAssertEqual(target.activations, 1, "keyboard back to the previous app")
        XCTAssertEqual(r.poster.posts, 1)
        XCTAssertFalse(r.widget.copiedOnly)
        XCTAssertEqual(r.trusted.requests, 0, "never prompts")
    }

    func testPasteWithoutAccessibilityOnlyCopiesAndSaysSo() async throws {
        let r = try rig(trusted: false)
        r.pb.copyText("copy me"); r.timer.tick()
        let target = FakeTarget(front: r.front)
        r.widget.paste(r.widget.items[0], to: target)
        await r.widget.pasteTask?.value
        XCTAssertEqual(r.poster.posts, 0, "no ⌘V without Accessibility")
        XCTAssertEqual(r.pb.written, [.text("copy me")])
        XCTAssertTrue(r.widget.copiedOnly)
        XCTAssertEqual(target.activations, 1)
        XCTAssertEqual(r.trusted.requests, 0, "never prompts outside Settings")
        XCTAssertNotNil(r.widget.peekView(id: ClipboardWidget.copiedPeekID), "\"Copied — press ⌘V\" peek")
    }

    func testPasteNeverPostsIntoOurOwnWindow() async throws {
        // The notch panel had the keyboard (an approval peek): ⌘V must not land there.
        let r = try rig(trusted: true)
        r.pb.copyText("x"); r.timer.tick()
        let target = FakeTarget(isOurs: true, front: r.front)
        r.widget.paste(r.widget.items[0], to: target)
        await r.widget.pasteTask?.value
        XCTAssertEqual(r.poster.posts, 0)
        XCTAssertEqual(target.activations, 0)
        XCTAssertTrue(r.widget.copiedOnly)
    }

    func testPasteFallsBackToCopyWhenTheTargetNeverComesToTheFront() async throws {
        let r = try rig(trusted: true)
        r.pb.copyText("x"); r.timer.tick()
        let target = FakeTarget(front: nil)   // activation does nothing
        r.widget.paste(r.widget.items[0], to: target)
        await r.widget.pasteTask?.value
        XCTAssertEqual(target.activations, 1)
        XCTAssertEqual(r.poster.posts, 0, "⌘V would go to another app")
        XCTAssertTrue(r.widget.copiedOnly)
    }

    func testPasteFallsBackToCopyWhilePlatyNotchIsActive() async throws {
        let r = try rig(trusted: true)
        r.pb.copyText("x"); r.timer.tick()
        r.front.weAreActive = true
        r.widget.paste(r.widget.items[0], to: FakeTarget(front: r.front))
        await r.widget.pasteTask?.value
        XCTAssertEqual(r.poster.posts, 0)
        XCTAssertTrue(r.widget.copiedOnly)
    }

    func testNewPasteCancelsTheOlderOne() async throws {
        let r = try rig(trusted: true, focusTimeout: .seconds(30))
        r.pb.copyText("old"); r.timer.tick()
        r.pb.copyText("new"); r.timer.tick()
        let old = r.widget.items.first { $0.title == "old" }!
        let new = r.widget.items.first { $0.title == "new" }!
        r.widget.paste(old, to: FakeTarget(front: nil))    // waits for focus that never comes
        let first = r.widget.pasteTask
        r.widget.paste(new, to: FakeTarget(front: r.front))
        let started = Date()
        await first?.value
        await r.widget.pasteTask?.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the older paste was cancelled")
        XCTAssertEqual(r.poster.posts, 1, "only the newer paste posts ⌘V")
        XCTAssertEqual(r.pb.written.last, .text("new"))
    }

    func testStopCancelsAPendingPaste() async throws {
        let r = try rig(trusted: true, focusTimeout: .seconds(30))
        r.pb.copyText("x"); r.timer.tick()
        r.widget.paste(r.widget.items[0], to: FakeTarget(front: nil))
        r.registry.setEnabled(ClipboardWidget.widgetID, false)
        let started = Date()
        await r.widget.pasteTask?.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "cancelled, not left waiting")
        XCTAssertEqual(r.poster.posts, 0)
        XCTAssertFalse(r.widget.copiedOnly, "no notice after stop")
    }

    func testFoldersExcludedFromBackupAndSpotlight() throws {
        let r = try rig()
        r.pb.copyText("x"); r.timer.tick()
        XCTAssertTrue(PrivateFolder.isMarked(r.dir))
    }

    // MARK: - Picker

    func testPickerModelKeys() throws {
        let r = try rig()
        for t in ["alpha", "beta", "gamma"] { r.pb.copyText(t); r.timer.tick() }
        let m = ClipPickerModel(widget: r.widget)
        m.refresh()
        XCTAssertEqual(m.results.map(\.title), ["gamma", "beta", "alpha"])
        XCTAssertNil(m.perform(.down))
        XCTAssertEqual(m.perform(.paste), .choose(m.results[1]))
        XCTAssertEqual(m.perform(.quickPick(3)), .choose(m.results[2]))
        XCTAssertNil(m.perform(.quickPick(7)))
        XCTAssertNil(m.perform(.togglePin))
        m.refresh()
        XCTAssertEqual(m.results.first?.title, "beta", "pinned first")
        m.query = "ALP"
        XCTAssertEqual(m.results.map(\.title), ["alpha"])
        XCTAssertNil(m.perform(.delete))
        m.refresh()
        XCTAssertTrue(m.results.isEmpty)
        XCTAssertFalse(r.widget.items.contains { $0.title == "alpha" })
        XCTAssertEqual(m.perform(.close), .close)
        XCTAssertNil(m.perform(.swallow))
    }

    func testPickerWindowSitsBelowTheNotchPanelAndDoesNotActivate() {
        let picker = ClipPickerWindow()
        let notch = NotchPanel(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertLessThan(picker.level.rawValue, notch.level.rawValue, "can never cover an approval card")
        XCTAssertTrue(picker.styleMask.contains(.nonactivatingPanel), "the previous app stays active")
        XCTAssertTrue(picker.canBecomeKey)
        XCTAssertFalse(picker.isVisible)
    }

    func testPickerFrameStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = ClipPickerPanel.frame(near: CGPoint(x: 990, y: 20), size: ClipPickerWindow.size, screens: [screen])
        XCTAssertTrue(screen.contains(f), "\(f)")
    }

    // MARK: - Smoke

    func testInertWidgetTouchesNothing() {
        let w = ClipboardWidget.inert()
        XCTAssertFalse(w.trust.isTrusted())
        XCTAssertNil(w.peekView(id: ClipboardWidget.copiedPeekID))
        XCTAssertNil(w.imageURL(for: ClipItem(kind: .image(fileURL: URL(fileURLWithPath: "/x.png"), width: 1, height: 1),
                                              copiedAt: Date())))
        XCTAssertTrue(w.items.isEmpty)
    }
}
