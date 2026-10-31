import PlatyNotchKit
import SwiftUI

/// Today's internal tab ids (spec 14 "tab links"), kept so `WidgetContext.openPanel(tab:)`
/// and `NotchController.expand(tab:)` callers keep working: each maps through
/// `PanelRoute.legacy` (today → Now, focus / memory / games → that Library tool).
enum BuiltinTab {
    /// The default destination (spec 6.4).
    static let now = "now"
    static let agents = "agents"
    static let library = "library"
    static let today = "today"
    static let focus = "focus"
    static let memory = "memory"
    static let games = GamesWidget.tabID
}

/// The open panel (spec 6.1): the three destinations (Now, Agents, Library) or an open
/// Library tool's header, pending approvals (always on top), then the destination or tool.
struct ExpandedPanel: View {
    let store: AppStore
    let responder: ApprovalResponder
    let arming: ApprovalArming
    let today: TodayServices
    let widgets: WidgetRegistry
    let memory: MemoryServices
    /// Plugin `panelTabs()`: Library tools, never a destination of their own (spec 6.9).
    let extraTabs: [PanelTab]
    @Binding var route: PanelRoute
    let onCollapse: () -> Void
    /// Opens the Settings window (the gear; mouse only, no keyboard shortcut).
    var onOpenSettings: () -> Void = {}
    /// Keep awake, Mirror and the battery badge in the header; nil leaves just the gear.
    var header: HeaderServices?
    /// Now's hero selection (the panel model's; reset on each open).
    var deck: Binding<HeroDeck> = .constant(HeroDeck())
    /// Renders only: Now at a fixed time.
    var fixedNow: Date?
    /// Where Now's chosen glances and the Library's recents are saved (renders and tests
    /// pass their own).
    var glanceDefaults: UserDefaults = .standard
    /// The Agents destination shows (`AgentsVisibility.isVisible`, via
    /// `PanelDestination.shown`); hidden until an agent first connects.
    var agentsVisible: Bool = true
    /// The Agents empty state's "Connect an agent": Settings › Agents.
    var onConnectAgent: () -> Void = {}
    /// Renders only: the Memory tool's first view.
    var memoryMode: MemoryTab.Mode = .search
    /// Existing users' tour card at the top of Now (spec 14).
    var tourOffer: TourOffer?
    /// The first run's "Try it" sample in Now.
    var tourSample: LiveActivity?
    /// Settings › Now › hero cycling (`PanelViewModel.nowSettings`).
    var heroCycling: Bool = true
    let onDecide: (Approval, ApprovalBehavior) -> Void
    let onOpenTerminal: (Session) -> Void

    /// The nav's destinations (forwards to `PanelDestination.shown`).
    static func destinations(agentsVisible: Bool) -> [PanelDestination] {
        PanelDestination.shown(agentsVisible: agentsVisible)
    }

    var destinations: [PanelDestination] { Self.destinations(agentsVisible: agentsVisible) }

    /// Where a glance, the quiet line or a tile opens a tool.
    static func route(forTool id: String) -> PanelRoute {
        PanelRoute(destination: .library, tool: id)
    }

    var body: some View {
        // An open tool is resolved alone (it redraws often); the grid builds the catalog.
        let normal: PanelRoute = route.normalized(agentsVisible: agentsVisible)
        let open: LibraryTool? = normal.destination == .library ? normal.tool.flatMap { libraryTool($0) } : nil
        let tools: [LibraryTool] = normal.destination == .library && open == nil ? libraryTools : []
        // A tool that is not in the Library now (its widget turned off) shows the grid.
        let shown: PanelRoute = open == nil ? PanelRoute(destination: normal.destination) : normal
        VStack(alignment: .leading, spacing: 0) {
            header(tool: open)
                .frame(height: NowMetrics.nav)
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
                    .padding(.top, NowMetrics.gap)
            }
            destination(shown, tool: open, tools: tools)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Now is left unclipped: it relies on the fit tests (`NowMetrics`,
                // `NowViewTests`, `HeroViewsTests`) to stay inside, and must not clip Platy or
                // the live glyph while they morph in from the pill. Other destinations stay clipped.
                .clipped(unless: shown.destination == .now)
                .padding(.top, open == nil ? NowMetrics.gap : ToolHost.gap)
                .environment(\.openPanelRoute, { route = $0 })   // the games tile opens its tool
                .environment(\.openMemorySettings, { [memory] in memory.onOpenSettings() })   // empty states' one button
        }
        .coordinateSpace(name: Self.space)
        // One accent: prominent buttons and controls in brand teal, never system blue.
        .tint(DS.dynamicColor(.working))
    }

    @ViewBuilder private func header(tool: LibraryTool?) -> some View {
        if let tool {
            ToolHeader(title: tool.item.title, onBack: goBack, trailing: AnyView(controls))
        } else {
            HStack(spacing: 2) {
                nav
                Spacer(minLength: 4)
                controls
            }
        }
    }

    @ViewBuilder private func destination(_ shown: PanelRoute, tool: LibraryTool?, tools: [LibraryTool]) -> some View {
        switch shown.destination {
        case .now:
            nowView
        case .agents:
            AgentsView(sessions: store.sessions, usage: store.usage, log: today.agentActivity.log,
                       onOpenTerminal: onOpenTerminal, onConnect: onConnectAgent, fixedNow: fixedNow)
        case .library:
            if let tool {
                ToolBody(content: tool.view())
                    .id(tool.item.id)
            } else {
                LibraryView(items: sortedItems(tools), tile: { id in tools.first { $0.item.id == id }?.tile },
                            onOpen: { openTool($0) }, onSetUp: { setUp($0) })
            }
        }
    }

    /// Now; its glances and quiet line open their tool directly.
    var nowView: NowView {
        NowView(store: store, widgets: widgets, today: today, deck: deck, glanceDefaults: glanceDefaults,
                onOpenTool: { openTool($0) },
                onOpenAgents: { route = PanelRoute(destination: .agents) }, onOpenTerminal: onOpenTerminal,
                fixedNow: fixedNow, cycling: heroCycling,
                tourOffer: tourOffer, tourSample: tourSample)
    }

    // MARK: - Library

    /// One tool by id, or nil when it is not in the Library now.
    func libraryTool(_ id: String) -> LibraryTool? {
        let store = self.store
        let memory = self.memory
        let mode = memoryMode
        return LibraryCatalog.tool(id, widgets: widgets, extraTabs: extraTabs,
                                   memory: { AnyView(MemoryTab(store: store, memory: memory, mode: mode)) })
    }

    /// The Library's tools in input order (`LibraryCatalog`): widget tools, Platy Chase,
    /// Memory, plugin tabs.
    var libraryTools: [LibraryTool] {
        let store = self.store
        let memory = self.memory
        let mode = memoryMode
        return LibraryCatalog.tools(widgets: widgets, extraTabs: extraTabs,
                                    memory: { AnyView(MemoryTab(store: store, memory: memory, mode: mode)) })
    }

    /// The grid's order: recently used first.
    func sortedLibraryItems() -> [LibraryItem] { sortedItems(libraryTools) }

    private func sortedItems(_ tools: [LibraryTool]) -> [LibraryItem] {
        LibraryOrder.sorted(tools.map(\.item), recents: LibraryRecentsCache.resolve(from: glanceDefaults))
    }

    /// Opens a tool full-panel and notes it for the grid's order.
    func openTool(_ id: String) {
        var recents = LibraryRecents.load(from: glanceDefaults)
        recents.noteOpened(id, at: Date())
        recents.save(to: glanceDefaults)
        route = Self.route(forTool: id)
    }

    /// The back chevron: the Library grid.
    func goBack() { route = route.back() }

    /// A dimmed tile's "Set up": the widget's own setup, else its settings page.
    func setUp(_ id: String) { widgets.runSetup(id) }

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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.color(.attention))
            }
            // At its own height when it fits (the destination gets the rest), else
            // scrolling inside the 240 pt region. Cards never move: they sit at the top.
            ViewThatFits(in: .vertical) {
                list
                ScrollView(.vertical) { list }
            }
        }
    }

    /// Now, Agents (while shown) and Library.
    private var nav: some View {
        let current: PanelDestination = route.normalized(agentsVisible: agentsVisible).destination
        return HStack(spacing: 2) {
            ForEach(destinations, id: \.self) { d in
                let selected: Bool = d == current
                Button { route = PanelRoute(destination: d) } label: {
                    Text(verbatim: Self.title(d))
                        .font(DS.font(TypeScale.headline).weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selected ? Theme.card : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(Self.title(d)) (\u{2318}\(Self.shortcutDigit(d)))")
                .accessibilityLabel(Self.title(d))
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    /// ⌘1 / ⌘2 / ⌘3 (`NotchController.commandDigit`).
    static func shortcutDigit(_ d: PanelDestination) -> Int {
        switch d {
        case .now: 1
        case .agents: 2
        case .library: 3
        }
    }

    static func title(_ d: PanelDestination) -> String {
        switch d {
        case .now: "Now"
        case .agents: "Agents"
        case .library: "Library"
        }
    }

    /// The connection state, Settings and close: at the trailing edge of the nav or a tool's header.
    private var controls: some View {
        HStack(spacing: 2) {
            if store.connection != .connected {
                let text: String = store.connection == .connecting ? "Connecting…" : "Reconnecting…"
                ViewThatFits(in: .horizontal) {
                    Label(text, systemImage: "bolt.horizontal.circle")
                    Image(systemName: "bolt.horizontal.circle")
                }
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(Theme.color(.attention))
                .help(text)
                .accessibilityLabel(text)
            }
            if let header {
                HeaderToggles(services: header, widgets: widgets, route: $route, onOpenSettings: onOpenSettings,
                              fixedNow: fixedNow)
            } else {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("PlatyNotch Settings")
                .accessibilityLabel("Open PlatyNotch Settings")
            }
            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
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

/// The saved Library recents, decoded once per saved value (the grid reads them on every draw).
@MainActor
enum LibraryRecentsCache {
    private static var last: (data: Data, recents: LibraryRecents)?

    static func resolve(from defaults: UserDefaults) -> LibraryRecents {
        guard let data = defaults.data(forKey: LibraryRecents.key) else { return LibraryRecents() }
        if let last, last.data == data { return last.recents }
        let recents = LibraryRecents.decode(data)
        last = (data, recents)
        return recents
    }
}
