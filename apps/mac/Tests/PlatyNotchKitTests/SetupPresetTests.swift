import Foundation
import PlatyNotchKit
import XCTest

final class SetupPresetTests: DefaultsTestCase {
    private let everydayOn = ["music", "meeting", "time", "weather", "shelf", "clipboard"]
    private let allBuiltIns = ["music", "meeting", "focus", "loops", "time", "hud", "shelf", "clipboard", "reminders",
                               "weather", "wellbeing", "system", "games", "launch", "baskets", "fileActions", "mail",
                               "notes", "mirror", "snap"]

    func testPresetGoldenTable() {
        struct Row { let p: SetupPreset; let on: [String]; let off: [String]
            let mode: AppearanceSettings.Mode; let agents: Bool }
        let rows: [Row] = [
            Row(p: .everyday, on: everydayOn, off: ["fileActions", "snap"],
                mode: .alwaysOn, agents: false),
            Row(p: .developer, on: everydayOn + ["fileActions", "snap"], off: [],
                mode: .alwaysOn, agents: true),
            Row(p: .minimal, on: ["music", "weather"], off: allBuiltIns.filter { $0 != "music" && $0 != "weather" },
                mode: .minimal, agents: true),
        ]
        XCTAssertEqual(SetupPreset.allCases, rows.map(\.p))
        for r in rows {
            XCTAssertEqual(r.p.turnsOn, r.on, "\(r.p)")
            XCTAssertEqual(r.p.turnsOff, r.off, "\(r.p)")
            XCTAssertEqual(r.p.mode, r.mode, "\(r.p)")
            XCTAssertEqual(r.p.showsAgents, r.agents, "\(r.p)")
        }
    }

    func testPlanOnlyChanges() {
        let change = PresetChange.plan(.everyday, enabled: ["music", "shelf", "snap", "games"])
        XCTAssertEqual(change.turnOn, ["meeting", "time", "weather", "clipboard"], "already on: left out")
        XCTAssertEqual(change.turnOff, ["snap"], "already off: left out; not listed: kept")
        XCTAssertTrue(change.needsConfirmation)
        let none = PresetChange.plan(.developer, enabled: Set(everydayOn))
        XCTAssertEqual(none.turnOn, ["fileActions", "snap"])
        XCTAssertEqual(none.turnOff, [])
        XCTAssertFalse(none.needsConfirmation, "nothing turned off: no question")
    }

    func testMinimalNeedsConfirmation() {
        let change = PresetChange.plan(.minimal, enabled: ["music", "meeting", "time"])
        XCTAssertEqual(change.turnOn, ["weather"])
        XCTAssertEqual(change.turnOff, ["meeting", "time"])
        XCTAssertTrue(change.needsConfirmation)
        XCTAssertFalse(PresetChange.plan(.minimal, enabled: ["music"]).needsConfirmation)
    }

    func testPresetsNeverTouchPlugins() {
        let plugin = "com.example.standup"
        for p in SetupPreset.allCases {
            let change = PresetChange.plan(p, enabled: [plugin, "music"])
            XCTAssertFalse(change.turnOn.contains(plugin))
            XCTAssertFalse(change.turnOff.contains(plugin), "\(p) leaves a plug-in widget alone")
            XCTAssertTrue(Set(p.turnsOn + p.turnsOff).isSubset(of: Set(allBuiltIns)))
        }
    }

    func testFirstRunStates() {
        XCTAssertEqual(FirstRunState.resolve(onboardingDone: false, hasSavedLayout: false, tourOffered: false), .firstRun)
        XCTAssertEqual(FirstRunState.resolve(onboardingDone: true, hasSavedLayout: true, tourOffered: false), .offerTour)
        XCTAssertEqual(FirstRunState.resolve(onboardingDone: false, hasSavedLayout: true, tourOffered: false), .offerTour,
                       "an existing user who never finished onboarding is not forced through it")
        XCTAssertEqual(FirstRunState.resolve(onboardingDone: true, hasSavedLayout: false, tourOffered: false), .offerTour)
        XCTAssertEqual(FirstRunState.resolve(onboardingDone: true, hasSavedLayout: true, tourOffered: true), .settled)
        XCTAssertEqual(FirstRunState.resolve(onboardingDone: false, hasSavedLayout: true, tourOffered: true), .settled)
    }

    func testTourSkipsPresets() {
        XCTAssertEqual(OnboardingFlow.firstRun.pages, [.meetPlaty, .pickSetup, .permissions, .tryIt])
        XCTAssertEqual(OnboardingFlow.tour.pages, [.meetPlaty, .permissions, .tryIt])
        XCTAssertFalse(OnboardingFlow.tour.pages.contains(.pickSetup))
    }

    private func savedLayout() -> Data {
        WidgetLayout(order: ["snap", "music", "games", "com.example.standup"],
                     enabled: ["snap", "games", "com.example.standup"]).encoded()
    }

    func testExistingUserKeepsWidgets() {
        let d = defaults()
        let layout = savedLayout()
        d.set(layout, forKey: WidgetLayout.key)
        UpgradeMigration.run(defaults: d, existingUser: true)
        XCTAssertEqual(d.data(forKey: WidgetLayout.key), layout, "byte-identical")
    }

    func testExistingUserKeepsAgents() {
        let d = defaults()
        UpgradeMigration.run(defaults: d, existingUser: true)
        XCTAssertTrue(AgentsVisibility.load(from: d).everConnected, "Agents stays where it was")
        XCTAssertFalse(AgentsVisibility.load(from: d).forcedOn)
        // The appearance is kept.
        let other = defaults()
        other.removeObject(forKey: UpgradeMigration.key)
        AppearanceStore.save(AppearanceSettings(mode: .minimal), to: other)
        UpgradeMigration.run(defaults: other, existingUser: true)
        XCTAssertEqual(AppearanceStore.load(from: other).mode, .minimal)
    }

    func testMigrationIdempotent() {
        let d = defaults()
        UpgradeMigration.run(defaults: d, existingUser: true)
        XCTAssertTrue(d.bool(forKey: UpgradeMigration.key))
        // The user later hides Agents: a second run changes nothing.
        AgentsVisibility(everConnected: false).save(to: d)
        UpgradeMigration.run(defaults: d, existingUser: true)
        XCTAssertFalse(AgentsVisibility.load(from: d).everConnected)
    }

    func testNewUserWritesNothing() {
        let d = defaults()
        UpgradeMigration.run(defaults: d, existingUser: false)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: suiteName)?.keys.sorted() ?? [], [])
    }

    /// A new install across launches: quit during the first run twice, then finish it. It
    /// stays a first run until finished, and Agents is never "upgraded" into view.
    func testNewInstallAcrossLaunches() {
        let d = defaults()
        // Launch 1: nothing saved.
        XCTAssertEqual(FirstRunState.prepare(defaults: d, onboardingDone: false, layoutSaved: false), .firstRun)
        d.set(WidgetLayout(order: ["music"], enabled: ["music"]).encoded(), forKey: WidgetLayout.key)   // saved meanwhile
        // Launches 2 and 3: quit mid first run, a layout now saved.
        for _ in 0..<2 {
            XCTAssertEqual(FirstRunState.prepare(defaults: d, onboardingDone: false, layoutSaved: true), .firstRun)
            XCTAssertFalse(AgentsVisibility.load(from: d).everConnected, "never upgraded into view")
        }
        // Finished: settled, still no upgrade.
        FirstRunState.finish(defaults: d)
        XCTAssertEqual(FirstRunState.prepare(defaults: d, onboardingDone: true, layoutSaved: true), .settled)
        XCTAssertFalse(AgentsVisibility.load(from: d).everConnected)
    }

    /// Someone updating: the tour card, the upgrade once, and finishing settles it.
    func testExistingUserPrepare() {
        let d = defaults()
        d.set(WidgetLayout(order: ["music"], enabled: ["music"]).encoded(), forKey: WidgetLayout.key)
        XCTAssertEqual(FirstRunState.prepare(defaults: d, onboardingDone: true, layoutSaved: true), .offerTour)
        XCTAssertTrue(AgentsVisibility.load(from: d).everConnected)
        XCTAssertFalse(d.bool(forKey: FirstRunState.pendingKey))
        FirstRunState.finish(defaults: d)
        XCTAssertEqual(FirstRunState.prepare(defaults: d, onboardingDone: true, layoutSaved: true), .settled)
    }

    func testPresetPlanAsksOutsideTheFirstRun() {
        let plan = PresetPlan.plan(.everyday, enabled: ["music"], mode: .minimal)
        XCTAssertEqual(plan.turnOn, ["meeting", "time", "weather", "shelf", "clipboard"])
        XCTAssertEqual(plan.mode, .alwaysOn)
        XCTAssertFalse(plan.asks(firstRun: true), "a new install's first run applies directly")
        XCTAssertTrue(plan.asks(firstRun: false), "Settings always asks, even with nothing turned off")
        XCTAssertEqual(plan.summary(title: { $0.capitalized }), [
            "Turns on Meeting, Time, Weather, Shelf, Clipboard.",
            "The notch stays on.",
        ])
        let current = PresetPlan.plan(.minimal, enabled: ["music", "weather"], mode: .minimal)
        XCTAssertTrue(current.isCurrent)
        XCTAssertFalse(current.asks(firstRun: false), "nothing to change: nothing to ask")
    }

    /// Island spec 6: weather is on in all three presets.
    func testWeatherOnInEveryPreset() {
        for p in SetupPreset.allCases {
            XCTAssertTrue(p.turnsOn.contains("weather"), "\(p)")
            XCTAssertFalse(p.turnsOff.contains("weather"), "\(p)")
        }
    }
}
