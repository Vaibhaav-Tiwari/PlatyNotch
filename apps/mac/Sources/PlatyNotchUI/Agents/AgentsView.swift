import PlatyNotchKit
import SwiftUI

/// The Agents destination (Quiet Notch spec 2.3, wireframe C): one dense row per session in
/// attention order (`AgentsOrder`) with hairlines between, then a hairline and one quiet line
/// about open loops. Pending approvals sit above it in the panel's approvals region; usage is
/// small mono numbers in the header (`UsageLine`). Empty: Platy and "No agents running".
struct AgentsView: View {
    let sessions: [Session]
    let log: AgentFinishLog
    /// Open loops, for the quiet line under the list (hidden at zero).
    var openLoops: Int = 0
    let onOpenTerminal: (Session) -> Void
    let onConnect: () -> Void
    /// "open loops" opens the loops list inside the panel.
    var onOpenLoops: () -> Void = {}
    /// Renders only: the status lines' clock.
    var fixedNow: Date?
    @Environment(\.panelTicking) private var ticking
    @Environment(\.agentIcons) private var icons

    init(sessions: [Session], log: AgentFinishLog, openLoops: Int = 0,
         onOpenTerminal: @escaping (Session) -> Void, onConnect: @escaping () -> Void,
         onOpenLoops: @escaping () -> Void = {}, fixedNow: Date? = nil) {
        self.sessions = sessions
        self.log = log
        self.openLoops = openLoops
        self.onOpenTerminal = onOpenTerminal
        self.onConnect = onConnect
        self.onOpenLoops = onOpenLoops
        self.fixedNow = fixedNow
    }

    /// The sessions in list order at `now`.
    func rows(now: Date) -> [Session] {
        AgentsOrder.sorted(sessions, log: log, now: now)
    }

    var body: some View {
        if sessions.isEmpty {
            AgentsEmptyState(onConnect: onConnect)
                .background(Self.naturalHeight)
        } else if let fixedNow {
            content(now: fixedNow)
        } else if ticking {
            // Ages in the rows move while the panel is shown.
            TimelineView(.periodic(from: .now, by: 30)) { ctx in content(now: ctx.date) }
        } else {
            content(now: Date())
        }
    }

    /// Every text the destination lays out at `now`, in order (tests): the rows or the empty
    /// state, then the open-loops line. Tooltips are not included.
    func visibleTexts(now: Date) -> [String] {
        if sessions.isEmpty { return AgentsEmptyState.texts }
        var out: [String] = []
        for s in rows(now: now) {
            out += AgentRow.texts(s, attention: AgentAttention.of(s, log: log, now: now), now: now,
                                  finishedAt: log.finishedAt(s.key, now: now))
        }
        if let footer = AgentsFooter.text(openLoops: openLoops) { out.append(footer) }
        return out
    }

    /// "4 sessions · 1 needs you · 1 error": needs you and errors counted apart (VoiceOver's
    /// summary of the list).
    func countsLine(now: Date) -> String {
        guard !sessions.isEmpty else { return "" }
        let rated: [AgentAttention] = sessions.map { AgentAttention.of($0, log: log, now: now) }
        let needs: Int = rated.filter { $0 == .needsYou }.count
        let errors: Int = rated.filter { $0 == .errored }.count
        var parts: [String] = [sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"]
        if needs > 0 { parts.append("\(needs) needs you") }
        if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
        return parts.joined(separator: " · ")
    }

    /// Reports the content's natural height (`HomeHeightKey`), whatever room it was given, so
    /// the panel can hug it (spec 2).
    private static var naturalHeight: some View {
        GeometryReader { g in Color.clear.preference(key: HomeHeightKey.self, value: g.size.height) }
    }

    /// The rows and the open-loops line hug their height while they fit the room the panel
    /// leaves (an approval above can take most of it), and scroll together inside it when
    /// they do not.
    private func content(now: Date) -> some View {
        ViewThatFits(in: .vertical) {
            stack(now: now)
                .background(Self.naturalHeight)
            ScrollView(.vertical) {
                stack(now: now)
                    .background(Self.naturalHeight)
                    .preference(key: AgentsScrollsKey.self, value: true)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(countsLine(now: now))
    }

    private func stack(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            list(now: now)
            if let footer = AgentsFooter.text(openLoops: openLoops) {
                Hairline().padding(.vertical, 8)
                footerLine(footer)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func list(now: Date) -> some View {
        let sorted: [Session] = rows(now: now)
        let column: CGFloat = AgentBadge.column(for: sorted.map { AgentBrand(agent: $0.agent, agentName: $0.agentName) },
                                                source: icons)
        let buttons: CGFloat? = AgentRow.buttonColumn(sorted.compactMap { TerminalFocus.title(for: $0) })
        return VStack(spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, s in
                if index > 0 { Hairline() }
                AgentRow(session: s, attention: AgentAttention.of(s, log: log, now: now), now: now,
                         finishedAt: log.finishedAt(s.key, now: now), badgeWidth: column, buttonWidth: buttons,
                         onOpenTerminal: onOpenTerminal)
            }
        }
    }

    /// `2 open loops · Search memory with ⌘K`: "open loops" opens the loops list.
    private func footerLine(_ text: String) -> some View {
        HStack(spacing: 0) {
            Button(action: onOpenLoops) {
                Text(verbatim: AgentsFooter.loops(openLoops))
            }
            .buttonStyle(.plain)
            .help("Show open loops")
            Text(verbatim: " · " + AgentsFooter.searchHint)
        }
        .font(DS.font(TypeScale.caption))
        .foregroundStyle(DS.tertiary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityAction(named: "Show open loops", onOpenLoops)
    }
}

/// No sessions yet: Platy (or a quiet symbol without Platy), the words, and one way forward.
struct AgentsEmptyState: View {
    let onConnect: () -> Void
    @Environment(\.platyMood) private var platyMood

    static let texts: [String] = ["No agents running", "Connect an agent"]

    func connect() { onConnect() }

    var body: some View {
        VStack(spacing: 8) {
            if let platyMood {
                PlatyView(mood: platyMood, size: 54)
            } else {
                DS.icon("terminal", size: IconSize.header).foregroundStyle(DS.tertiary)
            }
            Text(verbatim: Self.texts[0])
                .font(DS.font(TypeScale.body))
                .foregroundStyle(DS.secondary)
            Button(action: connect) {
                PanelButtonLabel(title: Self.texts[1])
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connect an agent")
            .accessibilityHint("Opens Settings, Agents")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// True while the Agents list scrolls inside the room it was given (layout tests).
struct AgentsScrollsKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
