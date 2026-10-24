import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
private final class FakeShelf: ShelfAdding {
    var added: [URL] = []
    func addFile(_ url: URL) -> Bool { added.append(url); return true }
}

@MainActor
private final class FakeTimer: TimerStarter {
    var started: [TimeInterval] = []
    func startTimer(duration: TimeInterval, label: String?) -> Bool { started.append(duration); return true }
}

@MainActor
private final class SilentSound: RingSound {
    func play(_ sound: TimeSound) {}
    func stop() {}
    var isPlaying: Bool { false }
}

/// Task 2, R7 and R8: links ask before they act, and do nothing while their widget is off.
@MainActor
final class URLRoutesTests: DefaultsTestCase {
    nonisolated(unsafe) private let fm = FileManager.default
    nonisolated(unsafe) private var root: URL!

    override func setUp() {
        super.setUp()
        root = fm.temporaryDirectory.appendingPathComponent("URLRoutesTests-\(UUID().uuidString)")
        try? fm.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
        super.tearDown()
    }

    private struct Rig {
        let router: URLRouter
        let shelf: FakeShelf
        let timer: FakeTimer
        var peeks: [String] { box.peeks }
        var ended: [String] { box.ended }
        let box: PeekLog
        let clock: ClockBox
    }

    private final class PeekLog {
        var peeks: [String] = []
        var ended: [String] = []
        var shows = true
    }

    private final class ClockBox {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func rig(shelfOn: Bool = true, timerOn: Bool = true) -> Rig {
        let r = URLRouter()
        let shelf = FakeShelf(), timer = FakeTimer(), log = PeekLog(), clock = ClockBox()
        r.shelf = { shelfOn ? shelf : nil }
        r.timer = { timerOn ? timer : nil }
        r.peek = { id, _ in log.peeks.append(id); return log.shows }
        r.endPeek = { log.ended.append($0) }
        r.now = { clock.now }
        r.home = root.appendingPathComponent("home")
        return Rig(router: r, shelf: shelf, timer: timer, box: log, clock: clock)
    }

    private func userFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("user/\(name)")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testShelfAddAsksThenAdds() throws {
        let r = rig()
        let a = try userFile("a.txt"), b = try userFile("b.txt")
        XCTAssertTrue(r.router.handle(.shelfAdd([a.path, b.path])))
        XCTAssertTrue(r.shelf.added.isEmpty, "nothing from the URL alone")
        XCTAssertEqual(r.peeks, [URLRouter.confirmID])
        XCTAssertEqual(r.router.question, "Add 2 files to the shelf?")
        XCTAssertEqual(r.router.detail, "a.txt, b.txt")
        XCTAssertNotNil(r.router.peekView(id: URLRouter.confirmID))
        r.router.confirm()
        XCTAssertEqual(r.shelf.added, [b, a].map(\.standardizedFileURL), "the first ends up first")
        XCTAssertEqual(r.ended, [URLRouter.confirmID])
        XCTAssertNil(r.router.pending)
        XCTAssertNil(r.router.peekView(id: URLRouter.confirmID))
    }

    func testShelfAddDoesNothingWhileTheShelfIsOff() throws {
        let r = rig(shelfOn: false)
        XCTAssertTrue(r.router.handle(.shelfAdd([try userFile("a.txt").path])))
        XCTAssertNil(r.router.pending)
        XCTAssertTrue(r.peeks.isEmpty, "not even a question")
    }

    func testShelfAddRefusesBadPaths() throws {
        let r = rig()
        let inHome = root.appendingPathComponent("home/secret.txt")
        try Data("s".utf8).write(to: inHome)
        r.router.handle(.shelfAdd(["relative", "/nope/gone.txt", inHome.path]))
        XCTAssertNil(r.router.pending)
        let many = try (0..<21).map { try userFile("f\($0).txt").path }
        r.router.handle(.shelfAdd(many))
        XCTAssertNil(r.router.pending, "more than 20: nothing")
    }

    func testCancelAndExpiry() throws {
        let r = rig()
        r.router.handle(.timerStart(25 * 60))
        XCTAssertEqual(r.router.question, "Start a 25 minute timer?")
        r.router.cancel()
        XCTAssertTrue(r.timer.started.isEmpty)
        XCTAssertEqual(r.ended, [URLRouter.confirmID])

        r.router.handle(.timerStart(60))
        r.clock.now += URLRouter.confirmTime + 1
        r.router.confirm()
        XCTAssertTrue(r.timer.started.isEmpty, "a peek that ran out does nothing")
        XCTAssertNil(r.router.pending)
    }

    func testTimerStartAsksThenStarts() {
        let r = rig()
        r.router.handle(.timerStart(90))
        XCTAssertTrue(r.timer.started.isEmpty)
        r.router.confirm()
        XCTAssertEqual(r.timer.started, [90])
        let off = rig(timerOn: false)
        off.router.handle(.timerStart(90))
        XCTAssertNil(off.router.pending)
    }

    /// A widget turned off while its question shows: the click does nothing.
    func testWidgetOffBeforeTheClick() throws {
        let on = PeekLog()   // `shows` stands for "the shelf runs"
        let r = rig()
        let shelf = FakeShelf()
        r.router.shelf = { on.shows ? shelf : nil }
        r.router.handle(.shelfAdd([try userFile("a.txt").path]))
        on.shows = false
        r.router.confirm()
        XCTAssertTrue(shelf.added.isEmpty)
    }

    func testNoPanelMeansNoQuestion() throws {
        let r = rig()
        r.box.shows = false
        r.router.handle(.shelfAdd([try userFile("a.txt").path]))
        XCTAssertNil(r.router.pending, "a question nobody can see is dropped")
    }

    func testClipboardOpenOnlyOpensThePicker() {
        let r = rig()
        var opened = 0
        r.router.clipboardPicker = { { opened += 1 } }
        XCTAssertTrue(r.router.handle(.clipboardOpen))
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(r.peeks.isEmpty)
        r.router.clipboardPicker = { nil }   // clipboard history off
        r.router.handle(.clipboardOpen)
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(r.router.handle(.open), "not the router's")
    }

    func testConfirmCardsBuild() throws {
        let r = rig()
        r.router.handle(.shelfAdd([try userFile("a.txt").path]))
        let card = NSHostingView(rootView: try XCTUnwrap(r.router.peekView(id: URLRouter.confirmID)).frame(width: 400, height: 60))
        card.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(card.fittingSize.width, 0)
        r.router.showNotice("Turn on the Shelf")
        XCTAssertNotNil(r.router.peekView(id: URLRouter.noticeID))
    }

    /// The app's peeks come after the widgets'.
    func testRegistryAsksTheAppForPeeks() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        XCTAssertNil(registry.peekView(id: URLRouter.noticeID))
        registry.appPeeks = { $0 == URLRouter.noticeID ? AnyView(Text("x")) : nil }
        XCTAssertNotNil(registry.peekView(id: URLRouter.noticeID))
        XCTAssertNil(registry.peekView(id: "other"))
    }

    // MARK: - Finder service (R8)

    func testFinderServiceAddsWhileTheShelfRuns() throws {
        let service = FinderService()
        let shelf = FakeShelf()
        var notices: [String] = []
        service.notice = { notices.append($0) }
        let a = try userFile("a.txt"), b = try userFile("b.txt")
        let pb = NSPasteboard(name: NSPasteboard.Name("dev.platynotch.tests.finder-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([a as NSURL, b as NSURL])

        service.shelf = { nil }
        XCTAssertEqual(service.receive(FinderService.fileURLs(pb)), 0)
        XCTAssertEqual(notices, ["Turn on the Shelf"])

        service.shelf = { shelf }
        var error: NSString?
        service.addToShelf(pb, userData: nil, error: &error)
        XCTAssertEqual(shelf.added, [b, a], "the first selected ends up first")
        XCTAssertEqual(notices.last, "Added 2 files to the shelf")
    }

    /// The Info.plist entry names the method the provider has.
    func testServiceIsDeclared() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let services = try XCTUnwrap(dict["NSServices"] as? [[String: Any]])
        let entry = try XCTUnwrap(services.first)
        XCTAssertEqual((entry["NSMenuItem"] as? [String: String])?["default"], "Add to PlatyNotch Shelf")
        XCTAssertEqual(entry["NSPortName"] as? String, dict["CFBundleName"] as? String)
        let message = try XCTUnwrap(entry["NSMessage"] as? String)
        XCTAssertTrue(FinderService().responds(to: NSSelectorFromString("\(message):userData:error:")))
        XCTAssertEqual(entry["NSSendFileTypes"] as? [String], ["public.item"])
    }

    // MARK: - TimerStarter on the Time widget

    func testTimeWidgetStartsTimersOnlyWhileRunning() {
        let time = TimeWidget(defaults: defaults(), persist: false, sound: SilentSound())
        XCTAssertFalse(time.startTimer(duration: 60, label: nil), "off: nothing")
        time.start(context: WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                          config: ConfigFileStore(url: root.appendingPathComponent("config.json")),
                                          events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                          openPanel: { _ in }))
        defer { time.stop() }
        XCTAssertFalse(time.startTimer(duration: 0, label: nil))
        XCTAssertFalse(time.startTimer(duration: DurationParser.maximum + 1, label: nil))
        XCTAssertTrue(time.startTimer(duration: 25 * 60, label: nil))
        XCTAssertTrue(time.startTimer(duration: 90, label: "Tea"))
        XCTAssertEqual(time.state.timers.map(\.label), ["25 min", "Tea"])
        XCTAssertTrue(time.state.timers.allSatisfy { $0.isRunning(at: Date()) })
    }
}
