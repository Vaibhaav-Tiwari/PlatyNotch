import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Phase B review: the tools' behaviour, driven through their models and views.
@MainActor
final class IslandToolBehaviourTests: DefaultsTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pnisland-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func context(_ root: URL, registry: WidgetRegistry? = nil) -> WidgetContext {
        WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                      config: ConfigFileStore(url: root.appendingPathComponent("config.json")),
                      events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(), openPanel: { _ in })
    }

    /// Notes whose writes fail (no vault; the fallback write refuses).
    private func failingNotes() -> NotesWidget {
        var s = VaultServices.none
        s.appendFallback = { _, _ in .failed("Disk full") }
        return NotesWidget(services: s, defaults: defaults())
    }

    // MARK: - C1: Note never loses typed text

    /// A write that fails (or a daily note that does not exist yet) keeps the line.
    func testFailedAppendKeepsTypedNote() async {
        let w = failingNotes()
        w.start(context: context(tempDir()))
        let pad = NotePad(notes: w, append: { [w] in w.appendNote($0) })
        pad.text = "buy milk"
        pad.submit()
        await w.settleWrites()
        XCTAssertEqual(pad.text, "buy milk", "the typed note survives a failed write")
        w.stop()
    }

    /// A half-typed note survives the tool closing (the pad is rebuilt) and a relaunch.
    func testHalfTypedNoteSurvivesCloseAndRelaunch() async {
        let w = failingNotes()
        w.start(context: context(tempDir()))
        let pad = NotePad(notes: w, append: { [w] in w.appendNote($0) })
        pad.text = "half a tho"
        let reopened = NotePad(notes: w, append: { [w] in w.appendNote($0) })
        XCTAssertEqual(reopened.text, "half a tho", "closing the tool keeps it")
        w.stop()
        let relaunched = failingNotes()
        XCTAssertEqual(relaunched.draft, "half a tho", "quitting keeps it")
    }

    // MARK: - I1: a tool opened from search

    func testToolOpenedFromSearchNeedsOneEscAndKeepsHotKey() {
        let r = HomeRenders.builtIns(meeting: false)
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.debugHandle(.layout(HomeRenders.layout))
        c.panelIsKey = { true }
        c.openCommandLine()
        XCTAssertTrue(c.panelModel.commandFocused)
        // What running the "Games" row does.
        c.panelModel.route = PanelRoute(destination: .home, tool: GamesWidget.widgetID)
        c.escapePressed()
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home), "one Esc goes back")
        c.panelModel.route = PanelRoute(destination: .home, tool: GamesWidget.widgetID)
        XCTAssertTrue(c.commandHotKey(), "⌥⌘K opens the search instead of closing")
        XCTAssertEqual(c.panelModel.route.tool, PanelTools.search)
        r.registry.stopAll()
    }

    // MARK: - I2: play snake

    func testPlaySnakeOpensTheBoard() {
        var routes: [PanelRoute] = []
        var picked: [GameKind] = []
        var a = CommandActions()
        a.gamesOn = { true }
        a.open = { routes.append($0) }
        a.selectGame = { picked.append($0) }
        let runner = CommandRunner(actions: a)
        _ = runner.run(CommandSuggestion(command: .play(.snake), title: "Play Snake", detail: nil))
        XCTAssertEqual(picked, [.snake])
        XCTAssertEqual(routes, [PanelRoute(destination: .home, tool: PanelTools.gamesPlay)])
        _ = runner.run(CommandSuggestion(command: .play(nil), title: "Play", detail: nil))
        XCTAssertEqual(routes.last, PanelRoute(destination: .home, tool: GamesWidget.widgetID), "no game named: the list")
    }

    // MARK: - I4: Timer is a tool, Focus is its tab

    func testSearchOffersTimerNotTheOldFocusView() {
        let r = HomeRenders.builtIns(meeting: false)
        let ids = ToolCatalog.tools(widgets: r.registry, extraTabs: [], memory: { AnyView(EmptyView()) }).map(\.id)
        XCTAssertTrue(ids.contains(PanelTools.timer), "\(ids)")
        XCTAssertFalse(ids.contains(FocusWidget.widgetID), "\(ids)")
        let focus = ToolCatalog.tool(FocusWidget.widgetID, widgets: r.registry, extraTabs: [],
                                     memory: { AnyView(EmptyView()) })
        XCTAssertEqual(focus?.title, "Timer", "Focus opens the Timer tool")
        r.registry.stopAll()
    }

    // MARK: - C2: the Shelf keeps its file actions

    func testShelfRowCarriesTheShelfMenu() throws {
        let root = tempDir()
        let shelf = ShelfWidget(directory: root.appendingPathComponent("shelf"))
        shelf.fileActionsOn = { true }
        shelf.start(context: context(root))
        let png = root.appendingPathComponent("a.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        XCTAssertTrue(shelf.addFile(png))
        let host = NSHostingView(rootView: ShelfTool(shelf: shelf).environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: 580, height: 300)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: 580, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func find(_ v: NSView) -> ShelfItemView? {
            (v as? ShelfItemView) ?? v.subviews.lazy.compactMap(find).first
        }
        let handle = try XCTUnwrap(find(host), "each row has the shelf's AppKit handle (select, drag, menu)")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        let titles = handle.menu(for: event)?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("Quick Look"), "\(titles)")
        XCTAssertTrue(titles.contains("Actions"), "\(titles)")
        window.contentView = nil
        shelf.stop()
    }

    // MARK: - I6: the Note pad has the keyboard; approval keys stay text keys

    func testNotePadIsTheFirstResponderAndApprovalKeysEditIt() throws {
        let notes = NotesWidget.inert()
        let panel = NotchPanel(frame: CGRect(x: -10_000, y: 10_000, width: 580, height: 260))
        panel.allowsKey = true
        panel.grantKey()
        var answered = 0
        let probe = ActionProbe { answered += 1 }
        let allow = NSButton(title: "Allow", target: probe, action: #selector(ActionProbe.fire))
        allow.keyEquivalent = "\r"
        allow.keyEquivalentModifierMask = .command
        allow.frame = CGRect(x: 0, y: 0, width: 60, height: 20)
        let host = NSHostingView(rootView: NoteTool(notes: notes).environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 30, width: 580, height: 230)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 580, height: 260))
        content.addSubview(host)
        content.addSubview(allow)
        panel.contentView = content
        panel.makeKey()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(panel.firstResponder is NSText, "the pad takes the keyboard when the tool opens")
        let cmdReturn = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                       timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                                       isARepeat: false, keyCode: 36))
        XCTAssertTrue(panel.performKeyEquivalent(with: cmdReturn))
        XCTAssertEqual(answered, 0, "⌘↩ in the pad never answers the approval")
        panel.contentView = nil
    }

    // MARK: - C1: saved as typed, on close and on quit; Retry after a failure

    func testDraftIsSavedAsTypedAndOnQuit() async throws {
        let w = failingNotes()
        w.draft = "on the way"
        try await Task.sleep(for: NotesWidget.draftSaveDelay + .milliseconds(200))
        XCTAssertEqual(defaults().string(forKey: NotesWidget.draftKey), "on the way", "saved shortly after typing")
        w.draft = "on the way home"
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(defaults().string(forKey: NotesWidget.draftKey), "on the way home", "saved at once on quit")
    }

    func testFailedWriteOffersRetry() async {
        let w = failingNotes()
        w.start(context: context(tempDir()))
        w.draft = "call mum"
        w.addDraft()
        await w.settleWrites()
        XCTAssertTrue(w.writeFailed, "status: \(w.status ?? "nil")")
        XCTAssertEqual(w.draft, "call mum")
        XCTAssertTrue(NoteTool.texts(entries: w.recentEntries, writeFailed: w.writeFailed).contains(NoteTool.retry))
        w.stop()
    }

    // MARK: - I3: Clipboard ↩ pastes into the app you were in; ⌘↩ copies

    private final class FakeClipboard: ClipboardPasting {
        var copied: [ClipItem] = []
        var pasted: [(ClipItem, PasteTarget?)] = []
        func copy(_ item: ClipItem) -> Bool { copied.append(item); return true }
        func paste(_ item: ClipItem, to target: PasteTarget?) { pasted.append((item, target)) }
    }

    private struct FakeTarget: PasteTarget {
        var isOurs: Bool { false }
        var processID: pid_t { 4242 }
        func activate() {}
    }

    func testClipboardReturnPastesIntoTheFrontApp() {
        let item = ClipItem(kind: .text("hello"), copiedAt: Date())
        let clip = FakeClipboard()
        var closed = 0
        ClipboardTool.choose(item, copyOnly: false, clipboard: clip, target: FakeTarget(), close: { closed += 1 })
        XCTAssertEqual(clip.pasted.count, 1)
        XCTAssertEqual(clip.pasted.first?.1?.processID, 4242, "pasted into the app you were in")
        XCTAssertEqual(closed, 1, "the panel gives the keyboard back first")
        ClipboardTool.choose(item, copyOnly: true, clipboard: clip, target: FakeTarget(), close: { closed += 1 })
        XCTAssertEqual(clip.copied.count, 1, "⌘↩ copies only")
        XCTAssertEqual(clip.pasted.count, 1)
        XCTAssertEqual(closed, 1, "and the panel stays")
    }

    /// An approval waits: the panel stays in the approval peek with the keyboard, so a ⌘V
    /// could land on the card. Return only copies and says so; nothing closes or pastes.
    func testClipboardReturnOnlyCopiesWhileAnApprovalWaits() {
        let item = ClipItem(kind: .text("hello"), copiedAt: Date())
        let clip = FakeClipboard()
        var closed = 0
        let message = ClipboardTool.choose(item, copyOnly: false, clipboard: clip, target: FakeTarget(),
                                           approvalPending: true, close: { closed += 1 })
        XCTAssertEqual(clip.pasted.count, 0, "never a synthetic ⌘V while an approval waits")
        XCTAssertEqual(clip.copied.count, 1)
        XCTAssertEqual(closed, 0)
        XCTAssertEqual(message, ClipboardTool.copiedMessage)
        XCTAssertEqual(ClipboardTool.copiedMessage, "Copied. Press ⌘V")
    }

    /// The paste target is never "ours unaware": our panel keeping the keyboard marks it ours,
    /// so the paster only copies (the clipboard picker's guard).
    func testPasteTargetIsOursWhenThePanelKeepsTheKeyboard() {
        let app = NSRunningApplication.current
        XCTAssertTrue(ClipboardTool.target(app: app, panelKeepsKey: false)?.isOurs ?? false, "PlatyNotch itself")
        if let other = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier != app.processIdentifier }) {
            XCTAssertFalse(ClipboardTool.target(app: other, panelKeepsKey: false)?.isOurs ?? true)
            XCTAssertTrue(ClipboardTool.target(app: other, panelKeepsKey: true)?.isOurs ?? false)
        }
    }

    /// ⌘↩ in the search field copies only; plain ↩ pastes.
    func testCommandReturnKeyPathCopiesOnly() {
        XCTAssertEqual(ClipboardTool.returnCopiesOnly(modifiers: .command), true)
        XCTAssertEqual(ClipboardTool.returnCopiesOnly(modifiers: []), false)
        XCTAssertEqual(ClipboardTool.returnCopiesOnly(modifiers: .shift), false)
    }

    /// The Shelf reads file sizes once (on appear or when the items change), not per redraw.
    func testShelfSizesAreCachedNotReadPerRedraw() throws {
        let root = tempDir()
        let f = root.appendingPathComponent("a.bin")
        try Data(count: 2_000).write(to: f)
        let items = [ShelfItem(kind: .file(ShelfFileRef(path: f.path)), addedAt: Date())]
        let sizes = ShelfTool.sizes(items)
        XCTAssertEqual(sizes[f.path], "2 KB")
        try Data(count: 9_000_000).write(to: f)
        XCTAssertEqual(ShelfTool.rows(items, sizes: sizes).first?.detail, "2 KB", "rows use the cache")
        XCTAssertEqual(ShelfTool.rows(items, sizes: [:]).first?.detail, "Missing")
    }

    // MARK: - Timer column

    func testTimerColumnListsRunningTimersInEveryMode() {
        let now = Date()
        let tea = CountdownTimer(label: "Tea", duration: 190, startedAt: now)
        for mode in TimerMode.allCases {
            XCTAssertEqual(TimerTool.columnRows(mode: mode, timers: [tea], laps: [], now: now), ["Tea · 3:10 left"], "\(mode)")
        }
        XCTAssertEqual(TimerTool.columnRows(mode: .timer, timers: [], laps: [], now: now), [TimerTool.noneRunning])
        XCTAssertEqual(TimerTool.columnRows(mode: .stopwatch, timers: [tea], laps: [61.2], now: now), ["Lap 1 · 1:01.2"])
        XCTAssertEqual(TimerTool.focusMinutes(30), 1, "a custom 30 s focus is a minute, not zero")
        XCTAssertEqual(TimerTool.focusMinutes(3930), 66)
    }
}
