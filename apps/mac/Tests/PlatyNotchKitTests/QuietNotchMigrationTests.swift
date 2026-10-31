import Foundation
import PlatyNotchKit
import XCTest

final class QuietNotchMigrationTests: DefaultsTestCase {
    private func saved() -> NudgeSettings? {
        defaults().data(forKey: NudgeSettings.key).flatMap { try? JSONDecoder().decode(NudgeSettings.self, from: $0) }
    }

    func testNewUserWaterOff() {
        XCTAssertEqual(NudgeSettings().water, 0)
        QuietNotchMigration.run(defaults: defaults(), existingUser: false)
        XCTAssertNil(defaults().data(forKey: NudgeSettings.key))
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: suiteName)?.keys.sorted() ?? [], [],
                       "a new install writes nothing")
    }

    func testExistingUserKeepsSixty() {
        QuietNotchMigration.run(defaults: defaults(), existingUser: true)
        XCTAssertEqual(saved()?.water, 60)
        XCTAssertEqual(saved(), NudgeSettings(water: 60), "the rest are today's defaults")
        XCTAssertTrue(defaults().bool(forKey: QuietNotchMigration.key))
    }

    func testSavedChoiceNeverChanged() {
        var s = NudgeSettings()
        s.water = 30
        defaults().set(try! JSONEncoder().encode(s), forKey: NudgeSettings.key)
        QuietNotchMigration.run(defaults: defaults(), existingUser: true)
        XCTAssertEqual(saved()?.water, 30)
        // Water switched off on purpose stays off.
        defaults().removeObject(forKey: QuietNotchMigration.key)
        defaults().set(try! JSONEncoder().encode(NudgeSettings(water: 0)), forKey: NudgeSettings.key)
        QuietNotchMigration.run(defaults: defaults(), existingUser: true)
        XCTAssertEqual(saved()?.water, 0)
    }

    func testRunsOnce() {
        QuietNotchMigration.run(defaults: defaults(), existingUser: true)
        defaults().removeObject(forKey: NudgeSettings.key)
        QuietNotchMigration.run(defaults: defaults(), existingUser: true)
        XCTAssertNil(defaults().data(forKey: NudgeSettings.key), "a second run writes nothing")
    }

    func testSavedWithoutWaterKeyKeepsSixty() throws {
        let decoded = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"stand":50}"#.utf8))
        XCTAssertEqual(decoded.water, 60)
        XCTAssertEqual(decoded.water, NudgeSettings.legacyWaterMinutes)
        XCTAssertEqual(decoded.stand, 50)
    }

    /// A new install is marked done at launch, so the next launch (when a layout is saved and
    /// the user looks "existing") never hands them the old 60-minute water nudge.
    func testNewInstallNeverBecomesAnExistingUserLater() {
        let d = defaults()
        let first = FirstRunState.prepare(defaults: d, onboardingDone: false, layoutSaved: false)
        XCTAssertEqual(first, .firstRun)
        FirstRunState.finish(defaults: d)
        let second = FirstRunState.prepare(defaults: d, onboardingDone: true, layoutSaved: true)
        XCTAssertNotEqual(second, .firstRun)
        QuietNotchMigration.run(defaults: d, existingUser: true)
        XCTAssertNil(d.data(forKey: NudgeSettings.key))
    }

    func testPrepareMigratesAnExistingUser() {
        let d = defaults()
        let state = FirstRunState.prepare(defaults: d, onboardingDone: true, layoutSaved: true)
        XCTAssertNotEqual(state, .firstRun)
        XCTAssertEqual(saved()?.water, 60)
    }

    func testPrepareDoesNotTouchAnExistingUsersChoice() {
        let d = defaults()
        d.set(try! JSONEncoder().encode(NudgeSettings(water: 0)), forKey: NudgeSettings.key)
        _ = FirstRunState.prepare(defaults: d, onboardingDone: true, layoutSaved: true)
        XCTAssertEqual(saved()?.water, 0)
    }
}
