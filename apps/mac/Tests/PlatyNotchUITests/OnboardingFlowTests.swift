import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class OnboardingFlowTests: DefaultsTestCase {
    private func services() -> SettingsServices {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, focus: FocusModel(defaults: defaults()))
        BuiltInWidgets.register(in: registry, store: AppStore(), today: today, persist: false)
        return SettingsServices(config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                runner: CoreRunner(binaryURL: dir.appendingPathComponent("notch")),
                                store: AppStore(), capture: nil, calendar: CalendarService(eventKit: false),
                                reminders: RemindersService(eventKit: false), widgets: registry,
                                updater: AppUpdater(start: false, enabled: false))
    }

    private func home() -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: h) }
        return h
    }

    func testFirstRunHasFourPages() {
        XCTAssertEqual(OnboardingWindowController.pageCount, 4)
        let c = OnboardingWindowController(services: services(), home: home(), defaults: defaults())
        c.showForSmoke()
        defer { c.close() }
        XCTAssertEqual(c.model.flow, .firstRun)
        XCTAssertEqual(c.model.pages, [.meetPlaty, .pickSetup, .permissions, .tryIt])
    }

    func testTourHasThreePages() {
        let c = OnboardingWindowController(services: services(), home: home(), defaults: defaults())
        c.showForSmoke(flow: .tour)
        XCTAssertEqual(c.window?.frame.origin, NSPoint(x: -10_000, y: 10_000), "never where the user works")
        XCTAssertEqual(c.model.pages, [.meetPlaty, .permissions, .tryIt], "the tour skips the presets")
        c.close()
        // Finishing the tour marks it offered and onboarding seen.
        c.model.inert = false
        c.finish()
        XCTAssertTrue(defaults().bool(forKey: FirstRunState.tourOfferedKey))
        XCTAssertTrue(c.isDone)
    }

    /// Existing users are never sent through the first run: they get the card on Now.
    func testExistingUserNotForced() {
        let d = defaults()
        XCTAssertEqual(FirstRunState.resolve(onboardingDone: true, layoutSaved: true, defaults: d), .offerTour)
        XCTAssertEqual(FirstRunState.resolve(onboardingDone: false, layoutSaved: true, defaults: d), .offerTour)
        XCTAssertFalse(OnboardingLaunch.showsFirstRun(.offerTour))
        XCTAssertFalse(OnboardingLaunch.showsFirstRun(.settled))
        XCTAssertTrue(OnboardingLaunch.showsFirstRun(.firstRun))
        // A new install's own saved layout does not make it an existing user next launch.
        d.set(true, forKey: FirstRunState.pendingKey)
        XCTAssertEqual(FirstRunState.resolve(onboardingDone: false, layoutSaved: true, defaults: d), .firstRun)
    }

    func testTryItCompletesOnExpand() {
        let store = AppStore()
        let client = CoreClient(socketPath: "/nonexistent")
        let c = NotchController(store: store, client: client, plugins: [], appearance: AppearanceSettings())
        c.cursorLocation = { CGPoint(x: 100, y: 100) }
        let tour = TourCoordinator()
        tour.approvals = { store.approvals.count }
        var done = 0
        tour.controllers = [c]
        tour.arm { done += 1 }
        XCTAssertEqual(c.panelModel.tourSample?.id, TryItSession.sample.id, "armed: the sample waits in Now")
        c.expand()
        XCTAssertEqual(c.mode, .expanded)
        XCTAssertEqual(done, 1, "opening the panel finishes Try it")
        XCTAssertEqual(tour.session.phase, .showing)
        XCTAssertNotNil(c.panelModel.tourSample, "the sample stays while Now shows it")
        c.collapse()
        XCTAssertEqual(tour.session.phase, .done)
        XCTAssertNil(c.panelModel.tourSample, "gone once Now closes")
        c.expand()
        XCTAssertEqual(done, 1, "only once")
        XCTAssertNil(c.panelModel.tourSample)
    }

    /// The hover peek shows Now's hero: with Open on "Peek, then click" it completes Try it.
    func testTryItCompletesOnHoverPeek() {
        XCTAssertTrue(NotchController.showsHome(.peek(.hover)))
        XCTAssertTrue(NotchController.showsHome(.expanded))
        XCTAssertFalse(NotchController.showsHome(.peek(.approval)))
        XCTAssertFalse(NotchController.showsHome(.compact))
    }

    /// The sample leaves after the time limit even if Now stays open.
    func testTryItSampleExpires() async {
        let store = AppStore()
        let c = NotchController(store: store, client: CoreClient(socketPath: "/nonexistent"), plugins: [],
                                appearance: AppearanceSettings())
        c.cursorLocation = { CGPoint(x: 100, y: 100) }
        let tour = TourCoordinator()
        tour.showingLimit = .milliseconds(50)
        tour.controllers = [c]
        tour.arm {}
        c.expand()
        XCTAssertNotNil(c.panelModel.tourSample)
        let gone = await eventually { c.panelModel.tourSample == nil }
        XCTAssertTrue(gone)
    }

    func testTryItCopyFollowsOpenOn() {
        XCTAssertEqual(TryItCopy.title(.hover), "Move your pointer to the notch")
        XCTAssertEqual(TryItCopy.title(.click), "Click the notch")
        XCTAssertEqual(TryItCopy.title(.peekOnHover), "Hover, then click")
    }

    func testSampleIgnoredDuringApproval() {
        let sample = TryItSession.sample
        XCTAssertEqual(sample.title, "This is Home")
        let session = TryItSession()
        var done = false
        session.arm { done = true }
        XCTAssertFalse(session.panelExpanded(approvals: 1), "an approval peek is not Try it")
        XCTAssertFalse(done)
        XCTAssertTrue(session.armed)
        XCTAssertTrue(session.panelExpanded(approvals: 0))
        XCTAssertTrue(done)
        XCTAssertTrue(session.showsSample)
        XCTAssertTrue(session.panelCollapsed())
        XCTAssertFalse(session.showsSample)
    }

    /// Settings asks before a preset turns anything off; turning things on needs no question.
    func testPresetFromSettingsAsksBeforeTurningOff() {
        let s = services()
        let d = defaults()
        let change = s.presetChange(.minimal)
        XCTAssertTrue(change.needsConfirmation)
        s.applyPreset(.developer, defaults: d)
        XCTAssertTrue(s.widgets.isEnabled("snap"))
        XCTAssertTrue(s.widgets.isEnabled("fileActions"))
        XCTAssertTrue(AgentsVisibility.load(from: d).forcedOn)
        XCTAssertEqual(AppearanceStore.load(from: d).mode, .alwaysOn)
        s.applyPreset(.minimal, defaults: d)
        XCTAssertEqual(AppearanceStore.load(from: d).mode, .minimal)
        XCTAssertFalse(s.widgets.isEnabled("snap"))
        XCTAssertTrue(s.widgets.isEnabled("music"))
    }

    /// The first run applies the picked setup directly; the replay from Settings asks with a
    /// summary of every change.
    func testOnboardingConfirmation() {
        let s = services()
        let plan = s.presetPlan(.minimal, defaults: defaults())
        XCTAssertEqual(OnboardingView.continueStep(page: .pickSetup, confirmsPresets: false, plan: plan), .apply)
        XCTAssertEqual(OnboardingView.continueStep(page: .pickSetup, confirmsPresets: true, plan: plan), .confirm)
        XCTAssertEqual(OnboardingView.continueStep(page: .meetPlaty, confirmsPresets: true, plan: plan), .nextPage)
        let summary = s.presetSummary(plan)
        XCTAssertTrue(summary.contains("Turns off"), summary)
        XCTAssertTrue(summary.contains("Meetings"), "widgets are named, not ids: \(summary)")
        XCTAssertTrue(summary.contains("The notch hides until something is live."))
    }

    /// Settings › General never applies a setup without asking: it asks, or nothing changes.
    func testSettingsAlwaysAsks() {
        for p in SetupPreset.allCases {
            for enabled in [Set<String>(), Set(["music"]), Set(SetupPreset.builtIns)] {
                let plan = PresetPlan.plan(p, enabled: enabled, mode: .alwaysOn)
                XCTAssertEqual(GeneralSection.action(for: plan), plan.isCurrent ? .alreadyCurrent : .ask, "\(p)")
            }
        }
        let current = PresetPlan.plan(.minimal, enabled: ["music", "weather"], mode: .minimal)
        XCTAssertEqual(GeneralSection.action(for: current), .alreadyCurrent)
    }
}
