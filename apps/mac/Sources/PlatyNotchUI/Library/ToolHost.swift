import PlatyNotchKit
import SwiftUI

/// A Library tool opened full-panel: its header (a back chevron to the Library and the
/// tool's name) takes the nav row's place, and the tool has the rest of the panel. Content
/// taller than the room scrolls inside, fading at the edge that has more.
struct ToolHost: View {
    static let backLabel = "Back to Library"
    /// Between the header and the tool.
    static let gap: CGFloat = Space.xs

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
                HStack(spacing: Space.xs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(hovering ? wash : .clear, in: Circle())
                    Text(verbatim: title)
                        .font(DS.font(TypeScale.headline))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(ToolHost.backLabel + " (Esc)")
            .accessibilityLabel(ToolHost.backLabel)
            .accessibilityHint("\(title) is open")
            .layoutPriority(1)
            Spacer(minLength: Space.s)
            if let trailing { trailing }
        }
    }

    private var wash: Color { (scheme == .light ? Color.black : Color.white).opacity(0.08) }
}

/// A tool's content: at its own height from the top when it fits, else scrolling inside
/// the room with a fade at the edge that has more.
struct ToolBody: View {
    let content: AnyView
    @State private var edges = ScrollEdges()

    var body: some View {
        ViewThatFits(in: .vertical) {
            // Fits: the tool has the whole room (a tool that fills it, like the games, stays put).
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            scroller
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.inLibraryTool, true)
    }

    private var scroller: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: ScrollEdges.self) { g in
            ScrollEdges(top: g.contentOffset.y > 1,
                        bottom: g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1)
        } action: { _, new in
            edges = new
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(edges.top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: LibraryView.fade)
                Color.black
                LinearGradient(colors: [.black, .black.opacity(edges.bottom ? 0 : 1)], startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: LibraryView.fade)
            }
        }
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
