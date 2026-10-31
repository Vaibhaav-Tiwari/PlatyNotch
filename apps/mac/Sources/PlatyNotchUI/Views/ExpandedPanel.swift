import PlatyNotchKit
import SwiftUI

/// Today's internal tab ids (spec 14 "tab links"), kept so `WidgetContext.openPanel(tab:)`
/// and `NotchController.expand(tab:)` callers keep working: each maps through
/// `PanelRoute.legacy` (now / today / library → Home, focus / memory / games → that feature
/// open inside Home).
enum BuiltinTab {
    /// The default destination.
    static let now = "now"
    static let agents = "agents"
    static let library = "library"
    static let today = "today"
    static let focus = "focus"
    static let memory = "memory"
    static let games = GamesWidget.tabID
}

/// The open panel (spec 2): the two destinations (Home, Agents) or an open feature's header,
/// pending approvals (always on top), then the destination or feature.
struct ExpandedPanel: View {
    let store: AppStore
    let responder: ApprovalResponder
    let arming: ApprovalArming
    let today: TodayServices
    let widgets: WidgetRegistry
    let memory: MemoryServices
    /// Plugin `panelTabs()`: features that open inside Home, never a destination of their own.
    let extraTabs: [PanelTab]
    @Binding var route: PanelRoute
    let onCollapse: () -> Void
    /// Opens the Settings window (the gear; mouse only, no keyboard shortcut).
    var onOpenSettings: () -> Void = {}
    /// Keep awake, Mirror and the battery badge in the header; nil leaves just the gear.
    var header: HeaderServices?
    /// Settings › Home: the right column.
    var homeSettings = HomeSettings()
    /// The command line under Home's hairline.
    var commandLine: AnyView = AnyView(EmptyView())
    /// A file drag is near: Home becomes drop targets.
    var dropping = false
    var dropHover: DropTargetsView.Zone?
    /// Renders only: Now at a fixed time.
    var fixedNow: Date?
    /// The Agents destination shows (`AgentsVisibility.isVisible`, via
    /// `PanelDestination.shown`); hidden until an agent first connects.
    var agentsVisible: Bool = true
    /// The Agents empty state's "Connect an agent": Settings › Agents.
    var onConnectAgent: () -> Void = {}
    /// Renders only: the Memory tool's first view.
    var memoryMode: MemoryTab.Mode = .search
    /// The first run's "Try it" sample in Now.
    var tourSample: LiveActivity?
    /// The body's natural height (header, gap, Home) while plain Home shows with no approval;
    /// nil otherwise (the panel then takes its full height). The controller applies it.
    var onBodyHeight: (CGFloat?) -> Void = { _ in }
    @State private var homeBody: CGFloat?
    /// The approvals region's height while approvals show (it is part of the body).
    @State private var approvalsHeight: CGFloat?
    let onDecide: (Approval, ApprovalBehavior) -> Void
    let onOpenTerminal: (Session) -> Void

    /// The nav's destinations (forwards to `PanelDestination.shown`).
    static func destinations(agentsVisible: Bool) -> [PanelDestination] {
        PanelDestination.shown(agentsVisible: agentsVisible)
    }

    var destinations: [PanelDestination] { Self.destinations(agentsVisible: agentsVisible) }

    /// Where a glance, the quiet line or a chip opens a feature: inside Home.
    static func route(forTool id: String) -> PanelRoute {
        PanelRoute(destination: .home, tool: id)
    }

    var body: some View {
        // An open tool is resolved alone (it redraws often).
        let normal: PanelRoute = route.normalized(agentsVisible: agentsVisible)
        let open: PanelTool? = normal.destination == .home ? normal.tool.flatMap { panelTool($0) } : nil
        // A tool that is not available now (its widget turned off) shows Home.
        let shown: PanelRoute = open == nil ? PanelRoute(destination: normal.destination) : normal
        VStack(alignment: .leading, spacing: 0) {
            header(tool: open)
                .frame(height: HomeMetrics.nav)
                .panelChrome()
            if !store.approvals.isEmpty {
                approvals
                    .frame(maxHeight: 240, alignment: .top)
                    // Its own height up to 240, so the destination below keeps the rest.
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ApprovalsRegionFrameKey.self, value: g.frame(in: .named(Self.space)))
                    })
                    .layoutPriority(1)
                    .padding(.top, HomeMetrics.gap)
            }
            destination(shown, tool: open)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Home is left unclipped: it relies on the fit tests (`NowMetrics`,
                // `NowViewTests`, `HeroViewsTests`) to stay inside, and must not clip Platy or
                // the live glyph while they morph in from the pill. Other destinations stay clipped.
                .clipped(unless: shown.destination == .home && open == nil)
                .padding(.top, open == nil ? HomeMetrics.gap : ToolHost.gap)
                .environment(\.openPanelRoute, { route = $0 })   // the games tile opens its tool
                .environment(\.openMemorySettings, { [memory] in memory.onOpenSettings() })   // empty states' one button
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(HomeHeightKey.self) { homeBody = $0 }
        .onPreferenceChange(ApprovalsRegionFrameKey.self) { approvalsHeight = $0?.height }
        .onChange(of: reportedBody, initial: true) { _, new in onBodyHeight(new) }
        // No accent colour (Quiet Notch spec 5.3): controls tint white, never system blue.
        .tint(.white)
    }

    @ViewBuilder private func header(tool: PanelTool?) -> some View {
        if let tool {
            ToolHeader(title: tool.title, onBack: goBack, trailing: AnyView(controls))
        } else {
            PanelHeader(status: headerStatus, mono: headerIsUsage, nav: { nav }, controls: { controls })
        }
    }

    @ViewBuilder private func destination(_ shown: PanelRoute, tool: PanelTool?) -> some View {
        switch shown.destination {
        case .home:
            if let tool {
                ToolBody(content: tool.view())
                    .id(tool.id)
            } else {
                homeView
            }
        case .agents:
            AgentsView(sessions: store.sessions, log: today.agentActivity.log,
                       openLoops: LoopsFormat.open(store.loops).count,
                       onOpenTerminal: onOpenTerminal, onConnect: onConnectAgent,
                       onOpenLoops: { openTool(LoopsWidget.widgetID) }, fixedNow: fixedNow)
        }
    }

    /// Home: chips, the media block beside Up next, the command line.
    var homeView: HomeView {
        HomeView(today: today, widgets: widgets, settings: homeSettings, tourSample: store.approvals.isEmpty ? tourSample : nil, fixedNow: fixedNow,
                 dropping: dropping, dropHover: dropHover, onOpenTool: { openTool($0) }, commandLine: commandLine)
    }

    /// What to tell the controller about the body's height (spec 2: the panel follows its
    /// content, 160–380 pt; the controller clamps): the header, the approvals region when
    /// approvals show, and Home's or Agents' natural height. An open tool takes the full height.
    var reportedBody: CGFloat? {
        Self.bodyHeight(toolOpen: open != nil, approvals: !store.approvals.isEmpty, approvalsHeight: approvalsHeight,
                        content: homeBody)
    }

    /// `reportedBody`'s rule (tests): nil while a tool is open or a measurement is missing.
    static func bodyHeight(toolOpen: Bool, approvals: Bool, approvalsHeight: CGFloat?, content: CGFloat?) -> CGFloat? {
        guard !toolOpen, let content else { return nil }
        var height: CGFloat = HomeMetrics.nav + HomeMetrics.gap + content
        if approvals {
            guard let approvalsHeight else { return nil }
            height += approvalsHeight + HomeMetrics.gap
        }
        return height
    }

    private var open: PanelTool? {
        let normal: PanelRoute = route.normalized(agentsVisible: agentsVisible)
        return normal.destination == .home ? normal.tool.flatMap { panelTool($0) } : nil
    }

    /// The status text at the header's trailing side: Home's date and weather, or Agents'
    /// usage as small mono numbers (`UsageLine`). An open tool has its own header.
    private var headerStatus: [String] {
        switch route.normalized(agentsVisible: agentsVisible).destination {
        case .home: [PanelHeader<EmptyView, EmptyView>.homeStatus(now: fixedNow ?? Date(), weather: weatherText)]
        case .agents: UsageLine.parts(store.usage)
        }
    }

    private var headerIsUsage: Bool {
        route.normalized(agentsVisible: agentsVisible).destination == .agents
    }

    /// `14° Clear` while the Weather widget is on and has a reading.
    private var weatherText: String? {
        guard widgets.isEnabled(WeatherWidget.widgetID),
              let w = widgets.widget(WeatherWidget.widgetID) as? WeatherWidget, w.place != nil,
              let now = w.weather else { return nil }
        let d = WeatherCode.describe(now.code, isDay: now.isDay)
        return "\(WeatherFormat.temperature(now.temperatureC, unit: w.unit)) \(d.text)"
    }

    // MARK: - Features inside the panel

    /// One tool by id, or nil when it is not available now.
    func panelTool(_ id: String) -> PanelTool? {
        let store = self.store
        let memory = self.memory
        let mode = memoryMode
        return ToolCatalog.tool(id, widgets: widgets, extraTabs: extraTabs,
                                memory: { AnyView(MemoryTab(store: store, memory: memory, mode: mode)) })
    }

    /// Every feature that opens inside the panel (`ToolCatalog`): widget tools, Platy Chase,
    /// Memory, plugin tabs.
    var panelTools: [PanelTool] {
        let store = self.store
        let memory = self.memory
        let mode = memoryMode
        return ToolCatalog.tools(widgets: widgets, extraTabs: extraTabs,
                                 memory: { AnyView(MemoryTab(store: store, memory: memory, mode: mode)) })
    }

    /// Opens a feature full-panel inside Home.
    func openTool(_ id: String) {
        route = Self.route(forTool: id)
    }

    /// The back chevron: plain Home.
    func goBack() { route = route.back() }

    // MARK: - Chrome

    /// The coordinate space the approvals region and cards report their frames in (tests).
    static var space: String { "expandedPanel" }

    /// Pending approvals, oldest first. With several, summaries are shorter (each still
    /// scrolls to its full text) so more cards fit, and the list scrolls.
    @ViewBuilder private var approvals: some View {
        let count = store.approvals.count
        let list = ApprovalList(approvals: store.approvals, sessions: store.sessions,
                                canAnswer: store.canAnswerApprovals, responder: responder, arming: arming,
                                maxLines: count > 1 ? 5 : ApprovalFormat.maxSummaryLines,
                                onDecide: onDecide, onOpenTerminal: onOpenTerminal)
        VStack(alignment: .leading, spacing: 4) {
            if count > 1 {
                Text("\(count) approvals waiting · oldest first")
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(DS.color(.needsYou))
            }
            // At its own height when it fits (the destination gets the rest), else
            // scrolling inside the 240 pt region. Cards never move: they sit at the top.
            ViewThatFits(in: .vertical) {
                list
                ScrollView(.vertical) { list }
            }
        }
    }

    /// Home and Agents (while shown), as plain text (spec 2.1): the selected one in primary
    /// ink and semibold, the other secondary; no pill behind either. Agents carries an amber
    /// dot while a session needs you.
    private var nav: some View {
        let current: PanelDestination = route.normalized(agentsVisible: agentsVisible).destination
        let needsYou: Bool = store.sessions.contains { AgentAttention.of($0, log: today.agentActivity.log, now: fixedNow ?? Date()) == .needsYou }
        return HStack(spacing: Space.header) {
            ForEach(destinations, id: \.self) { d in
                let selected: Bool = d == current
                Button { route = PanelRoute(destination: d) } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: Self.title(d))
                            .font(DS.font(TypeScale.secondary).weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? DS.primary : DS.secondary)
                            .lineLimit(1)
                        if d == .agents, needsYou {
                            Circle().fill(DS.color(.needsYou)).frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(Self.title(d)) (\u{2318}\(Self.shortcutDigit(d)))")
                .accessibilityLabel(d == .agents && needsYou ? "Agents, a session needs you" : Self.title(d))
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    /// ⌘1 / ⌘2 (`NotchController.commandDigit`).
    static func shortcutDigit(_ d: PanelDestination) -> Int {
        switch d {
        case .home: 1
        case .agents: 2
        }
    }

    static func title(_ d: PanelDestination) -> String {
        switch d {
        case .home: "Home"
        case .agents: "Agents"
        }
    }

    /// The connection state, Settings and close: at the trailing edge of the nav or a tool's header.
    private var controls: some View {
        HStack(spacing: 6) {
            if store.connection != .connected {
                // Core status is not "needs you": a quiet icon, the words for hover and VoiceOver.
                let text: String = store.connection == .connecting ? "Connecting to the core…" : "Reconnecting to the core…"
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: IconSize.symbol))
                    .foregroundStyle(DS.tertiary)
                    .frame(width: 20, height: 20)
                    .help(text)
                    .accessibilityLabel(text)
            }
            if let header {
                HeaderToggles(services: header, widgets: widgets, route: $route, onOpenSettings: onOpenSettings,
                              fixedNow: fixedNow)
            } else {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: IconSize.header))
                        .foregroundStyle(DS.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("PlatyNotch Settings")
                .accessibilityLabel("Open PlatyNotch Settings")
            }
            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close panel")
        }
    }
}

extension View {
    /// `clipped()` unless `skip`.
    @ViewBuilder func clipped(unless skip: Bool) -> some View {
        if skip { self } else { clipped() }
    }
}

/// The approvals region's frame in `ExpandedPanel.space` (layout tests).
struct ApprovalsRegionFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// Each approval card's frame in `ExpandedPanel.space`, by approval id (layout tests).
struct ApprovalCardFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
