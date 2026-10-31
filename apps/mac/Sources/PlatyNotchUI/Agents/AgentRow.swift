import AppKit
import PlatyNotchKit
import SwiftUI

/// One session in the Agents list (Quiet Notch spec 2.3, wireframe C), one dense line in four
/// columns (18 / flexible / auto / auto, 10 pt apart, 7 pt above and below): the agent's app
/// icon (else its name), the **project** with ` · status · age`, a 7 pt state dot, and one
/// button naming the app it opens (`TerminalFocus.title(for:)`, "Open Claude" / "Show
/// folder"). A click anywhere on the row does the same.
struct AgentRow: View {
    /// The badge column: an 18 pt slot for the 16 pt icon.
    static let badgeColumn: CGFloat = 18
    static let gap: CGFloat = 10
    static let verticalPadding: CGFloat = 7
    /// The project never takes more than this, so the status stays readable beside it.
    static let projectMaxWidth: CGFloat = 240
    let session: Session
    let attention: AgentAttention
    let now: Date
    /// When the session finished (`AgentFinishLog.finishedAt`), for "finished · 3 m".
    var finishedAt: Date? = nil
    /// The first column's width (`AgentBadge.column`): 18 for icons, wider for names.
    var badgeWidth: CGFloat = AgentRow.badgeColumn
    /// The button column's width, so the dots and buttons line up down the list.
    var buttonWidth: CGFloat?
    let onOpenTerminal: (Session) -> Void

    /// The widest button among `titles` (12 pt text plus its 9 pt padding each side).
    static func buttonColumn(_ titles: [String]) -> CGFloat? {
        let font = NSFont.systemFont(ofSize: TypeScale.secondary.size)
        let widths: [CGFloat] = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 18 }
        return widths.max()
    }

    var body: some View {
        let openTitle: String? = TerminalFocus.title(for: session)
        let tone: StateTone = attention.tone
        Button { onOpenTerminal(session) } label: {
            HStack(spacing: Self.gap) {
                AgentBadge(brand: AgentBrand(agent: session.agent, agentName: session.agentName))
                    .frame(width: badgeWidth, alignment: .leading)
                    .help(session.agentName)
                HStack(spacing: 0) {
                    Text(verbatim: project)
                        .font(DS.font(TypeScale.title))
                        .foregroundStyle(DS.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Its own width up to the cap (a long name truncates there).
                        .frame(maxWidth: Self.projectMaxWidth, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(verbatim: " · " + status)
                        .font(DS.font(TypeScale.secondary))
                        .foregroundStyle(DS.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AgentDot(color: DS.dynamicNSColor(tone), style: tone == .working ? .pulse : .solid)
                if let openTitle {
                    PanelButtonLabel(title: openTitle, minWidth: buttonWidth)
                } else if let buttonWidth {
                    Color.clear.frame(width: buttonWidth, height: 1)
                }
            }
            .padding(.vertical, Self.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(openTitle == nil ? "" : AgentRowAction(attention) == .answer
                           ? "Answers in the app running this session" : "Shows the app running this session")
        .accessibilityAddTraits(openTitle == nil ? [] : .isButton)
        .accessibilityActions {
            if let openTitle { Button(openTitle) { onOpenTerminal(session) } }
        }
    }

    private var project: String { Self.project(session) }

    private var status: String {
        SessionStatusLine.compact(session, attention: attention, now: now, finishedAt: finishedAt)
    }

    static func project(_ s: Session) -> String {
        SessionName.display(s)
    }

    /// The row's visible text in order (tests): project, status, then the button.
    @MainActor static func texts(_ s: Session, attention: AgentAttention, now: Date, finishedAt: Date? = nil) -> [String] {
        var out: [String] = [project(s), SessionStatusLine.compact(s, attention: attention, now: now, finishedAt: finishedAt)]
        if let title = TerminalFocus.title(for: s) { out.append(title) }
        return out
    }

    /// VoiceOver: the agent, the project, the state in words (the dot's meaning), the status
    /// and the button.
    private var accessibilityText: String {
        var parts: [String] = [session.agentName, project, attention.tone.word, status]
        if let title = TerminalFocus.title(for: session) { parts.append(title) }
        return parts.joined(separator: ", ")
    }
}

/// A small panel button's look (spec 5.1): 12 pt, padding 3 × 9, radius 6, on the fill.
/// `tone` tints it (Allow: green text on green at 0.12).
struct PanelButtonLabel: View {
    let title: String
    var keycap: String?
    var tone: StateTone?
    /// Buttons in a column share one width (the title centred).
    var minWidth: CGFloat?

    var body: some View {
        let ink: Color = tone.map { DS.color($0) } ?? DS.primary
        let fill: Color = tone.map { DS.color($0, alpha: 0.12) } ?? DS.fill
        HStack(spacing: 5) {
            Text(verbatim: title)
                .font(DS.font(TypeScale.secondary))
                .lineLimit(1)
            if let keycap {
                Keycap(text: keycap, color: tone == nil ? DS.tertiary : ink.opacity(0.8))
            }
        }
        .foregroundStyle(ink)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(minWidth: minWidth)
        .padding(.vertical, 3)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

/// Highlights a row on hover and press: the fill behind it, no border.
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
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(DS.fill.opacity(configuration.isPressed ? 1 : hovering ? 0.7 : 0))
                        .padding(.horizontal, -6)
                )
                .onHover { hovering = $0 }
        }
    }
}
