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
}
