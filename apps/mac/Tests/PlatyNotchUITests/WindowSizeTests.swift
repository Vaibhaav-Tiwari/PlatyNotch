import AppKit
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// The onboarding and Settings windows keep the size they are given. SwiftUI's hosting
/// controller must not shrink or stretch them to the content's ideal size (a user saw
/// onboarding open as a narrow strip the height of the screen).
@MainActor
final class WindowSizeTests: DefaultsTestCase {
    private func services() -> SettingsServices {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let defaults = self.defaults()
        return SettingsServices(config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                runner: CoreRunner(binaryURL: dir.appendingPathComponent("notch")),
                                store: AppStore(), capture: nil,
                                calendar: CalendarService(eventKit: false),
                                reminders: RemindersService(eventKit: false),
                                widgets: WidgetRegistry(defaults: defaults, persist: false),
                                updater: AppUpdater(start: false, enabled: false))
    }

    /// Lets SwiftUI lay out and the hosting controller apply any size it wants.
    private func settle(_ view: NSView?) {
        view?.window?.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view?.window?.layoutIfNeeded()
    }

    func testOnboardingKeepsItsSize() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let c = OnboardingWindowController(services: services(), home: home)
        c.showForSmoke()
        defer { c.close() }
        for page in 0..<OnboardingWindowController.pageCount {
            c.model.page = page
            settle(c.hostingView)
            let size = c.hostingView?.window?.contentView?.frame.size ?? .zero
            XCTAssertEqual(size.width, 620, accuracy: 1, "page \(page) width")
            XCTAssertEqual(size.height, 520, accuracy: 1, "page \(page) height")
        }
    }

    func testSettingsKeepsItsSize() {
        let c = SettingsWindowController(services: services(), pluginSections: [])
        c.showForSmoke()
        defer { c.close() }
        for section in c.sectionIDs {
            c.model.selection = section
            settle(c.hostingView)
            let size = c.hostingView?.window?.contentView?.frame.size ?? .zero
            XCTAssertGreaterThanOrEqual(size.width, 640, section)
            XCTAssertGreaterThanOrEqual(size.height, 420, section)
            XCTAssertLessThanOrEqual(size.height, 900, section)
        }
    }

    /// Every first-run page and every Settings page (sub-pages too) keeps its exact size,
    /// off screen at (-10000, 10000).
    func testWindowsKeepExactSizeOffScreen() {
        let away = NSPoint(x: -10_000, y: 10_000)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let o = OnboardingWindowController(services: services(), home: home, defaults: defaults())
        o.showForSmoke()
        for page in 0..<OnboardingWindowController.pageCount {
            o.model.page = page
            settle(o.hostingView)
            XCTAssertEqual(o.window?.contentView?.frame.size, NSSize(width: 620, height: 520), "page \(page)")
            XCTAssertEqual(o.window?.frame.origin, away, "page \(page)")
        }
        o.close()
        let c = SettingsWindowController(services: services(), pluginSections: [])
        c.showForSmoke()
        defer { c.close() }
        let targets: [SettingsTarget] = c.sectionIDs.map { SettingsTarget(section: $0) }
            + [SettingsTarget(section: "agents", detail: "approvals"), SettingsTarget(section: "agents", detail: "policy"),
               SettingsTarget(section: "widgets", detail: "weather")]
        for t in targets {
            c.model.go(to: t, ids: c.sectionIDs)
            settle(c.hostingView)
            let name = t.section + (t.detail.map { "/" + $0 } ?? "")
            XCTAssertEqual(c.hostingView?.window?.contentView?.frame.size, NSSize(width: 800, height: 580), name)
            XCTAssertEqual(c.hostingView?.window?.frame.origin, away, name)
        }
    }
}
