import Foundation
import XCTest

/// A test class whose tests use `UserDefaults` (C3): one fixed suite per class,
/// `dev.platynotch.tests.<Class>`, emptied in `setUp` and `tearDown`. A suite's plist in
/// ~/Library/Preferences stays behind as an empty file after `removePersistentDomain`, so
/// per-test (UUID) names left thousands of files; a fixed name leaves at most one per
/// class however often the tests run. Never name a suite any other way in Tests/.
///
/// The suite is per user, not per process: `swift test --parallel` workers and test runs in
/// other worktrees use the same one, and another process's `setUp` emptied it mid-test.
/// So each test holds an exclusive `flock` on `<TMPDIR>/<suite>.lock` from `setUp` to
/// `tearDown`, and processes take turns with the suite (the lock goes when a process dies).
class DefaultsTestCase: XCTestCase {
    /// `dev.platynotch.tests.<Class>`.
    final var suiteName: String { "dev.platynotch.tests." + String(describing: type(of: self)) }

    /// The held lock file (-1: none).
    private var suiteLock: Int32 = -1

    override func setUp() {
        super.setUp()
        lockSuite()
        clearDefaults()
    }

    override func tearDown() {
        clearDefaults()
        unlockSuite()
        super.tearDown()
    }

    final func clearDefaults() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// The class's suite: every call in a test returns the same storage.
    final func defaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!   // a plain reverse-DNS name never fails
    }

    /// Waits until no other process is using the suite.
    private func lockSuite() {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(suiteName + ".lock")
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return XCTFail("cannot open \(path): errno \(errno)") }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(fd)
                return XCTFail("cannot lock \(path): errno \(errno)")
            }
        }
        suiteLock = fd
    }

    private func unlockSuite() {
        guard suiteLock >= 0 else { return }
        close(suiteLock)   // releases the flock
        suiteLock = -1
    }
}
