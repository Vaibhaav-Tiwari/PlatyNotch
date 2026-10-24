import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Mouse monitors, drag pasteboard and pointer, faked: installs nothing.
@MainActor
private final class Signals: DragSignals {
    var starts = 0
    var stops = 0
    var onButton: (@MainActor (DragButtonEvent) -> Void)?
    var dragChangeCount = 0
    var leftButtonDown = false
    var mouseLocation: CGPoint = CGPoint(x: 300, y: 300)
    var dragTypes: [String] = ["public.file-url", "NSFilenamesPboardType"]
    var ticks: [Int: @MainActor () -> Void] = [:]
    private var nextTick = 0

    func start(_ onButton: @escaping @MainActor (DragButtonEvent) -> Void) {
        starts += 1
        self.onButton = onButton
    }

    func stop() {
        stops += 1
        onButton = nil
    }

    func repeatEvery(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void {
        let id = nextTick
        nextTick += 1
        ticks[id] = tick
        return { [weak self] in MainActor.assumeIsolated { _ = self?.ticks.removeValue(forKey: id) } }
    }

    func tick() { for t in Array(ticks.values) { t() } }
    func press() { leftButtonDown = true; onButton?(.down) }
    /// The drag pasteboard changes (a drag begins).
    func startDrag() { dragChangeCount += 1; onButton?(.dragged); tick() }
    func release() { leftButtonDown = false; onButton?(.up) }

    /// The pointer goes left and right 40 pt, `legs` times, one poll each.
    func shake(at p: CGPoint, legs: Int = 8) {
        for i in 0...legs {
            mouseLocation = CGPoint(x: p.x + (i % 2 == 0 ? 0 : 40), y: p.y)
            tick()
        }
    }
}

@MainActor
private final class FakeWindow: BasketWindowing {
    var frame: CGRect
    var visible = false
    var closed = false
    var placements: [CGRect] = []
    init(frame: CGRect) { self.frame = frame }
    func place(_ frame: CGRect) { self.frame = frame; placements.append(frame) }
    func show() { visible = true }
    func hide() { visible = false }
    func close() { closed = true; visible = false }
}

@MainActor
private final class FakeSwitcher: BasketSwitcherShowing {
    var shown: [(names: [String], selected: Int)] = []
    var visible = false
    func show(_ baskets: [(name: String, color: BasketColor)], selected: Int, screens: [BasketScreen]) {
        shown.append((baskets.map(\.name), selected))
        visible = true
    }
    func hide() { visible = false }
}

@MainActor
private final class FakeSystem: BasketSystem {
    var displays: [BasketScreen]
    var pointer: CGPoint = CGPoint(x: 400, y: 400)
    var observers = 0
    var observing = false
    var changed: (@MainActor () -> Void)?
    var beeps = 0
    var screenReads = 0
    var nameRequests: [(current: String, near: CGRect, done: @MainActor (String?) -> Void)] = []
    var windows: [FakeWindow] = []
    let switcher = FakeSwitcher()

    init(displays: [BasketScreen]) { self.displays = displays }

    func screens() -> [BasketScreen] {
        screenReads += 1
        return displays
    }
    func observe(_ changed: @escaping @MainActor () -> Void) -> () -> Void {
        observers += 1
        observing = true
        self.changed = changed
        return { [weak self] in MainActor.assumeIsolated { self?.observing = false } }
    }
    func beep() { beeps += 1 }
    func askName(current: String, near: CGRect, done: @escaping @MainActor (String?) -> Void) {
        nameRequests.append((current, near, done))
    }
    func makeWindow(host: BasketHost, frame: CGRect) -> BasketWindowing {
        let w = FakeWindow(frame: frame)
        windows.append(w)
        return w
    }
    func makeSwitcher() -> BasketSwitcherShowing { switcher }
}

@MainActor
private final class Reg: HotKeyRegistration {
    let combo: KeyCombo
    let handler: @MainActor () -> Void
    var active = true
    init(_ combo: KeyCombo, _ handler: @escaping @MainActor () -> Void) { self.combo = combo; self.handler = handler }
    func unregister() { active = false }
}

@MainActor
private final class CoveredDisplays {
    var ids: Set<CGDirectDisplayID> = []
}

@MainActor
private final class CoveredSink: PanelSurfaceSink {
    var covered = false
    func receive(_ signal: PanelSurfaceSignal) {}
    var showsHUD: Bool { false }
    var hudWouldShow: Bool { false }
    var displayID: CGDirectDisplayID? { 7 }
    var coveredByFullScreen: Bool { covered }
}

@MainActor
final class BasketControllerTests: DefaultsTestCase {
    nonisolated(unsafe) private var dirs: [URL] = []
    private let sleeper = ManualSleeper()
    private var regs: [Reg] = []
    private var now: TimeInterval = 0

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("BasketControllerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    // 14-inch MacBook Pro: notch 654...858 x 950...982.
    private let mbp = PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                                  auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                                  auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    private var display: BasketScreen { BasketScreen(visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), layout: mbp) }

    private struct Rig {
        let controller: BasketController
        let system: FakeSystem
        let signals: Signals
        let drags: DragMonitor
        let store: BasketStore
        let dir: URL
    }

    private func rig(start: Bool = true, combo: KeyCombo? = BasketSettings.switcherPresets[0]) -> Rig {
        let dir = tempDir()
        let store = BasketStore(directory: dir.appendingPathComponent("baskets.noindex"), defaults: defaults())
        let system = FakeSystem(displays: [display])
        let signals = Signals()
        let drags = DragMonitor(signals: signals, surfaces: nil)
        let sleeper = self.sleeper
        let c = BasketController(store: store, system: system,
                                 makeHotKey: { [unowned self] k, m, h in
                                     let r = Reg(KeyCombo(keyCode: k, modifiers: m), h)
                                     self.regs.append(r)
                                     return r
                                 },
                                 clock: { [unowned self] in self.now += 0.05; return self.now },
                                 sleep: { await sleeper.sleep($0) })
        if start { c.start(drags: drags, sensitivity: 3, switcher: combo) }
        return Rig(controller: c, system: system, signals: signals, drags: drags, store: store, dir: dir)
    }

    // MARK: - Shake

    func testShakeDuringAFileDragSummonsABasketAtThePointer() throws {
        let r = rig()
        r.signals.press()
        r.signals.startDrag()
        r.signals.shake(at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(r.controller.hosts.count, 1)
        let w = try XCTUnwrap(r.system.windows.first)
        XCTAssertTrue(w.visible)
        XCTAssertTrue(w.frame.insetBy(dx: -40, dy: 0).contains(CGPoint(x: 320, y: 300)), "under the pointer")
        r.signals.shake(at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(r.controller.hosts.count, 1, "one basket per drag")
        r.signals.release()
        r.signals.press()
        r.signals.startDrag()
        r.signals.shake(at: CGPoint(x: 900, y: 300))
        XCTAssertEqual(r.controller.hosts.count, 2, "the next drag can make another")
    }

    func testShakeWhileSelectingTextNeverSummons() {
        let r = rig()
        r.signals.dragTypes = ["public.utf8-plain-text", "public.rtf"]
        r.signals.press()
        r.signals.startDrag()
        r.signals.shake(at: CGPoint(x: 300, y: 300), legs: 20)
        XCTAssertTrue(r.controller.hosts.isEmpty)
        XCTAssertEqual(r.controller.samplesFed, 0, "the detector is never fed")
    }

    func testShakeWhileDrawingOrMovingAWindowNeverSummons() {
        let r = rig()
        r.signals.press()   // the button is down, but no drag pasteboard change
        r.signals.onButton?(.dragged)
        r.signals.shake(at: CGPoint(x: 300, y: 300), legs: 20)
        XCTAssertTrue(r.controller.hosts.isEmpty)
        XCTAssertEqual(r.controller.samplesFed, 0)
        r.signals.release()
        // And with no button at all: the poll is not even running.
        r.signals.shake(at: CGPoint(x: 300, y: 300), legs: 20)
        XCTAssertEqual(r.controller.samplesFed, 0)
    }

    func testOwnDragsAndConcealedDragsNeverSummon() throws {
        let r = rig()
        let host = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        host.outgoingDragChanged(true)   // dragging an item out of the basket
        r.signals.press()
        r.signals.startDrag()
        r.signals.shake(at: CGPoint(x: 900, y: 300))
        XCTAssertEqual(r.controller.hosts.count, 1)
        r.signals.release()
        host.outgoingDragChanged(false)
        r.signals.dragTypes = ["public.file-url", ShelfDropPolicy.transientType]
        r.signals.press()
        r.signals.startDrag()
        r.signals.shake(at: CGPoint(x: 900, y: 300))
        XCTAssertEqual(r.controller.hosts.count, 1)
        XCTAssertEqual(r.controller.samplesFed, 0)
    }

    func testSensitivityApplies() {
        let r = rig()
        r.controller.setSensitivity(1)   // 7 reversals
        r.signals.press()
        r.signals.startDrag()
        r.signals.shake(at: CGPoint(x: 300, y: 300), legs: 6)
        XCTAssertTrue(r.controller.hosts.isEmpty)
        r.signals.shake(at: CGPoint(x: 300, y: 300), legs: 2)
        XCTAssertEqual(r.controller.hosts.count, 1)
    }

    func testNeverAsksForTheNotchDragSession() {
        let r = rig()
        XCTAssertFalse(r.controller.dragBegan(), "the drag monitor stays the session's one writer (R5)")
    }

    // MARK: - Approvals win (R5)

    func testBasketsNeverCoverTheApprovalCardOrThePanel() throws {
        let r = rig()
        let card = try XCTUnwrap(mbp.approvalSlot(for: .peek(.approval)))
        for p in [CGPoint(x: 756, y: 970), CGPoint(x: 756, y: 800), CGPoint(x: 640, y: 940), CGPoint(x: 870, y: 700)] {
            r.signals.press()
            r.signals.startDrag()
            r.signals.shake(at: p)
            r.signals.release()
        }
        XCTAssertEqual(r.system.windows.count, 4)
        for w in r.system.windows {
            XCTAssertFalse(w.frame.intersects(card), "\(w.frame)")
            XCTAssertFalse(w.frame.intersects(mbp.contentRect(for: .expanded)))
            XCTAssertFalse(w.frame.intersects(mbp.dragZone), "the notch drop zone stays the shelf's")
        }
        // Dragged by its header onto the notch: it slides out at every step.
        let host = r.controller.hosts[0]
        let w = r.system.windows[0]
        for y in stride(from: 600.0, through: 950, by: 25) {
            r.controller.basketMoved(host, to: CGRect(x: 640, y: y, width: 260, height: 132))
            XCTAssertFalse(w.frame.intersects(card), "while moving (\(y))")
            XCTAssertTrue(BasketPlacement.isClear(w.frame, screens: [display]))
        }
    }

    func testDisplayChangePlacesBasketsAgain() throws {
        let r = rig()
        let host = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        let w = try XCTUnwrap(r.controller.window(for: host) as? FakeWindow)
        // The display shrinks under it (a resolution change).
        r.system.displays = [BasketScreen(visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 280), exclusion: nil)]
        r.system.changed?()
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 280).contains(w.frame))
    }

    // MARK: - Nothing while off

    func testNothingRunsWhileTheWidgetIsOff() {
        let dir = tempDir()
        let system = FakeSystem(displays: [display])
        var hotKeys = 0
        let widget = BasketsWidget(directory: dir.appendingPathComponent("baskets.noindex"), system: system,
                                   makeHotKey: { _, _, _ in hotKeys += 1; return nil })
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(widget)
        let signals = Signals()
        let drags = DragMonitor(signals: signals, surfaces: nil)
        registry.start(context: WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              drags: drags, openPanel: { _ in }))
        XCTAssertFalse(registry.isEnabled(BasketsWidget.widgetID), "off by default")
        XCTAssertEqual(signals.starts, 0, "no mouse monitors")
        XCTAssertEqual(drags.subscriberCount, 0)
        XCTAssertEqual(hotKeys, 0, "no shortcut")
        XCTAssertEqual(system.observers, 0, "no notifications")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("baskets.noindex").path))

        registry.setEnabled(BasketsWidget.widgetID, true)
        XCTAssertEqual(signals.starts, 1)
        XCTAssertEqual(hotKeys, 1)
        XCTAssertTrue(system.observing)
        XCTAssertTrue(widget.controller.isRunning)

        registry.setEnabled(BasketsWidget.widgetID, false)
        XCTAssertEqual(signals.stops, 1, "monitors removed")
        XCTAssertEqual(drags.subscriberCount, 0)
        XCTAssertFalse(system.observing)
        XCTAssertFalse(widget.controller.isRunning)
        signals.press()
        signals.startDrag()
        signals.shake(at: CGPoint(x: 300, y: 300))
        XCTAssertTrue(widget.controller.hosts.isEmpty)
    }

    func testStopClearsUnpinnedBasketsAndKeepsPinnedOnes() throws {
        let r = rig()
        let loose = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        let kept = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 900, y: 300)))
        let copy = try XCTUnwrap(loose.store.addOwnedData(Data("png".utf8), filename: "a.png"))
        r.controller.setPinned(kept, true)
        kept.store.addText("kept")
        XCTAssertNotNil(r.controller.hosts.first?.items)
        r.controller.stop()
        XCTAssertTrue(r.system.windows.allSatisfy(\.closed))
        XCTAssertTrue(regs.allSatisfy { !$0.active }, "shortcut released")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(copy.fileRef?.path)))
        XCTAssertEqual(r.store.baskets.map(\.id), [kept.id])
        // Next start: the pinned one comes back where it was.
        let frame = try XCTUnwrap(r.controller.window(for: kept)?.frame ?? r.system.windows.last?.frame)
        r.controller.start(drags: r.drags, sensitivity: 3, switcher: nil)
        XCTAssertEqual(r.controller.hosts.map(\.id), [kept.id])
        XCTAssertEqual(r.controller.hosts.first?.items.map(\.title), ["kept"])
        XCTAssertEqual(r.system.windows.last?.frame.origin, frame.origin)
    }

    // MARK: - Baskets

    func testDroppingABasketOnAnotherMergesThem() throws {
        let r = rig()
        let a = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        let b = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 900, y: 300)))
        a.store.addText("one")
        a.afterChange()
        let target = try XCTUnwrap(r.controller.window(for: b)?.frame)
        r.controller.basketDropped(a, pointer: CGPoint(x: target.midX, y: target.midY))
        XCTAssertEqual(r.controller.hosts.map(\.id), [b.id])
        XCTAssertEqual(b.items.map(\.title), ["one"])
        XCTAssertTrue((r.system.windows.first)?.closed ?? false)
        // Released on empty space: it just stays there.
        r.controller.basketDropped(b, pointer: CGPoint(x: 10, y: 10))
        XCTAssertEqual(r.store.basket(b.id)?.origin, r.controller.window(for: b)?.frame.origin)
    }

    func testCloseAsksInsideTheBasketNeverModally() throws {
        let r = rig()
        let empty = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        r.controller.requestClose(empty)
        XCTAssertNil(empty.closeAsk)
        XCTAssertTrue(r.controller.hosts.isEmpty, "an empty basket just closes")

        let full = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        full.store.addText("x")
        full.afterChange()
        r.controller.requestClose(full)
        // The question is asked inside the basket and answered later: nothing modal ran.
        XCTAssertEqual(full.closeAsk, BasketCloseAsk(count: 1, canMoveToShelf: false), "the shelf is off")
        XCTAssertNil(NSApp.modalWindow, "no modal session: the approval card stays clickable")
        XCTAssertEqual(r.controller.hosts.count, 1, "still open until answered")
        r.controller.resolveClose(full, .cancel)
        XCTAssertNil(full.closeAsk)
        XCTAssertEqual(r.controller.hosts.count, 1)

        // Move to Shelf: transferred, never deleted.
        let shelf = ShelfStore(directory: r.dir.appendingPathComponent("shelf.noindex"))
        r.store.shelf = { shelf }
        let copy = try XCTUnwrap(full.store.addOwnedData(Data("png".utf8), filename: "a.png"))
        r.controller.requestClose(full)
        XCTAssertEqual(full.closeAsk?.canMoveToShelf, true)
        r.controller.resolveClose(full, .moveToShelf)
        XCTAssertTrue(r.controller.hosts.isEmpty)
        XCTAssertEqual(Set(shelf.items.map(\.title)), ["x", "a.png"])
        let moved = try XCTUnwrap(shelf.items.first { $0.id == copy.id }?.fileRef?.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        r.controller.resolveClose(full, .discard)   // a stale answer does nothing
    }

    func testBasketsCodeNeverStartsAModalSessionOrActivatesTheApp() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/PlatyNotchUI/Basket").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 5)
        for f in files {
            let code = try String(contentsOf: f, encoding: .utf8)
            for banned in ["runModal", "NSApp.activate", "activate(ignoringOtherApps", "NSAlert"] {
                XCTAssertFalse(code.contains(banned), "\(f.lastPathComponent) uses \(banned)")
            }
        }
    }

    func testRenameIsAskedBesideTheBasketAndAppliedLater() throws {
        let r = rig()
        let host = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        r.controller.rename(host)
        let ask = try XCTUnwrap(r.system.nameRequests.last)
        XCTAssertEqual(ask.current, "Basket 1")
        XCTAssertEqual(ask.near, r.controller.window(for: host)?.frame)
        XCTAssertEqual(host.name, "Basket 1", "nothing until confirmed")
        ask.done("Invoices")
        XCTAssertEqual(host.name, "Invoices")
        r.controller.rename(host)
        r.system.nameRequests.last?.done(nil)
        XCTAssertEqual(host.name, "Invoices", "cancelled")
    }

    func testRenamePanelIsNonActivatingAndPlacedClear() {
        let panel = BasketRenamePanel(name: "B", frame: CGRect(x: 100, y: 100, width: 260, height: 64)) { _ in }
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "typing never activates the app")
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.statusBar.rawValue)
        var got: [String?] = []
        let p2 = BasketRenamePanel(name: "B", frame: .zero) { got.append($0) }
        p2.finish("X")
        p2.finish("Y")
        XCTAssertEqual(got, ["X"], "answers once")
    }

    func testMenuAndItsActions() throws {
        let r = rig()
        let host = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        let menu = r.controller.menu(for: host)
        XCTAssertEqual(menu.items.map(\.title).filter { !$0.isEmpty },
                       ["Pin Basket", "Color", "Rename…", "Move All to Shelf", "Clear", "Close Basket"])
        XCTAssertFalse(menu.items.first { $0.title == "Move All to Shelf" }?.isEnabled ?? true)
        r.controller.setColor(host, .pink)
        XCTAssertEqual(host.color, .pink)
        r.controller.setPinned(host, true)
        XCTAssertTrue(host.pinned)
        XCTAssertEqual(r.controller.menu(for: host).items.first?.title, "Unpin Basket")
    }

    func testEveryShelfActionIsOfferedWhileFileActionsRuns() throws {
        let r = rig()
        let host = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        XCTAssertNil(host.fileActions)
        r.controller.fileActionsOn = { true }
        XCTAssertNotNil(host.fileActions)
        XCTAssertTrue(host.fileActions?.results === host)
        let reserved = try XCTUnwrap(host.reserveResultFolder())
        let url = reserved.folder.appendingPathComponent("out.txt")
        try Data("x".utf8).write(to: url)
        let src = try XCTUnwrap(host.store.addText("source"))
        XCTAssertTrue(host.addResult(url, id: reserved.id, after: src.id))
        XCTAssertEqual(host.ownedFolder(of: reserved.id), reserved.folder)
        XCTAssertNil(host.ownedFolder(of: src.id), "text has no folder")
    }

    func testDropsAreCappedAndReadOnlyOnDrop() throws {
        let r = rig()
        let host = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        for i in 0..<(BasketStore.maxItems - 1) { host.store.addText("t\(i)") }
        let files = (0..<3).map { i -> URL in
            let u = r.dir.appendingPathComponent("f\(i).txt")
            try? Data("x".utf8).write(to: u)
            return u
        }
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects(files as [NSURL])
        XCTAssertEqual(host.receive(pasteboard: pb), 1, "only one slot left")
        XCTAssertEqual(host.items.count, BasketStore.maxItems)
        XCTAssertEqual(host.receive(pasteboard: pb), 0, "full")
        for f in files { XCTAssertTrue(FileManager.default.fileExists(atPath: f.path)) }
        let secret = NSPasteboard.withUniqueName()
        secret.clearContents()
        secret.setString("pw", forType: .string)
        secret.setString("", forType: NSPasteboard.PasteboardType(ShelfDropPolicy.concealedType))
        host.remove([host.items[0].id])
        XCTAssertEqual(host.receive(pasteboard: secret), 0, "a password is never kept")
        pb.releaseGlobally()
        secret.releaseGlobally()
    }

    func testSixBasketsAtMost() {
        let r = rig()
        for i in 0..<6 { XCTAssertNotNil(r.controller.summon(at: CGPoint(x: 200 + i * 100, y: 300))) }
        XCTAssertNil(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        XCTAssertEqual(r.system.beeps, 1)
    }

    // MARK: - Switcher

    func testSwitcherCyclesBasketsAndMakesOneWhenThereAreNone() async throws {
        let r = rig()
        let reg = try XCTUnwrap(regs.first)
        XCTAssertEqual(reg.combo.display, "⌃⌥B")
        reg.handler()
        XCTAssertEqual(r.controller.hosts.count, 1, "none yet: one at the pointer")
        _ = r.controller.summon(at: CGPoint(x: 900, y: 300))
        reg.handler()
        XCTAssertEqual(r.system.switcher.shown.last?.selected, 0)
        XCTAssertTrue(r.controller.hosts[0].highlighted)
        reg.handler()
        XCTAssertEqual(r.system.switcher.shown.last?.selected, 1)
        reg.handler()
        XCTAssertEqual(r.system.switcher.shown.last?.selected, 0, "wraps around")
        XCTAssertEqual(r.system.switcher.shown.last?.names, ["Basket 1", "Basket 2"])
        await sleeper.fire()
        XCTAssertFalse(r.system.switcher.visible, "the strip goes after a moment")
        XCTAssertFalse(r.controller.hosts.contains { $0.highlighted })
    }

    func testSwitcherShortcutCanChangeOrGoOff() {
        let r = rig()
        XCTAssertTrue(r.controller.holdsSwitcher)
        r.controller.setSwitcher(BasketSettings.switcherPresets[2])
        XCTAssertFalse(regs[0].active)
        XCTAssertEqual(regs.last?.combo.display, "⌃⌥⌘B")
        r.controller.setSwitcher(nil)
        XCTAssertFalse(r.controller.holdsSwitcher)
        XCTAssertTrue(regs.allSatisfy { !$0.active })
        // A clipboard preset is never taken.
        r.controller.setSwitcher(KeyCombo(ClipHotKey.controlOptionV))
        XCTAssertTrue(r.controller.switcherTaken)
    }

    // MARK: - Full screen

    func testOnlyBasketsOnACoveredDisplayHideAndAShakeShowsThem() throws {
        let r = rig()
        let ext = BasketScreen(visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055), exclusion: nil, displayID: 2)
        r.system.displays = [BasketScreen(visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), layout: mbp, displayID: 1), ext]
        let covered = CoveredDisplays()
        r.controller.coveredDisplays = { covered.ids }
        let a = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        let b = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 2400, y: 300)))
        let wa = try XCTUnwrap(r.controller.window(for: a) as? FakeWindow)
        let wb = try XCTUnwrap(r.controller.window(for: b) as? FakeWindow)
        covered.ids = [1]
        r.controller.fullScreenChanged()   // pushed by the panels, no sleep
        XCTAssertFalse(wa.visible, "on the covered display")
        XCTAssertTrue(wb.visible, "the other display's basket stays")
        XCTAssertEqual(r.controller.hidden, [a.id])
        r.signals.press()
        r.signals.startDrag()
        r.signals.shake(at: CGPoint(x: 900, y: 300))
        XCTAssertTrue(wa.visible, "a shake shows them")
        XCTAssertEqual(r.controller.hosts.count, 3)
        r.controller.fullScreenChanged()
        XCTAssertFalse(wa.visible, "hidden again at the next change")
        covered.ids = []
        r.controller.fullScreenChanged()
        XCTAssertTrue(r.system.windows.allSatisfy(\.visible))
    }

    func testSurfacesPushFullScreenDisplays() {
        let surfaces = PanelSurfaces()
        let sink = CoveredSink()
        surfaces.attach(sink)
        var pushes: [Set<CGDirectDisplayID>] = []
        surfaces.onFullScreenChange(owner: self) { pushes.append($0) }
        sink.covered = true
        surfaces.sinkStateChanged()
        XCTAssertEqual(surfaces.fullScreenDisplays, [7])
        surfaces.sinkStateChanged()
        sink.covered = false
        surfaces.sinkStateChanged()
        XCTAssertEqual(pushes, [[7], []], "only on changes")
        surfaces.onFullScreenChange(owner: self, nil)
        sink.covered = true
        surfaces.sinkStateChanged()
        XCTAssertEqual(pushes.count, 2)
    }

    // MARK: - Round 1 fixes

    func testTextSelectionShakenLikeAHandNeverFires() {
        let r = rig()
        r.signals.dragTypes = ["public.utf8-plain-text", "public.rtf", "public.html"]
        r.signals.press()
        r.signals.startDrag()
        for i in 0..<60 {   // 3 Hz, 60 pt legs, at 20 Hz for 3 s
            r.signals.mouseLocation = CGPoint(x: 500 + 30 * sin(2 * .pi * 3 * Double(i) * 0.05), y: 300)
            r.signals.tick()
        }
        XCTAssertTrue(r.controller.hosts.isEmpty)
        XCTAssertEqual(r.controller.samplesFed, 0)
    }

    func testDisplayChangesCostNothingWithoutABasketAndRememberThePlace() throws {
        let r = rig()
        let reads = r.system.screenReads
        r.system.changed?()
        XCTAssertEqual(r.system.screenReads, reads, "no basket: nothing read")
        let host = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        r.system.displays = [BasketScreen(visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 280), exclusion: nil)]
        r.system.changed?()
        let f = try XCTUnwrap(r.controller.window(for: host)?.frame)
        XCTAssertEqual(r.store.basket(host.id)?.origin, f.origin, "the new place is remembered")
    }

    func testHeaderDragReadsScreensOnce() throws {
        let r = rig()
        let host = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        r.controller.beginMove(host)
        let reads = r.system.screenReads
        for x in stride(from: 300.0, through: 700, by: 10) {
            r.controller.basketMoved(host, to: CGRect(x: x, y: 300, width: 260, height: 132))
        }
        XCTAssertEqual(r.system.screenReads, reads, "cached for the whole drag")
        r.controller.basketDropped(host, pointer: CGPoint(x: 10, y: 10))
        r.controller.basketMoved(host, to: CGRect(x: 100, y: 100, width: 260, height: 132))
        XCTAssertEqual(r.system.screenReads, reads + 1, "read again after the drag")
    }

    func testRoomCountsPendingResultsAndPromises() async throws {
        let r = rig()
        let host = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
        for i in 0..<(BasketStore.maxItems - 2) { host.store.addText("t\(i)") }
        XCTAssertEqual(host.room, 2)
        let reserved = try XCTUnwrap(host.reserveResultFolder())
        XCTAssertEqual(host.room, 1, "a result being made holds a slot")
        host.beginReceiving(UUID())
        XCTAssertEqual(host.room, 0, "so does a promise being written")
        XCTAssertNil(host.reserveResultFolder(), "full")
        host.discardResult(reserved.id)
        XCTAssertEqual(host.room, 1)
        XCTAssertTrue(host.isBusy)
        await sleeper.fire()   // the promise never finished: after the timeout it lets go
        XCTAssertFalse(host.isBusy)
        XCTAssertEqual(host.room, 2)
    }

    func testNothingLeaksAfterCloseOrStop() throws {
        weak var host: BasketHost?
        weak var store: ShelfStore?
        weak var window: FakeWindow?
        let r = rig()
        try autoreleasepool {
            let h = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
            h.store.addText("x")
            h.afterChange()
            _ = r.controller.menu(for: h)
            host = h
            store = h.store
            window = r.controller.window(for: h) as? FakeWindow
            r.controller.close(h, keepItems: false)
        }
        r.system.windows.removeAll()
        XCTAssertNil(host, "the host is released after close")
        XCTAssertNil(store)
        XCTAssertNil(window)

        weak var host2: BasketHost?
        weak var store2: ShelfStore?
        try autoreleasepool {
            let h = try XCTUnwrap(r.controller.summon(at: CGPoint(x: 300, y: 300)))
            host2 = h
            store2 = h.store
        }
        r.controller.stop()
        r.system.windows.removeAll()
        XCTAssertNil(host2, "and after stop")
        XCTAssertNil(store2)
    }

    func testRealPanelIsReleasedAfterClose() throws {
        weak var panel: BasketPanel?
        weak var host: BasketHost?
        autoreleasepool {
            let store = ShelfStore(directory: tempDir(), persist: false)
            let h = BasketHost(basket: Basket(name: "B", color: .blue), store: store)
            let p = BasketPanel(host: h, frame: CGRect(x: 100, y: 100, width: 260, height: 132))
            p.close()
            panel = p
            host = h
        }
        XCTAssertNil(panel)
        XCTAssertNil(host, "the panel's view does not keep the host")
    }

    // MARK: - The window (R5)

    func testBasketWindowIsNeverKeyAndSitsBelowTheNotchPanel() {
        let store = ShelfStore(directory: tempDir(), persist: false)
        let host = BasketHost(basket: Basket(name: "B", color: .blue), store: store)
        let panel = BasketPanel(host: host, frame: CGRect(x: 100, y: 100, width: 260, height: 132))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.statusBar.rawValue, "approvals win")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.contentView?.registeredDraggedTypes.contains(.fileURL) ?? false)
        panel.close()
        let switcher = BasketSwitcherPanel()
        XCTAssertFalse(switcher.canBecomeKey)
        XCTAssertTrue(switcher.ignoresMouseEvents)
        XCTAssertLessThan(switcher.level.rawValue, NSWindow.Level.statusBar.rawValue)
    }
}

/// Waits until cancelled.
private struct HangingEngine: FileActionPerforming {
    func perform(_ action: FileAction, sources: [URL], into folder: URL?) async throws -> FileActionOutput {
        while !Task.isCancelled { try await Task.sleep(for: .seconds(60)) }
        throw CancellationError()
    }
}

@MainActor
final class BasketBusyTests: DefaultsTestCase {
    /// A file action still writing into a basket: it is neither closed nor merged.
    func testBusyBasketIsNotClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BasketBusyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BasketStore(directory: dir.appendingPathComponent("baskets.noindex"), defaults: defaults())
        let screen = BasketScreen(visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), exclusion: nil)
        let system = FakeSystem(displays: [screen])
        let engine = HangingEngine()
        let c = BasketController(store: store, system: system, makeHotKey: { _, _, _ in nil },
                                 actions: { FileActionCenter(engine: engine) })
        c.start(drags: DragMonitor(signals: Signals(), surfaces: nil), sensitivity: 3, switcher: nil)
        c.fileActionsOn = { true }
        let host = try XCTUnwrap(c.summon(at: CGPoint(x: 300, y: 300)))
        let src = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: src)
        host.store.addFile(src)
        host.sync()
        let item = try XCTUnwrap(host.items.first)
        let center = try XCTUnwrap(host.fileActions)
        center.run(.zip, on: [(item, src)])
        XCTAssertTrue(host.isBusy)
        c.requestClose(host)
        XCTAssertEqual(system.beeps, 1)
        XCTAssertEqual(c.hosts.count, 1, "still open")
        c.stop()
    }
}
