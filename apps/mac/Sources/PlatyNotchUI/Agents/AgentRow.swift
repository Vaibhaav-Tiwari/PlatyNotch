import PlatyNotchKit
import SwiftUI

/// One session in the Agents list (spec 6.5): the agent's icon with its state badge, the
/// project, the status line, the last action in monospaced caption, and one action from
/// `TerminalFocus.title(for:)` ("Open Claude" / "Show folder"). Both answer in the session's host app.
struct AgentRow: View {
    static let height: CGFloat = 52
    let session: Session
    let attention: AgentAttention
    let now: Date
    /// When the session finished (`AgentFinishLog.finishedAt`), for "Finished · n m ago".
    var finishedAt: Date? = nil
    let onOpenTerminal: (Session) -> Void

    var body: some View {
        let action = AgentRowAction(attention)
        let openTitle: String? = TerminalFocus.title(for: session)
        let tone: StateTone = attention.tone
        Button { onOpenTerminal(session) } label: {
            HStack(spacing: Space.m) {
                AgentBadge(brand: AgentBrand(agent: session.agent, agentName: session.agentName), tone: tone)
                    .help(session.agentName)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: project)
                        .font(DS.font(TypeScale.headline))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: status)
                        .font(DS.font(TypeScale.body))
                        .foregroundStyle(attention == .needsYou || attention == .errored
                                         ? AnyShapeStyle(DS.dynamicColor(tone)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let last = Self.lastLine(session, attention: attention) {
                        Text(verbatim: last)
                            .font(DS.font(TypeScale.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let openTitle {
                    Text(verbatim: openTitle)
                        .font(DS.font(TypeScale.body).weight(.semibold))
                        .foregroundStyle(action == .answer ? AnyShapeStyle(DS.dynamicColor(.needsYou)) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, 3)
                        .background(Theme.card, in: Capsule())
                }
            }
            .padding(.vertical, Space.xs)
            .padding(.leading, Space.xs)
            .padding(.trailing, Space.s)
            .frame(minHeight: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(openTitle == nil ? "" : action == .answer
                           ? "Answers in the app running this session" : "Shows the app running this session")
        .accessibilityAddTraits(openTitle == nil ? [] : .isButton)
        .accessibilityActions {
            if let openTitle { Button(openTitle) { onOpenTerminal(session) } }
        }
    }

    private var project: String { Self.project(session) }

    private var status: String {
        SessionStatusLine.text(session, attention: attention, now: now, finishedAt: finishedAt)
    }

    /// The last action, unless the status line already says it ("Edit · 4 m" over "Edit").
    static func lastLine(_ s: Session, attention: AgentAttention) -> String? {
        if attention == .working, s.message == nil, s.title == nil { return nil }
        return SessionStatusLine.lastAction(s)
    }

    static func project(_ s: Session) -> String {
        if let p = s.project, !p.isEmpty { return p }
        return s.title ?? s.agentName
    }

    /// The row's visible text, top to bottom then the action (tests).
    @MainActor static func texts(_ s: Session, attention: AgentAttention, now: Date, finishedAt: Date? = nil) -> [String] {
        var out: [String] = [project(s), SessionStatusLine.text(s, attention: attention, now: now, finishedAt: finishedAt)]
        if let last = lastLine(s, attention: attention) { out.append(last) }
        if let title = TerminalFocus.title(for: s) { out.append(title) }
        return out
    }

    private var accessibilityText: String {
        var parts: [String] = [session.agentName, project, status]
        if let last = Self.lastLine(session, attention: attention) { parts.append(last) }
        if let title = TerminalFocus.title(for: session) { parts.append(title) }
        return parts.joined(separator: ", ")
    }
}

/// Highlights a row on hover and press.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Theme.card.opacity(configuration.isPressed ? 1 : hovering ? 0.7 : 0))
                )
                .onHover { hovering = $0 }
        }
    }
}
