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
        XCTAssertTrue(rebuilt.contains(PermissionAdvice.resetAppleEvents), rebuilt)
        XCTAssertTrue(rebuilt.contains("does not ask again"), rebuilt)

        let unknown = PermissionAdvice.automationDenied(app: "Music", history: .never)
        XCTAssertTrue(unknown.contains("Automation › PlatyNotch › Music"), unknown)
        XCTAssertTrue(unknown.contains(PermissionAdvice.resetAppleEvents), unknown)
    }

    /// A first-time user still finding the switch is never told "rebuilt": only a grant
    /// seen for another build is definite; otherwise conditional wording, and only after
    /// they clicked Allow and came back.
    func testAccessibilityAdviceByHistory() {
        typealias A = PermissionAdvice
        XCTAssertEqual(A.accessibility(trusted: true, returnedAfterAllow: true, history: .otherBuild), .none)
        // Never granted before.
        XCTAssertEqual(A.accessibility(trusted: false, returnedAfterAllow: false, history: .never), .none)
        XCTAssertEqual(A.accessibility(trusted: false, returnedAfterAllow: true, history: .never), .maybeStale)
        // Granted to this very build, then turned off or removed.
        XCTAssertEqual(A.accessibility(trusted: false, returnedAfterAllow: false, history: .thisBuild), .none)
        XCTAssertEqual(A.accessibility(trusted: false, returnedAfterAllow: true, history: .thisBuild), .maybeStale)
        // Granted to another build: definite, at once.
        XCTAssertEqual(A.accessibility(trusted: false, returnedAfterAllow: false, history: .otherBuild), .rebuilt)
        XCTAssertEqual(A.AccessibilityAdvice.rebuilt.text, A.accessibilityRebuilt)
        XCTAssertTrue(A.accessibilityRebuilt.contains("rebuilt"))
        let maybe = A.AccessibilityAdvice.maybeStale.text ?? ""
        XCTAssertFalse(maybe.contains("rebuilt"), maybe)
        XCTAssertTrue(maybe.hasPrefix("If you already turned PlatyNotch on in Accessibility"), maybe)
    }

    func testResetCommandNamesThisAppAndWhatItClears() {
        XCTAssertEqual(PermissionAdvice.resetAppleEvents, "tccutil reset AppleEvents " + PermissionAdvice.bundleID)
        let text = PermissionAdvice.automationDenied(app: "Safari", history: .otherBuild)
        for part in ["terminal focus", "Music", "Spotify", "browsers"] {
            XCTAssertTrue(text.contains(part), part)
        }
    }
}
