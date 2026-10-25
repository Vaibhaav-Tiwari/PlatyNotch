import PlatyNotchKit
import SwiftUI

/// The Now destination (spec 6.4): one hero (the top live item, or the Today summary), a
/// row of up to four glances and a quiet line, always inside the open panel without
/// scrolling (`NowMetrics`). While an approval is pending, Now gives way to one compact
/// line ("Now: Design in 8 min · Music", spec 6.8); the approvals region above keeps its
/// behaviour and the hero never cycles to or from an approval.
struct NowView: View {
    let store: AppStore
    let widgets: WidgetRegistry
    let today: TodayServices
    @Binding var deck: HeroDeck
    /// Where the chosen glances are saved (`GlanceSlots.key`).
    let glanceDefaults: UserDefaults
    let onOpenTool: (String) -> Void
    let onOpenAgents: () -> Void
    let onOpenTerminal: (Session) -> Void
    /// Renders only: the Today summary's clock at a fixed time (live items always rank
    /// against the real clock).
    var fixedNow: Date?
    @Environment(\.platyMood) private var platyMood

    init(store: AppStore, widgets: WidgetRegistry, today: TodayServices, deck: Binding<HeroDeck>,
         glanceDefaults: UserDefaults = .standard, onOpenTool: @escaping (String) -> Void,
         onOpenAgents: @escaping () -> Void, onOpenTerminal: @escaping (Session) -> Void, fixedNow: Date? = nil) {
        self.store = store
        self.widgets = widgets
        self.today = today
        _deck = deck
        self.glanceDefaults = glanceDefaults
        self.onOpenTool = onOpenTool
        self.onOpenAgents = onOpenAgents
        self.onOpenTerminal = onOpenTerminal
        self.fixedNow = fixedNow
    }

    var body: some View {
        let now: Date = Date()
        let agents: AgentsLive? = agentsLive(now: now)
        let items: [LiveItem] = HeroDeck.items(widgets.rankedLive(agents: agents, now: now))
        let mode: NowMode = NowMode.resolve(approvals: store.approvals.count, deck: items, now: now)
        switch mode {
        case .approvalsPending(let line):
            compactLine(line)
        case .live:
            VStack(alignment: .leading, spacing: NowMetrics.gap) {
                liveHero(items, agents: agents)
                rows
            }
        case .summary:
            VStack(alignment: .leading, spacing: NowMetrics.gap) {
                HeroFrame(keyline: nil, position: nil, onStep: nil) {
                    TodaySummaryHero(calendar: today.calendar, fixedNow: fixedNow)
                }
                rows
            }
        }
    }

    /// The glance row (when any glance has something to show) and the quiet line.
    @ViewBuilder private var rows: some View {
        let entries: [GlanceEntry] = glances
        if !entries.isEmpty {
            GlanceRow(entries: entries, onOpen: openGlance)
        }
        let quiet: [QuietLineItem] = QuietLine.items(openLoops: openLoops, tasks: tasksDue,
                                                     glanceIDs: entries.map(\.id))
        if !quiet.isEmpty {
            QuietLineView(items: quiet, onOpen: onOpenTool)
        }
    }

    /// The agents item; reads the log's revision too, so Now re-ranks when a 10-minute
    /// window runs out.
    private func agentsLive(now: Date) -> AgentsLive? {
        let activity: AgentActivityModel = today.agentActivity
        guard activity.revision >= 0 else { return nil }
        return AgentsLive.make(sessions: store.sessions, log: activity.log, now: now)
    }

    // MARK: - Hero

    @ViewBuilder private func liveHero(_ items: [LiveItem], agents: AgentsLive?) -> some View {
        let index: Int = deck.current(in: items) ?? 0
        let item: LiveItem = items[index]
        let count: Int = items.count
        HeroFrame(keyline: keyline(item), position: HeroDeck.position(index, of: count),
                  onStep: count > 1 ? { delta in deck.step(delta, in: items) } : nil) {
            heroContent(item)
        }
        .id(item.id)
        .transition(.opacity)
    }

    @ViewBuilder private func heroContent(_ item: LiveItem) -> some View {
        switch item.source {
        case .agents(let agents):
            agentsHero(agents)
        case .activity(let activity):
            if let hero = widgets.widget(activity.widgetID)?.heroView() {
                hero
            } else {
                GenericHero(item: item)
            }
        }
    }

    /// Platy at 96 pt beside the most urgent session (Task 10 adds the primary action).
    private func agentsHero(_ agents: AgentsLive) -> some View {
        HStack(spacing: Space.l) {
            if let platyMood { PlatyView(mood: platyMood, size: 96) }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: agents.title).font(DS.font(TypeScale.title)).lineLimit(1)
                if let subtitle = agents.subtitle {
                    Text(verbatim: subtitle).font(DS.font(TypeScale.body)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenAgents)
    }

    private func keyline(_ item: LiveItem) -> Color? {
        switch item.source {
        case .agents(let a):
            switch a.rank {
            case .agentNeedsYou: return DS.dynamicColor(.needsYou, alpha: 0.7)
            case .agentFinished: return DS.dynamicColor(.done, alpha: 0.7)
            default: return DS.dynamicColor(.working, alpha: 0.7)
            }
        case .activity(let a):
            return a.tint.keyline
        }
    }

    // MARK: - Glances and the quiet line

    private var glances: [GlanceEntry] {
        let capable: [String] = widgets.glanceCapableIDs + [GlanceSlots.usageID]
        let slots: GlanceSlots = GlanceSlots.load(from: glanceDefaults, glanceCapable: capable)
        var views: [String: AnyView] = [:]
        for w in widgets.glanceWidgets {
            if let v = w.glanceView() { views[w.id] = v }
        }
        if UsageGlance.reading(store.usage) != nil {
            views[GlanceSlots.usageID] = AnyView(UsageGlance(usage: store.usage))
        }
        return slots.shown(available: Set(views.keys)).compactMap { id in
            views[id].map { GlanceEntry(id: id, view: $0) }
        }
    }

    private func openGlance(_ id: String) {
        if id == GlanceSlots.usageID { onOpenAgents() } else { onOpenTool(id) }
    }

    private var openLoops: Int {
        guard widgets.running.contains(LoopsWidget.widgetID),
              let w = widgets.widget(LoopsWidget.widgetID) as? LoopsWidget else { return 0 }
        return w.openCount
    }

    private var tasksDue: Int {
        guard widgets.running.contains(RemindersWidget.widgetID),
              let w = widgets.widget(RemindersWidget.widgetID) as? RemindersWidget else { return 0 }
        return w.dueCount
    }

    // MARK: - Approvals pending

    /// One body line; nothing at all when nothing is live.
    @ViewBuilder private func compactLine(_ line: String?) -> some View {
        if let line {
            Text(verbatim: line)
                .font(DS.font(TypeScale.body))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: NowMetrics.quietLine, alignment: .leading)
                .accessibilityLabel(line)
        }
    }
}
