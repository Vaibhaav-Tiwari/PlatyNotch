import Foundation
import PlatyNotchKit
import XCTest

final class IslandMigrationTests: DefaultsTestCase {
    private let london = GeoPlace(id: 2643743, name: "London", country: "United Kingdom",
                                  latitude: 51.50853, longitude: -0.12574)

    private func savePlace() {
        defaults().set(try! JSONEncoder().encode(london), forKey: WeatherLocation.legacyPlaceKey)
    }

    func testSavedPlaceBecomesCity() {
        savePlace()
        IslandMigration.run(defaults: defaults(), existingUser: true)
        XCTAssertEqual(WeatherLocation.load(from: defaults()), .city(london), "no Location prompt for a city user")
        XCTAssertTrue(defaults().bool(forKey: IslandMigration.key))
        XCTAssertEqual(IslandMigration.key, "ui.island.migrated")
    }

    func testNewUserUntouched() {
        savePlace()
        IslandMigration.run(defaults: defaults(), existingUser: false)
        XCTAssertNil(WeatherLocation.load(from: defaults()))
    }

    func testRunsOnce() {
        savePlace()
        IslandMigration.run(defaults: defaults(), existingUser: true)
        WeatherLocation.automatic.save(to: defaults())
        IslandMigration.run(defaults: defaults(), existingUser: true)
        XCTAssertEqual(WeatherLocation.load(from: defaults()), .automatic)
    }

    func testNewInstallMarkedDone() {
        _ = FirstRunState.prepare(defaults: defaults(), onboardingDone: false, layoutSaved: false)
        XCTAssertTrue(defaults().bool(forKey: IslandMigration.key))
    }

    func testMailColumnSwapsGames() {
        HomeSettings(rightColumn: .mail).save(to: defaults())
        IslandMigration.run(defaults: defaults(), existingUser: true)
        let dock = DockLayout.load(from: defaults())
        XCTAssertNotNil(defaults().data(forKey: DockLayout.key))
        XCTAssertEqual(dock.slots[6], .tool("mail"))
        XCTAssertFalse(dock.slots.contains(.core(.games)))
        XCTAssertEqual(dock.slots.count, 8)

        let other = UserDefaults(suiteName: suiteName + ".notes")!
        other.removePersistentDomain(forName: suiteName + ".notes")
        defer { other.removePersistentDomain(forName: suiteName + ".notes") }
        HomeSettings(rightColumn: .notes).save(to: other)
        IslandMigration.run(defaults: other, existingUser: true)
        XCTAssertNil(other.data(forKey: DockLayout.key), "no Mail column: no dock saved")
    }

    func testMailSwapKeepsASavedDock() {
        HomeSettings(rightColumn: .mail).save(to: defaults())
        let mine = DockLayout(slots: [.core(.games), .core(.search)])
        mine.save(to: defaults())
        IslandMigration.run(defaults: defaults(), existingUser: true)
        XCTAssertEqual(DockLayout.load(from: defaults()), mine)
    }

    func testSettingsUntouched() {
        let d = defaults()
        let layout = WidgetLayout(order: ["music", "mail"], enabled: ["music", "mail"]).encoded()
        d.set(layout, forKey: WidgetLayout.key)
        AppearanceStore.save(AppearanceSettings(mode: .minimal), to: d)
        let appearance = d.data(forKey: AppearanceStore.key)
        d.set("oneHour", forKey: KeepAwakeDuration.preferenceKey)
        HomeSettings(rightColumn: .mail).save(to: d)
        IslandMigration.run(defaults: d, existingUser: true)
        XCTAssertEqual(d.data(forKey: WidgetLayout.key), layout)
        XCTAssertEqual(d.data(forKey: AppearanceStore.key), appearance)
        XCTAssertEqual(d.string(forKey: KeepAwakeDuration.preferenceKey), "oneHour")
    }

    /// Review M5: the Mail swap runs once; a dock cleared later never brings Mail back.
    func testMailSwapRunsOnce() {
        HomeSettings(rightColumn: .mail).save(to: defaults())
        IslandMigration.run(defaults: defaults(), existingUser: true)
        XCTAssertTrue(defaults().bool(forKey: IslandMigration.mailDockKey))
        defaults().removeObject(forKey: DockLayout.key)
        IslandMigration.run(defaults: defaults(), existingUser: true)
        XCTAssertNil(defaults().data(forKey: DockLayout.key))
        XCTAssertEqual(IslandMigration.mailDockKey, "ui.island.mailDock")
    }
}
