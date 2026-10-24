import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// A widget that supplies a peek, a ringing card, a HUD and a drop zone.
@MainActor
private final class SurfaceWidget: NotchWidget {
    let id = "fake"
    let title = "Fake"
    let systemImage = "star"
    let defaultEnabled = true
    var context: WidgetContext?

    func start(context: WidgetContext) { self.context = context }
    func tileView() -> AnyView { AnyView(Text(verbatim: "tile")) }
    func peekView(id: String) -> AnyView? {
        id.hasPrefix("fake.") ? AnyView(Text(verbatim: "peek \(id)").frame(width: 200, height: 40)) : nil
    }
    func hudView(kind: HUDKind, level: Double) -> AnyView? {
        kind == .volume ? AnyView(Text(verbatim: "vol \(level)")) : nil
    }
    func dropZoneView() -> AnyView? { AnyView(Text(verbatim: "drop")) }
}

/// Drives each transient surface through `WidgetContext` → `PanelSurfaces` → `NotchController`
/// without a window (no `attach`), and builds every surface view off screen.
@MainActor
final class PanelSurfacesTests: DefaultsTestCase {



    @MainActor private struct Rig {
        let surfaces: PanelSurfaces
        let registry: WidgetRegistry
        let widget: SurfaceWidget
        let controller: NotchController
        var context: WidgetContext { widget.context! }
    }

    private func rig(minimal: Bool = false) -> Rig {
        let client = CoreClient(socketPath: "/nonexistent")
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let surfaces = PanelSurfaces(registry: registry)
        let w = SurfaceWidget()
        registry.register(w)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnsurf\(UUID().uuidString)")
        registry.start(context: WidgetContext(store: AppStore(), client: client,
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              surfaces: surfaces, openPanel: { _ in }))
        let c = NotchController(store: AppStore(), client: client, plugins: [], widgets: registry,
                                surfaces: surfaces, appearance: AppearanceSettings(mode: minimal ? .minimal : .alwaysOn))
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        return Rig(surfaces: surfaces, registry: registry, widget: w, controller: c)
    }

    func testPeekThroughContextAndEnd() {
        let r = rig()
        XCTAssertTrue(r.context.peek(id: "fake.water", until: Date().addingTimeInterval(60)))
        XCTAssertEqual(r.controller.mode, .peek(.widget(id: "fake.water")))
        r.context.endPeek(id: "fake.water")
        XCTAssertEqual(r.controller.mode, .compact)
    }

    func testPeekWithoutAViewIsRefused() {
        let r = rig()
        XCTAssertFalse(r.context.peek(id: "other.thing", until: Date().addingTimeInterval(60)))
        XCTAssertFalse(r.context.ring(id: "other.alarm", title: "Other"))
        XCTAssertEqual(r.controller.mode, .compact)
    }

    func testPeekExpiresOnItsOwn() async {
        let r = rig()
        r.context.peek(id: "fake.short", until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(r.controller.mode, .peek(.widget(id: "fake.short")))
        let expired = await eventually { r.controller.mode == .compact }
        XCTAssertTrue(expired, "the peek ends at its until without any other event")
    }

    func testRingingSharedAndStopped() {
        let r = rig()
        XCTAssertTrue(r.context.ring(id: "fake.alarm", title: "Alarm 7:30"))
        XCTAssertEqual(r.controller.mode, .peek(.ringing(id: "fake.alarm")))
        XCTAssertEqual(r.surfaces.rings, [RingingItem(id: "fake.alarm", title: "Alarm 7:30")])
        XCTAssertEqual(r.context.ringing, ["fake.alarm"])
        XCTAssertEqual(r.surfaces.ringing, ["fake.alarm"])
        r.context.stopRinging(id: "fake.alarm")
        XCTAssertEqual(r.controller.mode, .compact)
        XCTAssertTrue(r.context.ringing.isEmpty)
    }

    func testHUDReportsWhetherShown() {
        let r = rig()
        XCTAssertTrue(r.context.showHUD(kind: .volume, level: 0.4))
        XCTAssertEqual(r.controller.mode, .peek(.hud(.volume)))
        r.controller.debugHandle(.setFullScreen(true))
        XCTAssertFalse(r.context.showHUD(kind: .volume, level: 0.5), "over full screen the system HUD should show instead")
        r.controller.debugHandle(.setFullScreen(false))
        r.context.ring(id: "fake.alarm", title: "Alarm 7:30")
        XCTAssertFalse(r.context.showHUD(kind: .volume, level: 0.5), "under the ringing card the HUD is dropped")
    }

    func testHUDDuringApprovalIsIndicator() {
        let r = rig()
        r.controller.debugHandle(.event(.approvalsChanged(count: 1)))
        XCTAssertTrue(r.context.showHUD(kind: .brightness, level: 0.4))
        XCTAssertEqual(r.controller.mode, .peek(.approval))
        XCTAssertEqual(r.controller.hudIndicator?.kind, .brightness)
    }

    private var mbpLayout: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }

    func testDragSessionExpandsOnlyNearTheNotch() {
        let r = rig()
        r.controller.debugHandle(.layout(mbpLayout))
        r.controller.mouseDown = { true }
        r.context.dragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(r.controller.mode, .compact, "a drag far from the notch changes nothing")
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        r.controller.dragMoved(to: CGPoint(x: 756, y: 700))   // inside the drop zone
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        r.controller.dragMoved(to: CGPoint(x: 100, y: 100))   // left it
        XCTAssertEqual(r.controller.mode, .compact)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        r.controller.cursorLocation = { CGPoint(x: 100, y: 100) }   // the drag ended off the zone
        r.context.dragSession(active: false)
        XCTAssertEqual(r.controller.mode, .compact)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .compact, "no drag session: no drop zone")
    }

    /// Fix round 1: a stuck drag session (mouse already up) never opens the drop zone on hover.
    func testDragNeedsTheMouseButtonDown() {
        let r = rig()
        r.controller.debugHandle(.layout(mbpLayout))
        var down = true
        r.controller.mouseDown = { down }
        r.context.dragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        down = false
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        // Released on the zone: it waits for the drop (Task 5 fix round 1), then closes.
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        r.controller.panelDragEnded()
        XCTAssertEqual(r.controller.mode, .compact, "button released: the drop zone closes")
        r.controller.dragMoved(to: CGPoint(x: 756, y: 960))
        XCTAssertEqual(r.controller.mode, .compact, "hovering with the button up never opens it")
    }

    /// Fix round 1: turning a widget off mid-peek or mid-ring drops its surface.
    func testDisablingAWidgetDropsItsPeekAndRing() async {
        let r = rig()
        r.context.peek(id: "fake.water", until: Date().addingTimeInterval(60))
        r.context.ring(id: "fake.alarm", title: "Alarm")
        r.registry.setEnabled("fake", false)
        await Task.yield()
        XCTAssertTrue(r.surfaces.ringing.isEmpty)
        XCTAssertEqual(r.controller.mode, .compact, "no blank peek or ringing card")
    }

    /// Fix round 1: "Open PlatyNotch" works while ringing (header chip) and over the drop zone.
    func testExpandWhileRingingShowsPanelWithChip() {
        let r = rig()
        r.context.ring(id: "fake.alarm", title: "Alarm 7:30")
        r.controller.expand()
        XCTAssertEqual(r.controller.mode, .expanded)
        XCTAssertEqual(r.controller.ringingChip, RingingItem(id: "fake.alarm", title: "Alarm 7:30"))
        r.context.stopRinging(id: "fake.alarm")
        XCTAssertNil(r.controller.ringingChip)

        r.controller.debugHandle(.layout(mbpLayout))
        r.controller.mouseDown = { true }
        r.controller.debugHandle(.event(.click))   // close
        r.context.dragSession(active: true)
        r.controller.dragMoved(to: CGPoint(x: 756, y: 940))
        XCTAssertEqual(r.controller.mode, .peek(.drop))
        r.controller.expand()
        XCTAssertEqual(r.controller.mode, .expanded)
    }

    /// Fix round 1: after a peek / ringing card / drop zone ends with the cursor on the
    /// pill, hovering opens the panel (the debouncer does not think it is still hovering).
    func testHoverOpensAfterANonOpeningSurfaceEnds() {
        let r = rig()
        r.context.peek(id: "fake.water", until: Date().addingTimeInterval(60))
        r.controller.hoverSample(inside: true, at: 0)
        r.controller.hoverSample(inside: true, at: 1)
        XCTAssertEqual(r.controller.mode, .peek(.widget(id: "fake.water")), "hovering a peek does not open")
        r.context.endPeek(id: "fake.water")
        r.controller.hoverSample(inside: true, at: 2)
        r.controller.hoverSample(inside: true, at: 3)
        XCTAssertEqual(r.controller.mode, .expanded)
    }

    func testMenuStopItemsFollowRinging() {
        XCTAssertTrue(MenuBarController.stopItems([]).isEmpty)
        let items = MenuBarController.stopItems([RingingItem(id: "a", title: "Alarm 7:30"),
                                                  RingingItem(id: "b", title: "Tea timer")])
        XCTAssertEqual(items.map(\.title), ["Stop Alarm 7:30", "Stop Tea timer"])
        XCTAssertEqual(items.map(\.id), ["a", "b"])
    }

    func testNewControllerGetsRingingAndPeekReplayed() {
        let r = rig()
        r.context.ring(id: "fake.alarm", title: "Alarm 7:30")
        let late = NotchController(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"), plugins: [],
                                   widgets: r.registry, surfaces: r.surfaces, appearance: AppearanceSettings(mode: .minimal))
        XCTAssertEqual(late.mode, .peek(.ringing(id: "fake.alarm")))
        late.detach()
        r.context.stopRinging(id: "fake.alarm")
        XCTAssertEqual(late.mode, .peek(.ringing(id: "fake.alarm")), "a detached controller gets nothing")
    }

    /// The smoke sequence (also run by `--smoke` on the real panel).
    func testSmokeSequence() {
        let r = rig()
        XCTAssertNil(r.controller.runSurfaceSmoke())
        XCTAssertEqual(r.controller.mode, .compact, "smoke leaves the panel as it found it")
    }

    func testSurfaceViewsBuild() {
        let r = rig()
        let views: [AnyView] = [
            r.registry.peekView(id: "fake.water")!,
            r.registry.hudView(kind: .volume, level: 0.3)!,
            r.registry.dropZoneView()!,
            AnyView(HUDBar(state: HUDState(kind: .keyboardBacklight, level: 0.5, until: Date()))),
            AnyView(HUDIndicator(state: HUDState(kind: .volume, level: 0.5, until: Date()))),
            AnyView(DropZonePlaceholder()),
            AnyView(RingingFallback(id: "x", onStop: {})),
            AnyView(RingingChip(item: RingingItem(id: "x", title: "Alarm"), onStop: {})),
        ]
        for v in views {
            let host = NSHostingView(rootView: v.frame(width: 380).environment(\.colorScheme, .dark))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
        }
        XCTAssertNil(r.registry.hudView(kind: .brightness, level: 0.3), "no widget view: the panel draws HUDBar")
        r.registry.setEnabled("fake", false)
        XCTAssertNil(r.registry.peekView(id: "fake.water"), "a stopped widget supplies nothing")
    }

    // MARK: - Task 1b carry items

    func testNowPlayingIgnoresUpdatesWhenNotStarted() {
        let np = NowPlaying()
        np.update(NowPlayingInfo(bundleIdentifier: "com.spotify.client", title: "Song", isPlaying: true))
        XCTAssertNil(np.info, "a late adapter or poll result after stop must not resurrect the pill")
        XCTAssertFalse(np.isPlaying)
    }

    func testMusicBarsStillUnlessTickingAndMotionAllowed() {
        XCTAssertTrue(MusicBars.animates(ticking: true, reduceMotion: false))
        XCTAssertFalse(MusicBars.animates(ticking: false, reduceMotion: false))
        XCTAssertFalse(MusicBars.animates(ticking: true, reduceMotion: true))
        XCTAssertEqual(MusicBars.heights(at: nil), MusicBars.heights(at: nil))
        XCTAssertEqual(MusicBars.heights(at: nil).count, 3)
        XCTAssertNotEqual(MusicBars.heights(at: 0.1), MusicBars.heights(at: 0.4))
    }
}
