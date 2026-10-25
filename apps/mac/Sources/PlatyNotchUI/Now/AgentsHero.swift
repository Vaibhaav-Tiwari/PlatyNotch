import PlatyNotchKit
import SwiftUI

/// Now's hero for the agents item (spec 6.4, 6.7): Platy at 96 pt showing the aggregate
/// mood, the most urgent session ("Claude Code · platynotch"), what it is doing, the
/// counts in words, and one action from `AgentRowAction` (Answer / Open terminal).
struct AgentsHero: View {
    let agents: AgentsLive
    let action: AgentRowAction
    let mood: PlatyMood?
    let onPrimary: () -> Void

    init(agents: AgentsLive, action: AgentRowAction, mood: PlatyMood?, onPrimary: @escaping () -> Void) {
        self.agents = agents
        self.action = action
        self.mood = mood
        self.onPrimary = onPrimary
    }

    /// The lead session's row action (`AgentsLive.leadAttention`): Answer while it needs you
    /// or errored, else Open terminal.
    static func action(for agents: AgentsLive) -> AgentRowAction {
        AgentRowAction(agents.leadAttention)
    }

    /// The lead session's state colour and symbol: errored is the coral error state.
    static func tone(for agents: AgentsLive) -> StateTone {
        agents.leadAttention.tone
    }

    var body: some View {
        HeroLayout(title: agents.title, subtitle: agents.subtitle,
                   action: HeroAction(title: action.title, systemImage: symbol, run: onPrimary)) {
            if let mood {
                PlatyView(mood: mood, size: 96, morphID: MorphID.platy)
            } else {
                DS.icon(tone.symbol, size: IconSize.hero)
                    .foregroundStyle(DS.dynamicColor(tone))
                    .frame(width: 44, height: 44)
            }
        } value: {
            Label {
                Text(verbatim: counts)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            } icon: {
                Image(systemName: tone.symbol).foregroundStyle(DS.dynamicColor(tone))
            }
            .font(DS.font(TypeScale.caption))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
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
