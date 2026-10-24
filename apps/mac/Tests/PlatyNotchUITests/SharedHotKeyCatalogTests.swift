import AppKit
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Final review M1: window snapping and the basket switcher claim their shortcuts in the
/// app's one runtime catalog (`WidgetContext.hotKeys`), so a clash between them is named
/// ("used by Baskets") instead of being blamed on another app.
@MainActor
final class SharedHotKeyCatalogTests: DefaultsTestCase {
    private final class Reg: HotKeyRegistration {
        var active = true
        func unregister() { active = false }
    }

    private var regs: [Reg] = []

    private func make(_ keyCode: UInt32, _ modifiers: UInt32, _ handler: @escaping @MainActor () -> Void) -> HotKeyRegistration? {
        let r = Reg()
        regs.append(r)
        return r
    }

    private func start(catalog: SharedHotKeyCatalog) -> (WidgetRegistry, WindowSnapWidget, BasketsWidget) {
        let maker: HotKeyMaker = { [unowned self] k, m, h in self.make(k, m, h) }
        let snap = WindowSnapWidget(
            snapper: WindowSnapper(driver: NoSnapWindowDriver(), displays: { SnapDisplays(screens: [], primaryHeight: 0) },
                                   frontmost: { nil }),
            makeHotKey: maker, trust: AccessibilityTrust(isTrusted: { true }, request: {}),
            identity: { "build-1" }, pollSleep: {}, allowSleep: {})
        let baskets = BasketsWidget(directory: URL(fileURLWithPath: "/nonexistent/baskets.noindex"), persist: false,
                                    system: NoBasketSystem(), makeHotKey: maker)
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(snap)
        registry.register(baskets)
        registry.setEnabled(WindowSnapWidget.widgetID, true)
        registry.setEnabled(BasketsWidget.widgetID, true)
        registry.start(context: WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                              config: ConfigFileStore(url: URL(fileURLWithPath: "/nonexistent/config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              hotKeys: catalog, openPanel: { _ in }))
        return (registry, snap, baskets)
    }

    func testSnapAndBasketsShareTheAppCatalog() {
        let catalog = SharedHotKeyCatalog()
        let (registry, snap, baskets) = start(catalog: catalog)
        XCTAssertEqual(snap.status, .on)
        XCTAssertTrue(baskets.controller.holdsSwitcher)
        // Every shortcut each feature holds is in the one catalog.
        for t in SnapTarget.allCases {
            XCTAssertEqual(catalog.catalog.combo(for: t.hotKeyFeature), t.defaultCombo)
        }
        XCTAssertEqual(catalog.catalog.combo(for: BasketSettings.switcherFeature), BasketSettings.switcherPresets[0])
        XCTAssertEqual(catalog.catalog.assignments.count, SnapTarget.allCases.count + 1)
        XCTAssertTrue(snap.taken.isEmpty)
        XCTAssertFalse(baskets.controller.switcherTaken)

        // Turned off: each releases its own claims.
        registry.setEnabled(BasketsWidget.widgetID, false)
        XCTAssertNil(catalog.catalog.combo(for: BasketSettings.switcherFeature))
        XCTAssertEqual(catalog.catalog.assignments.count, SnapTarget.allCases.count)
        registry.setEnabled(WindowSnapWidget.widgetID, false)
        XCTAssertTrue(catalog.catalog.assignments.isEmpty)
    }

    func testAClashBetweenFeaturesIsNamed() {
        let catalog = SharedHotKeyCatalog()
        // Forced: the basket switcher's default held by window snapping, and snapping's
        // Center held by baskets (ids of their own, as a future shortcut of each would be).
        catalog.claim(BasketSettings.switcherPresets[0], for: "snap.forced")
        catalog.claim(SnapTarget.center.defaultCombo, for: "baskets.forced")
        let (registry, snap, baskets) = start(catalog: catalog)
        defer {
            registry.setEnabled(WindowSnapWidget.widgetID, false)
            registry.setEnabled(BasketsWidget.widgetID, false)
        }

        XCTAssertEqual(snap.taken, [.center])
        XCTAssertEqual(snap.usedBy, [.center: "Baskets"])
        let note = snap.takenNote ?? ""
        XCTAssertTrue(note.contains("used by Baskets"), note)
        XCTAssertFalse(note.contains("another app"), note)

        XCTAssertTrue(baskets.controller.switcherTaken)
        XCTAssertEqual(baskets.controller.switcherUsedBy, "Window snapping")
        let basketNote = BasketsSettingsView.takenNote(BasketSettings.switcherPresets[0],
                                                       usedBy: baskets.controller.switcherUsedBy)
        XCTAssertTrue(basketNote.contains("used by Window snapping"), basketNote)
        XCTAssertEqual(BasketsSettingsView.takenNote(BasketSettings.switcherPresets[0], usedBy: nil),
                       "⌃⌥B is taken by another app. Choose another shortcut.")
    }

    func testCarbonRefusalIsAnotherAppAndReleasesTheClaim() {
        let catalog = SharedHotKeyCatalog()
        let snapHotKeys = SnapHotKeys(make: { _, _, _ in nil }, catalog: catalog)
        snapHotKeys.register { _ in }
        XCTAssertEqual(snapHotKeys.taken, SnapTarget.allCases)
        XCTAssertTrue(snapHotKeys.usedBy.isEmpty, "refused by the system: another app")
        XCTAssertTrue(catalog.catalog.assignments.isEmpty, "nothing claimed that is not held")
    }
}
