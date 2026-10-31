import PlatyNotchKit
import SwiftUI

/// Now's hero for the agents item (spec 6.4, 6.7): Platy at 96 pt showing the aggregate
/// mood, the most urgent session ("Claude Code · platynotch"), what it is doing, the
/// counts in words, and one action naming the lead session's host app.
struct AgentsHero: View {
    let agents: AgentsLive
    let action: AgentRowAction
    let mood: PlatyMood?
    /// The lead session's agent: its icon with the state badge leads the counts line
    /// (user change: agent icons). nil when the core no longer lists that session.
    let lead: AgentBrand?
    /// The button's title: the lead session's `TerminalFocus.title(for:)`; "Show agents" when it
    /// has none (the action then opens the Agents view).
    let openTitle: String?
    let onPrimary: () -> Void

    init(agents: AgentsLive, action: AgentRowAction, mood: PlatyMood?, lead: AgentBrand? = nil,
         openTitle: String? = nil, onPrimary: @escaping () -> Void) {
        self.agents = agents
        self.action = action
        self.mood = mood
        self.lead = lead
        self.openTitle = openTitle
        self.onPrimary = onPrimary
    }

    /// The lead session's row action (`AgentsLive.leadAttention`): Answer while it needs
    /// you, else Open terminal (an errored session is looked at in its terminal).
    static func action(for agents: AgentsLive) -> AgentRowAction {
        AgentRowAction(agents.leadAttention)
    }

    /// The lead session's state colour and symbol: errored is the coral error state.
    static func tone(for agents: AgentsLive) -> StateTone {
        agents.leadAttention.tone
    }

    var body: some View {
        HeroLayout(title: agents.title, subtitle: agents.subtitle,
                   action: HeroAction(title: openTitle ?? "Show agents", systemImage: symbol, run: onPrimary)) {
            if let mood {
                PlatyView(mood: mood, size: 96, morphID: MorphID.platy)
            } else {
                DS.icon(tone.symbol, size: IconSize.hero)
                    .foregroundStyle(DS.dynamicColor(tone))
                    .frame(width: 44, height: 44)
            }
        } value: {
            // The full counts where they fit; else the lead state alone ("2 working"), as
            // in the hover peek's narrower hero, never a truncated line.
            ViewThatFits(in: .horizontal) {
                countsLabel(counts).preference(key: AgentsCountsShownKey.self, value: .full)
                countsLabel(shortCounts).preference(key: AgentsCountsShownKey.self, value: .short)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func countsLabel(_ text: String) -> some View {
        if let lead {
            HStack(spacing: Space.s) {
                AgentBadge(brand: lead, tone: tone, size: Self.leadIconSize)
                    .help(agents.title)
                Text(verbatim: text)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .fixedSize()
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.secondary)
            }
        } else {
            Label {
                Text(verbatim: text)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .fixedSize()
            } icon: {
                Image(systemName: tone.symbol).foregroundStyle(DS.dynamicColor(tone))
            }
            .font(DS.font(TypeScale.caption))
            .foregroundStyle(.secondary)
        }
    }

    /// The lead session's icon in the counts line.
    static let leadIconSize: CGFloat = 28

    /// The lead state only: "1 needs you", "2 working", else the state word.
    var shortCounts: String {
        if agents.needsYou > 0 { return "\(agents.needsYou) needs you" }
        if agents.working > 0 { return "\(agents.working) working" }
        return tone.word
    }

    private var symbol: String {
        action == .answer ? "arrowshape.turn.up.left.fill" : "terminal"
    }

    private var tone: StateTone { Self.tone(for: agents) }

    /// "1 needs you · 2 working · 4 sessions"; "Finished" once all are done.
    private var counts: String {
        var parts: [String] = []
        if agents.needsYou > 0 { parts.append("\(agents.needsYou) needs you") }
        if agents.working > 0 { parts.append("\(agents.working) working") }
        if parts.isEmpty { parts.append(tone.word) }
        parts.append(agents.total == 1 ? "1 session" : "\(agents.total) sessions")
        return parts.joined(separator: " · ")
    }
}

/// Which counts line the agents hero shows (tests).
enum AgentsCountsShown: Sendable { case full, short }

struct AgentsCountsShownKey: PreferenceKey {
    static let defaultValue: AgentsCountsShown? = nil
    static func reduce(value: inout AgentsCountsShown?, nextValue: () -> AgentsCountsShown?) {
        value = value ?? nextValue()
    }
}
