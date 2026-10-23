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
    var observing = false
    var onChange: (@MainActor () -> Void)?
    var outputName: String? = "Test Speakers"
    var canSetVolume: Bool { settable }
    var canMute: Bool { mutable }
    func state() -> VolumeChange.State? { current }
    func set(_ state: VolumeChange.State) -> Bool { current = state; return true }
    func startObserving(_ onChange: @escaping @MainActor () -> Void) { observing = true; self.onChange = onChange }
    func stopObserving() { observing = false; onChange = nil }
}

@MainActor
private final class FakeLevelControl: LevelControl {
    var isAvailable: Bool
    var value: Float = 0.25
    init(available: Bool) { isAvailable = available }
    func level() -> Float? { isAvailable ? value : nil }
    func setLevel(_ v: Float) -> Bool { value = v; return true }
}

@MainActor
final class HUDWidgetTests: XCTestCase {
    nonisolated(unsafe) private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "HUDWidgetTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    @MainActor private final class Rig {
        let tap = FakeKeyTap()
        let volume = FakeOutputVolume()
        let brightness = FakeLevelControl(available: true)
        let backlight = FakeLevelControl(available: false)
        var trusted = true
        var prompts = 0
        var taps = 0
        var registry: WidgetRegistry!
        var surfaces: PanelSurfaces!
        var widget: HUDWidget!
        var controllers: [NotchController] = []
    }

    /// A registry with the HUD widget and one panel per display in `displays`.
    private func rig(trusted: Bool = true, displays: [CGDirectDisplayID] = [1]) -> Rig {
        let r = Rig()
        r.trusted = trusted
        let client = CoreClient(socketPath: "/nonexistent")
        r.registry = WidgetRegistry(defaults: defaults(), persist: false)
        r.surfaces = PanelSurfaces(registry: r.registry)
        r.surfaces.defaultHUDDisplay = { 1 }
        r.widget = HUDWidget(
            makeTap: { [unowned r] in r.taps += 1; return r.tap },
            makeControls: { [unowned r] in HUDControls(volume: r.volume, brightness: r.brightness, backlight: r.backlight) },
            trust: AccessibilityTrust(isTrusted: { [unowned r] in r.trusted }, request: { [unowned r] in r.prompts += 1 }))
        r.registry.register(r.widget)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnhud\(UUID().uuidString)")
        r.registry.start(context: WidgetContext(store: AppStore(), client: client,
                                                config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                                events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                                surfaces: r.surfaces, openPanel: { _ in }))
        for d in displays {
            let c = NotchController(store: AppStore(), client: client, plugins: [], widgets: r.registry, surfaces: r.surfaces)
            c.debugHandle(.display(d))
            r.controllers.append(c)
        }
        return r
    }

    /// Lets the main-queue hand-off from the router run.
    private func drain() async {
        try? await Task.sleep(for: .milliseconds(50))
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
        XCTAssertTrue(r.tap.press(.volumeUp), "under an approval the HUD is the 2 pt indicator: still ours")
        await drain()
        XCTAssertEqual(r.controllers[0].mode, .peek(.approval))
        XCTAssertEqual(r.controllers[0].hudIndicator?.kind, .volume)
    }

    func testUnavailableControlsPassThrough() {
        let r = rig()
        r.volume.mutable = false
        r.registry.setEnabled(HUDWidget.widgetID, true)
        XCTAssertFalse(r.tap.press(.backlightUp), "no backlit keyboard")
        XCTAssertFalse(r.tap.press(.mute), "no settable mute on this output")
        XCTAssertNotNil(r.widget.unavailableNote)
        r.volume.settable = false
        r.volume.onChange?()   // default output changed (e.g. to HDMI)
        XCTAssertFalse(r.tap.press(.volumeUp))
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
}
