import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// A widget publishing whatever live activities a test sets.
@MainActor
private final class LiveFake: NotchWidget {
    let id = "livefake"
    let title = "Live"
    let systemImage = "star"
    let defaultEnabled = true
    var live: [LiveActivity] = []
    var liveActivities: [LiveActivity] { live }
    func tileView() -> AnyView { AnyView(EmptyView()) }
}

/// Phase 3 fix round 1: the controller's wiring of the pill content and the hover peek,
/// through its seams (no window, never the real mouse).
@MainActor
final class NotchControllerWiringTests: DefaultsTestCase {
    private var mbpLayout: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }

    private struct Rig {
        let controller: NotchController
        let store: AppStore
        let widget: LiveFake
    }

    private func rig(_ appearance: AppearanceSettings) -> Rig {
        let client = CoreClient(socketPath: "/nonexistent")
        let store = AppStore()
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let surfaces = PanelSurfaces(registry: registry)
        let w = LiveFake()
        registry.register(w)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnwire\(UUID().uuidString)")
        registry.start(context: WidgetContext(store: store, client: client,
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              surfaces: surfaces, openPanel: { _ in }))
        let c = NotchController(store: store, client: client, plugins: [], widgets: registry, surfaces: surfaces,
                                appearance: appearance)
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        c.debugHandle(.layout(mbpLayout))
        return Rig(controller: c, store: store, widget: w)
    }

    private func session(_ state: SessionState) -> Session {
        let t = Date()
        return Session(key: "a", agent: "claude-code", agentName: "Claude Code", sessionID: "a", state: state,
                       startedAt: t, updatedAt: t)
    }

    /// Appearance › Open on: Peek on hover → hovering the pill shows the hover peek.
    func testPeekOnHoverSettingReachesTheMachine() {
        let r = rig(AppearanceSettings(openOn: .peekOnHover))
        r.controller.hoverSample(inside: true, at: 0)
        r.controller.hoverSample(inside: true, at: 1)
        XCTAssertEqual(r.controller.mode, .peek(.hover))
        r.controller.hoverSample(inside: false, at: 2)
        r.controller.hoverSample(inside: false, at: 3)
        XCTAssertEqual(r.controller.mode, .compact)
    }

    /// A ring over the hover peek hands the peek back when it stops; the debouncer must
    /// still count the cursor as hovering it, so moving away closes it (Phase 3 review:
    /// the reset counts `.peek(.hover)` as hovering, not only `.expanded`).
    func testRingOverHoverPeekThenLeaveCollapses() {
        let r = rig(AppearanceSettings(openOn: .peekOnHover))
        r.controller.hoverSample(inside: true, at: 0)
        r.controller.hoverSample(inside: true, at: 1)
        XCTAssertEqual(r.controller.mode, .peek(.hover))
        r.controller.receive(.ring(id: "wire.ring"))
        XCTAssertEqual(r.controller.mode, .peek(.ringing(id: "wire.ring")))
        r.controller.receive(.stopRinging(id: "wire.ring"))
        XCTAssertEqual(r.controller.mode, .peek(.hover))
        r.controller.hoverSample(inside: false, at: 2)
        r.controller.hoverSample(inside: false, at: 3)
        XCTAssertEqual(r.controller.mode, .compact)
    }

    /// Changing Open on while running reaches the machine too.
    func testPeekOnHoverAppliesLive() {
        let r = rig(AppearanceSettings())
        r.controller.appearance = AppearanceSettings(openOn: .peekOnHover)
        r.controller.hoverSample(inside: true, at: 0)
        r.controller.hoverSample(inside: true, at: 1)
        XCTAssertEqual(r.controller.mode, .peek(.hover))
    }

    /// Minimal mode stays up for a session waiting for you (`PillContent.keepsMinimalUp`).
    func testMinimalStaysUpForAWaitingSession() throws {
        let r = rig(AppearanceSettings(mode: .minimal))
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.mode, .hidden)
        try r.store.apply(Envelope.make(.snapshot, Snapshot(sessions: [session(.waitingInput)])))
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.mode, .compact)
    }

    /// An ambient activity alone never keeps Minimal up.
    func testMinimalHidesWithOnlyAmbient() {
        let r = rig(AppearanceSettings(mode: .minimal))
        r.widget.live = [LiveActivity(id: "shelf", widgetID: "livefake", priority: LivePriority.shelfItems,
                                      glyph: .symbol("tray"))]
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.mode, .hidden)
        r.widget.live = [LiveActivity(id: "music", widgetID: "livefake", priority: LivePriority.musicPlaying,
                                      glyph: .musicBars)]
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.mode, .compact, "a live item keeps it up")
    }
}
