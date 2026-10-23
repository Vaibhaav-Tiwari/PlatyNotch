import PlatyNotchKit
import SwiftUI

/// One agent session: state dot, title, tool, state and age. Clicking focuses its terminal.
struct SessionRow: View {
    let session: Session
    let now: Date
    let onOpenTerminal: (Session) -> Void

    var body: some View {
        Button { onOpenTerminal(session) } label: {
            HStack(spacing: 8) {
                AgentDot(tone: AgentTone(session.state), size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if let tool = session.tool, session.state == .active || session.state == .blocked {
                    Tag(text: tool)
                }
                Text(PanelFormat.stateLabel(session.state))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.color(AgentTone(session.state)))
                Text(PanelFormat.relativeAge(from: session.updatedAt, now: now))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 26, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Shows the terminal running this session")
    }

    private var title: String {
        session.title ?? session.project ?? session.agentName
    }

    private var subtitle: String {
        [session.agentName, session.project].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [session.agentName, title, PanelFormat.stateLabel(session.state)]
        if let tool = session.tool { parts.append(tool) }
        parts.append("updated \(PanelFormat.relativeAge(from: session.updatedAt, now: now))")
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
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.card.opacity(configuration.isPressed ? 1 : hovering ? 0.7 : 0))
                )
                .onHover { hovering = $0 }
        }
    }
}
