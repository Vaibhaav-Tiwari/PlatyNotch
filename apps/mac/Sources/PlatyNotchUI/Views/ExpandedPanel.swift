import PlatyNotchKit
import SwiftUI

enum BuiltinTab {
    /// The default destination (spec 6.4).
    static let now = "now"
    static let agents = "agents"
    static let today = "today"
    static let focus = "focus"
    static let memory = "memory"
    static let games = GamesWidget.tabID
}

/// The open panel: tab bar, pending approvals (always on top), then the selected tab.
struct ExpandedPanel: View {
    let store: AppStore
    let responder: ApprovalResponder
    let arming: ApprovalArming
    let today: TodayServices
    let widgets: WidgetRegistry
    let memory: MemoryServices
    let extraTabs: [PanelTab]
    @Binding var selectedTab: String
    let onCollapse: () -> Void
    /// Opens the Settings window (the gear; mouse only, no keyboard shortcut).
    var onOpenSettings: () -> Void = {}
    /// Now's hero selection (the panel model's; reset on each open).
    var deck: Binding<HeroDeck> = .constant(HeroDeck())
    /// Renders only: Now at a fixed time.
    var fixedNow: Date?
    /// Where Now's chosen glances are saved (renders and tests pass their own).
    var glanceDefaults: UserDefaults = .standard
    /// The Agents destination shows (`AgentsVisibility.isVisible`, via
    /// `PanelDestination.shown`); hidden until an agent first connects.
    var agentsVisible: Bool = true
    /// The Agents empty state's "Connect an agent": Settings › Agents.
    var onConnectAgent: () -> Void = {}
    let onDecide: (Approval, ApprovalBehavior) -> Void
    let onOpenTerminal: (Session) -> Void

    var body: some View {
        let tabs = allTabs
        VStack(alignment: .leading, spacing: NowMetrics.gap) {
            tabBar(tabs)
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
            }
            (tabs.first { $0.id == selectedTab } ?? tabs[0]).view
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Now is left unclipped: it relies on the fit tests (`NowMetrics`,
                // `NowViewTests`, `HeroViewsTests`) to stay inside, and must not clip Platy or
                // the live glyph while they morph in from the pill. Other tabs stay clipped.
                .clipped(unless: selectedTab == BuiltinTab.now)
                .environment(\.selectPanelTab, { selectedTab = $0 })   // the games tile opens its tab
        }
        .coordinateSpace(name: Self.space)
    }

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

    /// Now first, then today's tabs (they move into the Library in Task 21), then plugins'.
    var allTabs: [PanelTab] {
        let store = self.store
        let open = onOpenTerminal
        let today = self.today
        let widgets = self.widgets
        let memory = self.memory
        let deck = self.deck
        let fixedNow = self.fixedNow
        let glanceDefaults = self.glanceDefaults
        let connect = onConnectAgent
        let select: (String) -> Void = { [selectedTab = $selectedTab] in selectedTab.wrappedValue = $0 }
        var tabs = [
            PanelTab(id: BuiltinTab.now, title: "Now", systemImage: "sparkles") {
                NowView(store: store, widgets: widgets, today: today, deck: deck, glanceDefaults: glanceDefaults,
                        onOpenTool: { select(Self.tab(forTool: $0)) },
                        onOpenAgents: { select(BuiltinTab.agents) }, onOpenTerminal: open, fixedNow: fixedNow)
            },
            PanelTab(id: BuiltinTab.agents, title: "Agents", systemImage: "terminal") {
                AgentsView(sessions: store.sessions, usage: store.usage, log: today.agentActivity.log,
                           onOpenTerminal: open, onConnect: connect, fixedNow: fixedNow)
            },
            PanelTab(id: BuiltinTab.today, title: "Today", systemImage: "calendar") {
                TodayTab(widgets: widgets)
            },
        ]
        // The Focus tab belongs to the focus widget: hidden while it is off.
        if widgets.isEnabled(FocusWidget.widgetID) {
            tabs.append(PanelTab(id: BuiltinTab.focus, title: "Focus", systemImage: "timer") {
                FocusTab(focus: today.focus)
            })
        }
        tabs.append(PanelTab(id: BuiltinTab.memory, title: "Memory", systemImage: "brain") {
            MemoryTab(store: store, memory: memory)
        })
        // The Games tab belongs to the games widget: shown only while it runs.
        if widgets.running.contains(GamesWidget.widgetID),
           let games = widgets.widget(GamesWidget.widgetID) as? GamesWidget {
            let host = games.host
            tabs.append(PanelTab(id: BuiltinTab.games, title: "Games", systemImage: "gamecontroller") {
                GamesTab(host: host)
            })
        }
        let shown: [PanelDestination] = PanelDestination.shown(agentsVisible: agentsVisible)
        if !shown.contains(.agents) { tabs.removeAll { $0.id == BuiltinTab.agents } }
        return tabs + extraTabs
    }

    /// Where a tool opens until the Library (Task 21): its own tab, else Today's tiles.
    static func tab(forTool id: String) -> String {
        switch id {
        case FocusWidget.widgetID: BuiltinTab.focus
        case GamesWidget.widgetID: BuiltinTab.games
        default: BuiltinTab.today
        }
    }

    private func tabBar(_ tabs: [PanelTab]) -> some View {
        HStack(spacing: 2) {
            // The tabs get their room first; with many (plugin tabs) the labels shrink to
            // the 11 pt floor, then truncate, so the gear and close never leave the frame.
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    let selected = tab.id == (tabs.contains { $0.id == selectedTab } ? selectedTab : tabs[0].id)
                    Button { selectedTab = tab.id } label: {
                        Text(verbatim: tab.title)
                            .font(DS.font(TypeScale.headline).weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(TypeScale.minimum / TypeScale.headline.size)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(selected ? Theme.card : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(tab.title) tab")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if store.connection != .connected {
                let text: String = store.connection == .connecting ? "Connecting…" : "Reconnecting…"
                // With many tabs only the symbol fits; VoiceOver and the tooltip keep the word.
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
