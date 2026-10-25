import Foundation
import PlatyNotchKit
import XCTest

final class SettingsRouteTests: XCTestCase {
    func testLegacySections() {
        XCTAssertEqual(SettingsTarget.resolve("appearance"), SettingsTarget(section: "notch"))
        XCTAssertEqual(SettingsTarget.resolve("permissions"), SettingsTarget(section: "privacy"))
        XCTAssertEqual(SettingsTarget.resolve("approvals"), SettingsTarget(section: "agents", detail: "approvals"))
        XCTAssertEqual(SettingsTarget.resolve("policy"), SettingsTarget(section: "agents", detail: "policy"))
        XCTAssertEqual(SettingsTarget.resolve("agents"), SettingsTarget(section: "agents"))
        XCTAssertEqual(SettingsTarget.resolve("memory"), SettingsTarget(section: "memory"))
        XCTAssertEqual(SettingsTarget.resolve(nil), SettingsTarget(section: "general"))
        XCTAssertEqual(SettingsTarget.resolve(""), SettingsTarget(section: "general"))
    }

    func testWidgetDetail() {
        XCTAssertEqual(SettingsTarget.resolve("widgets/music"), SettingsTarget(section: "widgets", detail: "music"))
        XCTAssertEqual(SettingsTarget.resolve("widgets/fileActions"), SettingsTarget(section: "widgets", detail: "fileActions"),
                       "widget ids keep their case")
        XCTAssertEqual(SettingsTarget.resolve("widgets"), SettingsTarget(section: "widgets"))
        XCTAssertEqual(SettingsTarget.resolve("agents/approvals"), SettingsTarget(section: "agents", detail: "approvals"))
    }

    func testPluginSectionPassesThrough() {
        XCTAssertEqual(SettingsTarget.resolve("com.example.standup"), SettingsTarget(section: "com.example.standup"))
    }

    func testAppURLKeepsPath() {
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings/widgets/music")!), .settings(section: "widgets/music"))
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings")!), .settings(section: nil))
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings/Memory")!), .settings(section: "memory"))
    }

    func testPagesInOrder() {
        XCTAssertEqual(SettingsPage.allCases.map(\.rawValue),
                       ["general", "notch", "now", "notifications", "widgets", "agents", "memory", "privacy", "about"])
        XCTAssertEqual(SettingsPage.privacy.title, "Privacy & Permissions")
        for page in SettingsPage.allCases {
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.systemImage.isEmpty)
            XCTAssertEqual(SettingsTarget.resolve(page.rawValue), SettingsTarget(section: page.rawValue))
        }
    }
}
