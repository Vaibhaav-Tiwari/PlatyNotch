import Foundation
import PlatyNotchKit
import XCTest

final class SetupPresetTests: DefaultsTestCase {
    private let everydayOn = ["music", "meeting", "time", "weather", "shelf", "clipboard"]
    private let allBuiltIns = ["music", "meeting", "focus", "loops", "time", "hud", "shelf", "clipboard", "reminders",
                               "weather", "wellbeing", "system", "games", "launch", "baskets", "fileActions", "mail",
                               "notes", "mirror", "snap"]

    func testPresetGoldenTable() {
        struct Row { let p: SetupPreset; let on: [String]; let off: [String]; let glances: [String]
            let mode: AppearanceSettings.Mode; let agents: Bool }
        let rows: [Row] = [
            Row(p: .everyday, on: everydayOn, off: ["fileActions", "snap"],
                glances: ["meeting", "weather", "system", "loops"], mode: .alwaysOn, agents: false),
            Row(p: .developer, on: everydayOn + ["fileActions", "snap"], off: [],
                glances: ["meeting", "agents.usage", "weather", "system"], mode: .alwaysOn, agents: true),
            Row(p: .minimal, on: ["music"], off: allBuiltIns.filter { $0 != "music" },
                glances: ["agents.usage"], mode: .minimal, agents: true),
        ]
        XCTAssertEqual(SetupPreset.allCases, rows.map(\.p))
        for r in rows {
            XCTAssertEqual(r.p.turnsOn, r.on, "\(r.p)")
            XCTAssertEqual(r.p.turnsOff, r.off, "\(r.p)")
            XCTAssertEqual(r.p.glances, r.glances, "\(r.p)")
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
        XCTAssertEqual(change.turnOn, [])
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
        UpgradeMigration.run(defaults: d, existingUser: true, glanceCapable: ["games", "snap", "weather", "system", "loops"])
        XCTAssertEqual(d.data(forKey: WidgetLayout.key), layout, "byte-identical")
        XCTAssertEqual(GlanceSlots.decode(d.data(forKey: GlanceSlots.key))?.ids, ["games", "snap", "weather", "system"],
                       "the first four glance-capable widgets the caller passes")
    }

    func testExistingUserKeepsAgents() {
        let d = defaults()
        UpgradeMigration.run(defaults: d, existingUser: true, glanceCapable: [])
        XCTAssertTrue(AgentsVisibility.load(from: d).everConnected, "Agents stays where it was")
        XCTAssertFalse(AgentsVisibility.load(from: d).forcedOn)
        // Chosen glances and appearance are kept.
        let other = defaults()
        other.removeObject(forKey: UpgradeMigration.key)
        GlanceSlots(ids: ["music"]).save(to: other)
        AppearanceStore.save(AppearanceSettings(mode: .minimal), to: other)
        UpgradeMigration.run(defaults: other, existingUser: true, glanceCapable: ["weather"])
        XCTAssertEqual(GlanceSlots.decode(other.data(forKey: GlanceSlots.key))?.ids, ["music"])
        XCTAssertEqual(AppearanceStore.load(from: other).mode, .minimal)
    }

    func testMigrationIdempotent() {
        let d = defaults()
        UpgradeMigration.run(defaults: d, existingUser: true, glanceCapable: ["weather"])
        XCTAssertTrue(d.bool(forKey: UpgradeMigration.key))
        // The user later hides Agents and changes glances: a second run changes nothing.
        AgentsVisibility(everConnected: false).save(to: d)
        GlanceSlots(ids: ["music"]).save(to: d)
        UpgradeMigration.run(defaults: d, existingUser: true, glanceCapable: ["weather"])
        XCTAssertFalse(AgentsVisibility.load(from: d).everConnected)
        XCTAssertEqual(GlanceSlots.decode(d.data(forKey: GlanceSlots.key))?.ids, ["music"])
    }

    func testNewUserWritesNothing() {
        let d = defaults()
        UpgradeMigration.run(defaults: d, existingUser: false, glanceCapable: ["weather"])
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: suiteName)?.keys.sorted() ?? [], [])
    }
}
