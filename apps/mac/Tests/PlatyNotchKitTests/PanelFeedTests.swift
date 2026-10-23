import XCTest
@testable import PlatyNotchKit

final class PanelFeedTests: XCTestCase {
    func testFirstApprovalAndNewNoticeProduceEvents() {
        var f = PanelFeed()
        XCTAssertEqual(f.update(approvalCount: 0, noticeSequence: 0), [])
        XCTAssertEqual(f.update(approvalCount: 2, noticeSequence: 0), [.approvalsChanged(count: 2)])
        XCTAssertEqual(f.update(approvalCount: 2, noticeSequence: 1), [.notice])
        XCTAssertEqual(f.update(approvalCount: 2, noticeSequence: 1), [])
        XCTAssertEqual(f.update(approvalCount: 0, noticeSequence: 2), [.approvalsChanged(count: 0), .notice])
    }

    func testSeededFeedDoesNotReplayShownNotice() {
        // A controller rebuilt after a display change starts from what was already shown.
        var f = PanelFeed(approvalCount: 0, noticeSequence: 1)
        XCTAssertEqual(f.update(approvalCount: 0, noticeSequence: 1), [])
        XCTAssertEqual(f.update(approvalCount: 0, noticeSequence: 2), [.notice])
    }

    @MainActor
    func testIdenticalConsecutiveNoticesEachPeek() throws {
        // Two equal notices (same kind and title) are two events: both must peek.
        let store = AppStore()
        var f = PanelFeed(noticeSequence: store.noticeSequence)
        let same = Notice(kind: "info", title: "Memory saved")
        store.apply(try .make(.notice, same))
        XCTAssertEqual(f.update(approvalCount: 0, noticeSequence: store.noticeSequence), [.notice])
        store.apply(try .make(.notice, same))
        XCTAssertEqual(f.update(approvalCount: 0, noticeSequence: store.noticeSequence), [.notice])
        XCTAssertEqual(f.update(approvalCount: 0, noticeSequence: store.noticeSequence), [])
    }

    func testCarriedMachineStaysExpandedAcrossRebuild() {
        var m = PanelStateMachine()
        m.handle(.click)
        var f = PanelFeed()
        _ = f.update(approvalCount: 0, noticeSequence: 1)
        // Rebuild: carry machine + feed; replaying the store produces nothing.
        var carried = PanelCarryOver(machine: m, feed: f)
        for e in carried.feed.update(approvalCount: 0, noticeSequence: 1) { carried.machine.handle(e) }
        XCTAssertEqual(carried.machine.mode, .expanded)
    }
}
