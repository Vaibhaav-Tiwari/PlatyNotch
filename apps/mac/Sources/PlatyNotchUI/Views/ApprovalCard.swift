import PlatyNotchKit
import SwiftUI

/// One pending approval: who asks (agent, project, tool), the summary in a monospaced,
/// selectable, scrollable view (hidden characters made visible), a countdown to
/// `expires_at`, and Deny / Allow.
///
/// Return never answers: no button is a default action, and Allow cannot take keyboard
/// focus. ⌘↩ allows and ⌘⌫ denies, only on the card given `shortcuts` (the oldest).
/// Shortcuts need the panel to be key, which happens only when the user clicks into it.
/// Answers before the card is armed (`ApprovalArming`) are dropped by `onDecide`'s owner
/// and the card shows "Look first…".
struct ApprovalCard: View {
    let approval: Approval
    let session: Session?
    let canAnswer: Bool
    let phase: DecisionPhase?
    let arming: ApprovalArming
    /// Most summary lines shown before scrolling (the peek has less room than the panel).
    var maxLines = ApprovalFormat.maxSummaryLines
    var shortcuts = false
    /// Set in the peek: the header and a "More" button open the full panel.
    var onExpand: (() -> Void)?
    /// Open panel only: the full command, path and diff (Task 17). The peek passes none
    /// and keeps today's summary (spec 6.8).
    var preview: ApprovalPreview? = nil
    /// Cards showing at once: one gets an 8-line diff box, several get 4 (Ruling 11).
    var cards: Int = 1
    /// The diff starts with every line shown (tests and renders).
    var diffExpanded: Bool = false
    /// The peek's "Show changes" link (calls `onExpand`), when the payload has a diff.
    var showChanges: Bool = false
    let onDecide: (ApprovalBehavior) -> Void
    let onOpenTerminal: (Session) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let visible = VisibleApproval(approval)
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let status = ApprovalCardStatus(approval: approval, now: ctx.date, canAnswer: canAnswer, phase: phase)
            let lookFirst = status.canAnswer && arming.showsLookFirst(approval.id, at: ctx.date)
            VStack(alignment: .leading, spacing: 6) {
                header(visible, status, lookFirst: lookFirst)
                if hasHidden {
                    Label("Contains hidden characters", systemImage: "exclamationmark.triangle.fill")
                        .font(DS.font(TypeScale.caption).weight(.medium))
                        .foregroundStyle(Theme.warning(scheme))
                }
                SummaryView(summary: summaryText, maxLines: maxLines)
                if let preview, preview.path != nil || !preview.diff.isEmpty {
                    ApprovalDiffBox(preview: preview, cards: cards, expanded: diffExpanded)
                }
                footer(status)
            }
        }
        .padding(8)
        .dsCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(visible.agentName) asks to run \(visible.tool)")
    }

    /// What the summary box shows: the payload's full command when there is one (open
    /// panel), else the core's summary; hidden characters spelled out either way.
    var summaryText: String {
        preview?.command ?? VisibleApproval(approval).summary
    }

    /// Anything shown on the card had hidden characters.
    var hasHidden: Bool {
        VisibleApproval(approval).hadHidden || (preview?.hadHidden ?? false)
    }

    private func header(_ visible: VisibleApproval, _ status: ApprovalCardStatus, lookFirst: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Theme.agentSymbol(approval.agent))
                .foregroundStyle(Theme.color(.attention))
                .accessibilityHidden(true)
            Text(verbatim: visible.agentName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let project = visible.project, !project.isEmpty {
                Text(verbatim: project)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(visible.cwd ?? project)
            }
            Tag(text: visible.tool)
                .layoutPriority(1)
            Spacer(minLength: 4)
            statusLabel(status, lookFirst: lookFirst)
                .layoutPriority(2)
        }
        .contentShape(Rectangle())
        .onTapGesture { onExpand?() }
        .accessibilityAction(named: "Show all approvals") { onExpand?() }
    }

    @ViewBuilder private func statusLabel(_ status: ApprovalCardStatus, lookFirst: Bool) -> some View {
        Group {
            switch status {
            case .ready where lookFirst:
                Text("Look first…").foregroundStyle(Theme.color(.attention))
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
        VStack(alignment: .leading, spacing: 4) {
            if case .ready(_, let error?) = status {
                Text(verbatim: error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.color(.critical))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let session {
                    Button("Open terminal") { onOpenTerminal(session) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .accessibilityHint("Shows the terminal running this session")
                }
                // "Show changes" takes "More"'s place (both open the panel), so the
                // peek's footer keeps its width.
                if showChanges, let onExpand {
                    Button("Show changes", action: onExpand)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .accessibilityLabel("Show changes")
                        .accessibilityHint("Opens the panel with this request's changes")
                } else if let onExpand {
                    Button("More", action: onExpand)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .accessibilityLabel("Show all approvals")
                }
                Spacer(minLength: 0)
                decisionButtons(enabled: status.canAnswer)
            }
        }
        .controlSize(.small)
    }

    /// Deny and Allow; neither is a default action, so Return does nothing. Allow never
    /// takes keyboard focus, so Space with Full Keyboard Access cannot allow either.
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
            .tint(Theme.allow(scheme))
            .focusable(false)
            .keyboardShortcut(shortcuts ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .accessibilityLabel("Allow")
            .accessibilityHint(shortcuts ? "Command-Return" : "")
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }
}

/// The summary: monospaced, selectable, growing to `maxLines` and then scrolling.
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
            configuration.icon.font(DS.font(TypeScale.caption))
        }
    }
}

/// One line for an approval waiting behind the first in the peek: agent · tool · first
/// summary line, and "Open" (answering happens in the full panel).
struct ApprovalRow: View {
    let approval: Approval
    /// Approvals beyond this one ("+n more").
    let more: Int
    let onOpen: () -> Void

    var body: some View {
        let visible = VisibleApproval(approval)
        HStack(spacing: 6) {
            Image(systemName: Theme.agentSymbol(approval.agent))
                .foregroundStyle(Theme.color(.attention))
                .accessibilityHidden(true)
            if visible.hadHidden {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.color(.attention))
                    .help("Contains hidden characters")
                    .accessibilityLabel("Contains hidden characters")
            }
            Text(verbatim: "\(visible.agentName) · \(visible.tool)")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(verbatim: ApprovalFormat.firstLine(approval.summary, lineCountSuffix: true))
                .font(Theme.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if more > 0 {
                Text("+\(more) more").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Open", action: onOpen)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .accessibilityLabel("Open the panel to answer \(visible.agentName)'s \(visible.tool) request")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .dsCard()
        .accessibilityElement(children: .contain)
    }
}

/// All pending approvals, oldest first; only the oldest takes the keyboard shortcuts.
struct ApprovalList: View {
    let approvals: [Approval]
    let sessions: [Session]
    let canAnswer: Bool
    let responder: ApprovalResponder
    let arming: ApprovalArming
    var maxLines = ApprovalFormat.maxSummaryLines
    let onDecide: (Approval, ApprovalBehavior) -> Void
    let onOpenTerminal: (Session) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(ApprovalFormat.ordered(approvals).enumerated()), id: \.element.id) { index, approval in
                ApprovalCard(approval: approval,
                             session: sessions.first { $0.key == approval.sessionKey },
                             canAnswer: canAnswer,
                             phase: responder.phase(for: approval.id),
                             arming: arming,
                             maxLines: maxLines,
                             shortcuts: index == 0,
                             preview: ApprovalPreview(approval: approval),
                             cards: approvals.count,
                             onDecide: { onDecide(approval, $0) },
                             onOpenTerminal: onOpenTerminal)
            }
        }
    }
}
