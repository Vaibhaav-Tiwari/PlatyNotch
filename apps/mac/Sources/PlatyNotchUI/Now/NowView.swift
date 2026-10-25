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
    /// The hover peek: the hero alone (no glances, no quiet line).
    var heroOnly = false
    @Environment(\.platyMood) private var platyMood

    init(store: AppStore, widgets: WidgetRegistry, today: TodayServices, deck: Binding<HeroDeck>,
         glanceDefaults: UserDefaults = .standard, onOpenTool: @escaping (String) -> Void,
         onOpenAgents: @escaping () -> Void, onOpenTerminal: @escaping (Session) -> Void, fixedNow: Date? = nil,
         heroOnly: Bool = false) {
        self.store = store
        self.widgets = widgets
        self.today = today
        _deck = deck
        self.glanceDefaults = glanceDefaults
        self.onOpenTool = onOpenTool
        self.onOpenAgents = onOpenAgents
        self.onOpenTerminal = onOpenTerminal
        self.fixedNow = fixedNow
        self.heroOnly = heroOnly
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
            let heroID: String = items[deck.current(in: items) ?? 0].id
            VStack(alignment: .leading, spacing: NowMetrics.gap) {
                liveHero(items, agents: agents)
                rows
            }
            // Stepping or a new top item cross-fades (spec 9: ≤ 0.2 s).
            .animation(.easeInOut(duration: MotionPreset.crossFade), value: heroID)
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
        if !heroOnly { glanceAndQuietRows.panelChrome() }
    }

    @ViewBuilder private var glanceAndQuietRows: some View {
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
                  onStep: count > 1 ? { delta in deck.step(delta, in: items) } : nil, itemID: item.id) {
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

    /// Platy at 96 pt beside the most urgent session; its action opens that session's
    /// terminal (the Agents tab when the core no longer lists it).
    private func agentsHero(_ agents: AgentsLive) -> some View {
        AgentsHero(agents: agents, action: AgentsHero.action(for: agents), mood: platyMood) {
            if let lead = leadSession(agents) { onOpenTerminal(lead) } else { onOpenAgents() }
        }
    }

    /// The agents item's lead session (`AgentsLive.leadKey`, the one classifier's choice).
    private func leadSession(_ agents: AgentsLive) -> Session? {
        store.sessions.first { $0.key == agents.leadKey }
    }

    private func keyline(_ item: LiveItem) -> Color? {
        switch item.source {
        case .agents(let a):
            return DS.dynamicColor(AgentsHero.tone(for: a), alpha: 0.7)
        case .activity(let a):
            // Music takes the album art's colour, like a Live Activity's tinted keyline.
            if a.widgetID == MusicWidget.widgetID, let tint = today.nowPlaying.artworkTint {
                return tint.opacity(0.8)
            }
            return a.tint.keyline
        }
    }

    // MARK: - Glances and the quiet line

    private var glances: [GlanceEntry] {
        Self.glanceEntries(widgets: widgets, usage: store.usage, defaults: glanceDefaults)
    }

    /// The chosen glances that have something to show, in slot order. The slots come from
    /// `defaultGlanceOrder` (saved on first use); one with nothing to show is skipped,
    /// never replaced (Ruling 6).
    static func glanceEntries(widgets: WidgetRegistry, usage: Usage, defaults: UserDefaults) -> [GlanceEntry] {
        let capable: [String] = widgets.defaultGlanceOrder
        let slots: GlanceSlots = GlanceSlotsCache.resolve(from: defaults, glanceCapable: capable)
        var views: [String: AnyView] = [:]
        for w in widgets.glanceWidgets {
            if let v = w.glanceView() { views[w.id] = v }
        }
        if UsageGlance.reading(usage) != nil {
            views[GlanceSlots.usageID] = AnyView(UsageGlance(usage: usage))
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

/// Saved glance slots, decoded once per saved value (Now's body reads them on every draw).
@MainActor
enum GlanceSlotsCache {
    private static var last: (data: Data, slots: GlanceSlots)?

    static func resolve(from defaults: UserDefaults, glanceCapable: [String]) -> GlanceSlots {
        if let data = defaults.data(forKey: GlanceSlots.key), let last, last.data == data { return last.slots }
        let slots = GlanceSlots.resolve(from: defaults, glanceCapable: glanceCapable)
        if let data = defaults.data(forKey: GlanceSlots.key) { last = (data, slots) }
        return slots
    }
}
