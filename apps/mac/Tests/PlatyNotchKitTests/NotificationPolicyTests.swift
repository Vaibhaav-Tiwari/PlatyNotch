import Foundation
import PlatyNotchKit
import XCTest

final class NotificationPolicyTests: DefaultsTestCase {
    /// Spec 6.3 with Rulings 8 and 17: (show in pill, can open, quiet during Focus).
    func testDefaultsTable() {
        let expected: [(NotificationKind, Bool, Bool, Bool)] = [
            (.approval, true, true, false),
            (.agentNeedsYou, true, true, false),
            (.agentFinished, true, true, true),
            (.ringing, true, true, false),
            (.meetingStarting, true, true, true),
            (.reminder, true, true, true),
            (.other, true, false, true),
            (.pluginUndeclared, true, true, true),
        ]
        XCTAssertEqual(expected.count, NotificationKind.allCases.count, "every row is in the table")
        let p = NotificationPolicy()
        for (kind, pill, open, quiet) in expected {
            XCTAssertEqual(p[kind], NotificationRule(showInPill: pill, canOpen: open, quietDuringFocus: quiet), "\(kind)")
        }
        XCTAssertEqual(p.hiddenInPill, [])
    }

    func testApprovalCellsLocked() {
        var p = NotificationPolicy()
        for field in NotificationField.allCases {
            XCTAssertTrue(NotificationPolicy.isLocked(.approval, field))
            XCTAssertFalse(NotificationPolicy.isLocked(.agentNeedsYou, field))
        }
        p[.approval] = NotificationRule(showInPill: false, canOpen: false, quietDuringFocus: true)
        XCTAssertEqual(p[.approval], NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: false))
        XCTAssertTrue(p.mayOpen(.approval, focusActive: true))
        XCTAssertFalse(p.hiddenInPill.contains(.approval))
        // Damaged or hand-edited saved values cannot silence approvals either.
        let json = #"{"approval":{"showInPill":false,"canOpen":false,"quietDuringFocus":true}}"#
        defaults().set(Data(json.utf8), forKey: NotificationPolicy.key)
        XCTAssertEqual(NotificationPolicy.load(from: defaults())[.approval], NotificationPolicy.defaultRule(.approval))
    }

    func testQuietDuringFocus() {
        let p = NotificationPolicy()
        XCTAssertFalse(p.mayOpen(.agentFinished, focusActive: true))
        XCTAssertTrue(p.mayOpen(.agentFinished, focusActive: false))
        XCTAssertTrue(p.mayOpen(.agentNeedsYou, focusActive: true))
        XCTAssertFalse(p.mayOpen(.reminder, focusActive: true))
        XCTAssertTrue(p.mayOpen(.reminder, focusActive: false))
        XCTAssertFalse(p.mayOpen(.other, focusActive: false), "everything else never opens by default")
        XCTAssertTrue(p.mayOpen(.pluginUndeclared, focusActive: false), "today's plug-in behaviour")
    }

    func testNoticeKinds() {
        XCTAssertEqual(NotificationPolicy.kind(noticeKind: "session-done"), .agentFinished)
        XCTAssertEqual(NotificationPolicy.kind(noticeKind: "session-failed"), .agentNeedsYou)
        XCTAssertEqual(NotificationPolicy.kind(noticeKind: "approval-timeout"), .agentNeedsYou)
        XCTAssertEqual(NotificationPolicy.kind(noticeKind: "needs-input"), .agentNeedsYou)
        XCTAssertNil(NotificationPolicy.kind(noticeKind: "info"))
        XCTAssertNil(NotificationPolicy.kind(noticeKind: "agents-visible"))
    }

    func testRoundTrip() {
        XCTAssertEqual(NotificationPolicy.load(from: defaults()), NotificationPolicy(), "nothing saved: the defaults")
        var p = NotificationPolicy()
        p[.agentFinished] = NotificationRule(showInPill: false, canOpen: false, quietDuringFocus: false)
        p[.other] = NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: false)
        p.save(to: defaults())
        let loaded = NotificationPolicy.load(from: defaults())
        XCTAssertEqual(loaded, p)
        XCTAssertEqual(loaded.hiddenInPill, [.agentFinished])
        defaults().set(Data("not json".utf8), forKey: NotificationPolicy.key)
        XCTAssertEqual(NotificationPolicy.load(from: defaults()), NotificationPolicy(), "damaged: the defaults")
        // A value saved before a kind existed gives that kind its default.
        defaults().set(Data(#"{"other":{"showInPill":false,"canOpen":true,"quietDuringFocus":false}}"#.utf8),
                       forKey: NotificationPolicy.key)
        let partial = NotificationPolicy.load(from: defaults())
        XCTAssertEqual(partial[.other], NotificationRule(showInPill: false, canOpen: true, quietDuringFocus: false))
        XCTAssertEqual(partial[.reminder], NotificationPolicy.defaultRule(.reminder))
    }

    func testFeedDropsDisallowedNotice() {
        var feed = PanelFeed()
        XCTAssertEqual(feed.update(approvalCount: 0, noticeSequence: 1, allowNotice: false), [])
        XCTAssertEqual(feed.noticeSequence, 1, "consumed: it never replays")
        XCTAssertEqual(feed.update(approvalCount: 0, noticeSequence: 1), [])
        XCTAssertEqual(feed.update(approvalCount: 0, noticeSequence: 2), [.notice])
        // Approvals are never gated.
        XCTAssertEqual(feed.update(approvalCount: 1, noticeSequence: 3, holdNotices: true, allowNotice: false),
                       [.approvalsChanged(count: 1)])
    }
}
