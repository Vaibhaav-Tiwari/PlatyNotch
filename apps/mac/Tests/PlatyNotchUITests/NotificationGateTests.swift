import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// A widget peeking with a chosen kind (or, like a plug-in from before kinds, none).
@MainActor
private final class KindWidget: NotchWidget {
    let id = "gate"
    let title = "Gate"
    let systemImage = "bell"
    let defaultEnabled = true
    var context: WidgetContext?

    func start(context: WidgetContext) { self.context = context }
    func tileView() -> AnyView { AnyView(Text(verbatim: "tile")) }
    func peekView(id: String) -> AnyView? {
        id.hasPrefix("gate.") ? AnyView(Text(verbatim: id).frame(width: 200, height: 40)) : nil
    }
}

/// Settings › Notifications in the running panel: governed peeks, rings and notices.
@MainActor
final class NotificationGateTests: DefaultsTestCase {
    @MainActor private struct Rig {
        let store: AppStore
        let surfaces: PanelSurfaces
        let registry: WidgetRegistry
        let widget: KindWidget
        let controller: NotchController
        let today: TodayServices
        var context: WidgetContext { widget.context! }
    }

    private func rig(policy: NotificationPolicy = NotificationPolicy(), focus: Bool = false) -> Rig {
        let client = CoreClient(socketPath: "/nonexistent")
        let store = AppStore()
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let surfaces = PanelSurfaces(registry: registry)
        surfaces.notificationPolicy = policy
        surfaces.focusActive = { focus }
        let w = KindWidget()
        registry.register(w)
        let today = TodayServices(client: client, focus: FocusModel(defaults: defaults()))
        registry.register(FocusWidget(focus: today.focus))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pngate\(UUID().uuidString)")
        registry.start(context: WidgetContext(store: store, client: client,
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              surfaces: surfaces, openPanel: { _ in }))
        let c = NotchController(store: store, client: client, plugins: [], today: today, widgets: registry,
                                surfaces: surfaces, appearance: AppearanceSettings())
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        return Rig(store: store, surfaces: surfaces, registry: registry, widget: w, controller: c, today: today)
    }

    private func soon() -> Date { Date().addingTimeInterval(60) }

    /// "Everything else" (downloads, charging) may not open the notch by default.
    func testDownloadPeekOffByDefault() {
        let r = rig()
        XCTAssertFalse(r.context.peek(id: "gate.download", until: soon(), as: .other))
        XCTAssertEqual(r.controller.mode, .compact)
        var open = NotificationPolicy()
        open[.other] = NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: true)
        r.surfaces.notificationPolicy = open
        XCTAssertTrue(r.context.peek(id: "gate.download", until: soon(), as: .other), "turned on, it opens")
        XCTAssertEqual(r.controller.mode, .peek(.widget(id: "gate.download")))
    }

    /// Wellbeing nudges are reminders the user asked for: they open, but not during Focus.
    func testWellbeingNudgeStillPeeks() {
        let r = rig()
        XCTAssertTrue(r.context.peek(id: "gate.water", until: soon(), as: .reminder))
        XCTAssertEqual(r.controller.mode, .peek(.widget(id: "gate.water")))
        let focused = rig(focus: true)
        XCTAssertFalse(focused.context.peek(id: "gate.water", until: soon(), as: .reminder), "quiet during Focus")
        XCTAssertEqual(focused.controller.mode, .compact)
    }

    /// A plug-in calling the old `peek(id:until:)` counts as "Plug-ins without a kind" and
    /// still opens, as it did before kinds.
    func testUndeclaredPluginPeekStillOpens() {
        let r = rig()
        XCTAssertTrue(r.context.peek(id: "gate.plugin", until: soon()))
        XCTAssertEqual(r.controller.mode, .peek(.widget(id: "gate.plugin")))
        var off = NotificationPolicy()
        off[.pluginUndeclared] = NotificationRule(showInPill: true, canOpen: false, quietDuringFocus: true)
        let quiet = rig(policy: off)
        XCTAssertFalse(quiet.context.peek(id: "gate.plugin", until: soon()), "the row governs it")
    }

    /// A confirmation of the user's own click ("Copied") is never governed.
    func testConfirmationsNotGoverned() {
        var policy = NotificationPolicy()
        for kind in NotificationKind.allCases {
            policy[kind] = NotificationRule(showInPill: false, canOpen: false, quietDuringFocus: true)
        }
        let r = rig(policy: policy, focus: true)
        XCTAssertTrue(r.context.peek(id: "gate.copied", until: soon(), as: nil))
        XCTAssertEqual(r.controller.mode, .peek(.widget(id: "gate.copied")))
        // And the real clipboard widget peeks its "Copied" card with no kind: its peek
        // goes straight through `PanelSurfaces.peek(…, kind: nil)` here.
        XCTAssertTrue(r.surfaces.peek(id: "gate.copied2", until: soon()))
    }

    /// Ringing that may not open the notch still rings: the menu bar's "Stop" and the
    /// pill and hero have it, but no panel is told to open.
    func testRingWithoutOpenStillRings() {
        var policy = NotificationPolicy()
        policy[.ringing] = NotificationRule(showInPill: true, canOpen: false, quietDuringFocus: false)
        let r = rig(policy: policy)
        XCTAssertTrue(r.context.ring(id: "gate.alarm", title: "Alarm"))
        XCTAssertEqual(r.surfaces.rings.map(\.id), ["gate.alarm"], "still ringing: Stop in the menu bar")
        XCTAssertEqual(r.controller.mode, .compact, "no ringing card")
        // A panel made later (a display change) is not told either.
        let later = NotchController(store: r.store, client: CoreClient(socketPath: "/nonexistent"), plugins: [],
                                    widgets: r.registry, surfaces: r.surfaces, appearance: AppearanceSettings())
        later.cursorLocation = { CGPoint(x: 100, y: 100) }
        XCTAssertEqual(later.mode, .compact)
        r.context.stopRinging(id: "gate.alarm")
        XCTAssertEqual(r.surfaces.rings, [])
        // On by default.
        let d = rig()
        XCTAssertTrue(d.context.ring(id: "gate.alarm", title: "Alarm"))
        XCTAssertEqual(d.controller.mode, .peek(.ringing(id: "gate.alarm")))
    }

    /// A session that starts waiting for input posts a "needs-input" notice, which peeks
    /// as "Agent needs you" (even during Focus); "Agent finished" is quiet during Focus.
    func testNeedsInputPostsNotice() {
        let r = rig()
        let activity = r.today.agentActivity
        activity.postNeedsInputNotices(to: r.store)
        let t = Date()
        func session(_ state: SessionState) -> Session {
            Session(key: "s1", agent: "claude-code", agentName: "Claude Code", sessionID: "1", project: "platynotch",
                    state: state, startedAt: t, updatedAt: t)
        }
        activity.sessionsChanged([session(.active)], now: t)
        XCTAssertEqual(r.store.notices, [], "the first look posts nothing")
        activity.sessionsChanged([session(.waitingInput)], now: t)
        XCTAssertEqual(r.store.notices.last,
                       Notice(kind: "needs-input", title: "Claude Code needs your input", body: "platynotch", sessionKey: "s1"))
        // Waiting for an approval posts nothing: the approval card is the notice.
        activity.sessionsChanged([session(.active)], now: t)
        activity.sessionsChanged([session(.blocked)], now: t)
        XCTAssertEqual(r.store.notices.count, 1)
        XCTAssertEqual(AgentActivityModel.needsInputNotices(SessionChanges(finished: [], enteredNeedsYou: ["s1"],
                                                                            allFinished: false),
                                                            sessions: [session(.blocked)]), [])
    }

    /// The store's notices peek or not by their row; info notices keep the focus hold.
    func testNoticesFollowTheirRow() {
        let r = rig()
        r.registry.setEnabled(FocusWidget.widgetID, true)
        r.today.focus.start(minutes: 25)
        XCTAssertTrue(r.today.focus.focusActive)
        defer { r.today.focus.stop() }
        r.store.postLocalNotice(Notice(kind: "session-done", title: "Done"))
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.mode, .compact, "agent finished: quiet during Focus")
        r.store.postLocalNotice(Notice(kind: "info", title: "Config reloaded"))
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.mode, .compact, "info notices keep the focus hold")
        r.store.postLocalNotice(Notice(kind: "needs-input", title: "Claude Code needs your input"))
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.mode, .peek(.notice), "needs you: not quiet during Focus")
    }

    /// Settings › Notifications' "Show in pill" reaches the panel's view model, and a change
    /// to the policy is picked up on the next store sync.
    func testHiddenKindsReachThePill() {
        var policy = NotificationPolicy()
        policy[.other] = NotificationRule(showInPill: false, canOpen: false, quietDuringFocus: true)
        let r = rig(policy: policy)
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.panelModel.hiddenKinds, [.other])
        r.surfaces.notificationPolicy = NotificationPolicy()
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.panelModel.hiddenKinds, [])
    }

    /// Settings › Now's hero cycling reaches the panel's view model (Now and the hover peek read it).
    func testHeroCyclingReachesThePanel() {
        let r = rig()
        XCTAssertTrue(r.controller.panelModel.nowSettings.heroCycling)
        r.controller.nowSettingsChanged(NowSettings(heroCycling: false))
        XCTAssertFalse(r.controller.panelModel.nowSettings.heroCycling)
        XCTAssertFalse(PanelRootView.heroCycling(r.controller.panelModel), "what the open panel and hover peek get")
        XCTAssertFalse(NowView.showsSteps(count: 3, cycling: PanelRootView.heroCycling(r.controller.panelModel)))
    }

    /// Two notices at once: the toast is the newest one that may open, not merely the newest.
    func testToastIsTheNoticeThatMayOpen() {
        let done = Notice(kind: "session-done", title: "Done")
        let needs = Notice(kind: "needs-input", title: "Claude Code needs your input")
        let policy = NotificationPolicy()
        XCTAssertEqual(NotchController.toast([needs, done], policy: policy, focusActive: true), needs,
                       "agent finished is quiet in a focus session; needs-you is not")
        XCTAssertEqual(NotchController.toast([needs, done], policy: policy, focusActive: false), done)
        XCTAssertNil(NotchController.toast([done, Notice(kind: "info", title: "x")], policy: policy, focusActive: true))
        let r = rig()
        r.registry.setEnabled(FocusWidget.widgetID, true)
        r.today.focus.start(minutes: 25)
        defer { r.today.focus.stop() }
        r.store.postLocalNotice(needs)
        r.store.postLocalNotice(done)
        r.controller.debugHandle(.syncStore)
        XCTAssertEqual(r.controller.mode, .peek(.notice))
        XCTAssertEqual(r.controller.panelModel.toastNotice, needs)
    }
}
