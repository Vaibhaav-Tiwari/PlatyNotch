import PlatyNotchKit
import SwiftUI

/// An open-panel approval card's preview (spec 6.5, 6.8; Ruling 11): the file path, then
/// the unified diff in a box of fixed height (8 lines with one card, 4 with several) that
/// scrolls inside itself. It starts with the first 12 diff lines; "Show all" reveals the
/// rest inside the same box, so the card never changes height and nothing moves under the
/// pointer. Added lines start with "+", removed with "−" (never colour alone). Every line
/// comes from the hook payload through `ApprovalPreview`, hidden characters spelled out.
struct ApprovalDiffBox: View {
    let preview: ApprovalPreview
    let cards: Int
    @State private var expanded: Bool
    @Environment(\.colorScheme) private var scheme

    /// `expanded`: start with every line shown (tests and renders).
    init(preview: ApprovalPreview, cards: Int, expanded: Bool = false) {
        self.preview = preview
        self.cards = cards
        _expanded = State(initialValue: expanded)
    }

    /// The box's fixed height: `ApprovalPreview.boxLines` mono lines.
    static func boxHeight(preview: ApprovalPreview, cards: Int) -> CGFloat {
        CGFloat(ApprovalPreview.boxLines(diffCount: preview.diff.count, cards: cards)) * Theme.monoLineHeight
    }

    /// The path row's fixed height (the "Show all" link sits in it).
    static let pathRowHeight: CGFloat = 16

    static func sign(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "\u{2212}"
        case .context: " "
        case .hunk: ""
        }
    }

    static func text(_ line: DiffLine) -> String { sign(line.kind) + line.text }

    static func tone(_ kind: DiffLine.Kind) -> StateTone? {
        switch kind {
        case .added: .done
        case .removed: .error
        case .context, .hunk: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if preview.path != nil || preview.hasMore {
                pathRow.frame(height: Self.pathRowHeight)
            }
            if !preview.diff.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let lines = preview.lines(expanded: expanded)
                        ForEach(lines.indices, id: \.self) { i in row(lines[i]) }
                    }
                    .padding(.horizontal, 4)
                }
                .scrollIndicators(.automatic)
                // Lines start at the top left; a short diff is never centred in the box.
                .defaultScrollAnchor(.topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.boxHeight(preview: preview, cards: cards))
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Changes, \(preview.diff.count) lines")
            }
        }
    }

    private var pathRow: some View {
        HStack(spacing: 4) {
            if let path = preview.path {
                Image(systemName: "doc.text")
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: path)
                    .font(Theme.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
                    .accessibilityLabel("File \(path)")
            }
            Spacer(minLength: 4)
            if preview.hasMore {
                Button(expanded ? "Show first \(ApprovalPreview.collapsedLines)" : "Show all \(preview.diff.count) lines") {
                    expanded.toggle()
                }
                .buttonStyle(.panelLink)
                .font(DS.font(TypeScale.caption))
                .lineLimit(1)
                .fixedSize()
                .focusable(false)
            }
        }
    }

    private func row(_ line: DiffLine) -> some View {
        let tone: StateTone? = Self.tone(line.kind)
        let color: Color = tone.map { DS.color($0) } ?? (line.kind == .hunk ? Color.secondary : Color.primary)
        return Text(verbatim: Self.text(line))
            .font(Theme.mono)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: Theme.monoLineHeight, alignment: .leading)
            .accessibilityLabel(Self.spoken(line))
    }

    private static func spoken(_ line: DiffLine) -> String {
        switch line.kind {
        case .added: "Added: \(line.text)"
        case .removed: "Removed: \(line.text)"
        case .context: line.text
        case .hunk: line.text
        }
    }
}
