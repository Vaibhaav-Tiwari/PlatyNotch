import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Records every AX call a snap makes, in order. Thread-safe: snaps run off the main actor.
private final class FakeDriver: SnapWindowDriver, @unchecked Sendable {
    enum Call: Equatable {
        case read(pid_t)
        case position(CGPoint)
        case size(CGSize)
        case readSize
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var window: SnapWindowInfo?
    var refusePosition = false
    var refuseSize = false
    /// Blocks `focusedWindow` until signalled (a snap still running).
    var gate: DispatchSemaphore?
    /// The size the window keeps whatever is set (an app that says it is settable).
    var keptSize: CGSize?
    private var lastSize: CGSize?
    private var _onMain: [Bool] = []

    var calls: [Call] { lock.withLock { _calls } }
    /// `Thread.isMainThread` at each `focusedWindow`.
    var readsOnMain: [Bool] { lock.withLock { _onMain } }
    private func record(_ c: Call) { lock.withLock { _calls.append(c) } }

    func focusedWindow(pid: pid_t) -> SnapWindowInfo? {
        record(.read(pid))
        lock.withLock { _onMain.append(Thread.isMainThread) }
        gate?.wait()
        return window
    }

    func setPosition(_ position: CGPoint, of window: SnapWindowHandle) -> Bool {
        record(.position(position))
        return !refusePosition
    }

    func setSize(_ size: CGSize, of window: SnapWindowHandle) -> Bool {
        record(.size(size))
        if !refuseSize { lock.withLock { lastSize = size } }
        return !refuseSize
    }

    func size(of window: SnapWindowHandle) -> CGSize? {
        record(.readSize)
        return keptSize ?? lock.withLock { lastSize } ?? self.window?.frame.size
    }
}

@MainActor
private final class Keys {
    final class Reg: HotKeyRegistration {
        let keyCode: UInt32, modifiers: UInt32
        let handler: @MainActor () -> Void
        var active = true
        init(_ k: UInt32, _ m: UInt32, _ h: @escaping @MainActor () -> Void) { keyCode = k; modifiers = m; handler = h }
        func unregister() { active = false }
    }
    var all: [Reg] = []
    /// Key codes another app holds.
    var refused: Set<UInt32> = []
    var active: [Reg] { all.filter(\.active) }

    lazy var make: HotKeyMaker = { [unowned self] k, m, h in
        guard !self.refused.contains(k) else { return nil }
        let r = Reg(k, m, h)
        self.all.append(r)
        return r
    }

    func press(_ t: SnapTarget) {
        active.first { $0.keyCode == t.defaultCombo.keyCode && $0.modifiers == t.defaultCombo.modifiers }?.handler()
    }
}

@MainActor
private final class TrustBox {
    var trusted = false
    var requests = 0
}

@MainActor
final class WindowSnapperTests: DefaultsTestCase {
    private let displays = SnapDisplays(
        screens: [SnapScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visible: CGRect(x: 0, y: 0, width: 1440, height: 875))],
        primaryHeight: 900)

    private func window(resizable: Bool = true, fullScreen: Bool = false) -> SnapWindowInfo {
        SnapWindowInfo(handle: SnapWindowHandle(nil), frame: CGRect(x: 100, y: 100, width: 400, height: 300),
                       sizeSettable: resizable, fullScreen: fullScreen)
    }

    func testPositionThenSizeThenPositionAgain() {
        let d = FakeDriver()
        d.window = window()
        let out = WindowSnapper.perform(.leftHalf, pid: 7, driver: d, displays: displays, gap: 0)
        XCTAssertEqual(out, .snapped)
        XCTAssertEqual(d.calls, [.read(7), .position(CGPoint(x: 0, y: 25)), .size(CGSize(width: 720, height: 875)),
                                 .readSize, .position(CGPoint(x: 0, y: 25))])
    }

    /// Review focus: a fixed-size window is moved, never resized, and nothing is retried.
    func testFixedSizeWindowIsOnlyMovedOnce() {
        let d = FakeDriver()
        d.window = window(resizable: false)
        let out = WindowSnapper.perform(.maximize, pid: 7, driver: d, displays: displays, gap: 0)
        XCTAssertEqual(out, .moved)
        XCTAssertEqual(d.calls.filter { if case .size = $0 { true } else { false } }, [])
        XCTAssertEqual(d.calls.count, 2, "one read, one move")
    }

    func testRefusalsAreNotRetried() {
        let d = FakeDriver()
        d.window = window()
        d.refusePosition = true
        XCTAssertEqual(WindowSnapper.perform(.rightHalf, pid: 7, driver: d, displays: displays, gap: 0), .failed)
        XCTAssertEqual(d.calls.count, 2, "a refused move stops there")

        let s = FakeDriver()
        s.window = window()
        s.refuseSize = true
        XCTAssertEqual(WindowSnapper.perform(.rightHalf, pid: 7, driver: s, displays: displays, gap: 0), .moved)
        XCTAssertEqual(s.calls.count, 5, "position, size (refused), one read, position: no loop")
        XCTAssertEqual(s.calls.last, .position(CGPoint(x: 880, y: 312)), "the kept size centred in the right half")
    }

    /// Fix round 1: an app that says its size is settable but keeps its own gets one
    /// re-centred move (not the target's top-left), and nothing more.
    func testKeptSizeIsCentredOnce() {
        let d = FakeDriver()
        d.window = window()
        d.keptSize = CGSize(width: 400, height: 300)
        let out = WindowSnapper.perform(.leftHalf, pid: 7, driver: d, displays: displays, gap: 0)
        XCTAssertEqual(out, .moved)
        XCTAssertEqual(d.calls, [.read(7), .position(CGPoint(x: 0, y: 25)), .size(CGSize(width: 720, height: 875)),
                                 .readSize, .position(CGPoint(x: 160, y: 312))])
    }

    /// Fix round 1 (critical): never PlatyNotch's own windows, nothing while a panel is key.
    func testOwnWindowsAndKeyPanelAreNeverSnapped() {
        let d = FakeDriver()
        d.window = window()
        let own = WindowSnapper(driver: d, displays: { [displays] in displays }, frontmost: { 42 }, blocked: { false },
                                ownPID: 42)
        XCTAssertNil(own.snap(.maximize))
        let selfPID = WindowSnapper(driver: d, displays: { [displays] in displays },
                                    frontmost: { ProcessInfo.processInfo.processIdentifier }, blocked: { false })
        XCTAssertNil(selfPID.snap(.maximize), "the default own pid is this process")
        let blocked = WindowSnapper(driver: d, displays: { [displays] in displays }, frontmost: { 42 }, blocked: { true })
        XCTAssertNil(blocked.snap(.maximize))
        XCTAssertEqual(d.calls, [], "no AX call at all")
    }

    /// Fix round 2: the panel-key scan looks at every window, not `NSApp.keyWindow`.
    func testPanelIsKeyScansWindows() {
        let panel = NotchPanel(frame: .zero)
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled],
                             backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        XCTAssertTrue(WindowSnapper.panelIsKey(in: [other, panel], isKey: { $0 === panel }))
        XCTAssertFalse(WindowSnapper.panelIsKey(in: [other, panel], isKey: { $0 === other }), "another key window")
        XCTAssertFalse(WindowSnapper.panelIsKey(in: [other, panel], isKey: { _ in false }))
        XCTAssertFalse(WindowSnapper.panelIsKey(in: [], isKey: { _ in true }))
        XCTAssertFalse(WindowSnapper.panelIsKey(in: [panel]), "a panel that never became key")
    }

    /// Fix round 2: a cancelled snap finishing late never clears the snap that followed.
    func testLateCancelledSnapLeavesTheNewerOne() async {
        let d = FakeDriver()
        d.window = window()
        let gate = DispatchSemaphore(value: 0)
        d.gate = gate
        let snapper = WindowSnapper(driver: d, displays: { [displays] in displays }, frontmost: { 42 }, blocked: { false })
        let a = snapper.snap(.leftHalf)
        XCTAssertNotNil(a)
        snapper.cancel()
        let b = snapper.snap(.rightHalf)
        XCTAssertNotNil(b, "a new press after cancel starts a snap")
        gate.signal()   // A's read returns
        let outA = await a?.value
        XCTAssertEqual(outA, .cancelled)
        XCTAssertEqual(snapper.inFlight, b, "A's late result left B in flight")
        gate.signal()   // B's read returns
        let outB = await b?.value
        XCTAssertEqual(outB, .snapped)
        XCTAssertNil(snapper.inFlight)
    }

    /// Fix round 1: turning snapping off while a snap runs leaves the window alone.
    func testDisableCancelsARunningSnap() async {
        let r = rig(trusted: true)
        let gate = DispatchSemaphore(value: 0)
        r.driver.gate = gate
        r.keys.press(.maximize)
        let task = r.widget.snapper.inFlight
        XCTAssertNotNil(task)
        r.registry.setEnabled(WindowSnapWidget.widgetID, false)
        XCTAssertNil(r.widget.snapper.inFlight)
        gate.signal()
        let out = await task?.value
        XCTAssertEqual(out, .cancelled)
        XCTAssertEqual(r.driver.calls, [.read(42)], "nothing set after the feature was turned off")
    }

    func testNoWindowFullScreenAndNoScreens() {
        let none = FakeDriver()
        XCTAssertEqual(WindowSnapper.perform(.maximize, pid: 7, driver: none, displays: displays, gap: 0), .noWindow)
        let full = FakeDriver()
        full.window = window(fullScreen: true)
        XCTAssertEqual(WindowSnapper.perform(.maximize, pid: 7, driver: full, displays: displays, gap: 0), .fullScreen)
        XCTAssertEqual(full.calls.count, 1, "a full-screen window is never moved")
        let blind = FakeDriver()
        blind.window = window()
        XCTAssertEqual(WindowSnapper.perform(.maximize, pid: 7, driver: blind,
                                             displays: SnapDisplays(screens: [], primaryHeight: 0), gap: 0), .noWindow)
        XCTAssertEqual(blind.calls.count, 1)
    }

    func testGapReachesThePlan() {
        let d = FakeDriver()
        d.window = window()
        _ = WindowSnapper.perform(.maximize, pid: 7, driver: d, displays: displays, gap: 8)
        XCTAssertEqual(d.calls[1], .position(CGPoint(x: 8, y: 33)))
        XCTAssertEqual(d.calls[2], .size(CGSize(width: 1424, height: 859)))
    }

    /// The AX work runs off the main actor; a press while one runs is dropped.
    func testSnapRunsOffMainAndDropsPressesMeanwhile() async {
        let d = FakeDriver()
        d.window = window()
        let gate = DispatchSemaphore(value: 0)
        d.gate = gate
        let snapper = WindowSnapper(driver: d, displays: { [displays] in displays }, frontmost: { 42 }, blocked: { false })
        let first = snapper.snap(.leftHalf)
        XCTAssertNotNil(first)
        XCTAssertNil(snapper.snap(.rightHalf), "dropped while the first runs")
        gate.signal()
        let out = await first?.value
        XCTAssertEqual(out, .snapped)
        XCTAssertNil(snapper.inFlight)
        XCTAssertEqual(d.calls.first, .read(42))
        XCTAssertEqual(d.calls.count, 5, "only the first press did anything")
        XCTAssertEqual(d.readsOnMain, [false], "AX work never runs on the main thread")

        let noFront = WindowSnapper(driver: d, displays: { [displays] in displays }, frontmost: { nil }, blocked: { false })
        XCTAssertNil(noFront.snap(.leftHalf))
    }

    // MARK: - Widget

    private struct Rig {
        let registry: WidgetRegistry
        let widget: WindowSnapWidget
        let keys: Keys
        let trust: TrustBox
        let driver: FakeDriver
        let defaults: UserDefaults
    }

    private func rig(trusted: Bool, enabled: Bool = true, refused: Set<UInt32> = []) -> Rig {
        let defaults = self.defaults()
        let keys = Keys()
        keys.refused = refused
        let box = TrustBox()
        box.trusted = trusted
        let driver = FakeDriver()
        driver.window = window()
        let snapper = WindowSnapper(driver: driver, displays: { [displays] in displays }, frontmost: { 42 },
                                    blocked: { false })
        let widget = WindowSnapWidget(snapper: snapper, makeHotKey: keys.make,
                                      trust: AccessibilityTrust(isTrusted: { box.trusted }, request: { box.requests += 1 }),
                                      identity: { "build-1" }, pollSleep: {}, allowSleep: { await Task.yield() })
        let registry = WidgetRegistry(defaults: defaults, persist: false)
        registry.register(widget)
        if enabled { registry.setEnabled(WindowSnapWidget.widgetID, true) }
        registry.start(context: WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                              config: ConfigFileStore(url: URL(fileURLWithPath: "/nonexistent/config.json")),
                                              events: CoreEventHub(), defaults: defaults, notify: NoopNotifier(),
                                              openPanel: { _ in }))
        return Rig(registry: registry, widget: widget, keys: keys, trust: box, driver: driver, defaults: defaults)
    }

    func testOffByDefaultPowerFeatureWithNoTile() {
        let r = rig(trusted: true, enabled: false)
        XCTAssertFalse(r.widget.defaultEnabled)
        XCTAssertEqual(r.widget.category, .power)
        XCTAssertFalse(r.widget.hasTile)
        XCTAssertFalse(r.widget.isRunning)
        XCTAssertTrue(r.keys.all.isEmpty, "a disabled widget holds no shortcuts")
        XCTAssertEqual(r.trust.requests, 0, "never prompts by itself")
        XCTAssertEqual(r.driver.calls, [])
    }

    func testNoShortcutsWithoutAccessibility() {
        let r = rig(trusted: false)
        XCTAssertEqual(r.widget.status, .needsAccessibility)
        XCTAssertTrue(r.keys.all.isEmpty)
        XCTAssertNotNil(r.widget.explanation)
        XCTAssertEqual(r.trust.requests, 0, "the prompt comes only from Allow")
    }

    func testShortcutsWhileOnAndTrustedThenReleased() async {
        let r = rig(trusted: true)
        XCTAssertEqual(r.widget.status, .on)
        XCTAssertEqual(r.keys.active.count, 15)
        XCTAssertNil(r.widget.explanation)
        XCTAssertEqual(r.defaults.string(forKey: AccessibilityGrant.key), "build-1")

        r.keys.press(.rightHalf)
        _ = await r.widget.snapper.inFlight?.value
        XCTAssertEqual(r.driver.calls.first, .read(42))
        XCTAssertEqual(r.driver.calls[1], .position(CGPoint(x: 720, y: 25)))

        r.registry.setEnabled(WindowSnapWidget.widgetID, false)
        XCTAssertEqual(r.widget.status, .stopped)
        XCTAssertTrue(r.keys.active.isEmpty, "turning it off releases every shortcut")
    }

    func testAllowThenGrantRegisters() async {
        let r = rig(trusted: false)
        r.widget.requestAccess()
        XCTAssertEqual(r.trust.requests, 1)
        r.trust.trusted = true
        let on = await eventually { r.widget.status == .on }
        XCTAssertTrue(on)
        XCTAssertEqual(r.keys.active.count, 15)
        r.trust.trusted = false
        r.widget.recheckTrust()
        XCTAssertEqual(r.widget.status, .needsAccessibility)
        XCTAssertTrue(r.keys.active.isEmpty, "a revoked grant drops the shortcuts")
    }

    /// Fix round 1: the Settings window closing re-reads trust (`AccessibilityGate`).
    func testSettingsClosingRechecksTrust() async {
        let r = rig(trusted: false)
        r.trust.trusted = true
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled],
                                backing: .buffered, defer: true)
        settings.isReleasedWhenClosed = false
        settings.identifier = AppWindowID.settings
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settings)
        let on = await eventually { r.widget.status == .on }
        XCTAssertTrue(on)
        XCTAssertEqual(r.keys.active.count, 15)
        r.registry.setEnabled(WindowSnapWidget.widgetID, false)
    }

    func testTakenShortcutsAreReported() {
        let c = SnapTarget.center.defaultCombo.keyCode
        let r = rig(trusted: true, refused: [c])
        XCTAssertEqual(r.widget.taken, [.center])
        XCTAssertEqual(r.keys.active.count, 14)
        XCTAssertEqual(r.widget.takenNote?.contains("⌃⌥C"), true)
        r.keys.refused = []
        r.widget.retryShortcuts()
        XCTAssertEqual(r.widget.taken, [])
        XCTAssertEqual(r.keys.active.count, 15)
        XCTAssertNil(r.widget.takenNote)
    }

    func testGapIsSavedAndUsed() async {
        let r = rig(trusted: true)
        XCTAssertEqual(r.widget.gap, 0)
        r.widget.setGap(8)
        r.widget.setGap(5)   // not a preset: ignored
        XCTAssertEqual(r.widget.gap, 8)
        XCTAssertEqual(r.defaults.integer(forKey: SnapLayout.gapDefaultsKey), 8)
        r.keys.press(.maximize)
        _ = await r.widget.snapper.inFlight?.value
        XCTAssertEqual(r.driver.calls[1], .position(CGPoint(x: 8, y: 33)))
    }

    func testInertWidgetDoesNothing() {
        let w = WindowSnapWidget.inert()
        XCTAssertEqual(w.category, .power)
        XCTAssertNil(w.snapper.snap(.maximize), "no frontmost app in a smoke run")
        XCTAssertTrue(AppDelegate.buildViews(of: w))
    }
}
