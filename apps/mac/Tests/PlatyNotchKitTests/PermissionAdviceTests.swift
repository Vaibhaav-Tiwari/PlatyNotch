import Foundation
import XCTest
@testable import PlatyNotchKit

/// User feedback 6, 7 and 13: a permission given to an earlier (rebuilt) PlatyNotch no
/// longer applies and macOS does not ask again, so every "not allowed" names the real
/// state and the way out.
final class PermissionAdviceTests: XCTestCase {
    func testGrantHistory() {
        XCTAssertEqual(GrantHistory(savedStamp: nil, current: "dr:a"), .never)
        XCTAssertEqual(GrantHistory(savedStamp: "", current: "dr:a"), .never)
        XCTAssertEqual(GrantHistory(savedStamp: "dr:a", current: "dr:a"), .thisBuild)
        XCTAssertEqual(GrantHistory(savedStamp: "dr:old", current: "dr:a"), .otherBuild)
    }

    func testAutomationDeniedNamesTheStateAndTheWayOut() {
        let path = "System Settings › Privacy & Security › Automation › PlatyNotch › Safari"
        let off = PermissionAdvice.automationDenied(app: "Safari", history: .thisBuild)
        XCTAssertTrue(off.contains(path), off)
        XCTAssertFalse(off.contains("tccutil"), "the same build: the switch is simply off")

        let rebuilt = PermissionAdvice.automationDenied(app: "Safari", history: .otherBuild)
        XCTAssertTrue(rebuilt.contains("rebuilt"), rebuilt)
        XCTAssertTrue(rebuilt.contains("tccutil reset AppleEvents dev.platynotch.app"), rebuilt)
        XCTAssertTrue(rebuilt.contains("does not ask again"), rebuilt)

        let unknown = PermissionAdvice.automationDenied(app: "Music", history: .never)
        XCTAssertTrue(unknown.contains("Automation › PlatyNotch › Music"), unknown)
        XCTAssertTrue(unknown.contains("tccutil reset AppleEvents dev.platynotch.app"), unknown)
    }

    func testAccessibilityStuck() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let after = t0.addingTimeInterval(PermissionAdvice.accessibilityStuckAfter)
        // Trusted: never stuck.
        XCTAssertFalse(PermissionAdvice.accessibilityStuck(trusted: true, allowClickedAt: t0, now: after, history: .otherBuild))
        // Not asked yet, never granted: just "Allow".
        XCTAssertFalse(PermissionAdvice.accessibilityStuck(trusted: false, allowClickedAt: nil, now: after, history: .never))
        // Allow clicked a moment ago: give the user time to flip the switch.
        XCTAssertFalse(PermissionAdvice.accessibilityStuck(trusted: false, allowClickedAt: t0, now: t0.addingTimeInterval(1),
                                                          history: .never))
        // Allow clicked and still not trusted: explain.
        XCTAssertTrue(PermissionAdvice.accessibilityStuck(trusted: false, allowClickedAt: t0, now: after, history: .never))
        // A grant made to another build: explain at once.
        XCTAssertTrue(PermissionAdvice.accessibilityStuck(trusted: false, allowClickedAt: nil, now: t0, history: .otherBuild))
        XCTAssertTrue(PermissionAdvice.accessibilityRebuilt.contains("remove PlatyNotch (−) and allow it again"))
    }
}
