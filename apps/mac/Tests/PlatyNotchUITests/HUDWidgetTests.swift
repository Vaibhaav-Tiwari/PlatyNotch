import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Stands in for the event tap: never creates one. Tests push keys through the router.
@MainActor
private final class FakeKeyTap: MediaKeyTapping {
    var refuse = false
    var starts = 0
    var stops = 0
    var router: MediaKeyRouter?

    func start(router: MediaKeyRouter) -> Bool {
        starts += 1
        guard !refuse else { return false }
        self.router = router
        return true
    }

    func stop() {
        stops += 1
        router = nil
    }

    /// What the real callback does after decoding: true = swallowed.
    func press(_ kind: MediaKeyKind, display: CGDirectDisplayID = 1, modifiers: MediaKeyModifiers = MediaKeyModifiers()) -> Bool {
        guard let router else { return false }   // no tap: the system gets the key
        return router.route(MediaKeyEvent(kind: kind, isDown: true, isRepeat: false), modifiers: modifiers, display: display)
    }
}

@MainActor
private final class FakeOutputVolume: VolumeControl {
    var settable = true
    var mutable = true
    var current = VolumeChange.State(volume: 0.5, muted: false)
    var failSet = false
    /// The device stores volume in coarser steps than asked (read back differs).
    var quantum: Float?
    var observing = false
    var onChange: (@MainActor () -> Void)?
    var outputName: String? = "Test Speakers"
    var canSetVolume: Bool { settable }
    var canMute: Bool { mutable }
    func state() -> VolumeChange.State? { current }
    var muteWriteFails = false
    /// Like `SystemVolume.set`: false only when the volume did not apply.
    func set(_ state: VolumeChange.State) -> Bool {
        guard !failSet else { return false }
        var s = state
        if let q = quantum { s.volume = (s.volume / q).rounded(.down) * q }
        if muteWriteFails { s.muted = current.muted }
        current = s
        return true
    }
    func startObserving(_ onChange: @escaping @MainActor () -> Void) { observing = true; self.onChange = onChange }
    func stopObserving() { observing = false; onChange = nil }
}

@MainActor
private final class FakeLevelControl: LevelControl {
    var isAvailable: Bool
    var value: Float = 0.25
    var controlledDisplay: CGDirectDisplayID?
    var failSet = false
    init(available: Bool, display: CGDirectDisplayID? = nil) {
        isAvailable = available
        controlledDisplay = display
    }
    func level() -> Float? { isAvailable ? value : nil }
    func setLevel(_ v: Float) -> Bool {
        guard !failSet else { return false }
        value = v
        return true
    }
}

@MainActor
final class HUDWidgetTests: DefaultsTestCase {



    @MainActor private final class Rig {
        let tap = FakeKeyTap()
        let volume = FakeOutputVolume()
        let brightness = FakeLevelControl(available: true, display: 1)
        let backlight = FakeLevelControl(available: false)
        var trusted = true
        var prompts = 0
        var taps = 0
        var registry: WidgetRegistry!
        var surfaces: PanelSurfaces!
        var widget: HUDWidget!
        var controllers: [NotchController] = []
        var sleeps = 0
    }

    /// A registry with the HUD widget and one panel per display in `displays`.
    private func rig(trusted: Bool = true, displays: [CGDirectDisplayID] = [1], identity: String = "dr:this-build") -> Rig {
        let r = Rig()
        r.trusted = trusted
        let client = CoreClient(socketPath: "/nonexistent")
        r.registry = WidgetRegistry(defaults: defaults(), persist: false)
        r.surfaces = PanelSurfaces(registry: r.registry)
        r.surfaces.defaultHUDDisplay = { 1 }
        r.widget = HUDWidget(
            makeTap: { [unowned r] in r.taps += 1; return r.tap },
            makeControls: { [unowned r] in HUDControls(volume: r.volume, brightness: r.brightness, backlight: r.backlight) },
            trust: AccessibilityTrust(isTrusted: { [unowned r] in r.trusted }, request: { [unowned r] in r.prompts += 1 }),
            identity: { identity },
            pollSleep: { [unowned r] in r.sleeps += 1; await Task.yield() })
        r.registry.register(r.widget)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnhud\(UUID().uuidString)")
        r.registry.start(context: WidgetContext(store: AppStore(), client: client,
                                                config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                                events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                                surfaces: r.surfaces, openPanel: { _ in }))
        for d in displays {
            let c = NotchController(store: AppStore(), client: client, plugins: [], widgets: r.registry, surfaces: r.surfaces)
            c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
            c.debugHandle(.display(d))
            r.controllers.append(c)
        }
        return r
    }

    /// Lets the main-queue hand-off from the router run.
    private func drain() async {
        await drainMainQueue()
    }

    func testOffByDefaultAndDoesNoWork() {
        let r = rig()
        XCTAssertFalse(r.widget.defaultEnabled)
        XCTAssertFalse(r.registry.isEnabled(HUDWidget.widgetID))
        XCTAssertEqual(r.taps, 0, "a disabled widget creates no tap")
        XCTAssertFalse(r.volume.observing, "and no CoreAudio listener")
        XCTAssertEqual(r.widget.status, .stopped)
        XCTAssertEqual(r.prompts, 0)
    }

    func testEnabledAndTrustedTakesVolumeKeysAndShowsOurHUD() async {
        let r = rig()
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertEqual(r.widget.status, .on)
        XCTAssertEqual(r.tap.starts, 1)
        XCTAssertTrue(r.volume.observing)
        XCTAssertEqual(r.prompts, 0, "enabling never prompts; only the Allow button does")

        XCTAssertTrue(r.tap.press(.volumeUp))
        await drain()
        XCTAssertEqual(r.volume.current, VolumeChange.State(volume: 0.5625, muted: false))
        XCTAssertEqual(r.controllers[0].mode, .peek(.hud(.volume)))

        XCTAssertTrue(r.tap.press(.brightnessDown, modifiers: MediaKeyModifiers(option: true, shift: true)))
        await drain()
        XCTAssertEqual(r.brightness.value, 0.234375, "⌥⇧: a quarter step")
        XCTAssertEqual(r.controllers[0].mode, .peek(.hud(.brightness)))
    }

    func testMuteShowsEmptyBar() async {
        let r = rig()
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertTrue(r.tap.press(.mute))
        await drain()
        XCTAssertTrue(r.volume.current.muted)
    }

    func testWithoutAccessibilityNoTapAndSystemHUD() {
        let r = rig(trusted: false)
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertEqual(r.widget.status, .needsAccessibility)
        XCTAssertEqual(r.taps, 0)
        XCTAssertFalse(r.tap.press(.volumeUp), "no tap: the system handles the key")
        XCTAssertEqual(r.volume.current.volume, 0.5)
        XCTAssertNotNil(r.widget.explanation, "Settings says why")
        XCTAssertEqual(r.prompts, 0)
        r.widget.requestAccess()
        XCTAssertEqual(r.prompts, 1, "the Allow button prompts")
    }

    func testTapRefusedPassesEverything() {
        let r = rig()
        r.tap.refuse = true
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertEqual(r.widget.status, .tapRefused)
        XCTAssertFalse(r.tap.press(.volumeUp))
        XCTAssertNotNil(r.widget.explanation)
        r.tap.refuse = false
        r.widget.retry()
        XCTAssertEqual(r.widget.status, .on)
        XCTAssertTrue(r.tap.press(.volumeUp))
    }

    func testPassesThroughWhenOurHUDWouldNotShow() async {
        let r = rig()
        r.registry.setEnabled(HUDWidget.widgetID, true)
        r.controllers[0].debugHandle(.setFullScreen(true))
        XCTAssertFalse(r.tap.press(.volumeUp), "full screen: the system HUD shows")
        r.controllers[0].debugHandle(.setFullScreen(false))
        r.controllers[0].debugHandle(.event(.ringStarted(id: "alarm")))
        XCTAssertFalse(r.tap.press(.volumeUp), "under a ringing card our HUD is dropped")
        r.controllers[0].debugHandle(.event(.ringStopped(id: "alarm")))
        XCTAssertFalse(r.tap.press(.volumeUp, display: 2), "no panel on the display under the cursor")
        await drain()
        XCTAssertEqual(r.volume.current.volume, 0.5, "nothing taken, nothing changed by us")
        r.controllers[0].debugHandle(.event(.approvalsChanged(count: 1)))
        XCTAssertFalse(r.tap.press(.volumeUp),
                       "under an approval only the 2 pt indicator could show: not enough feedback, the system HUD shows")
        r.controllers[0].debugHandle(.event(.approvalsChanged(count: 0)))
        r.controllers[0].debugHandle(.event(.click))
        XCTAssertFalse(r.tap.press(.volumeUp), "open panel: the same")
        await drain()
        XCTAssertEqual(r.volume.current.volume, 0.5)
        XCTAssertNil(r.controllers[0].hudIndicator)
    }

    func testBrightnessOnlyOnTheBuiltInDisplay() async {
        let r = rig(displays: [1, 2])
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertFalse(r.tap.press(.brightnessUp, display: 2), "cursor on the external display: its brightness is the system's")
        XCTAssertTrue(r.tap.press(.volumeUp, display: 2), "volume is not per display")
        XCTAssertTrue(r.tap.press(.brightnessUp, display: 1))
        await drain()
        XCTAssertEqual(r.brightness.value, 0.3125)
        XCTAssertEqual(r.controllers[0].mode, .peek(.hud(.brightness)))
    }

    func testHUDShowsTheLevelReadBack() async {
        let r = rig()
        r.volume.quantum = 0.1
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertTrue(r.tap.press(.volumeUp))
        await drain()
        XCTAssertEqual(r.controllers[0].hud?.level ?? -1, Double(r.volume.current.volume), accuracy: 1e-6,
                       "the HUD shows what the device kept, not what was asked")
        XCTAssertNotEqual(r.volume.current.volume, 0.5625)
    }

    func testFailedSetShowsNoHUDAndHandsTheKeyBack() async {
        let r = rig()
        r.registry.setEnabled(HUDWidget.widgetID, true)
        r.brightness.failSet = true   // reads still work: only the set fails
        XCTAssertTrue(r.tap.press(.brightnessUp), "the gate had not heard yet")
        await drain()
        XCTAssertEqual(r.controllers[0].mode, .compact, "nothing changed: no HUD claiming it did")
        XCTAssertFalse(r.tap.press(.brightnessUp), "the system gets every later press, though the level still reads")
        XCTAssertTrue(r.tap.press(.volumeUp), "other controls are unaffected")
        await drain()
        r.brightness.failSet = false
        XCTAssertFalse(r.tap.press(.brightnessUp), "still the system's until the displays change")
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(r.tap.press(.brightnessUp), "a screen change gives it another chance")
    }

    func testFailedVolumeSetWaitsForADeviceChange() async {
        let r = rig()
        r.registry.setEnabled(HUDWidget.widgetID, true)
        r.volume.failSet = true
        XCTAssertTrue(r.tap.press(.volumeDown))
        await drain()
        XCTAssertFalse(r.tap.press(.volumeDown))
        XCTAssertFalse(r.tap.press(.mute))
        r.volume.failSet = false
        r.volume.onChange?()   // a new default output
        XCTAssertTrue(r.tap.press(.volumeDown))
        r.registry.setEnabled(HUDWidget.widgetID, false)
        r.volume.failSet = true
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertTrue(r.tap.press(.volumeDown), "a restart starts clean")
    }

    func testFailedMuteWriteStillShowsTheReadBackState() async {
        let r = rig()
        r.volume.muteWriteFails = true
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertTrue(r.tap.press(.mute))
        await drain()
        XCTAssertFalse(r.volume.current.muted, "the device refused the mute")
        XCTAssertEqual(r.controllers[0].mode, .peek(.hud(.volume)))
        XCTAssertEqual(r.controllers[0].hud?.level ?? -1, 0.5, accuracy: 1e-6, "shows what the device has: not muted")
        XCTAssertTrue(r.tap.press(.volumeUp), "the volume still works, so the keys stay ours")
    }

    func testUnavailableControlsPassThrough() {
        let r = rig()
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertFalse(r.tap.press(.backlightUp), "no backlit keyboard")
        XCTAssertNotNil(r.widget.unavailableNote)
        r.volume.mutable = false
        r.volume.onChange?()   // default output changed to one muted per channel only
        XCTAssertFalse(r.tap.press(.mute), "no settable main mute")
        XCTAssertFalse(r.tap.press(.volumeUp), "volume up could not unmute it, and our HUD could not tell")
        r.volume.mutable = true
        r.volume.settable = false
        r.volume.onChange?()   // e.g. HDMI: no volume control
        XCTAssertFalse(r.tap.press(.volumeUp))
    }

    // MARK: - The tap thread (a plain mach port; no event tap)

    func testTapThreadStopsAndJoinsBeforeReturning() {
        guard let port = CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return XCTFail("no mach port")
        }
        let loop = TapThreadLoop()
        final class Flag: @unchecked Sendable { var onTapThread = false }
        let flag = Flag()
        loop.run(source: source) { flag.onTapThread = !Thread.isMainThread }
        XCTAssertTrue(flag.onTapThread, "the source lives on its own thread, not the main run loop")
        XCTAssertFalse(loop.hasExited)
        loop.stop(removing: source)
        XCTAssertTrue(loop.hasExited, "stop returns only after the thread left its run loop (then the box may be freed)")
        CFMachPortInvalidate(port)
    }

    // MARK: - Liveness (injectable clock, held main-queue posts)

    func testRouterPassesKeysWhileMainIsBehind() {
        final class Clock: @unchecked Sendable { var t: TimeInterval = 100 }
        final class Posts: @unchecked Sendable { var queue: [@Sendable () -> Void] = [] }
        let clock = Clock()
        let posts = Posts()
        var ran: [MediaKeyKind] = []
        let router = MediaKeyRouter(now: { clock.t }, toMain: { posts.queue.append($0) },
                                    onMain: { action, _ in MainActor.assumeIsolated { ran.append(action.kind) } })
        router.update {
            $0.active = true
            $0.available = MediaKeyKind.handled
            $0.readyDisplays = [1]
            $0.brightnessDisplay = 1
        }
        func press(_ k: MediaKeyKind) -> Bool {
            router.route(MediaKeyEvent(kind: k, isDown: true, isRepeat: false), modifiers: MediaKeyModifiers(), display: 1)
        }
        XCTAssertTrue(press(.volumeUp))
        clock.t += 0.2
        XCTAssertTrue(press(.volumeDown), "main 200 ms behind: still ours")
        clock.t += 0.1
        XCTAssertFalse(press(.volumeUp), "oldest hand-off 300 ms old: the app is hung, the system takes the key")
        XCTAssertEqual(router.gateSnapshot.pendingHandOffs, 2)
        for p in posts.queue { p() }   // main recovers
        posts.queue = []
        XCTAssertEqual(ran, [.volumeUp, .volumeDown], "in order, and the passed key was never applied by us")
        XCTAssertEqual(router.gateSnapshot.pendingHandOffs, 0)
        XCTAssertTrue(press(.volumeUp), "caught up: ours again")
    }

    func testDisableTearsDownEverything() {
        let r = rig()
        r.registry.setEnabled(HUDWidget.widgetID, true)
        let router = r.tap.router
        r.registry.setEnabled(HUDWidget.widgetID, false)
        XCTAssertEqual(r.tap.stops, 1)
        XCTAssertFalse(r.volume.observing)
        XCTAssertEqual(r.widget.status, .stopped)
        XCTAssertEqual(router?.gateSnapshot.active, false, "a stray callback passes everything")
        XCTAssertEqual(router?.route(MediaKeyEvent(kind: .volumeUp, isDown: true, isRepeat: false),
                                     modifiers: MediaKeyModifiers(), display: 1), false)
    }

    func testRevokedAccessibilityDropsTheTap() async {
        let r = rig()
        r.registry.setEnabled(HUDWidget.widgetID, true)
        r.trusted = false
        r.widget.trustMayHaveChanged()   // what the "com.apple.accessibility.api" notification calls
        for _ in 0..<30 where r.widget.status == .on { try? await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(r.widget.status, .needsAccessibility)
        XCTAssertEqual(r.tap.stops, 1)
        XCTAssertFalse(r.tap.press(.volumeUp))
    }

    // MARK: - HUD target display (Task 1b deferred: true only if the target display shows it)

    func testHUDGoesOnlyToTheTargetDisplay() {
        let r = rig(displays: [1, 2])
        XCTAssertTrue(r.surfaces.showHUD(kind: .volume, level: 0.3, display: 2))
        XCTAssertEqual(r.controllers[1].mode, .peek(.hud(.volume)))
        XCTAssertEqual(r.controllers[0].mode, .compact, "the other display's panel does not get it")
        XCTAssertFalse(r.surfaces.showHUD(kind: .volume, level: 0.3, display: 3), "no panel on display 3")
        r.controllers[1].debugHandle(.setFullScreen(true))
        XCTAssertFalse(r.surfaces.showHUD(kind: .volume, level: 0.3, display: 2),
                       "full screen on the target: false even though display 1 could show it")
        XCTAssertEqual(r.surfaces.hudReadiness, HUDReadiness(displays: [1]))
    }

    // MARK: - Feedback 7: "Allow Accessibility" stays after allowing

    /// A first-time user (no grant ever seen) is never told "rebuilt", and nothing appears
    /// on a timer: only after Allow and coming back does the conditional advice show.
    func testFirstTimeUserGetsConditionalAdviceOnlyAfterComingBack() async {
        let r = rig(trusted: false)
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertEqual(r.widget.advice, .none, "not before Allow")
        r.widget.requestAccess()
        for _ in 0..<5 { r.widget.recheckTrust() }
        XCTAssertEqual(r.widget.advice, .none, "still finding the switch: no advice, however long")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        let shown = await eventually { r.widget.advice == .maybeStale }
        XCTAssertTrue(shown)
        let text = r.widget.explanation ?? ""
        XCTAssertTrue(text.contains(PermissionAdvice.accessibilityMaybeStale), text)
        XCTAssertFalse(text.contains("rebuilt"), text)
        r.registry.setEnabled(HUDWidget.widgetID, false)
    }

    /// Coming back without having clicked Allow adds nothing.
    func testComingBackWithoutAllowAddsNothing() async {
        let r = rig(trusted: false)
        r.registry.setEnabled(HUDWidget.widgetID, true)
        r.widget.userReturned()
        r.widget.recheckTrust()
        XCTAssertEqual(r.widget.advice, .none)
        r.registry.setEnabled(HUDWidget.widgetID, false)
    }

    /// Trust seen for this very build, then lost: conditional advice after Allow and back.
    func testThisBuildGrantLostGetsConditionalAdvice() {
        defaults().set("dr:this-build", forKey: AccessibilityGrant.key)
        let r = rig(trusted: false, identity: "dr:this-build")
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertEqual(r.widget.advice, .none)
        r.widget.requestAccess()
        r.widget.userReturned()
        r.widget.recheckTrust()
        XCTAssertEqual(r.widget.advice, .maybeStale)
        r.registry.setEnabled(HUDWidget.widgetID, false)
    }

    /// Trust once seen for another build: the definite "rebuilt" text at once, before any click.
    func testGrantForAnotherBuildIsExplainedAtOnce() {
        defaults().set("dr:old-build", forKey: AccessibilityGrant.key)
        let r = rig(trusted: false, identity: "dr:new-build")
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertEqual(r.widget.advice, .rebuilt)
        XCTAssertTrue(r.widget.explanation?.contains(PermissionAdvice.accessibilityRebuilt) == true,
                      r.widget.explanation ?? "")
        r.registry.setEnabled(HUDWidget.widgetID, false)
    }

    /// A working grant is stamped with this build, so a later rebuild can be recognised.
    func testTrustIsStampedWithThisBuild() {
        let r = rig(trusted: true, identity: "dr:this-build")
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertEqual(defaults().string(forKey: AccessibilityGrant.key), "dr:this-build")
        r.registry.setEnabled(HUDWidget.widgetID, false)
    }

    /// Coming back to PlatyNotch, or the Settings window closing, re-reads trust.
    func testBecomingActiveAndSettingsClosingRecheckTrust() async {
        let r = rig(trusted: false)
        r.registry.setEnabled(HUDWidget.widgetID, true)
        r.trusted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        let on = await eventually { r.widget.status == .on }
        XCTAssertTrue(on)
        r.trusted = false
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled],
                                backing: .buffered, defer: true)
        settings.isReleasedWhenClosed = false
        settings.identifier = AppWindowID.settings
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settings)
        let off = await eventually { r.widget.status == .needsAccessibility }
        XCTAssertTrue(off)
        r.registry.setEnabled(HUDWidget.widgetID, false)
    }

    /// Only the Settings and onboarding windows count; panels, pickers and alerts do not.
    func testOnlySettingsLikeWindowsCount() {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        XCTAssertFalse(AppWindowID.isSettingsLike(w))
        XCTAssertFalse(AppWindowID.isSettingsLike(nil))
        w.identifier = AppWindowID.onboarding
        XCTAssertTrue(AppWindowID.isSettingsLike(w))
        w.identifier = AppWindowID.settings
        XCTAssertTrue(AppWindowID.isSettingsLike(w))
        w.identifier = NSUserInterfaceItemIdentifier("dev.platynotch.clip-picker")
        XCTAssertFalse(AppWindowID.isSettingsLike(w))
    }

    /// The Allow UI's poll reads trust only while its window is really on screen, and
    /// ends by itself once trusted.
    func testPollReadsTrustOnlyWhileTheWindowIsOnScreen() async {
        let r = rig(trusted: false)
        r.registry.setEnabled(HUDWidget.widgetID, true)
        var onScreen = false
        let watch = Task { await r.widget.watchTrustWhileVisible(isOnScreen: { onScreen }) }
        r.trusted = true
        let polled = await eventually { r.sleeps >= 5 }
        XCTAssertTrue(polled)
        XCTAssertEqual(r.widget.status, .needsAccessibility, "covered or hidden window: no reads")
        onScreen = true
        let on = await eventually { r.widget.status == .on }
        XCTAssertTrue(on)
        await watch.value   // returns by itself once trusted
        r.registry.setEnabled(HUDWidget.widgetID, false)
    }

    func testOnScreenNeedsVisibleAndUncovered() {
        XCTAssertTrue(WindowProbe.isOnScreen(visible: true, occlusion: .visible))
        XCTAssertFalse(WindowProbe.isOnScreen(visible: true, occlusion: []))
        XCTAssertFalse(WindowProbe.isOnScreen(visible: false, occlusion: .visible))
        XCTAssertFalse(WindowProbe.isOnScreen(nil))
    }
}
