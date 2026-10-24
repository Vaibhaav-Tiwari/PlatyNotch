import AppKit
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// The onboarding and Settings windows keep the size they are given. SwiftUI's hosting
/// controller must not shrink or stretch them to the content's ideal size (a user saw
/// onboarding open as a narrow strip the height of the screen).
@MainActor
final class WindowSizeTests: XCTestCase {
    private func services() -> SettingsServices {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "platynotch.tests.\(UUID().uuidString)")!
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
}
