import Foundation
import XCTest

/// A test class whose tests use `UserDefaults` (C3): one fixed suite per class,
/// `dev.platynotch.tests.<Class>`, emptied in `setUp` and `tearDown`. A suite's plist in
/// ~/Library/Preferences stays behind as an empty file after `removePersistentDomain`, so
/// per-test (UUID) names left thousands of files; a fixed name leaves at most one per
/// class however often the tests run. Never name a suite any other way in Tests/.
class DefaultsTestCase: XCTestCase {
    /// `dev.platynotch.tests.<Class>`.
    final var suiteName: String { "dev.platynotch.tests." + String(describing: type(of: self)) }

    override func setUp() {
        super.setUp()
        clearDefaults()
    }

    override func tearDown() {
        clearDefaults()
        super.tearDown()
    }

    final func clearDefaults() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// The class's suite: every call in a test returns the same storage.
    final func defaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!   // a plain reverse-DNS name never fails
    }
}
