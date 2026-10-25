import PlatyNotchKit
import SwiftUI

/// The Agents destination (spec 6.5): a header with the usage chips, then every session
/// sorted by attention (`AgentsOrder`), each with one action. Pending approvals sit above
/// it in the panel's approvals region, as before. Empty: Platy, "No agents running" and
/// "Connect an agent" (Settings › Agents).
struct AgentsView: View {
    let sessions: [Session]
    let usage: Usage
    let log: AgentFinishLog
    let onOpenTerminal: (Session) -> Void
    let onConnect: () -> Void
    /// Renders only: the status lines' clock.
    var fixedNow: Date?
    @Environment(\.panelTicking) private var ticking

    init(sessions: [Session], usage: Usage, log: AgentFinishLog, onOpenTerminal: @escaping (Session) -> Void,
         onConnect: @escaping () -> Void, fixedNow: Date? = nil) {
        self.sessions = sessions
        self.usage = usage
        self.log = log
        self.onOpenTerminal = onOpenTerminal
        self.onConnect = onConnect
        self.fixedNow = fixedNow
    }

    /// The sessions in list order at `now`.
    func rows(now: Date) -> [Session] {
        AgentsOrder.sorted(sessions, log: log, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header
            if sessions.isEmpty {
                AgentsEmptyState(onConnect: onConnect)
            } else if let fixedNow {
                list(now: fixedNow)
            } else if ticking {
                // Minutes in the status lines move while the panel is shown.
                TimelineView(.periodic(from: .now, by: 30)) { ctx in list(now: ctx.date) }
            } else {
                list(now: Date())
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.s) {
            Text(verbatim: countsLine)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            UsageRings(usage: usage, hint: PanelFormat.claudeLimitsHint(usage: usage, sessions: sessions))
        }
    }

    /// Every text the destination lays out at `now`, in order (tests): the header, then
    /// the rows or the empty state. Tooltips are not included.
    func visibleTexts(now: Date) -> [String] {
        var out: [String] = []
        let counts = countsLine(now: now)
        if !counts.isEmpty { out.append(counts) }
        out += UsageRings(usage: usage, hint: PanelFormat.claudeLimitsHint(usage: usage, sessions: sessions)).visibleTexts
        if sessions.isEmpty { return out + AgentsEmptyState.texts }
        for s in rows(now: now) {
            out += AgentRow.texts(s, attention: AgentAttention.of(s, log: log, now: now), now: now)
        }
        return out
    }

    private var countsLine: String { countsLine(now: fixedNow ?? Date()) }

    /// "4 sessions · 1 needs you".
    private func countsLine(now: Date) -> String {
        guard !sessions.isEmpty else { return "" }
        let needs: Int = sessions.filter {
            let a = AgentAttention.of($0, log: log, now: now)
            return a == .needsYou || a == .errored
        }.count
        let total: String = sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"
        return needs > 0 ? "\(total) · \(needs) needs you" : total
    }

    private func list(now: Date) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(rows(now: now)) { s in
                    AgentRow(session: s, attention: AgentAttention.of(s, log: log, now: now), now: now,
                             onOpenTerminal: onOpenTerminal)
                }
            }
            // Room for the state badges that sit over the icons' corners.
            .padding(.bottom, StateBadge.overhang)
        }
        .scrollIndicators(.automatic)
    }
}

/// No sessions yet: Platy (or the agents symbol without Platy), and one way forward.
struct AgentsEmptyState: View {
    let onConnect: () -> Void
    @Environment(\.platyMood) private var platyMood

    static let texts: [String] = ["No agents running", "Connect an agent"]

    func connect() { onConnect() }

    var body: some View {
        VStack(spacing: Space.s) {
            if let platyMood {
                PlatyView(mood: platyMood, size: 96)
            } else {
                DS.icon("terminal", size: IconSize.hero).foregroundStyle(.secondary)
            }
            Text(verbatim: Self.texts[0])
                .font(DS.font(TypeScale.headline))
            Button(action: connect) {
                Label(Self.texts[1], systemImage: "link")
                    .font(DS.font(TypeScale.body).weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Connect an agent")
            .accessibilityHint("Opens Settings, Agents")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
