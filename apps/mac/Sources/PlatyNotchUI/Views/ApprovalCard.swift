import PlatyNotchKit
import SwiftUI

/// One pending approval: who asks (agent, project, tool), the exact summary in a
/// monospaced, selectable, scrollable view, a countdown to `expires_at`, and Deny / Allow.
///
/// Return never answers: no button is a default action. ⌘↩ allows and ⌘⌫ denies, and
/// only on the card given `shortcuts` (the oldest), so one keystroke answers one approval.
/// Shortcuts need the panel to be key, which happens only when the user clicks into it.
struct ApprovalCard: View {
    let approval: Approval
    let session: Session?
    let canAnswer: Bool
    let phase: DecisionPhase?
    /// Most summary lines shown before scrolling (the peek has less room than the panel).
    var maxLines = ApprovalFormat.maxSummaryLines
    var shortcuts = false
    let onDecide: (ApprovalBehavior) -> Void
    let onOpenTerminal: (Session) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let status = ApprovalCardStatus(approval: approval, now: ctx.date, canAnswer: canAnswer, phase: phase)
            VStack(alignment: .leading, spacing: 6) {
                header(status)
                SummaryView(summary: approval.summary, maxLines: maxLines)
                footer(status)
            }
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(approval.agentName) asks to run \(approval.tool)")
    }

    private func header(_ status: ApprovalCardStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Theme.agentSymbol(approval.agent))
                .foregroundStyle(Theme.color(.attention))
                .accessibilityHidden(true)
            Text(verbatim: approval.agentName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let project = approval.project, !project.isEmpty {
                Text(verbatim: project)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(approval.cwd ?? project)
            }
            Tag(text: approval.tool)
                .layoutPriority(1)
            Spacer(minLength: 4)
            statusLabel(status)
                .layoutPriority(2)
        }
    }

    @ViewBuilder private func statusLabel(_ status: ApprovalCardStatus) -> some View {
        Group {
            switch status {
            case .ready(let countdown, _):
                Text(countdown).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("Expires in \(countdown)")
            case .reconnecting(let countdown):
                Text("Reconnecting… \(countdown)").monospacedDigit().foregroundStyle(Theme.color(.attention))
            case .sending:
                Text("Sending…").foregroundStyle(.secondary)
            case .expired:
                Text("Expired — answer in the terminal").foregroundStyle(Theme.color(.attention))
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private func footer(_ status: ApprovalCardStatus) -> some View {
        HStack(spacing: 8) {
            if case .ready(_, let error?) = status {
                Text(verbatim: error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.color(.critical))
                    .lineLimit(2)
            } else if let session {
                Button("Open terminal") { onOpenTerminal(session) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .accessibilityHint("Shows the terminal running this session")
            }
            Spacer(minLength: 0)
            decisionButtons(enabled: status.canAnswer)
        }
        .controlSize(.small)
    }

    /// Deny and Allow; neither is a default action, so Return does nothing.
    private func decisionButtons(enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Button { onDecide(.deny) } label: {
                Label { Text("Deny") } icon: { Text("⌘⌫").foregroundStyle(.secondary) }
                    .labelStyle(TrailingIconLabelStyle())
            }
            .keyboardShortcut(shortcuts ? KeyboardShortcut(.delete, modifiers: .command) : nil)
            .accessibilityLabel("Deny")
            .accessibilityHint(shortcuts ? "Command-Delete" : "")
            Button { onDecide(.allow) } label: {
                Label { Text("Allow") } icon: { Text("⌘↩").foregroundStyle(.secondary) }
                    .labelStyle(TrailingIconLabelStyle())
            }
            .tint(Theme.color(.active))
            .keyboardShortcut(shortcuts ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .accessibilityLabel("Allow")
            .accessibilityHint(shortcuts ? "Command-Return" : "")
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }
}

/// The exact summary: monospaced, selectable, growing to `maxLines` and then scrolling.
private struct SummaryView: View {
    let summary: String
    let maxLines: Int

    var body: some View {
        let height = CGFloat(min(ApprovalFormat.visibleLines(for: summary), maxLines)) * Theme.monoLineHeight
        ViewThatFits(in: .vertical) {
            text
            ScrollView(.vertical) { text }
                .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, minHeight: Theme.monoLineHeight, maxHeight: max(height, Theme.monoLineHeight) + 8,
               alignment: .topLeading)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var text: some View {
        // Verbatim: never interpreted as Markdown or a localization key.
        Text(verbatim: summary)
            .font(Theme.mono)
            .lineSpacing(0)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
    }
}

/// Title first, then the shortcut hint.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.system(size: 10))
        }
    }
}

/// All pending approvals, oldest first; only the oldest takes the keyboard shortcuts.
struct ApprovalList: View {
    let approvals: [Approval]
    let sessions: [Session]
    let canAnswer: Bool
    let responder: ApprovalResponder
    var maxLines = ApprovalFormat.maxSummaryLines
    let onOpenTerminal: (Session) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(ApprovalFormat.ordered(approvals).enumerated()), id: \.element.id) { index, approval in
                ApprovalCard(approval: approval,
                             session: sessions.first { $0.key == approval.sessionKey },
                             canAnswer: canAnswer,
                             phase: responder.phase(for: approval.id),
                             maxLines: maxLines,
                             shortcuts: index == 0,
                             onDecide: { responder.decide(approval, $0) },
                             onOpenTerminal: onOpenTerminal)
            }
        }
    }
}
