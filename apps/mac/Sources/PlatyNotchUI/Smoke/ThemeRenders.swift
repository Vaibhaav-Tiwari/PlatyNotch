import AppKit
import PlatyNotchKit
import SwiftUI

/// `--smoke` with `PLATYNOTCH_RENDER_DIR`: renders views that sit on the themed panel
/// surface in both color schemes, the way `PanelRootView` draws them (the scheme in the
/// environment, `Theme.surface(scheme)` behind), and writes `<name>-<scheme>.png`.
/// Inert models only: nothing is read, played or saved.
@MainActor
enum ThemeRenders {
    /// Writes every render; returns the number written, or the first problem.
    static func write(to dir: URL) -> Result<Int, RenderError> {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(RenderError(message: "cannot create \(dir.path): \(error.localizedDescription)"))
        }
        var count = 0
        for scheme in [ColorScheme.dark, .light] {
            for (name, view, hosted) in views() {
                let url = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                let data = hosted ? renderHosted(view, scheme: scheme) : render(view, scheme: scheme)
                guard let png = data else {
                    return .failure(RenderError(message: "\(name) did not render"))
                }
                do { try png.write(to: url) } catch {
                    return .failure(RenderError(message: "cannot write \(url.path)"))
                }
                count += 1
            }
        }
        return .success(count)
    }

    struct RenderError: Error {
        let message: String
    }

    static func framed(_ view: AnyView, scheme: ColorScheme) -> some View {
        view
            .padding(12)
            .background(Theme.surface(scheme))
            .environment(\.colorScheme, scheme)
            // Monograms, so renders look the same on every Mac (one render passes a fake app icon).
            .environment(\.agentIcons, .monogramsOnly)
    }

    private static func render(_ view: AnyView, scheme: ColorScheme) -> Data? {
        let renderer = ImageRenderer(content: framed(view, scheme: scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Views holding AppKit views (the shelf card's drag handle), which `ImageRenderer`
    /// draws as a placeholder: an off-screen hosting view's own drawing instead.
    /// `settle`: seconds the run loop turns before the capture, so a symbol or text that
    /// fades in on first appearance is drawn settled (the pill gallery).
    static func renderHosted(_ view: AnyView, scheme: ColorScheme, settle: TimeInterval = 0) -> Data? {
        let host = NSHostingView(rootView: framed(view, scheme: scheme))
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if settle > 0 {
            // In an off-screen window at 2x, so every layer draws at the window's scale.
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: host.frame.width,
                                                      height: host.frame.height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            host.layoutSubtreeIfNeeded()
            host.display()
            defer { window.orderOut(nil) }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
        guard host.bounds.width > 0, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// (file name, view, needs a hosting view)
    private static func views() -> [(String, AnyView, Bool)] {
        let soon = Date().addingTimeInterval(30)
        let bar = HUDBar(state: HUDState(kind: .volume, level: 0.6, until: soon)).frame(width: 300)
        let hud = HUDView(kind: .volume, level: 0.4, output: "MacBook Pro Speakers").frame(width: 300)   // volume, as the app shows it: with the speaker name (A6)
        let line = HUDIndicator(state: HUDState(kind: .volume, level: 0.7, until: soon)).frame(width: 300, height: 8)
        let shelf = ShelfTile(host: ShelfWidget.inert()).frame(width: 360)
        var out: [(String, AnyView, Bool)] = []
        out.append(("hud-bar", AnyView(bar), false))
        out.append(("hud-view", AnyView(hud), false))
        out.append(("hud-indicator", AnyView(line), false))
        out.append(("hud-tile", AnyView(HUDWidget.inert().tileView().frame(width: 360)), false))
        out.append(("approval-card", approvalCard(), false))
        out += games().map { ($0.0, $0.1, false) }
        out.append(("shelf-tile-empty", AnyView(shelf), false))
        out.append(("shelf-cards", shelfCards(), true))
        out.append(("memory-graph", memoryGraph(selection: nil), true))
        out.append(("memory-graph-selected", memoryGraph(selection: "t-pr"), true))
        out.append(("memory-graph-empty", memoryGraph(MemoryGraph(nodes: [], edges: []), selection: nil), true))
        out += NowRenders.views()
        for width in AppearanceSettings.PillWidth.allCases {
            for count in [4, 12] {
                out.append(("pill-\(width.rawValue)-\(count)", compactPill(width, sessions: count), true))
            }
        }
        out.append(("pill-platy-idle", PillRenders.pill(.idle, width: .standard, notch: true), true))
        out.append(("pill-agents-music", PillRenders.pill(.music, width: .standard, notch: true), true))
        out.append(("pill-indicators", PillRenders.pill(.timer, width: .wide, notch: true), true))
        return out
    }

    /// The resting pill beside a 14-inch MacBook Pro notch at `width`, with `sessions`
    /// working sessions over four agents: Platy, the dots that fit and "+n".
    private static func compactPill(_ width: AppearanceSettings.PillWidth, sessions count: Int) -> AnyView {
        let layout = PillRenders.notchLayout(width)
        let rect = layout.contentRect(for: .compact)
        let content = PillContent(activities: [], sessions: PillRenders.sessions(count), approvals: 0, hiddenKinds: [],
                                  now: Date())
        let pill = CompactPill(content: content, connection: .connected, hasNotch: true,
                               notchWidth: layout.anchor.width, liveSide: .right, earWidth: layout.liveEarWidth,
                               platy: .working)
        let view = ZStack {
            Theme.panelShape(hasNotch: true).fill(Color(PanelPalette.darkSurface))
            Color(white: 0.2).frame(width: layout.anchor.width)
            pill
        }
        .frame(width: rect.width, height: rect.height)
        .environment(\.colorScheme, .dark)
        .environment(\.panelTicking, false)
        return AnyView(view)
    }

    /// The Memory tab's Graph mode at the panel's content size, with a sample week.
    private static func memoryGraph(_ graph: MemoryGraph = MemoryGraphSample.week, selection: String?) -> AnyView {
        let model = MemoryGraphModel(preset: graph)
        let view = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Spacer(minLength: 4)
                MemoryGraphControls(model: model)
            }
            MemoryGraphView(model: model, fadeIn: false, initialSelection: selection)
        }
        return AnyView(view.frame(width: 536, height: 270))
    }

    private static func approvalCard() -> AnyView {
        let now = Date()
        // A zero-width space: the card shows "Contains hidden characters".
        let summary = "rm -rf ./build\u{200B} && npm test -- --grep \"panel\""
        let approval = Approval(id: "render", sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                                project: "platynotch", tool: "Bash", summary: summary,
                                createdAt: now, expiresAt: now.addingTimeInterval(300))
        let card = ApprovalCard(approval: approval, session: nil, canAnswer: true, phase: nil,
                                arming: ApprovalArming(), onDecide: { _ in }, onOpenTerminal: { _ in })
        return AnyView(card.frame(width: 396))
    }

    private static func games() -> [(String, AnyView)] {
        let w = GamesWidget.inert()
        var out: [(String, AnyView)] = []
        for kind in [GameKind.snake, .twenty48] {
            w.host.select(kind)
            let board = GameBoard(session: w.host.session, date: Date(), decorate: false)
            out.append(("game-\(kind.rawValue)", AnyView(board)))
        }
        return out
    }

    private static func shelfCards() -> AnyView {
        let shelf = ShelfWidget.inert()
        let now = Date()
        let text = ShelfItem(kind: .text("Meeting notes for Thursday"), addedAt: now)
        let link = ShelfItem(kind: .url(URL(string: "https://example.com/report")!), addedAt: now, pinned: true)
        let row = HStack(spacing: 6) {
            ShelfCard(host: shelf, item: text, missing: false, selected: false)
            ShelfCard(host: shelf, item: link, missing: false, selected: true)
        }
        return AnyView(row)
    }
}

/// Now at the open panel's real size beside a 38 pt camera housing (nav, approvals region
/// and Now; 528 × the room below the housing), with inert models and fixed data.
@MainActor
enum NowRenders {
    /// (file name, view, needs a hosting view): Platy is a layer-backed view.
    static func views() -> [(String, AnyView, Bool)] {
        var out: [(String, AnyView, Bool)] = []
        out.append(("now-summary", panel(builtIns(meeting: false)), true))
        out.append(("now-live-generic", panel(everythingOn()), true))
        out.append(("now-approvals-line", panel(approvalPending()), true))
        out.append(("hero-music", panel(musicHero()), true))
        out.append(("hero-timer", panel(timerHero()), true))
        out.append(("hero-meeting", panel(meetingHero()), true))
        out.append(("hero-agents", panel(agentsHero()), true))
        out.append(("peek-hover", hoverPeek(agentsHero()), true))
        out += AgentsRenders.views()
        return out
    }

    /// Every built-in on with glances, loops and tasks, and nothing live yet.
    static func builtIns(meeting: Bool) -> Rig {
        let rig = Rig()
        BuiltInWidgets.register(in: rig.registry, store: rig.store, today: rig.today, persist: false)
        rig.startAll()
        seed(rig, meeting: meeting)
        return rig
    }

    /// A track playing (no artwork in a smoke run: the placeholder).
    static func musicHero() -> Rig {
        let rig = builtIns(meeting: false)
        rig.today.nowPlaying.debugApply(NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Weightless",
                                                       artist: "Marconi Union", isPlaying: true))
        return rig
    }

    /// A 25-minute timer running.
    static func timerHero() -> Rig {
        let rig = builtIns(meeting: false)
        _ = (rig.registry.widget(TimeWidget.widgetID) as? TimeWidget)?.addTimer("25m")
        return rig
    }

    /// A meeting in 8 minutes with a video link.
    static func meetingHero() -> Rig {
        builtIns(meeting: true)
    }

    /// Two agents working.
    static func agentsHero() -> Rig {
        var rig = builtIns(meeting: false)
        rig.mood = .working
        let start = Date().addingTimeInterval(-252)
        let sessions = [
            Session(key: "a", agent: "claude-code", agentName: "Claude Code", sessionID: "a", project: "platynotch",
                    state: .active, title: "Running tests", startedAt: start, updatedAt: Date()),
            Session(key: "b", agent: "codex", agentName: "Codex", sessionID: "b", project: "api",
                    state: .active, tool: "Edit", startedAt: start.addingTimeInterval(60), updatedAt: Date()),
        ]
        try? rig.store.apply(Envelope.make(.snapshot, Snapshot(sessions: sessions, usage: rig.store.usage,
                                                               loops: rig.store.loops)))
        return rig
    }

    /// A 14-inch MacBook Pro whose camera housing is 38 pt tall.
    static let layout = PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                                    auxLeft: CGRect(x: 0, y: 944, width: 654, height: 38),
                                    auxRight: CGRect(x: 858, y: 944, width: 654, height: 38))

    /// The summary's clock: the real time, so its "Next: …" line and the meeting glance
    /// agree with the seeded calendar.
    static var fixedNow: Date { Date() }

    /// Inert models for one render.
    @MainActor
    struct Rig {
        let store = AppStore()
        let client = CoreClient(socketPath: "/nonexistent")
        let registry: WidgetRegistry
        let today: TodayServices
        let glances: UserDefaults
        var mood: PlatyMood = .idle

        init() {
            glances = UserDefaults(suiteName: "dev.platynotch.render-now") ?? .standard
            glances.removePersistentDomain(forName: "dev.platynotch.render-now")
            registry = WidgetRegistry(defaults: glances, persist: false)
            today = TodayServices(client: client, nowPlaying: NowPlaying(),
                                  visualiser: MusicVisualiser(defaults: glances),
                                  calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: glances),
                                  focus: FocusModel(defaults: glances))
        }

        /// Starts the registry (inert context) and turns every widget on.
        func startAll() {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pn-render-now")
            registry.start(context: WidgetContext(store: store, client: client,
                                                  config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                                  events: CoreEventHub(), defaults: glances, notify: NoopNotifier(),
                                                  surfaces: PanelSurfaces(registry: registry), openPanel: { _ in }))
            for w in registry.orderedWidgets { registry.setEnabled(w.id, true) }
        }
    }

    /// The open panel as `PanelRootView` lays it out: 16 pt margins, content below the
    /// camera housing, 10 pt at the bottom; clipped, so anything too tall shows.
    static func panel(_ rig: Rig, tab: String = BuiltinTab.now) -> AnyView {
        let width: CGFloat = PanelLayout.expandedSize.width - 2 * Space.panelMargin
        let height: CGFloat = NowMetrics.available(in: layout)
        var selected = tab
        let view = ExpandedPanel(store: rig.store, responder: ApprovalResponder(client: rig.client), arming: ApprovalArming(),
                                 today: rig.today, widgets: rig.registry, memory: MemoryServices(client: rig.client),
                                 extraTabs: [], selectedTab: Binding(get: { selected }, set: { selected = $0 }),
                                 onCollapse: {}, fixedNow: fixedNow, glanceDefaults: rig.glances, onDecide: { _, _ in }, onOpenTerminal: { _ in })
            .frame(width: width, height: height, alignment: .top)
            .clipped()
            .environment(\.platyMood, rig.mood)
            .environment(\.panelTicking, false)
        return AnyView(view)
    }

    /// The hover peek (Peek on hover, open on click) as `PanelRootView` lays it out beside
    /// the 38 pt camera housing: Now's hero alone in 420 × (housing + 176).
    static func hoverPeek(_ rig: Rig) -> AnyView {
        let rect: CGRect = layout.contentRect(for: .peek(.hover))
        let top: CGFloat = layout.contentInset(for: .peek(.hover))
        var deck = HeroDeck()
        let view = NowView(store: rig.store, widgets: rig.registry, today: rig.today,
                           deck: Binding(get: { deck }, set: { deck = $0 }), glanceDefaults: rig.glances,
                           onOpenTool: { _ in }, onOpenAgents: {}, onOpenTerminal: { _ in }, fixedNow: fixedNow,
                           heroOnly: true)
            .padding(EdgeInsets(top: top, leading: 12, bottom: 6, trailing: 12))
            .frame(width: rect.width, height: rect.height, alignment: .top)
            .background(alignment: .top) { Color(PanelPalette.darkSurface).frame(height: layout.anchor.height) }
            .clipped()
            .environment(\.platyMood, rig.mood)
            .environment(\.panelTicking, false)
        return AnyView(view)
    }

    /// Every built-in on, with a meeting, loops, usage and three live items.
    static func everythingOn() -> Rig {
        let rig = Rig()
        BuiltInWidgets.register(in: rig.registry, store: rig.store, today: rig.today, persist: false)
        rig.registry.register(RenderLiveWidget())
        rig.startAll()
        seed(rig, meeting: true)
        return rig
    }

    /// Music and a meeting in 8 minutes, and an approval waiting above Now.
    static func approvalPending() -> Rig {
        let rig = everythingOn()
        let created = Date()
        let approval = Approval(id: "render", sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                                project: "platynotch", tool: "Bash", summary: "npm test -- --grep \"panel\"",
                                createdAt: created, expiresAt: created.addingTimeInterval(300))
        rig.store.apply(.connected)
        try? rig.store.apply(Envelope.make(.approvalAdded, approval))
        return rig
    }

    /// Loops, usage, tasks, the glance choice and (with `meeting`) a meeting in 8 minutes.
    static func seed(_ rig: Rig, meeting: Bool) {
        let now = Date()
        let loops = [Loop(id: "l1", title: "Send Priya the deck", kind: "promise", status: "open", detectedAt: now),
                     Loop(id: "l2", title: "Review the PR", kind: "follow-up", status: "open", detectedAt: now)]
        // Limits have no public initialiser: decoded the way the core sends them.
        let json = #"{"claude":{"five_hour":{"used_percent":62},"updated_at":"2026-10-25T09:00:00Z"}}"#
        let usage: Usage = (try? JSONCoding.decoder.decode(Usage.self, from: Data(json.utf8))) ?? Usage()
        try? rig.store.apply(Envelope.make(.snapshot, Snapshot(usage: usage, loops: loops)))
        let start = now.addingTimeInterval(8 * 60)
        let later = now.addingTimeInterval(45 * 60)   // today, and not yet live
        let next = meeting ? CalendarMeeting(id: "design", title: "Design review", start: start,
                                             end: start.addingTimeInterval(1800),
                                             joinURL: URL(string: "https://meet.example.com/design"))
                           : CalendarMeeting(id: "sync", title: "Team sync", start: later, end: later.addingTimeInterval(1800))
        rig.today.calendar.setForTesting(access: .granted, meetings: [next])
        let tasks = ["Book flights", "Water the plants", "Call the bank"].enumerated().map { i, title in
            ReminderItem(id: "r\(i)", title: title, due: now, hasTime: false)
        }
        (rig.registry.widget(RemindersWidget.widgetID) as? RemindersWidget)?.reminders
            .setForTesting(access: .granted, items: tasks)
        var slots = GlanceSlots()
        slots.set([MeetingWidget.widgetID, GlanceSlots.usageID, WellbeingWidget.widgetID, LoopsWidget.widgetID])
        slots.save(to: rig.glances)
    }
}

/// A render-only widget with three live items from three "widgets" (the deck keeps one
/// entry per widget).
@MainActor
private final class RenderLiveWidget: NotchWidget {
    let id = "render.live"
    let title = "Live"
    let systemImage = "sparkles"
    let defaultEnabled = true
    var kind: WidgetKind { [.live, .tool] }

    var liveActivities: [LiveActivity] {
        let now = Date()
        return [
            LiveActivity(id: "render:timer", widgetID: "render.timer", priority: LivePriority.timerRunning,
                         glyph: .symbol("timer"), tint: .accent, countdownTo: now.addingTimeInterval(252),
                         title: "Tea", subtitle: "Timer · 5 min", startedAt: now.addingTimeInterval(-48)),
            LiveActivity(id: "render:download", widgetID: "render.download", priority: LivePriority.download,
                         glyph: .ring(progress: 0.4), tint: .accent, title: "Downloading report.pdf",
                         subtitle: "12 MB of 30 MB"),
        ]
    }

    func tileView() -> AnyView { AnyView(EmptyView()) }
}

/// The Agents destination in the open panel (Task 18): one session, four in mixed states,
/// twelve over four agents, none, and one row with a stand-in "installed app" icon passed
/// through the icon seam (a plain drawn tile, never a real logo).
@MainActor
enum AgentsRenders {
    static func views() -> [(String, AnyView, Bool)] {
        [
            ("agents-one", NowRenders.panel(rig(one()), tab: BuiltinTab.agents), true),
            ("agents-mixed", NowRenders.panel(mixed(), tab: BuiltinTab.agents), true),
            ("agents-twelve", NowRenders.panel(rig(twelve()), tab: BuiltinTab.agents), true),
            ("agents-empty", NowRenders.panel(rig([]), tab: BuiltinTab.agents), true),
            ("agents-app-icon", appIcon(), true),
            ("approval-card-command", NowRenders.panel(approvals([bashApproval()]), tab: BuiltinTab.agents), true),
            ("approval-card-diff", NowRenders.panel(approvals([editApproval("e1")]), tab: BuiltinTab.agents), true),
            ("approval-cards-diff-3", NowRenders.panel(approvals([editApproval("e1"), writeApproval(),
                                                                  editApproval("e3")]), tab: BuiltinTab.agents), true),
            ("peek-show-changes", approvalPeek(approvals([editApproval("e1"), bashApproval()])), true),
        ]
    }

    // MARK: Approvals (Task 19)

    static func approvals(_ list: [Approval]) -> NowRenders.Rig {
        let r = rig(one())
        r.store.apply(.connected)
        for a in list { try? r.store.apply(Envelope.make(.approvalAdded, a)) }
        return r
    }

    private static func make(_ id: String, tool: String, summary: String, input: [String: JSONValue],
                             age: TimeInterval) -> Approval {
        let created = Date().addingTimeInterval(-age)
        return Approval(id: id, sessionKey: "a", agent: "claude-code", agentName: "Claude Code", project: "platynotch",
                        tool: tool, summary: summary, input: RawJSON(.object(input)), createdAt: created,
                        expiresAt: created.addingTimeInterval(300))
    }

    /// A long command with a zero-width space (the card says "Contains hidden characters").
    static func bashApproval() -> Approval {
        let command = "rm -rf ./build\u{200B} && swift build -c release \\\n  && swift test --filter ApprovalPreviewCardTests --parallel"
        return make("bash", tool: "Bash", summary: command,
                    input: ["command": .string(command), "description": .string("Clean build and test")], age: 30)
    }

    static func editApproval(_ id: String) -> Approval {
        let old = (1...30).map { "    let value\($0) = compute(\($0))" }.joined(separator: "\n")
        var lines = old.components(separatedBy: "\n")
        lines[3] = "    let value4 = compute(4) // checked"
        lines[4] = "    // value5 removed"
        lines.insert("    let total = values.reduce(0, +)", at: 10)
        lines[20] = "    let value20 = try compute(20, strict: true, reportingProgressTo: progressHandler)"
        return make(id, tool: "Edit", summary: "Edit Sources/PlatyNotchUI/Agents/AgentsView.swift",
                    input: ["file_path": .string("/Users/me/src/platynotch/apps/mac/Sources/PlatyNotchUI/Agents/AgentsView.swift"),
                            "old_string": .string(old), "new_string": .string(lines.joined(separator: "\n"))],
                    age: id == "e1" ? 60 : 10)
    }

    static func writeApproval() -> Approval {
        let content = "# Notes\n\n- one\n- two\n- three\n- four\n- five"
        return make("write", tool: "Write", summary: "Write NOTES.md",
                    input: ["file_path": .string("/Users/me/src/platynotch/NOTES.md"), "content": .string(content)], age: 40)
    }

    /// The approval peek beside the 38 pt camera housing, as `PanelRootView` lays it out.
    static func approvalPeek(_ r: NowRenders.Rig) -> AnyView {
        let layout = NowRenders.layout
        let rect: CGRect = layout.contentRect(for: .peek(.approval))
        let top: CGFloat = layout.contentInset(for: .peek(.approval))
        let view = ApprovalPeek(store: r.store, responder: ApprovalResponder(client: r.client), arming: ApprovalArming(),
                                onExpand: {}, onDecide: { _, _ in }, onOpenTerminal: { _ in })
            .padding(EdgeInsets(top: top, leading: 12, bottom: 10, trailing: 12))
            .frame(width: rect.width, height: rect.height, alignment: .top)
            .background(alignment: .top) { Color(PanelPalette.darkSurface).frame(height: layout.anchor.height) }
            .clipped()
            .environment(\.panelTicking, false)
        return AnyView(view)
    }

    static let start = Date().addingTimeInterval(-4 * 60 - 20)

    static func session(_ key: String, _ agent: String, _ name: String, project: String, _ state: SessionState,
                        title: String? = nil, tool: String? = nil, message: String? = nil,
                        updated: TimeInterval = 0) -> Session {
        Session(key: key, agent: agent, agentName: name, sessionID: key, project: project, state: state, title: title,
                tool: tool, message: message, startedAt: start, updatedAt: Date().addingTimeInterval(-updated))
    }

    static func one() -> [Session] {
        [session("a", "claude-code", "Claude Code", project: "platynotch", .active, title: "Running tests",
                 tool: "Bash", message: "swift test --filter AgentsViewTests")]
    }

    static func twelve() -> [Session] {
        let agents: [(String, String)] = [("claude-code", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor"),
                                          ("gemini", "Gemini CLI")]
        let projects = ["platynotch", "api", "web", "infra", "docs", "mobile", "billing", "search", "auth", "design",
                        "a-very-long-project-name-that-keeps-going-and-going-until-it-has-to-truncate", "cli"]
        return (0..<12).map { i in
            let (agent, name) = agents[i % 4]
            return session("s\(i)", agent, name, project: projects[i], i == 7 ? .waitingInput : .active,
                           title: i % 3 == 0 ? "Refactoring the panel layout" : nil, tool: "Edit",
                           message: i % 2 == 0 ? "Edit Sources/PlatyNotchUI/Agents/AgentsView.swift" : nil,
                           updated: TimeInterval(i * 20))
        }
    }

    /// Needs you, errored, working and just finished.
    static func mixed() -> NowRenders.Rig {
        let ask = session("ask", "claude-code", "Claude Code", project: "platynotch", .waitingInput, tool: "AskUserQuestion",
                          message: "Which colour should the badge use?")
        let err = session("err", "codex", "Codex", project: "api", .idle, tool: "Bash", message: "go test ./... (exit 1)",
                          updated: 30)
        let work = session("work", "cursor", "Cursor", project: "web", .active, title: "Fixing the login form",
                           tool: "Edit", message: "Edit src/login.tsx", updated: 10)
        var done = session("done", "opencode", "OpenCode", project: "docs", .active, tool: "Write", updated: 120)
        let r = rig([ask, err, work, done])
        r.today.agentActivity.sessionsChanged([ask, err, work, done], now: Date())
        done.state = .idle
        r.today.agentActivity.sessionsChanged([ask, err, work, done], now: Date())
        r.today.agentActivity.notice(Notice(kind: "session-failed", title: "Codex stopped", sessionKey: "err"), now: Date())
        try? r.store.apply(Envelope.make(.snapshot, Snapshot(sessions: [ask, err, work, done], usage: r.store.usage)))
        return r
    }

    static func rig(_ sessions: [Session]) -> NowRenders.Rig {
        var r = NowRenders.Rig()
        r.mood = sessions.isEmpty ? .idle : .working
        let json = #"{"claude":{"five_hour":{"used_percent":62},"weekly":{"used_percent":31},"updated_at":"2026-10-25T09:00:00Z"},"codex":{"weekly":{"used_percent":91},"updated_at":"2026-10-25T09:00:00Z"}}"#
        let usage: Usage = (try? JSONCoding.decoder.decode(Usage.self, from: Data(json.utf8))) ?? Usage()
        try? r.store.apply(Envelope.make(.snapshot, Snapshot(sessions: sessions, usage: usage)))
        return r
    }

    /// A stand-in for an installed app's icon: a plain gradient tile with a symbol.
    static func fakeAppIcon() -> NSImage {
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 13, yRadius: 13)
            NSGradient(starting: NSColor(white: 0.32, alpha: 1), ending: NSColor(white: 0.12, alpha: 1))?
                .draw(in: path, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: CGRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2,
                                       width: s.width, height: s.height))
            }
            return true
        }
    }

    static func appIcon() -> AnyView {
        let icon = fakeAppIcon()
        let source = AgentIconSource { $0 == "com.anthropic.claudefordesktop" ? icon : nil }
        let r = rig(one() + [session("b", "codex", "Codex", project: "api", .idle, updated: 400)])
        let view = AgentsView(sessions: r.store.sessions, usage: r.store.usage, log: AgentFinishLog(),
                              onOpenTerminal: { _ in }, onConnect: {})
            .frame(width: PanelLayout.expandedSize.width - 2 * Space.panelMargin, height: 170, alignment: .top)
            .environment(\.agentIcons, source)
            .environment(\.panelTicking, false)
        return AnyView(view)
    }
}
