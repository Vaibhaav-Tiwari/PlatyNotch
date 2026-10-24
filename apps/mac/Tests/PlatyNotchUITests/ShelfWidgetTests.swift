import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Stands in for the NSEvent monitors and the drag pasteboard: installs nothing.
@MainActor
private final class FakeDragSignals: DragSignals {
    var starts = 0
    var stops = 0
    var onButton: (@MainActor (DragButtonEvent) -> Void)?
    var dragChangeCount = 0
    var leftButtonDown = false
    var ticks: [Int: @MainActor () -> Void] = [:]
    private var nextTick = 0
    var polling: Bool { !ticks.isEmpty }

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

    // A user's gestures.
    func press() { leftButtonDown = true; onButton?(.down) }
    /// The pasteboard changes and the mouse moves; the change is seen at the next poll.
    func startDrag() { dragChangeCount += 1; onButton?(.dragged); tick() }
    func release() { leftButtonDown = false; onButton?(.up) }
}

/// A drag from another app carrying `pasteboard` (only what the panel and shelf read).
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    @MainActor init(_ pb: NSPasteboard) { draggingPasteboard = pb }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor
final class ShelfWidgetTests: XCTestCase {
    nonisolated(unsafe) private var suites: [String] = []
    nonisolated(unsafe) private var dirs: [URL] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []
        dirs = []
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "ShelfWidgetTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfWidgetTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    private struct Rig {
        let registry: WidgetRegistry
        let surfaces: PanelSurfaces
        let shelf: ShelfWidget
        let signals: FakeDragSignals
        let controller: NotchController
        let root: URL
    }

    private func rig(enabled: Bool = true) -> Rig {
        let root = tempDir()
        let signals = FakeDragSignals()
        let shelf = ShelfWidget(directory: root.appendingPathComponent("home/shelf"), makeSignals: { signals })
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let surfaces = PanelSurfaces(registry: registry)
        registry.register(shelf)
        if !enabled { registry.setEnabled(ShelfWidget.widgetID, false) }
        let client = CoreClient(socketPath: "/nonexistent")
        registry.start(context: WidgetContext(store: AppStore(), client: client,
                                              config: ConfigFileStore(url: root.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              surfaces: surfaces, openPanel: { _ in }))
        let c = NotchController(store: AppStore(), client: client, plugins: [], widgets: registry,
                                surfaces: surfaces, appearance: AppearanceSettings())
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        c.debugHandle(.layout(PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                          visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                                          auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                                          auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))))
        return Rig(registry: registry, surfaces: surfaces, shelf: shelf, signals: signals, controller: c, root: root)
    }

    private func file(_ r: Rig, _ name: String) throws -> URL {
        let url = r.root.appendingPathComponent("user/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: url)
        return url
    }

    // MARK: - Disabled does no work

    func testDisabledShelfInstallsNothingAndReadsNothing() {
        let r = rig(enabled: false)
        XCTAssertEqual(r.signals.starts, 0, "no event monitors")
        XCTAssertFalse(r.shelf.isRunning)
        XCTAssertNil(r.registry.dropTarget(), "no drop target")
        XCTAssertNil(r.registry.dropZoneView())
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.shelf.directory.path), "nothing read or written")
    }

    func testTurningOffStopsMonitorsAndKeepsItems() throws {
        let r = rig()
        XCTAssertEqual(r.signals.starts, 1)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.writeObjects([try file(r, "keep.txt") as NSURL])
        XCTAssertEqual(r.shelf.receive(pasteboard: pb), 1)
        r.signals.press()
        XCTAssertTrue(r.signals.polling)

        r.registry.setEnabled(ShelfWidget.widgetID, false)
        XCTAssertEqual(r.signals.stops, 1)
        XCTAssertFalse(r.signals.polling, "the poll stops with the widget")
        XCTAssertTrue(r.shelf.liveActivities.isEmpty || !r.registry.running.contains(ShelfWidget.widgetID))
        r.registry.setEnabled(ShelfWidget.widgetID, true)
        XCTAssertEqual(r.shelf.items.count, 1, "turning the shelf off keeps its items")
    }

    // MARK: - Drag detection

    func testDetectorOpensAndClosesTheDragSession() {
        let r = rig()
        XCTAssertFalse(r.signals.polling, "nothing polls with the button up")
        r.signals.press()
        XCTAssertTrue(r.signals.polling, "polls only while the button is down")
        r.signals.tick()
        XCTAssertFalse(r.surfaces.dragActive, "a click is not a drag")
        r.signals.startDrag()
        XCTAssertTrue(r.surfaces.dragActive)
        r.signals.release()
        XCTAssertFalse(r.surfaces.dragActive)
        XCTAssertFalse(r.signals.polling)
    }

    /// Fix round 1 (7): dragged events never read the drag pasteboard; only the poll does.
    func testDraggedEventsDoNotSample() {
        let r = rig()
        r.signals.press()
        r.signals.dragChangeCount += 1
        r.signals.onButton?(.dragged)
        XCTAssertFalse(r.surfaces.dragActive, "not until the poll")
        r.signals.tick()
        XCTAssertTrue(r.surfaces.dragActive)
        r.signals.release()
        // A missed down: the first dragged event starts the poll.
        r.signals.leftButtonDown = true
        r.signals.onButton?(.dragged)
        XCTAssertTrue(r.signals.polling)
        r.signals.release()
    }

    /// The up event never arrives (a drag that ends in another app): the poll sees it.
    func testPollCatchesAMissedMouseUp() {
        let r = rig()
        r.signals.press()
        r.signals.dragChangeCount += 1
        r.signals.tick()
        XCTAssertTrue(r.surfaces.dragActive)
        r.signals.leftButtonDown = false
        r.signals.tick()
        XCTAssertFalse(r.surfaces.dragActive)
        XCTAssertFalse(r.signals.polling)
    }

    func testOwnDragOutDoesNotOpenTheDropZone() {
        let r = rig()
        r.shelf.outgoingDragChanged(true)
        r.signals.press()
        r.signals.startDrag()
        XCTAssertFalse(r.surfaces.dragActive)
        r.signals.release()
        r.shelf.outgoingDragChanged(false)
        r.signals.press()
        r.signals.startDrag()
        XCTAssertTrue(r.surfaces.dragActive)
        r.signals.release()
    }

    func testStoppingMidDragEndsTheSession() {
        let r = rig()
        r.signals.press()
        r.signals.startDrag()
        XCTAssertTrue(r.surfaces.dragActive)
        r.registry.setEnabled(ShelfWidget.widgetID, false)
        XCTAssertFalse(r.surfaces.dragActive)
    }

    // MARK: - Drop zone and the panel (carries from Task 1b)

    func testDragToTheNotchShowsTheShelfDropZone() {
        let r = rig()
        var down = true
        r.controller.mouseDown = { down }
        r.signals.press()
        r.signals.startDrag()
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        XCTAssertNotNil(r.registry.dropTarget())
        XCTAssertNotNil(r.registry.dropZoneView())
        down = false
        r.controller.dragMoved(to: CGPoint(x: 756, y: 900))   // released on the zone
        XCTAssertEqual(r.controller.mode, .peek(.drop), "waits for the drop")
        r.controller.panelDragEnded()
        XCTAssertEqual(r.controller.mode, .compact)
    }

    /// Carry: `.dragBegan` clears `open`; a drop on the zone gives the open panel back.
    func testDropOnZoneRestoresTheOpenPanel() {
        let r = rig()
        var down = true
        r.controller.mouseDown = { down }
        r.controller.expand()
        XCTAssertEqual(r.controller.mode, .expanded)
        r.surfaces.setDragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        down = false
        r.controller.dragMoved(to: CGPoint(x: 756, y: 800))
        r.controller.panelDragEnded()   // the drop
        XCTAssertEqual(r.controller.mode, .expanded)

        // Leaving the zone with the button down: the panel rests.
        down = true
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        r.controller.dragMoved(to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(r.controller.mode, .compact)
        r.surfaces.setDragSession(active: false)
    }

    private func filePasteboard(_ r: Rig, _ name: String) throws -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([try file(r, name) as NSURL])
        return pb
    }

    /// Fix round 1 (Important 1): the button-up is often seen before AppKit delivers the
    /// drop. Released on the zone, it stays (taking drops) until the drop arrives.
    func testReleaseOnZoneThenDropIsAccepted() throws {
        let r = rig()
        var down = true
        r.controller.mouseDown = { down }
        r.controller.expand()
        r.surfaces.setDragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        down = false
        r.controller.dragMoved(to: CGPoint(x: 756, y: 800))   // the poll sees the release first
        r.controller.cursorLocation = { CGPoint(x: 756, y: 800) }   // still over the zone
        r.surfaces.setDragSession(active: false)              // and the detector ends the session
        XCTAssertEqual(r.controller.mode, .peek(.drop), "still the drop zone")
        XCTAssertTrue(r.controller.awaitingDrop)
        let pb = try filePasteboard(r, "late.txt")
        defer { pb.releaseGlobally() }
        let info = FakeDraggingInfo(pb)
        XCTAssertEqual(r.controller.panelDragUpdated(info), .copy)
        XCTAssertTrue(r.controller.panelPerformDrop(info), "the late drop is taken")
        r.controller.panelDragEnded()
        XCTAssertEqual(r.shelf.items.first?.title, "late.txt")
        XCTAssertFalse(r.controller.awaitingDrop)
        XCTAssertEqual(r.controller.mode, .expanded, "then the open panel comes back")
    }

    func testReleaseOnZoneWithoutDropClosesAfterGrace() async throws {
        let r = rig()
        var down = true
        r.controller.mouseDown = { down }
        r.surfaces.setDragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        down = false
        r.controller.dragMoved(to: CGPoint(x: 756, y: 800))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(r.controller.mode, .compact)
        XCTAssertFalse(r.controller.awaitingDrop)
        r.surfaces.setDragSession(active: false)
    }

    func testDropBeforeReleaseClosesAtOnce() {
        let r = rig()
        var down = true
        r.controller.mouseDown = { down }
        r.surfaces.setDragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        r.controller.panelDragEnded()   // the drop arrived first
        down = false
        r.controller.dragMoved(to: CGPoint(x: 756, y: 800))
        XCTAssertEqual(r.controller.mode, .compact)
        XCTAssertFalse(r.controller.awaitingDrop)
        r.surfaces.setDragSession(active: false)
    }

    func testReleaseOutsideTheZoneClosesAtOnce() {
        let r = rig()
        var down = true
        r.controller.mouseDown = { down }
        r.surfaces.setDragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        down = false
        r.controller.dragMoved(to: CGPoint(x: 100, y: 100))   // released away from the zone
        XCTAssertEqual(r.controller.mode, .compact)
        XCTAssertFalse(r.controller.awaitingDrop)
        r.controller.cursorLocation = { CGPoint(x: 100, y: 100) }
        r.surfaces.setDragSession(active: false)
        XCTAssertEqual(r.controller.mode, .compact)
    }

    /// Fix round 2 (3): a new drag that starts inside the grace is not closed by it.
    func testNewDragDuringGraceKeepsTheZone() async throws {
        let r = rig()
        var down = true
        r.controller.mouseDown = { down }
        r.controller.cursorLocation = { CGPoint(x: 756, y: 800) }
        r.surfaces.setDragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        down = false
        r.controller.dragMoved(to: CGPoint(x: 756, y: 800))
        r.surfaces.setDragSession(active: false)
        XCTAssertTrue(r.controller.awaitingDrop)
        down = true
        r.surfaces.setDragSession(active: true)   // the next drag, within 300 ms
        XCTAssertFalse(r.controller.awaitingDrop)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 900))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(r.controller.mode, .peek(.drop), "the old grace did not close the new drag's zone")
        r.controller.dragMoved(to: CGPoint(x: 100, y: 100))
        r.surfaces.setDragSession(active: false)
    }

    /// Fix round 2 (4): an image counts only once kept; a failed conversion is reported.
    func testImageCountedOnlyWhenKept() async throws {
        let r = rig()
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setData(Data("not a tiff".utf8), forType: .tiff)
        XCTAssertEqual(r.shelf.receive(pasteboard: pb), 1, "taken for import while the pasteboard is valid")
        await r.shelf.importTask?.value
        XCTAssertTrue(r.shelf.items.isEmpty)
        XCTAssertEqual(r.shelf.importFailures, 1)

        let image = NSImage(size: CGSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        pb.clearContents()
        pb.setData(png, forType: .png)
        XCTAssertEqual(r.shelf.receive(pasteboard: pb), 1)
        XCTAssertEqual(r.shelf.items.count, 1, "PNG data is written before it counts")
    }

    /// Fix round 1 (Important 2): with the shelf off, a drag reaching the panel starts
    /// no session and no placeholder drop zone.
    func testWindowFallbackNeedsADropTarget() throws {
        let r = rig(enabled: false)
        r.controller.mouseDown = { true }
        let pb = try filePasteboard(r, "a.txt")
        defer { pb.releaseGlobally() }
        XCTAssertEqual(r.controller.panelDragUpdated(FakeDraggingInfo(pb)), [])
        XCTAssertFalse(r.surfaces.dragActive)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .compact)
    }

    /// Fix round 1 (Important 2): a session the window started ends at the button-up even
    /// when no drag-end reaches the window, so nothing stays polled.
    func testWindowStartedSessionEndsOnButtonUp() throws {
        let r = rig()
        var down = true
        r.controller.mouseDown = { down }
        let pb = try filePasteboard(r, "a.txt")
        defer { pb.releaseGlobally() }
        _ = r.controller.panelDragUpdated(FakeDraggingInfo(pb))
        XCTAssertTrue(r.surfaces.dragActive, "the detector missed it: the window starts the session")
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        down = false
        r.controller.dragMoved(to: CGPoint(x: 100, y: 100))
        XCTAssertFalse(r.surfaces.dragActive, "ended at the button-up")
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertFalse(r.controller.mode == .peek(.drop))
    }

    /// Carry: ringing never covers the panel a drag opened; it is the chip there.
    func testRingingDuringDragIsAChip() {
        let r = rig()
        r.controller.mouseDown = { true }
        r.controller.debugHandle(.event(.ringStarted(id: "time.alarm")))
        r.surfaces.setDragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        XCTAssertEqual(r.controller.ringingChip?.id, "time.alarm")
        r.surfaces.setDragSession(active: false)
    }

    // MARK: - Receiving

    func testReceivesFilesTextAndLinks() throws {
        let r = rig()
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let a = try file(r, "a.txt"), b = try file(r, "b.txt")
        pb.clearContents()
        pb.writeObjects([a as NSURL, b as NSURL])
        XCTAssertEqual(r.shelf.receive(pasteboard: pb), 2)
        XCTAssertEqual(r.shelf.items.map(\.title), ["a.txt", "b.txt"], "dragged order kept")

        pb.clearContents()
        pb.writeObjects([URL(string: "https://example.com/page")! as NSURL])
        XCTAssertEqual(r.shelf.receive(pasteboard: pb), 1)
        XCTAssertEqual(r.shelf.items.first?.kind, .url(URL(string: "https://example.com/page")!))

        pb.clearContents()
        pb.setString("a snippet", forType: .string)
        XCTAssertEqual(r.shelf.receive(pasteboard: pb), 1)
        XCTAssertEqual(r.shelf.items.first?.kind, .text("a snippet"))
        XCTAssertEqual(r.shelf.liveActivities.first?.trailing, "4")
        XCTAssertEqual(r.shelf.liveActivities.first?.isAmbient, true, "never keeps the pill up (C9)")
    }

    func testRefusesConcealedDrops() {
        let r = rig()
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType(ShelfDropPolicy.concealedType)], owner: nil)
        pb.setString("hunter2", forType: .string)
        XCTAssertEqual(r.shelf.receive(pasteboard: pb), 0)
        XCTAssertTrue(r.shelf.items.isEmpty)
    }

    func testImageDataBecomesAnOwnedCopy() async throws {
        let r = rig()
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let image = NSImage(size: CGSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        pb.clearContents()
        pb.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff)
        XCTAssertEqual(r.shelf.receive(pasteboard: pb), 1)
        await r.shelf.importTask?.value   // TIFF → PNG off the main thread
        let item = try XCTUnwrap(r.shelf.items.first)
        XCTAssertTrue(item.ownsFile)
        XCTAssertEqual(item.fileRef?.url.pathExtension, "png")
        let url = try XCTUnwrap(item.fileRef?.url)
        XCTAssertTrue(url.path.hasPrefix(r.shelf.directory.path))
        r.shelf.remove([item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Missing files (Review Focus #2)

    func testMissingFileIsMarkedAndNeverDragged() async throws {
        let r = rig()
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let gone = try file(r, "gone.txt"), kept = try file(r, "kept.txt")
        pb.clearContents()
        pb.writeObjects([gone as NSURL, kept as NSURL])
        r.shelf.receive(pasteboard: pb)
        try FileManager.default.removeItem(at: gone)
        r.shelf.refreshMissing()
        await r.shelf.refreshTask?.value
        let goneItem = try XCTUnwrap(r.shelf.items.first { $0.title == "gone.txt" })
        XCTAssertEqual(r.shelf.missing, [goneItem.id])

        XCTAssertTrue(r.shelf.pasteboardWriters(for: [goneItem]).isEmpty, "a missing file is never dragged")
        r.shelf.selection = Set(r.shelf.items.map(\.id))
        let writers = r.shelf.pasteboardWriters(for: r.shelf.dragSet(startingAt: goneItem))
        XCTAssertEqual(writers.count, 1, "the rest of the selection still drags")
        XCTAssertEqual((writers.first?.1 as? NSURL)?.lastPathComponent, "kept.txt")

        let found = try file(r, "found.txt")
        r.shelf.relocate(goneItem, to: found)
        await r.shelf.refreshTask?.value
        XCTAssertTrue(r.shelf.missing.isEmpty)
        r.shelf.remove([goneItem.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: found.path), "removing never deletes a user's file")
    }

    /// Final review B1: starting the shelf (launch, login, turning it on) resolves no
    /// bookmark and checks no file path: a file in Downloads could make macOS ask.
    func testStartResolvesNothing() async throws {
        let r = rig()
        let pb = try filePasteboard(r, "doc.txt")
        defer { pb.releaseGlobally() }
        r.shelf.receive(pasteboard: pb)
        await r.shelf.refreshTask?.value
        try FileManager.default.removeItem(at: r.root.appendingPathComponent("user/doc.txt"))

        // Off and on again (the same store) and a fresh widget on the same folder (a relaunch).
        r.registry.setEnabled(ShelfWidget.widgetID, false)
        let before = r.shelf.refreshCount
        r.registry.setEnabled(ShelfWidget.widgetID, true)
        XCTAssertEqual(r.shelf.refreshCount, before, "turning the shelf on checks no file")
        XCTAssertTrue(r.shelf.missing.isEmpty)

        let relaunch = ShelfWidget(directory: r.shelf.directory, makeSignals: { FakeDragSignals() })
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(relaunch)
        registry.start(context: WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                              config: ConfigFileStore(url: r.root.appendingPathComponent("c2.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              surfaces: PanelSurfaces(registry: registry), openPanel: { _ in }))
        XCTAssertTrue(relaunch.isRunning)
        XCTAssertEqual(relaunch.items.count, 1, "the index is read")
        XCTAssertEqual(relaunch.refreshCount, 0, "no bookmark resolved, no path checked")
        XCTAssertNil(relaunch.refreshTask)
        XCTAssertTrue(relaunch.missing.isEmpty, "missing is only known once the tile shows")
        relaunch.refreshMissing()   // what the tile's onAppear does
        await relaunch.refreshTask?.value
        XCTAssertEqual(relaunch.missing.count, 1)
    }

    /// Fix round 1 (5): a file renamed in Finder shows its new name after a refresh.
    func testRefreshSavesRenamedPath() async throws {
        let r = rig()
        let pb = try filePasteboard(r, "old.txt")
        defer { pb.releaseGlobally() }
        r.shelf.receive(pasteboard: pb)
        await r.shelf.refreshTask?.value
        let old = r.root.appendingPathComponent("user/old.txt")
        try FileManager.default.moveItem(at: old, to: r.root.appendingPathComponent("user/new.txt"))
        r.shelf.refreshMissing()
        await r.shelf.refreshTask?.value
        XCTAssertEqual(r.shelf.items.first?.title, "new.txt")
        XCTAssertTrue(r.shelf.missing.isEmpty)
    }

    func testViewsBuild() throws {
        let r = rig()
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.writeObjects([try file(r, "a.txt") as NSURL])
        r.shelf.receive(pasteboard: pb)
        let views: [AnyView] = [r.shelf.tileView(), try XCTUnwrap(r.shelf.dropZoneView()),
                                try XCTUnwrap(r.shelf.settingsView()), ShelfWidget.inert().tileView()]
        for v in views {
            let host = NSHostingView(rootView: v.frame(width: 380).environment(\.colorScheme, .dark))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
        }
    }
}
