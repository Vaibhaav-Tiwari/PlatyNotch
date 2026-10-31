import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Phase 3 fix round 1: the open panel hugs its content with an approval showing (spec 2),
/// and the Agents rows scroll under a tall approval instead of being clipped.
@MainActor
final class PanelHeightWithApprovalsTests: DefaultsTestCase {
    private final class Box: @unchecked Sendable {
        var body: CGFloat?
        var scrolls = false
    }

    private struct Rig {
        let store: AppStore
        let window: NSWindow
        let host: NSView
        let box: Box
    }

    private let width: CGFloat = PanelLayout.expandedSize.width - 2 * Space.panelSide
    private var room: CGFloat { HomeRenders.available }

    private func rig(sessions: Int, approvals: [Approval]) throws -> Rig {
        let store = AppStore()
        store.apply(.connected)
        let list: [Session] = (0..<sessions).map {
            AgentsRenders.session("s\($0)", "claude-code", "Claude Code", project: "project-\($0)", .active,
                                  title: "Running tests")
        }
        try store.apply(Envelope.make(.snapshot, Snapshot(sessions: list)))
        for a in approvals { try store.apply(Envelope.make(.approvalAdded, a)) }
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults()),
                                  focus: FocusModel(defaults: defaults()))
        let box = Box()
        var route = PanelRoute(destination: .agents)
        let panel = ExpandedPanel(store: store, responder: ApprovalResponder(client: client), arming: ApprovalArming(),
                                  today: today, widgets: WidgetRegistry(defaults: defaults(), persist: false),
                                  memory: MemoryServices(client: client), extraTabs: [],
                                  route: Binding(get: { route }, set: { route = $0 }), onCollapse: {},
                                  onBodyHeight: { v in MainActor.assumeIsolated { box.body = v } },
                                  onDecide: { _, _ in }, onOpenTerminal: { _ in })
            .frame(width: width, height: room, alignment: .top)
            .onPreferenceChange(AgentsScrollsKey.self) { v in MainActor.assumeIsolated { box.scrolls = v } }
            .environment(\.colorScheme, .dark)
            .environment(\.panelTicking, false)
            .environment(\.agentIcons, .namesOnly)
        let host = NSHostingView(rootView: AnyView(panel))
        host.frame = CGRect(x: 0, y: 0, width: width, height: room)
        // Off screen: the user is working on this Mac.
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: width, height: room),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return Rig(store: store, window: window, host: host, box: box)
    }

    func testBodyHeightRule() {
        XCTAssertNil(ExpandedPanel.bodyHeight(toolOpen: true, approvals: false, approvalsHeight: nil, content: 100))
        XCTAssertNil(ExpandedPanel.bodyHeight(toolOpen: false, approvals: true, approvalsHeight: nil, content: 100),
                     "an approval not yet measured: full height")
        XCTAssertEqual(ExpandedPanel.bodyHeight(toolOpen: false, approvals: false, approvalsHeight: nil, content: 100),
                       HomeMetrics.nav + HomeMetrics.gap + 100)
        XCTAssertEqual(ExpandedPanel.bodyHeight(toolOpen: false, approvals: true, approvalsHeight: 120, content: 100),
                       HomeMetrics.nav + HomeMetrics.gap + 120 + HomeMetrics.gap + 100)
    }

    /// One approval and three rows: the panel is shorter than its 380 pt maximum.
    func testOneApprovalAndThreeRowsHug() throws {
        let r = try rig(sessions: 3, approvals: [AgentsRenders.bashApproval()])
        let body = try XCTUnwrap(r.box.body, "the panel reports its body with an approval showing")
        let height: CGFloat = HomeRenders.layout.expandedHeight(forBody: body)
        XCTAssertLessThan(height, PanelLayout.expandedHeights.upperBound)
        XCTAssertFalse(r.box.scrolls, "everything fits: no scrolling")
    }

    /// A diff approval takes most of the room: six rows and the loops line scroll inside the
    /// rest, so the last row stays reachable.
    func testRowsScrollUnderATallApproval() throws {
        let r = try rig(sessions: 6, approvals: [AgentsRenders.editApproval("e1")])
        XCTAssertTrue(r.box.scrolls, "the list scrolls instead of being clipped")
        let body = try XCTUnwrap(r.box.body)
        XCTAssertGreaterThanOrEqual(HomeRenders.layout.expandedHeight(forBody: body), PanelLayout.expandedHeights.upperBound,
                                    "the content is taller than the panel, which takes its full height")
    }
}
