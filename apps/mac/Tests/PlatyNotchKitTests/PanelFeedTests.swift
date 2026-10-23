import XCTest
@testable import PlatyNotchKit

final class PanelFeedTests: XCTestCase {
    let n1 = Notice(kind: "info", title: "one")
    let n2 = Notice(kind: "info", title: "two")

    func testFirstApprovalAndNewNoticeProduceEvents() {
        var f = PanelFeed()
        XCTAssertEqual(f.update(approvalCount: 0, latestNotice: nil), [])
        XCTAssertEqual(f.update(approvalCount: 2, latestNotice: nil), [.approvalsChanged(count: 2)])
        XCTAssertEqual(f.update(approvalCount: 2, latestNotice: n1), [.notice])
        XCTAssertEqual(f.update(approvalCount: 2, latestNotice: n1), [])
        XCTAssertEqual(f.update(approvalCount: 0, latestNotice: n2), [.approvalsChanged(count: 0), .notice])
    }

    func testSeededFeedDoesNotReplayShownNotice() {
        // A controller rebuilt after a display change starts from what was already shown.
        var f = PanelFeed(approvalCount: 0, lastNotice: n1)
        XCTAssertEqual(f.update(approvalCount: 0, latestNotice: n1), [])
        XCTAssertEqual(f.update(approvalCount: 0, latestNotice: n2), [.notice])
    }

    func testCarriedMachineStaysExpandedAcrossRebuild() {
        var m = PanelStateMachine()
        m.handle(.click)
        var f = PanelFeed()
        _ = f.update(approvalCount: 0, latestNotice: n1)
        // Rebuild: carry machine + feed; replaying the store produces nothing.
        var carried = PanelCarryOver(machine: m, feed: f)
        for e in carried.feed.update(approvalCount: 0, latestNotice: n1) { carried.machine.handle(e) }
        XCTAssertEqual(carried.machine.mode, .expanded)
    }
}
