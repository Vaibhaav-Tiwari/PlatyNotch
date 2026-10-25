import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// User feedback round 1: Settings from inside the notch (11), Calendar from the notch (8),
/// Apple Music's heart (6).
@MainActor
final class FeedbackFixesTests: DefaultsTestCase {

    private var mbpLayout: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }

    private func controller() -> NotchController {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let c = NotchController(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"), plugins: [],
                                widgets: registry, surfaces: PanelSurfaces(registry: registry))
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        c.debugHandle(.layout(mbpLayout))
        return c
    }

    /// The open panel's gear opens Settings through the app (the menu bar icon may be
    /// hidden) and changes nothing in the panel: no collapse, no approval answered.
    func testGearInTheOpenPanelOpensSettings() {
        let c = controller()
        var opened = 0
        c.onOpenSettings = { opened += 1 }
        c.expand()
        XCTAssertEqual(c.mode, .expanded)
        c.panelModel.onOpenSettings()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(c.mode, .expanded)
    }

    // MARK: - The gear in the views

    private func approval(_ id: String) -> Approval {
        let created = Date()
        return Approval(id: id, sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                        project: nil, cwd: nil, tool: "Bash", summary: "ls",
                        createdAt: created, expiresAt: created.addingTimeInterval(600))
    }

    /// The three destinations (Focus, Memory and Games are Library tools now) and "Reconnecting…".
    private func fullPanel(store: AppStore, onOpenSettings: @escaping () -> Void) -> ExpandedPanel {
        let client = CoreClient(socketPath: "/nonexistent")
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let today = TodayServices(client: client, calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults()))
        registry.register(FocusWidget(focus: today.focus))
        registry.register(GamesWidget(defaults: nil))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnfb\(UUID().uuidString)")
        registry.start(context: WidgetContext(store: store, client: client,
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              surfaces: PanelSurfaces(registry: registry), openPanel: { _ in }))
        registry.setEnabled(FocusWidget.widgetID, true)
        registry.setEnabled(GamesWidget.widgetID, true)
        var route = PanelRoute(destination: .agents)
        return ExpandedPanel(store: store, responder: ApprovalResponder(client: client), arming: ApprovalArming(),
                             today: today, widgets: registry, memory: MemoryServices(client: client), extraTabs: [],
                             route: Binding(get: { route }, set: { route = $0 }),
                             onCollapse: {}, onOpenSettings: onOpenSettings,
                             onDecide: { _, _ in }, onOpenTerminal: { _ in })
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<some View> {
        let h = NSHostingView(rootView: view.frame(width: width, height: height)
            .background(Color(white: 0.08)).environment(\.colorScheme, .dark))
        h.frame = CGRect(x: 0, y: 0, width: width, height: height)
        h.layoutSubtreeIfNeeded()
        return h
    }

    /// The open panel's gear action is the panel's `onOpenSettings` (which the controller
    /// wires to Settings, `testGearInTheOpenPanelOpensSettings`); the approval peek takes no
    /// such action at all, so it cannot show a gear. (SwiftUI builds no accessibility tree
    /// for an unshown test window, so the button itself is checked in the render below.)
    func testGearIsInTheOpenPanelAndNotInTheApprovalPeek() throws {
        let store = AppStore()
        store.apply(.connected)
        try store.apply(Envelope.make(.approvalAdded, approval("a")))
        var opened = 0
        let panel = fullPanel(store: store, onOpenSettings: { opened += 1 })
        panel.onOpenSettings()
        XCTAssertEqual(opened, 1)
        let client = CoreClient(socketPath: "/nonexistent")
        let peek = ApprovalPeek(store: store, responder: ApprovalResponder(client: client), arming: ApprovalArming(),
                                onExpand: {}, onDecide: { _, _ in }, onOpenTerminal: { _ in })
        let peekInputs = Mirror(reflecting: peek).children.compactMap(\.label)
        XCTAssertFalse(peekInputs.contains { $0.lowercased().contains("settings") }, "\(peekInputs)")
        let panelInputs = Mirror(reflecting: panel).children.compactMap(\.label)
        XCTAssertTrue(panelInputs.contains("onOpenSettings"), "\(panelInputs)")
    }

    /// Feedback 11 render check: every built-in tab, "Reconnecting…", the gear and the
    /// close chevron fit the narrowest open panel (its ideal width is within the content
    /// width). Writes the PNG for a look when PLATYNOTCH_RENDER_DIR is set.
    func testTabBarFitsWithEveryTabAndReconnecting() throws {
        let store = AppStore()
        store.apply(.connected)
        store.apply(.disconnected)
        XCTAssertEqual(store.connection, .reconnecting)
        let width = PanelLayout.expandedSize.width - 24   // the panel's 12 pt padding each side
        let ideal = NSHostingView(rootView: fullPanel(store: store, onOpenSettings: {}).fixedSize(horizontal: true, vertical: false))
        XCTAssertLessThanOrEqual(ideal.fittingSize.width, width, "the tab bar would crowd")
        let view = host(fullPanel(store: store, onOpenSettings: {}), width: width, height: 340)
        if let dir = ProcessInfo.processInfo.environment["PLATYNOTCH_RENDER_DIR"] {
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tabbar-reconnecting.png"))
        }
    }

    func testSettingsURLRoutes() {
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings")!), .settings(section: nil))
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings/widgets")!), .settings(section: "widgets"))
    }

    // MARK: - 8. Calendar / Reminders access from the notch

    /// What a prompt request did, in order.
    private final class FocusLog {
        var steps: [String] = []
        var active = false
        var front: pid_t? = 4242
    }

    private func focus(_ log: FocusLog) -> PromptFocus {
        PromptFocus(isActive: { log.active },
                    frontmost: { log.front },
                    activate: { log.steps.append("activate"); log.active = true },
                    restore: { log.steps.append("restore \($0)") })
    }

    /// The notch panel never activates the app, and EventKit shows its prompt only for the
    /// active app: the request from the tile activates PlatyNotch first and gives the
    /// keyboard back to the app that had it once answered.
    func testCalendarRequestFromTheNotchActivatesTheAppFirst() async {
        let log = FocusLog()
        var status = CalendarService.Access.notAsked
        let calendar = CalendarService(seam: .init(status: { status }, request: {
            log.steps.append("request active=\(log.active)")
            status = .granted
            return true
        }), focus: focus(log))
        await calendar.requestAccess()
        XCTAssertEqual(log.steps, ["activate", "request active=true", "restore 4242"])
        XCTAssertEqual(calendar.access, .granted)
    }

    func testRemindersRequestFromTheNotchActivatesTheAppFirst() async {
        let log = FocusLog()
        var status = RemindersService.Access.notAsked
        let reminders = RemindersService(seam: .init(status: { status }, request: {
            log.steps.append("request active=\(log.active)")
            status = .denied
            return false
        }), focus: focus(log), defaults: defaults())
        await reminders.requestAccess()
        XCTAssertEqual(log.steps, ["activate", "request active=true", "restore 4242"])
        XCTAssertEqual(reminders.access, .denied)
    }

    /// The user switched to another app while the prompt was up: it is left in front.
    func testNoRestoreWhenTheUserMovedOn() async {
        let log = FocusLog()
        let calendar = CalendarService(seam: .init(status: { .notAsked }, request: {
            log.active = false   // e.g. the user clicked into another app meanwhile
            return true
        }), focus: focus(log))
        await calendar.requestAccess()
        XCTAssertEqual(log.steps, ["activate"])
    }

    /// Already active (the Settings window): nothing is activated or handed back.
    func testRequestWhileActiveLeavesFocusAlone() async {
        let log = FocusLog()
        log.active = true
        let calendar = CalendarService(seam: .init(status: { .notAsked }, request: { true }), focus: focus(log))
        await calendar.requestAccess()
        XCTAssertEqual(log.steps, [])
    }

    // MARK: - 6. Apple Music's heart

    private final class FakeMusic: @unchecked Sendable {
        let lock = NSLock()
        var toggleResult: MusicFavourite.Outcome = .state(true)
        var readResult: MusicFavourite.Outcome = .state(false)
        var allowed = false
        var toggles = 0
        var reads = 0

        var scripting: MusicScripting {
            MusicScripting(isRunning: { true },
                           allowedWithoutAsking: { self.lock.withLock { self.allowed } },
                           toggle: { self.lock.withLock { self.toggles += 1; return self.toggleResult } },
                           read: { self.lock.withLock { self.reads += 1; return self.readResult } })
        }
    }

    private func musicTrack(_ title: String) -> NowPlayingInfo {
        NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: title, artist: "Someone", isPlaying: true)
    }

    private func nowPlaying(_ fake: FakeMusic, identity: String = "dr:build-A") -> NowPlaying {
        let np = NowPlaying()
        np.music = fake.scripting
        np.grants = AutomationGrants(defaults: defaults(), identity: { identity })
        return np
    }

    /// A refused click used to do nothing at all: now it says why, with the Automation steps.
    func testHeartRefusedSaysWhy() async {
        let fake = FakeMusic()
        fake.toggleResult = .notAllowed
        let np = nowPlaying(fake)
        np.debugApply(musicTrack("Song"))
        XCTAssertTrue(np.canLike)
        np.toggleLike()
        let said = await eventually { np.likeMessage != nil }
        XCTAssertTrue(said)
        XCTAssertNil(np.liked, "the heart does not claim a change that did not happen")
        XCTAssertTrue(np.likeMessage?.contains("Automation › PlatyNotch › Music") == true, np.likeMessage ?? "")
        XCTAssertEqual(np.likeHelp, .automation(reset: true))
        XCTAssertFalse(np.likeBusy)
    }

    /// Success fills the heart from Music's answer; after that a refusal on a new build
    /// names the rebuild and the reset command.
    func testHeartFollowsMusicAndExplainsARebuild() async {
        let fake = FakeMusic()
        let np = nowPlaying(fake)
        np.debugApply(musicTrack("Song"))
        np.toggleLike()
        let liked = await eventually { np.liked == true }
        XCTAssertTrue(liked)
        XCTAssertNil(np.likeMessage)

        let rebuilt = nowPlaying(fake, identity: "dr:build-B")
        fake.toggleResult = .notAllowed
        rebuilt.debugApply(musicTrack("Song"))
        rebuilt.toggleLike()
        let said = await eventually { rebuilt.likeMessage != nil }
        XCTAssertTrue(said)
        XCTAssertTrue(rebuilt.likeMessage?.contains(PermissionAdvice.resetAppleEvents) == true,
                      rebuilt.likeMessage ?? "")
    }

    /// The heart is read when the tile appears and on a track change while it is shown,
    /// only when Music already allows PlatyNotch; never for a heart nobody sees.
    func testHeartIsReadOnlyWhileShownAndAllowed() async {
        let fake = FakeMusic()
        fake.readResult = .state(true)
        fake.lock.withLock { fake.allowed = true }
        let np = nowPlaying(fake)
        np.debugApply(musicTrack("One"))
        await drainBackground()
        XCTAssertEqual(fake.lock.withLock { fake.reads }, 0, "no music view on screen: nothing read")
        XCTAssertNil(np.liked)

        np.setVisible(true)
        let read = await eventually { np.liked == true }
        XCTAssertTrue(read, "read once when the tile appears")

        fake.readResult = .state(false)
        np.debugApply(musicTrack("Two"))
        let next = await eventually { np.liked == false }
        XCTAssertTrue(next, "a new track while shown is read too")

        np.setVisible(false)
        let reads = fake.lock.withLock { fake.reads }
        np.debugApply(musicTrack("Three"))
        await drainBackground()
        XCTAssertEqual(fake.lock.withLock { fake.reads }, reads, "hidden again: no reads")
    }

    /// Not allowed yet: no Apple Event at all (so no prompt), even with the tile shown.
    func testHeartIsNotReadBeforeMusicAllows() async {
        let fake = FakeMusic()
        let np = nowPlaying(fake)
        np.debugApply(musicTrack("One"))
        np.setVisible(true)
        await drainBackground()
        XCTAssertEqual(fake.lock.withLock { fake.reads }, 0)
        XCTAssertNil(np.liked)
        np.setVisible(false)
    }

    /// Lets the AppleScript queue and the main-actor hop after it run.
    private func drainBackground() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            AppleScriptPlayer.queue.async { c.resume() }
        }
        await drainMainQueue()
        for _ in 0..<5 { await Task.yield() }
    }
}

/// Fix round 2: Allow follow-ups.
@MainActor
final class AllowFollowUpTests: XCTestCase {
    /// Allow, away and back: the return counts only after PlatyNotch resigned.
    func testReturnCountsOnlyAfterResigning() {
        var a = AllowReturn()
        a.appResigned()
        a.appBecameActive()
        XCTAssertFalse(a.returned, "before Allow nothing counts")
        a.allowClicked()
        a.appBecameActive()
        XCTAssertFalse(a.returned, "the prompt going away reactivates the app: not a visit")
        a.appResigned()
        a.appBecameActive()
        XCTAssertTrue(a.returned)
        a.allowClicked()
        XCTAssertFalse(a.returned, "a new click starts over")
    }

    /// A second Allow click replaces the first follow-up poll instead of stacking another.
    func testSecondAllowClickCancelsTheFirstPoll() {
        let trust = AccessibilityTrust(isTrusted: { false }, request: {})
        let p = Permissions(calendar: CalendarService(eventKit: false), reminders: RemindersService(eventKit: false),
                            trust: trust)
        p.requestAccessibility()
        let first = p.accessibilityPoll
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.isCancelled, false)
        p.requestAccessibility()
        XCTAssertEqual(first?.isCancelled, true)
        XCTAssertEqual(p.accessibilityPoll?.isCancelled, false)
        p.accessibilityPoll?.cancel()
    }
}
