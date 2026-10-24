import XCTest
@testable import PlatyNotchKit

private final class FakeAX: ManualAccessibilityAX, @unchecked Sendable {
    var settable: Set<pid_t> = []
    var calls: [String] = []
    func isSettable(pid: pid_t) -> Bool {
        calls.append("settable? \(pid)")
        return settable.contains(pid)
    }
    func set(_ on: Bool, pid: pid_t) { calls.append("set \(on) \(pid)") }
}

final class ManualAccessibilityTests: XCTestCase {
    func testOnlySettableAppsOnceEachAndAllUndone() {
        let ax = FakeAX()
        ax.settable = [10, 20]
        let m = ManualAccessibility(ax: ax)
        m.enable(pid: 10)
        m.enable(pid: 10)
        m.enable(pid: 30)   // a native app: not settable, never set
        m.enable(pid: 30)
        m.enable(pid: 20)
        XCTAssertEqual(m.enabled, [10, 20])
        XCTAssertEqual(ax.calls, ["settable? 10", "set true 10", "settable? 30", "settable? 20", "set true 20"])
        ax.calls = []
        m.disableAll()
        XCTAssertEqual(ax.calls, ["set false 10", "set false 20"])
        XCTAssertTrue(m.enabled.isEmpty)
        ax.calls = []
        m.enable(pid: 10)   // capture resumed: asked again
        XCTAssertEqual(ax.calls, ["settable? 10", "set true 10"])
    }
}
