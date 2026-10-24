import AppKit
import AVFoundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// The camera mirror (v0.2 R17): the camera runs only between a click in the tile and the
/// first stop event, never prompts except from that click, and stamps a working grant.
@MainActor
final class MirrorWidgetTests: DefaultsTestCase {
    private final class FakeAccess: @unchecked Sendable {
        var status: AVAuthorizationStatus = .authorized
        var answer: AVAuthorizationStatus = .authorized
        var requests = 0
        var statusReads = 0
    }

    private final class FakeFeed: CameraFeed {
        var session: AVCaptureSession? { nil }
        var onLost: (@MainActor () -> Void)?
        var hasCamera = true
        private(set) var running = false
        private(set) var starts = 0
        private(set) var stops = 0
        func start() -> Bool {
            guard hasCamera else { return false }
            starts += 1
            running = true
            return true
        }
        func stop() {
            stops += 1
            running = false
        }
    }

    private final class FakeSignals: MirrorStopSignals {
        private(set) var handler: (@MainActor (MirrorStopReason) -> Void)?
        private(set) var begins = 0
        var installed: Bool { handler != nil }
        func begin(_ onStop: @escaping @MainActor (MirrorStopReason) -> Void) {
            begins += 1
            handler = onStop
        }
        func end() { handler = nil }
        func fire(_ r: MirrorStopReason) { handler?(r) }
    }

    private struct Rig {
        let widget: MirrorWidget
        let access: FakeAccess
        let feed: FakeFeed
        let signals: FakeSignals
        let grant: GrantStamp
        var feedsMade: () -> Int
    }

    private func rig(status: AVAuthorizationStatus = .authorized, build: String = "dr:1") -> Rig {
        let access = FakeAccess()
        access.status = status
        let feed = FakeFeed()
        let signals = FakeSignals()
        let grant = GrantStamp(key: MirrorWidget.cameraGrantKey, defaults: defaults(), identity: { build })
        final class Counter { var n = 0 }
        let made = Counter()
        let camera = CameraAccess(status: {
            access.statusReads += 1
            return access.status
        }, request: {
            access.requests += 1
            access.status = access.answer
            return access.answer == .authorized
        })
        let w = MirrorWidget(access: camera, grant: grant, feed: { made.n += 1; return feed }, signals: signals)
        return Rig(widget: w, access: access, feed: feed, signals: signals, grant: grant, feedsMade: { made.n })
    }

    private func context() -> WidgetContext {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnmirror\(UUID().uuidString)")
        return WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                             config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                             events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                             openPanel: { _ in })
    }

    /// Started, with one visible tile, and the mirror showing in it.
    private func live(_ r: Rig) async -> MirrorTileToken {
        r.widget.start(context: context())
        let tile = MirrorTileToken()
        r.widget.tileAppeared(tile, visible: true)
        await r.widget.buttonClicked(tile)
        XCTAssertTrue(r.widget.live)
        XCTAssertTrue(r.feed.running)
        XCTAssertTrue(r.signals.installed, "stop signals are watched while live")
        return tile
    }

    private func assertStopped(_ r: Rig, _ reason: MirrorStopReason, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(r.widget.live, file: file, line: line)
        XCTAssertFalse(r.feed.running, "camera off", file: file, line: line)
        XCTAssertFalse(r.signals.installed, "signals removed", file: file, line: line)
        XCTAssertEqual(r.widget.lastStop, reason, file: file, line: line)
        XCTAssertNil(r.widget.owner, file: file, line: line)
    }

    func testIsAPowerFeatureOffByDefault() {
        let w = rig().widget
        XCTAssertEqual(w.category, .power)
        XCTAssertFalse(w.defaultEnabled)
        XCTAssertTrue(w.hasTile)
    }

    // MARK: - Starts only after a click

    func testNothingRunsWithoutAClick() {
        let r = rig()
        r.widget.start(context: context())
        let tile = MirrorTileToken()
        r.widget.tileAppeared(tile, visible: true)
        r.widget.tileVisibility(tile, visible: false)
        r.widget.tileVisibility(tile, visible: true)
        XCTAssertFalse(r.widget.live)
        XCTAssertEqual(r.feedsMade(), 0, "no capture session exists before a click")
        XCTAssertEqual(r.feed.starts, 0)
        XCTAssertEqual(r.signals.begins, 0, "no observers while the mirror is not showing")
        XCTAssertEqual(r.access.requests, 0)
    }

    func testClickWhileStoppedOrUnseenDoesNothing() async {
        let r = rig()
        let tile = MirrorTileToken()
        r.widget.tileAppeared(tile, visible: true)
        await r.widget.buttonClicked(tile)
        XCTAssertFalse(r.widget.live, "the widget is not running")
        r.widget.start(context: context())
        await r.widget.buttonClicked(MirrorTileToken())
        XCTAssertFalse(r.widget.live, "a tile that is not on screen")
        r.widget.tileVisibility(tile, visible: false)
        await r.widget.buttonClicked(tile)
        XCTAssertFalse(r.widget.live, "the panel's content is hidden")
        XCTAssertEqual(r.feed.starts, 0)
    }

    func testClickShowsAndStampsTheGrant() async {
        let r = rig()
        let owner = await live(r)
        defer { withExtendedLifetime(owner) {} }
        XCTAssertEqual(r.feed.starts, 1)
        XCTAssertEqual(r.access.requests, 0, "already authorized: no prompt")
        XCTAssertEqual(r.grant.saved, "dr:1")
        XCTAssertEqual(r.widget.tileState, .live)
    }

    func testSecondClickHides() async {
        let r = rig()
        let tile = await live(r)
        await r.widget.buttonClicked(tile)
        assertStopped(r, .userHid)
    }

    // MARK: - Stop events

    func testStopsOnCollapse() async {
        let r = rig()
        let tile = await live(r)
        r.widget.tileDisappeared(tile)
        assertStopped(r, .collapsed)
    }

    func testStopsWhenThePanelHides() async {
        let r = rig()
        let tile = await live(r)
        r.widget.tileVisibility(tile, visible: false)
        assertStopped(r, .panelHidden)
    }

    func testStopsOnScreenLock() async {
        let r = rig()
        let owner = await live(r)
        defer { withExtendedLifetime(owner) {} }
        r.signals.fire(.screenLocked)
        assertStopped(r, .screenLocked)
    }

    func testStopsOnDisplaySleep() async {
        let r = rig()
        let owner = await live(r)
        defer { withExtendedLifetime(owner) {} }
        r.signals.fire(.displaySleep)
        assertStopped(r, .displaySleep)
    }

    func testStopsOnSystemSleepAndUserSwitch() async {
        for reason in [MirrorStopReason.systemSleep, .sessionSwitched] {
            let r = rig()
            let owner = await live(r)
        defer { withExtendedLifetime(owner) {} }
            r.signals.fire(reason)
            assertStopped(r, reason)
        }
    }

    func testStopsWhenTheWidgetIsTurnedOff() async {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let r = rig()
        registry.register(r.widget)
        registry.setEnabled(MirrorWidget.widgetID, true)
        registry.start(context: context())
        let tile = MirrorTileToken()
        r.widget.tileAppeared(tile, visible: true)
        await r.widget.buttonClicked(tile)
        XCTAssertTrue(r.feed.running)
        registry.setEnabled(MirrorWidget.widgetID, false)
        assertStopped(r, .widgetOff)
    }

    func testStopsWhenTheCameraIsLost() async {
        let r = rig()
        let owner = await live(r)
        defer { withExtendedLifetime(owner) {} }
        r.feed.onLost?()
        assertStopped(r, .cameraLost)
    }

    func testAnotherTileLeavingDoesNotStopIt() async {
        let r = rig()
        let owner = await live(r)
        defer { withExtendedLifetime(owner) {} }
        let other = MirrorTileToken()
        r.widget.tileAppeared(other, visible: true)
        r.widget.tileVisibility(other, visible: false)
        r.widget.tileDisappeared(other)
        XCTAssertTrue(r.widget.live)
    }

    func testNeverRestartsByItself() async {
        let r = rig()
        let tile = await live(r)
        r.widget.tileDisappeared(tile)
        let next = MirrorTileToken()
        r.widget.tileAppeared(next, visible: true)
        r.widget.tileVisibility(next, visible: true)
        XCTAssertFalse(r.widget.live, "reopening the panel needs another click")
        XCTAssertEqual(r.feed.starts, 1)
    }

    // MARK: - Permission

    func testNeverAskedAsksOnlyFromTheClick() async {
        let r = rig(status: .notDetermined)
        r.widget.start(context: context())
        let tile = MirrorTileToken()
        r.widget.tileAppeared(tile, visible: true)
        XCTAssertEqual(r.widget.tileState, .allow)
        XCTAssertEqual(r.access.requests, 0, "starting and showing the tile never prompt")
        await r.widget.buttonClicked(tile)
        XCTAssertEqual(r.access.requests, 1)
        XCTAssertTrue(r.widget.live)
    }

    func testRefusedPromptNeverStartsTheCamera() async {
        let r = rig(status: .notDetermined)
        r.access.answer = .denied
        r.widget.start(context: context())
        let tile = MirrorTileToken()
        r.widget.tileAppeared(tile, visible: true)
        await r.widget.buttonClicked(tile)
        XCTAssertFalse(r.widget.live)
        XCTAssertEqual(r.feed.starts, 0)
        XCTAssertEqual(r.widget.tileState, .denied(rebuilt: false))
        await r.widget.buttonClicked(tile)
        XCTAssertEqual(r.access.requests, 1, "a refusal is never asked again from code")
    }

    func testDeniedNeverStartsOrPrompts() async {
        let r = rig(status: .denied)
        r.widget.start(context: context())
        let tile = MirrorTileToken()
        r.widget.tileAppeared(tile, visible: true)
        await r.widget.buttonClicked(tile)
        XCTAssertFalse(r.widget.live)
        XCTAssertEqual(r.access.requests, 0)
        XCTAssertEqual(r.feed.starts, 0)
    }

    func testAnswerAfterThePanelClosedDoesNotStart() async {
        let r = rig(status: .notDetermined)
        let tile = MirrorTileToken()
        // The prompt is answered (Allow) after the panel collapsed under it.
        let closing = Self.closingWidget(access: r.access, tile: tile, feed: r.feed, signals: r.signals, grant: r.grant)
        closing.start(context: context())
        closing.tileAppeared(tile, visible: true)
        await closing.buttonClicked(tile)
        XCTAssertFalse(closing.live, "never starts unseen")
        XCTAssertEqual(r.feed.starts, 0)
        XCTAssertEqual(closing.auth, .authorized)
    }

    private static func closingWidget(access: FakeAccess, tile: MirrorTileToken, feed: FakeFeed, signals: FakeSignals,
                                      grant: GrantStamp) -> MirrorWidget {
        @MainActor final class Box { weak var widget: MirrorWidget? }
        let box = Box()
        let camera = CameraAccess(status: { access.status }, request: {
            await MainActor.run { box.widget?.tileDisappeared(tile) }
            access.status = .authorized
            return true
        })
        let w = MirrorWidget(access: camera, grant: grant, feed: { feed }, signals: signals)
        box.widget = w
        return w
    }

    func testRebuildShowsTurnOnAgain() {
        let d = defaults()
        GrantStamp(key: MirrorWidget.cameraGrantKey, defaults: d, identity: { "dr:1" }).note()
        let r = rig(status: .notDetermined, build: "dr:2")
        r.widget.start(context: context())
        XCTAssertEqual(r.widget.tileState, .turnOnAgain)
        XCTAssertNil(r.grant.saved, "the other build's stamp is cleared at start")
        XCTAssertEqual(r.access.requests, 0)
    }

    func testNoCamera() async {
        let r = rig()
        r.feed.hasCamera = false
        r.widget.start(context: context())
        let tile = MirrorTileToken()
        r.widget.tileAppeared(tile, visible: true)
        await r.widget.buttonClicked(tile)
        XCTAssertFalse(r.widget.live)
        XCTAssertEqual(r.widget.tileState, .noCamera)
        XCTAssertFalse(r.signals.installed)
    }

    // MARK: - Rebuilt panels (C1)

    func testHideWorksFromAnyTile() async {
        let r = rig()
        let owner = await live(r)
        let other = MirrorTileToken()
        r.widget.tileAppeared(other, visible: true)
        await r.widget.buttonClicked(other)
        assertStopped(r, .userHid)
        withExtendedLifetime(owner) {}
    }

    func testStopsWhenTheOwnersViewWentWithoutDisappearing() async {
        let r = rig()
        var owner: MirrorTileToken? = await live(r)
        XCTAssertNotNil(owner)
        owner = nil   // the panel was torn down; onDisappear never came
        let next = MirrorTileToken()
        r.widget.tileAppeared(next, visible: true)
        assertStopped(r, .collapsed)
    }

    func testOwnerStillOnScreenKeepsItWhenAnotherTileAppears() async {
        let r = rig()
        let owner = await live(r)
        let next = MirrorTileToken()
        r.widget.tileAppeared(next, visible: true)
        XCTAssertTrue(r.widget.live)
        withExtendedLifetime(owner) {}
    }

    func testStopsWhenThePanelsAreRebuilt() async {
        let r = rig()
        let owner = await live(r)
        r.widget.panelsRebuilt()
        assertStopped(r, .displaysChanged)
        // The old tile's late onDisappear changes nothing; the new tile needs a click.
        r.widget.tileDisappeared(owner)
        let next = MirrorTileToken()
        r.widget.tileAppeared(next, visible: true)
        XCTAssertFalse(r.widget.live)
    }

    func testStopsOnDisplayChange() async {
        let r = rig()
        let owner = await live(r)
        r.signals.fire(.displaysChanged)
        assertStopped(r, .displaysChanged)
        withExtendedLifetime(owner) {}
    }

    func testANewShowingGetsANewFeed() async {
        let r = rig()
        let tile = await live(r)
        await r.widget.buttonClicked(tile)
        await r.widget.buttonClicked(tile)
        XCTAssertTrue(r.widget.live)
        XCTAssertEqual(r.feedsMade(), 2, "the feed is dropped when a showing ends")
    }

    func testInertNeverTouchesTheCamera() async {
        let w = MirrorWidget.inert()
        w.start(context: context())
        let tile = MirrorTileToken()
        w.tileAppeared(tile, visible: true)
        await w.buttonClicked(tile)
        XCTAssertFalse(w.live)
        XCTAssertTrue(AppDelegate.buildViews(of: w))
    }
}

/// The mirror is registered as an off-by-default power feature.
@MainActor
final class MirrorRegistrationTests: DefaultsTestCase {
    func testRegisteredOffByDefault() {
        let registry = WidgetRegistry(defaults: defaults())
        let today = TodayServices(client: CoreClient(socketPath: "/nonexistent"))
        BuiltInWidgets.register(in: registry, store: AppStore(), today: today, persist: false)
        XCTAssertTrue(registry.orderedWidgets(in: .power).map(\.id).contains(MirrorWidget.widgetID))
        XCTAssertFalse(registry.isEnabled(MirrorWidget.widgetID))
        XCTAssertFalse(registry.running.contains(MirrorWidget.widgetID))
    }
}

/// The real stop signals map the real notification names (posted to plain centers).
@MainActor
final class MirrorSignalsTests: DefaultsTestCase {
    func testMapsTheSystemNotifications() {
        let distributed = NotificationCenter(), workspace = NotificationCenter(), app = NotificationCenter()
        let signals = SystemMirrorSignals(distributed: distributed, workspace: workspace, app: app)
        var heard: [MirrorStopReason] = []
        signals.begin { heard.append($0) }
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        app.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(heard, [.screenLocked, .displaySleep, .systemSleep, .sessionSwitched, .displaysChanged])
        // Posted to the wrong center: not heard.
        app.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(heard.count, 5)
        signals.end()
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        app.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(heard.count, 5, "nothing after end")
    }

    func testDefaultCentersAreTheSystemOnes() {
        let s = SystemMirrorSignals()
        let centers = s.events.map { ObjectIdentifier($0.0) }
        XCTAssertEqual(centers[0], ObjectIdentifier(DistributedNotificationCenter.default()))
        XCTAssertEqual(centers[1], ObjectIdentifier(NSWorkspace.shared.notificationCenter))
        XCTAssertEqual(centers[4], ObjectIdentifier(NotificationCenter.default))
    }
}
