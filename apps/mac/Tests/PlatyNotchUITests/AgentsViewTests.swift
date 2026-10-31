import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Task 18: the Agents destination, and (user change) agent icons and usage chips.
@MainActor
final class AgentsViewTests: DefaultsTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private let claudeApp = "com.anthropic.claudefordesktop"
    /// Names the Claude app and nothing else, for this test only.
    private func stubHostNames() {
        let saved = HostAppName.lookup
        HostAppName.lookup = { $0 == "com.anthropic.claudefordesktop" ? "Claude" : nil }
        addTeardownBlock { @MainActor in HostAppName.lookup = saved }
    }

    private func session(_ key: String, _ state: SessionState, agent: String = "claude-code",
                         updated: TimeInterval = 0, host: String? = "com.anthropic.claudefordesktop",
                         cwd: String? = nil) -> Session {
        Session(key: key, agent: agent, agentName: agent == "codex" ? "Codex" : "Claude Code", sessionID: key,
                cwd: cwd, project: key, state: state, hostBundleID: host, startedAt: t0,
                updatedAt: t0.addingTimeInterval(updated))
    }

    func testRowButtonNamesTheHostApp() {
        stubHostNames()
        XCTAssertEqual(AgentRow.texts(session("p", .active), attention: .working, now: t0).last, "Open Claude")
    }

    func testUnknownHostRowSaysShowFolder() {
        stubHostNames()
        let s = session("p", .active, host: "com.example.gone", cwd: "/w/p")
        XCTAssertEqual(AgentRow.texts(s, attention: .working, now: t0).last, "Show folder")
        let none = session("p", .active, host: nil)
        XCTAssertNil(TerminalFocus.title(for: none), "no host and no folder: no button")
        XCTAssertEqual(AgentRow.texts(none, attention: .working, now: t0).count, 2)
    }

    private func usage(_ json: String) -> Usage {
        (try? JSONCoding.decoder.decode(Usage.self, from: Data(json.utf8))) ?? Usage()
    }

    func testRowsFollowAttentionOrder() {
        let sessions = [session("idle", .idle, updated: 50), session("work", .active, updated: 40),
                        session("ask", .waitingInput, updated: 10)]
        let view = AgentsView(sessions: sessions, usage: Usage(), log: AgentFinishLog(), onOpenTerminal: { _ in },
                              onConnect: {})
        XCTAssertEqual(view.rows(now: t0.addingTimeInterval(60)).map(\.key), ["ask", "work", "idle"])
        let shown = view.visibleTexts(now: t0.addingTimeInterval(60))
        let ask = shown.firstIndex { $0 == "ask" }
        let work = shown.firstIndex { $0 == "work" }
        XCTAssertNotNil(ask)
        XCTAssertNotNil(work)
        if let ask, let work { XCTAssertLessThan(ask, work, "\(shown)") }
    }

    func testLimitsHintOnlyAsTooltip() {
        let sessions = [session("a", .active)]
        let hint = PanelFormat.claudeLimitsHint(usage: Usage(), sessions: sessions)
        XCTAssertNotNil(hint)
        let rings = UsageRings(usage: Usage(), hint: hint)
        XCTAssertEqual(rings.hint, hint)
        let shown = AgentsView(sessions: sessions, usage: Usage(), log: AgentFinishLog(),
                               onOpenTerminal: { _ in }, onConnect: {}).visibleTexts(now: t0)
        XCTAssertFalse(shown.isEmpty)
        XCTAssertTrue(shown.contains(UsageChip.unavailableText), "\(shown)")
        XCTAssertFalse(shown.contains { $0.contains("status line") }, "\(shown)")
        // With limits, the chip says the provider, percent and window.
        let u = usage(#"{"claude":{"five_hour":{"used_percent":62},"updated_at":"2026-10-25T09:00:00Z"}}"#)
        XCTAssertNil(UsageRings(usage: u, hint: PanelFormat.claudeLimitsHint(usage: u, sessions: sessions)).hint)
        XCTAssertEqual(UsageRings(usage: u, hint: nil).visibleTexts, ["62%", "5 h"])
    }

    func testAgentsTabHiddenUntilConnected() {
        func destinations(_ v: AgentsVisibility) -> [PanelDestination] {
            let client = CoreClient(socketPath: "/nonexistent")
            let today = TodayServices(client: client, calendar: CalendarService(eventKit: false),
                                      reminders: RemindersService(eventKit: false, defaults: defaults()),
                                      focus: FocusModel(defaults: defaults()))
            var route = PanelRoute(destination: .agents)
            let panel = ExpandedPanel(store: AppStore(), responder: ApprovalResponder(client: client),
                                      arming: ApprovalArming(), today: today,
                                      widgets: WidgetRegistry(defaults: defaults(), persist: false),
                                      memory: MemoryServices(client: client), extraTabs: [],
                                      route: Binding(get: { route }, set: { route = $0 }),
                                      onCollapse: {}, agentsVisible: v.isVisible, onDecide: { _, _ in },
                                      onOpenTerminal: { _ in })
            return panel.destinations
        }
        XCTAssertEqual(destinations(AgentsVisibility()), [.home])
        XCTAssertEqual(destinations(AgentsVisibility(everConnected: true)), [.home, .agents])
        XCTAssertEqual(destinations(AgentsVisibility(forcedOn: true)), [.home, .agents])
        // A route to Agents while it is hidden shows Now.
        XCTAssertEqual(PanelRoute(destination: .agents).normalized(agentsVisible: AgentsVisibility().isVisible),
                       PanelRoute(destination: .home))
    }

    /// The app's one model notes sessions: the first connect shows Agents and tells once.
    func testFirstConnectShowsAgentsOnce() {
        let model = AgentActivityModel()
        model.loadVisibility(from: defaults())
        var told = 0
        model.onAgentsFirstShown = { told += 1 }
        model.sessionsChanged([], now: t0)
        XCTAssertFalse(model.agentsVisibility.isVisible)
        model.sessionsChanged([session("a", .active)], now: t0)
        model.sessionsChanged([session("a", .idle)], now: t0)
        XCTAssertTrue(model.agentsVisibility.isVisible)
        XCTAssertEqual(told, 1)
        XCTAssertTrue(AgentsVisibility.load(from: defaults()).everConnected, "saved")
        let store = AppStore()
        store.postLocalNotice(Notice(kind: "agents-visible", title: "Agents is in your notch now"))
        XCTAssertEqual(store.notices.last?.title, "Agents is in your notch now")
        XCTAssertEqual(store.noticeSequence, 1)
    }

    func testEmptyStateConnectCallsSettings() {
        var connected = 0
        let view = AgentsView(sessions: [], usage: Usage(), log: AgentFinishLog(), onOpenTerminal: { _ in },
                              onConnect: { connected += 1 })
        let shown = view.visibleTexts(now: t0)
        XCTAssertTrue(shown.contains("No agents running"), "\(shown)")
        XCTAssertTrue(shown.contains("Connect an agent"), "\(shown)")
        AgentsEmptyState(onConnect: view.onConnect).connect()
        XCTAssertEqual(connected, 1)
    }

    // MARK: - Agent icons (user change)

    func testInstalledAppIconComesFromTheSeam() {
        let fake = NSImage(size: NSSize(width: 32, height: 32))
        var asked: [String] = []
        let source = AgentIconSource { id in
            asked.append(id)
            return id == "com.openai.codex" ? fake : nil
        }
        let codex = AgentBrand(agent: "codex")
        XCTAssertTrue(source.icon(for: codex) === fake)
        XCTAssertEqual(asked, ["com.openai.codex"], "the allowlist only (never ChatGPT's app)")
        _ = source.icon(for: codex)
        XCTAssertEqual(asked.count, 1, "cached: looked up once per agent")
        XCTAssertEqual(AgentBadge.face(for: codex, source: source), .app)
    }

    func testMissingAppFallsBackToMonogram() {
        var asked: [String] = []
        let source = AgentIconSource { asked.append($0); return nil }
        let claude = AgentBrand(agent: "claude-code")
        XCTAssertNil(source.icon(for: claude))
        XCTAssertEqual(AgentBadge.face(for: claude, source: source), .monogram("Cl"))
        _ = source.icon(for: claude)
        XCTAssertEqual(asked, ["com.anthropic.claudefordesktop"], "a miss is cached too")
        // No allowlisted app: never looked up.
        XCTAssertEqual(AgentBadge.face(for: AgentBrand(agent: "gemini"), source: source), .monogram("Ge"))
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(AgentBadge.face(for: claude, source: .monogramsOnly), .monogram("Cl"))
    }

    func testRowSaysTheStateInWords() {
        stubHostNames()
        let shown = AgentsView(sessions: [session("p", .waitingInput)], usage: Usage(), log: AgentFinishLog(),
                               onOpenTerminal: { _ in }, onConnect: {}).visibleTexts(now: t0)
        XCTAssertTrue(shown.contains("Needs your input"), "\(shown)")
        XCTAssertEqual(shown.last, "Open Claude")
    }

    /// A working session with only a tool says it once ("Edit · just now"), not again below.
    func testLastActionNotRepeated() {
        stubHostNames()
        var s = session("p", .active)
        s.tool = "Edit"
        XCTAssertEqual(AgentRow.texts(s, attention: .working, now: t0), ["p", "Edit · just now", "Open Claude"])
        s.message = "Edit\u{200B} a.swift"
        XCTAssertEqual(AgentRow.texts(s, attention: .working, now: t0),
                       ["p", "Edit · just now", "Edit⟨U+200B⟩ a.swift", "Open Claude"])
        var ask = session("q", .waitingInput)
        ask.tool = "AskUserQuestion"
        XCTAssertEqual(AgentRow.texts(ask, attention: .needsYou, now: t0),
                       ["q", "Needs your input", "AskUserQuestion", "Open Claude"])
    }

    /// Approvals above leave little room: the header steps aside so a row still shows.
    func testHeaderStepsAsideWhenTight() {
        XCTAssertTrue(AgentsView.showsHeader(height: 300))
        XCTAssertFalse(AgentsView.showsHeader(height: 80))
        XCTAssertGreaterThanOrEqual(AgentsView.headerRoom, AgentRow.height)
    }

    /// Needs you and errors are counted apart; an errored row offers Open terminal.
    func testCountsSeparateErrors() {
        stubHostNames()
        var log = AgentFinishLog()
        log.noteFailure(sessionKey: "err", at: t0)
        let sessions = [session("ask", .waitingInput), session("err", .idle), session("w1", .active),
                        session("w2", .active)]
        let view = AgentsView(sessions: sessions, usage: Usage(), log: log, onOpenTerminal: { _ in }, onConnect: {})
        XCTAssertEqual(view.countsLine(now: t0.addingTimeInterval(5)), "4 sessions · 1 needs you · 1 error")
        XCTAssertEqual(AgentRow.texts(sessions[1], attention: .errored, now: t0).last, "Open Claude")
        let two = AgentsView(sessions: [session("a", .idle), session("b", .idle)], usage: Usage(),
                             log: { var l = AgentFinishLog(); l.noteFailure(sessionKey: "a", at: t0)
                                    l.noteFailure(sessionKey: "b", at: t0); return l }(),
                             onOpenTerminal: { _ in }, onConnect: {})
        XCTAssertEqual(two.countsLine(now: t0), "2 sessions · 2 errors")
    }

    /// An agent app installed while PlatyNotch runs: misses are forgotten on a launch, hits kept.
    func testMissesClearedWhenAnAppLaunches() {
        var installed = false
        let fake = NSImage(size: NSSize(width: 8, height: 8))
        var asked = 0
        let source = AgentIconSource { _ in asked += 1; return installed ? fake : nil }
        let claude = AgentBrand(agent: "claude-code")
        XCTAssertNil(source.icon(for: claude))
        installed = true
        XCTAssertNil(source.icon(for: claude), "cached miss")
        source.clearMisses()
        XCTAssertTrue(source.icon(for: claude) === fake)
        source.clearMisses()
        _ = source.icon(for: claude)
        XCTAssertEqual(asked, 2, "a hit is kept")
    }

}
