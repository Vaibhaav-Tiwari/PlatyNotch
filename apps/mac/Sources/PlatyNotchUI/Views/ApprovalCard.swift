import PlatyNotchKit
import SwiftUI

/// One pending approval in the v0.2 style (Quiet Notch spec 5.4): on #111 with radius 12 and
/// 12 pt padding, a header with the agent's app icon, its name in semibold, the project in
/// secondary, the tool in a small chip and the countdown in mono; the command in mono 12 on
/// the fill (selectable, hidden characters made visible; a command longer than a line wraps
/// and scrolls, never truncated); then right-aligned "Deny ⌘⌫" and "Allow ⌘↩" with keycaps,
/// Allow in green.
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

    /// Deny's and Allow's shortcuts, shown in keycaps.
    static let keycaps = ["\u{2318}\u{232B}", "\u{2318}\u{21A9}"]
    /// The command's font: SF Mono 12.
    static let commandFont: Font = DS.font(TypeScale.mono)
    /// One line of `commandFont`, used to size the command box.
    static let commandLineHeight: CGFloat = 15
    /// 12 at the sides; 10 above and below, so one card with a full diff box still fits the
    /// 240 pt approvals region without scrolling.
    static let padding: CGFloat = 12
    static let verticalPadding: CGFloat = 10

    var body: some View {
        let visible = VisibleApproval(approval)
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let status = ApprovalCardStatus(approval: approval, now: ctx.date, canAnswer: canAnswer, phase: phase)
            let lookFirst = status.canAnswer && arming.showsLookFirst(approval.id, at: ctx.date)
            VStack(alignment: .leading, spacing: 6) {
                header(visible, status, lookFirst: lookFirst)
                if hasHidden {
                    Label("Contains hidden characters", systemImage: "exclamationmark.triangle.fill")
                        .font(DS.font(TypeScale.secondary))
                        .foregroundStyle(Theme.warning)
                }
                SummaryView(summary: summaryText, maxLines: maxLines)
                if let preview, preview.path != nil || !preview.diff.isEmpty {
                    ApprovalDiffBox(preview: preview, cards: cards, expanded: diffExpanded)
                }
                footer(status)
            }
        }
        .padding(.horizontal, Self.padding)
        .padding(.vertical, Self.verticalPadding)
        .background(Theme.approvalCard, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(visible.agentName) asks to run \(visible.tool)")
    }

    /// What the summary box shows: in the open panel, a plain Bash command in full when it
    /// hides nothing (`ApprovalPreview.fullCommand`), else the core's summary; hidden
    /// characters spelled out either way.
    var summaryText: String {
        preview?.command ?? VisibleApproval(approval).summary
    }

    /// Anything shown on the card had hidden characters.
    var hasHidden: Bool {
        VisibleApproval(approval).hadHidden || (preview?.hadHidden ?? false)
    }

    private func header(_ visible: VisibleApproval, _ status: ApprovalCardStatus, lookFirst: Bool) -> some View {
        HStack(spacing: 8) {
            // The agent's installed app icon; without one, the name beside it says who asks.
            AgentBadge(brand: AgentBrand(agent: approval.agent, agentName: approval.agentName), nameFallback: false)
            Text(verbatim: visible.agentName)
                .font(DS.font(TypeScale.title))
                .foregroundStyle(DS.primary)
                .lineLimit(1)
            if let project = visible.project, !project.isEmpty {
                Text(verbatim: project)
                    .font(DS.font(TypeScale.secondary))
                    .foregroundStyle(DS.secondary)
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
        .frame(minHeight: AgentBadge.size)
        .contentShape(Rectangle())
        .onTapGesture { onExpand?() }
        .accessibilityAction(named: "Show all approvals") { onExpand?() }
    }

    @ViewBuilder private func statusLabel(_ status: ApprovalCardStatus, lookFirst: Bool) -> some View {
        Group {
            switch status {
            case .ready where lookFirst:
                Text("Look first…").foregroundStyle(DS.color(.needsYou))
            case .ready(let countdown, _):
                Text(countdown).font(DS.font(TypeScale.mono)).foregroundStyle(DS.secondary)
                    .accessibilityLabel("Expires in \(countdown)")
            case .reconnecting(let countdown):
                Text("Reconnecting… \(countdown)").monospacedDigit().foregroundStyle(DS.color(.needsYou))
            case .sending:
                Text("Sending…").foregroundStyle(DS.secondary)
            case .expired:
                Text("Expired — answer in the terminal").foregroundStyle(DS.color(.needsYou))
            }
        }
        .font(DS.font(TypeScale.secondary))
        .lineLimit(1)
    }

    private func footer(_ status: ApprovalCardStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .ready(_, let error?) = status {
                Text(verbatim: error)
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(DS.color(.error))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let session, let openTitle = TerminalFocus.title(for: session) {
                    Button(openTitle) { onOpenTerminal(session) }
                        .buttonStyle(.panelLink)
                        .font(.system(size: 11))
                        .accessibilityHint("Shows the app running this session")
                }
                // "Show changes" takes "More"'s place (both open the panel), so the
                // peek's footer keeps its width.
                if showChanges, let onExpand {
                    Button("Show changes", action: onExpand)
                        .buttonStyle(.panelLink)
                        .font(.system(size: 11))
                        .accessibilityLabel("Show changes")
                        .accessibilityHint("Opens the panel with this request's changes")
                } else if let onExpand {
                    Button("More", action: onExpand)
                        .buttonStyle(.panelLink)
                        .font(.system(size: 11))
                        .accessibilityLabel("Show all approvals")
                }
                Spacer(minLength: 0)
                decisionButtons(enabled: status.canAnswer)
            }
        }
        .controlSize(.small)
    }

    /// Deny and Allow with their keycaps; neither is a default action, so Return does
    /// nothing. Allow never takes keyboard focus, so Space with Full Keyboard Access cannot
    /// allow either.
    private func decisionButtons(enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Button { onDecide(.deny) } label: {
                PanelButtonLabel(title: "Deny", keycap: Self.keycaps[0])
            }
            .keyboardShortcut(shortcuts ? KeyboardShortcut(.delete, modifiers: .command) : nil)
            .accessibilityLabel("Deny")
            .accessibilityHint(shortcuts ? "Command-Delete" : "")
            Button { onDecide(.allow) } label: {
                PanelButtonLabel(title: "Allow", keycap: Self.keycaps[1], tone: .working)
            }
            .focusable(false)
            .keyboardShortcut(shortcuts ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .accessibilityLabel("Allow")
            .accessibilityHint(shortcuts ? "Command-Return" : "")
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// The command: SF Mono 12 on the fill (radius 6, padding 6 × 9), selectable. One line for
/// a one-line command; a longer one wraps and grows to `maxLines`, then scrolls (never
/// truncated: every character asked about stays readable).
struct SummaryView: View {
    let summary: String
    let maxLines: Int
    static let insets = EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)

    var body: some View {
        let lines: CGFloat = CGFloat(min(ApprovalFormat.visibleLines(for: summary), maxLines))
        let line: CGFloat = ApprovalCard.commandLineHeight
        let vertical: CGFloat = Self.insets.top + Self.insets.bottom
        ViewThatFits(in: .vertical) {
            text
            ScrollView(.vertical) { text }
                .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, minHeight: line + vertical, maxHeight: max(lines, 1) * line + vertical,
               alignment: .topLeading)
        .background(DS.fill, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }

    private var text: some View {
        // Verbatim: never interpreted as Markdown or a localization key.
        Text(verbatim: summary)
            .font(ApprovalCard.commandFont)
            .foregroundStyle(DS.primary)
            .lineSpacing(0)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Self.insets)
    }
}

/// A plain button that dims while pressed (the label draws its own fill).
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
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
            // The agent's installed app icon; the text beside it names the agent.
            AgentBadge(brand: AgentBrand(agent: approval.agent, agentName: approval.agentName), nameFallback: false)
            if visible.hadHidden {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.color(.needsYou))
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
        .background(Theme.approvalCard, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
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
                             preview: ApprovalPreviewCache.shared.preview(for: approval),
                             cards: approvals.count,
                             onDecide: { onDecide(approval, $0) },
                             onOpenTerminal: onOpenTerminal)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ApprovalCardFramesKey.self,
                                           value: [approval.id: g.frame(in: .named(ExpandedPanel.space))])
                })
            }
        }
        // Previews of answered approvals go (each is built once, `ApprovalPreviewCache`).
        .onChange(of: approvals.map(\.id), initial: true) { _, ids in
            ApprovalPreviewCache.shared.keep(ids: Set(ids))
        }
    }
}
