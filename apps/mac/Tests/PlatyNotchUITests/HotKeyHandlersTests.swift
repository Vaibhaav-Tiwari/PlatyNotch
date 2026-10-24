import XCTest
@testable import PlatyNotchUI

/// R6: press and release route to their own handlers; no real shortcut is registered.
@MainActor
final class HotKeyHandlersTests: DefaultsTestCase {
    func testPressAndReleaseRouteSeparately() {
        var log: [String] = []
        var handlers = HotKeyHandlers()
        handlers.set(1, press: { log.append("down 1") }, release: { log.append("up 1") })
        handlers.set(2, press: { log.append("down 2") }, release: nil)

        XCTAssertTrue(handlers.dispatch(1, released: false))
        XCTAssertTrue(handlers.dispatch(1, released: true))
        XCTAssertTrue(handlers.dispatch(2, released: false))
        XCTAssertFalse(handlers.dispatch(2, released: true), "no release handler: ignored, as before")
        XCTAssertFalse(handlers.dispatch(3, released: false), "not ours")
        XCTAssertEqual(log, ["down 1", "up 1", "down 2"])

        handlers.remove(1)
        XCTAssertFalse(handlers.dispatch(1, released: false))
        XCTAssertFalse(handlers.dispatch(1, released: true))
    }
}
