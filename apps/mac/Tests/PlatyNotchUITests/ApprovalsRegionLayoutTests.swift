import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Phase 4 fix round 1, I2: the open panel's approvals region, laid out for real in an
/// off-screen window. It takes its own height up to 240 pt, scrolls beyond that, and a
/// card never moves while the approvals after it come and go.
@MainActor
final class ApprovalsRegionLayoutTests: DefaultsTestCase {
    private final class Frames: @unchecked Sendable {
        var region: CGRect?
        var cards: [String: CGRect] = [:]
    }

    private struct Rig {
        let store: AppStore
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let frames: Frames
    }

    private let created = Date()

    private func approval(_ id: String, age: TimeInterval) -> Approval {
        let content = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let t = created.addingTimeInterval(-age)
        return Approval(id: id, sessionKey: "s", agent: "claude-code", agentName: "Claude Code", project: "p",
                        tool: "Write", summary: "Write notes.txt",
                        input: RawJSON(.object(["file_path": .string("/r/notes.txt"), "content": .string(content)])),
                        createdAt: t, expiresAt: t.addingTimeInterval(600))
    }

    private func rig() -> Rig {
        let store = AppStore()
        store.apply(.connected)
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults()),
                                  focus: FocusModel(defaults: defaults()))
        let frames = Frames()
        var route = PanelRoute(destination: .agents)
        let panel = ExpandedPanel(store: store, responder: ApprovalResponder(client: client), arming: ApprovalArming(),
                                  today: today, widgets: WidgetRegistry(defaults: defaults(), persist: false),
                                  memory: MemoryServices(client: client), extraTabs: [],
                                  route: Binding(get: { route }, set: { route = $0 }),
                                  onCollapse: {}, onDecide: { _, _ in }, onOpenTerminal: { _ in })
            .frame(width: 528, height: 330, alignment: .top)
            .onPreferenceChange(ApprovalsRegionFrameKey.self) { v in MainActor.assumeIsolated { frames.region = v } }
            .onPreferenceChange(ApprovalCardFramesKey.self) { v in MainActor.assumeIsolated { frames.cards = v } }
            .environment(\.colorScheme, .dark)
            .environment(\.panelTicking, false)
        let host = NSHostingView(rootView: AnyView(panel))
        host.frame = CGRect(x: 0, y: 0, width: 528, height: 330)
        // Off screen: the user is working on this Mac.
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: 528, height: 330),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        return Rig(store: store, host: host, window: window, frames: frames)
    }

    private func settle(_ r: Rig) {
        r.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        r.host.layoutSubtreeIfNeeded()
    }

    func testOneCardRegionIsTheCardHeight() throws {
        let r = rig()
        try r.store.apply(Envelope.make(.approvalAdded, approval("a", age: 30)))
        settle(r)
        let region = try XCTUnwrap(r.frames.region)
        let card = try XCTUnwrap(r.frames.cards["a"])
        XCTAssertEqual(region.height, card.height, accuracy: 0.5, "the region takes the card's own height")
        XCTAssertLessThan(region.height, 240)
        XCTAssertEqual(card.minY, region.minY, accuracy: 0.5)
    }

    func testThreeCardsScrollWithin240() throws {
        let r = rig()
        for (i, id) in ["a", "b", "c"].enumerated() {
            try r.store.apply(Envelope.make(.approvalAdded, approval(id, age: TimeInterval(30 - i))))
        }
        settle(r)
        let region = try XCTUnwrap(r.frames.region)
        XCTAssertLessThanOrEqual(region.height, 240.5)
        let last = try XCTUnwrap(r.frames.cards["c"])
        XCTAssertGreaterThan(last.maxY, region.maxY, "the third card is below the fold: the list scrolls")
    }

    /// With several cards (the header shown, `ApprovalPlacement.expanded(header: true)`),
    /// the oldest card keeps its frame while later ones arrive and are answered. Going from
    /// one card to two adds the header, which is a new placement and re-arms every card.
    func testFirstCardNeverMovesWhileOthersComeAndGo() throws {
        let r = rig()
        try r.store.apply(Envelope.make(.approvalAdded, approval("a", age: 30)))
        try r.store.apply(Envelope.make(.approvalAdded, approval("b", age: 20)))
        settle(r)
        let two = try XCTUnwrap(r.frames.cards["a"])
        try r.store.apply(Envelope.make(.approvalAdded, approval("c", age: 10)))
        settle(r)
        XCTAssertEqual(r.frames.cards["a"], two, "adding a later card")
        try r.store.apply(Envelope.make(.approvalResolved, ApprovalResolved(id: "c", behavior: "allow")))
        settle(r)
        XCTAssertEqual(r.frames.cards["a"], two, "resolving a later card")
        XCTAssertEqual(ApprovalPlacement(mode: .expanded, count: 1), .expanded(header: false))
        XCTAssertEqual(ApprovalPlacement(mode: .expanded, count: 3), ApprovalPlacement(mode: .expanded, count: 2))
    }
}
