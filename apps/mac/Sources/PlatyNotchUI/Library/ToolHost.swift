import PlatyNotchKit
import SwiftUI

/// A Library tool opened full-panel: its header (a back chevron to the Library and the
/// tool's name) takes the nav row's place, and the tool has the rest of the panel. Content
/// taller than the room scrolls inside, fading at the edge that has more.
struct ToolHost: View {
    static let backLabel = "Back to Library"
    /// Between the header and the tool: the nav's gap, so content starts where it does
    /// under the nav.
    static let gap: CGFloat = NowMetrics.gap

    let title: String
    let onBack: () -> Void
    let content: AnyView
    /// The panel's own controls at the header's trailing edge (Settings, close).
    var trailing: AnyView?

    init(title: String, onBack: @escaping () -> Void, content: AnyView, trailing: AnyView? = nil) {
        self.title = title
        self.onBack = onBack
        self.content = content
        self.trailing = trailing
    }

    /// The room a tool has below its header in `available` (the open panel's content
    /// height less the top inset and bottom padding).
    static func contentHeight(available: CGFloat) -> CGFloat {
        available - NowMetrics.nav - gap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            ToolHeader(title: title, onBack: onBack, trailing: trailing)
                .frame(height: NowMetrics.nav)
            ToolBody(content: content)
        }
    }
}

/// The tool header: ‹ and the tool's name, the panel's controls trailing.
struct ToolHeader: View {
    let title: String
    let onBack: () -> Void
    var trailing: AnyView?
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: Space.xs) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(hovering ? wash : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(ToolHost.backLabel + " (Esc)")
            .accessibilityLabel(ToolHost.backLabel)
            Text(verbatim: title)
                .font(DS.font(TypeScale.headline))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
                .layoutPriority(1)
            Spacer(minLength: Space.s)
            if let trailing { trailing }
        }
    }

    private var wash: Color { (scheme == .light ? Color.black : Color.white).opacity(0.08) }
}

/// A tool's content in one scroll view that never swaps it out (a swap would reset its
/// `@State`: typed text, a picker's choice, focus): at least the room tall, so a tool that
/// fills it (the games, a centred empty state) stays put, and scrolling only when taller,
/// with a fade at the edge that has more.
struct ToolBody: View {
    let content: AnyView

    var body: some View {
        FadingScroll(fillsRoom: true) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.inLibraryTool, true)
    }
}

/// One vertical scroll view whose content keeps its identity, with a soft fade at an edge
/// only while there is more beyond it. `fillsRoom`: the content is laid out at least as
/// tall as the scroll view (`FillHeight`).
struct FadingScroll<Content: View>: View {
    let fillsRoom: Bool
    /// The panel hides its scroller; a window page (the first run) shows it.
    var indicators: ScrollIndicatorVisibility = .hidden
    @ViewBuilder let content: Content
    @State private var edges = ScrollEdges()
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let room: CGFloat = geo.size.height
            ScrollView(.vertical) {
                FillHeight(minHeight: fillsRoom ? room : 0) { content }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .scrollIndicators(indicators)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: ScrollEdges.self) { g in
                ScrollEdges(top: g.contentOffset.y > 1,
                            bottom: g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1,
                            known: true)
            } action: { _, new in
                edges = new
            }
            // Before the first scroll report (and in renders) the content's height decides:
            // resting at the top, the bottom has more when the content is taller.
            .mask { ScrollFade(top: edges.known && edges.top,
                               bottom: edges.known ? edges.bottom : contentHeight > room + 1) }
        }
    }
}

/// The fade mask: solid, with `LibraryView.fade` of gradient at an edge that has more. Not
/// animated: it follows the scroll, and an opened grid shows its fade at once.
struct ScrollFade: View {
    let top: Bool
    let bottom: Bool

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: LibraryView.fade)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: LibraryView.fade)
        }
    }
}

/// Lays its one child out at least `minHeight` tall: a child that fills (a flexible frame)
/// gets the whole room, a taller one keeps its own height (the scroll view scrolls it).
struct FillHeight: Layout {
    let minHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal: CGSize = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let width: CGFloat = proposal.width ?? ideal.width
        return CGSize(width: width, height: max(minHeight, ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// MARK: - Tool presentation

private struct InLibraryToolKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a Library tool (`ToolBody`): a widget's view drops its own card and title
    /// (the tool header names it), and shows its empty state centred in the room.
    var inLibraryTool: Bool {
        get { self[InLibraryToolKey.self] }
        set { self[InLibraryToolKey.self] = newValue }
    }
}

/// A tool with nothing to show yet: its symbol, one line and what to do, centred in the
/// tool's room; an optional single action.
struct ToolEmptyState: View {
    let systemImage: String
    let title: String
    let detail: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Space.s) {
            DS.icon(systemImage, size: IconSize.hero)
                .foregroundStyle(.secondary)
                .padding(.bottom, Space.xs)
            Text(verbatim: title)
                .font(DS.font(TypeScale.headline))
                .multilineTextAlignment(.center)
            Text(verbatim: detail)
                .font(DS.font(TypeScale.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.regular)
                    .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A tool page composed for the room: an optional summary (a large value and its label)
/// above the tool's content in a readable column, the whole centred while it is shorter
/// than the room (taller, it scrolls from the top like any tool).
struct ToolPage<Content: View>: View {
    var value: String?
    var label: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: Space.l) {
            if let value {
                VStack(spacing: 2) {
                    Text(verbatim: value)
                        .font(DS.font(TypeScale.display))
                        .monospacedDigit()
                        .lineLimit(1)
                    if let label {
                        Text(verbatim: label)
                            .font(DS.font(TypeScale.body))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            content
                .frame(maxWidth: Self.column, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The content column: readable rows, not stretched across the panel.
    static var column: CGFloat { 440 }
}

/// A tool's one primary action (Join): a teal capsule, the same whether the panel is key
/// or not (a system prominent button turns grey in an inactive window). Text contrast:
/// near-black on the bright dark-theme teal, white on the deeper light-theme teal.
struct ToolPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryCapsule(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct PrimaryCapsule<Label: View>: View {
        let label: Label
        let pressed: Bool
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            label
                .font(DS.font(TypeStyle(size: TypeScale.body.size, weight: .semibold)))
                .foregroundStyle(scheme == .light ? Color.white : Color.black.opacity(0.85))
                .padding(.horizontal, Space.l)
                .frame(height: 30)
                .background(DS.color(.working, scheme).opacity(pressed ? 0.75 : 1), in: Capsule())
                .contentShape(Capsule())
        }
    }
}

/// An icon-led tool page for a tool with no list to show (Baskets, Keep awake on a
/// desktop): the tool's symbol in a large teal well, a title and one line, then its
/// controls, the whole centred in the room.
struct ToolIconPage<Content: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    static var well: CGFloat { 52 }

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(DS.dynamicColor(.working))
                .frame(width: Self.well, height: Self.well)
                .background(DS.dynamicColor(.working, alpha: 0.12),
                            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: Space.xs) {
                Text(verbatim: title)
                    .font(DS.font(TypeScale.headline))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: detail)
                    .font(DS.font(TypeScale.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            content
                .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Settings-style rows on one soft card (the Library tile's fill), for a tool page's
/// few controls.
struct ToolControlCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) { content }
            .padding(EdgeInsets(top: Space.s, leading: Space.m, bottom: Space.s, trailing: Space.m))
            .frame(width: 360)
            .background { LibraryTileCard(hovering: false) }
    }
}
