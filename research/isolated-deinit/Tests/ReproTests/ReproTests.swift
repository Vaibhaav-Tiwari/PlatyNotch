// Run each test in its own process: `swift test --filter ReproTests.ReproTests/<name>`.
import XCTest
import ReproLib

@MainActor
final class ReproTests: XCTestCase {
    /// The PlatyNotch shape: synchronous test method, no TaskLocal bound by us.
    func test_sync_noTaskLocal() {
        _ = MainFoo()
    }

    /// Synchronous test method, TaskLocal bound by us.
    func test_sync_taskLocal() {
        ReproLocal.$marker.withValue(1) { _ = MainFoo() }
    }

    /// Control: plain deinit in a synchronous test method.
    func test_sync_plainDeinit() {
        _ = MainPlain()
    }

    /// Async test method (XCTest runs it inside a Task).
    func test_async_noTaskLocal() async {
        _ = MainFoo()
    }

    /// Custom global actor, synchronous test method (deinit is enqueued on CustomActor).
    func test_sync_customActor() {
        guard #available(macOS 15.4, *) else { return }
        _ = CustomFoo()
        Thread.sleep(forTimeInterval: 0.3)
    }
}
