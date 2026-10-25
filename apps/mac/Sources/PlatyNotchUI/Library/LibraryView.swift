import PlatyNotchKit
import SwiftUI

/// The Library destination (spec 6.6): a 4-column grid of tool tiles, recently used first.
/// Twelve tools fit three rows without scrolling; with more (or with approvals taking room
/// above) the grid scrolls, fading at the edge that has more.
struct LibraryView: View {
    static let columnCount = 4
    static let spacing: CGFloat = Space.s
    /// The open panel's content width less the gaps, in four equal columns.
    static let tileWidth: CGFloat = (PanelLayout.expandedSize.width - 2 * Space.panelMargin - 3 * Space.s) / 4
    static let tileHeight: CGFloat = 84
    /// How far the edge fade reaches.
    static let fade: CGFloat = 24

    let items: [LibraryItem]
    let tile: (String) -> AnyView?
    let onOpen: (String) -> Void
    let onSetUp: (String) -> Void
    @State private var edges = ScrollEdges()

    init(items: [LibraryItem], tile: @escaping (String) -> AnyView?, onOpen: @escaping (String) -> Void,
         onSetUp: @escaping (String) -> Void) {
        self.items = items
        self.tile = tile
        self.onOpen = onOpen
        self.onSetUp = onSetUp
    }

    /// The grid's height for `count` tools (no scrolling).
    static func gridHeight(count: Int) -> CGFloat {
        let rows: Int = max(1, (count + columnCount - 1) / columnCount)
        let r: CGFloat = CGFloat(rows)
        return r * tileHeight + (r - 1) * spacing
    }

    /// Whether `count` tools need to scroll in `height`.
    static func scrolls(count: Int, height: CGFloat) -> Bool {
        gridHeight(count: count) > height + 0.5
    }

    /// A tile's one action: open the tool, or "Set up" when it has nothing yet.
    func activate(_ item: LibraryItem) {
        switch LibraryTile.action(for: item) {
        case .open: onOpen(item.id)
        case .setUp: onSetUp(item.id)
        }
    }

    var body: some View {
        if items.isEmpty {
            empty
        } else {
            GeometryReader { geo in
                let scrolls: Bool = Self.scrolls(count: items.count, height: geo.size.height)
                ScrollView(.vertical) {
                    grid
                }
                .scrollDisabled(!scrolls)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: ScrollEdges.self) { g in
                    ScrollEdges(top: g.contentOffset.y > 1,
                                bottom: g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1)
                } action: { _, new in
                    edges = new
                }
                .mask { fadeMask(scrolls: scrolls) }
            }
        }
    }

    private var grid: some View {
        let columns: [GridItem] = Array(repeating: GridItem(.fixed(Self.tileWidth), spacing: Self.spacing),
                                        count: Self.columnCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: Self.spacing) {
            ForEach(items) { item in
                LibraryTile(item: item, custom: tile(item.id), onTap: { activate(item) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Solid, with a soft fade at an edge only while there is more beyond it.
    @ViewBuilder private func fadeMask(scrolls: Bool) -> some View {
        let top: Bool = scrolls && edges.top
        let bottom: Bool = scrolls && edges.bottom
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fade)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fade)
        }
        .animation(.easeOut(duration: 0.15), value: edges)
    }

    private var empty: some View {
        VStack(spacing: Space.xs) {
            DS.icon("square.grid.2x2", size: IconSize.tile)
                .foregroundStyle(.tertiary)
            Text("No tools are on")
                .font(DS.font(TypeScale.body))
            Text("Turn widgets on in Settings › Widgets.")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Whether a scroll view has content above and below what shows.
struct ScrollEdges: Equatable {
    var top = false
    var bottom = false
}

/// A built-in widget's Library line ("2 timers", "5 items") when it has one; nil falls back
/// to the widget's top live activity. `libraryTitle` is a shorter name for the tile when the
/// widget's own title would not fit it.
@MainActor
protocol LibraryLiveLine {
    var libraryLine: String? { get }
    var libraryTitle: String? { get }
}

extension LibraryLiveLine {
    var libraryTitle: String? { nil }
}

/// One Library tool: its tile and the full-panel view it opens.
@MainActor
struct LibraryTool {
    let item: LibraryItem
    /// A plugin's own tile content (`libraryTile()`).
    let tile: AnyView?
    let view: () -> AnyView
}

/// The Library's tools in input order (Task 20): widget tools in the user's order, Platy
/// Chase right after Games, then Memory, then plugin tabs.
@MainActor
enum LibraryCatalog {
    static func tools(widgets: WidgetRegistry, extraTabs: [PanelTab], memory: @escaping () -> AnyView) -> [LibraryTool] {
        var out: [LibraryTool] = []
        for w in widgets.toolWidgets {
            out.append(LibraryTool(item: item(for: w), tile: w.libraryTile(), view: { [weak w] in
                w?.toolView() ?? AnyView(EmptyView())
            }))
            if w.id == GamesWidget.widgetID, let games = w as? GamesWidget {
                out.append(chase(games))
            }
        }
        out.append(LibraryTool(item: LibraryItem(id: LibraryTools.memory, title: "Memory", systemImage: "brain",
                                                 liveLine: "Search and graph", isSetUp: true),
                               tile: nil, view: memory))
        for tab in extraTabs {
            out.append(LibraryTool(item: LibraryItem(id: LibraryTools.plugin(tab.id), title: tab.title,
                                                     systemImage: tab.systemImage, liveLine: fallbackLine,
                                                     isSetUp: true),
                                   tile: nil, view: { tab.view }))
        }
        return out
    }

    /// The line of a tool that has nothing more specific to say (plugin widgets and tabs).
    static let fallbackLine = "Plug-in"

    /// Every tool id (`PanelRoute.legacy`), without building any view.
    static func ids(widgets: WidgetRegistry, extraTabs: [PanelTab]) -> Set<String> {
        var ids: Set<String> = [LibraryTools.memory]
        for w in widgets.toolWidgets {
            ids.insert(w.id)
            if w.id == GamesWidget.widgetID { ids.insert(LibraryTools.chase) }
        }
        for tab in extraTabs { ids.insert(LibraryTools.plugin(tab.id)) }
        return ids
    }

    static func item(for w: any NotchWidget) -> LibraryItem {
        let top: LiveActivity? = w.liveActivities.max { $0.priority < $1.priority }
        let lines: LibraryLiveLine? = w as? LibraryLiveLine
        // Never empty: the widget's own line, else its top live item, else a calm word.
        let line: String = lines?.libraryLine ?? top?.title ?? Self.fallbackLine
        return LibraryItem(id: w.id, title: lines?.libraryTitle ?? w.title, systemImage: w.systemImage, liveLine: line,
                           isSetUp: !w.needsSetup)
    }

    /// Platy Chase keeps its own entry (spec 6.10): the games tool with Chase picked.
    private static func chase(_ games: GamesWidget) -> LibraryTool {
        let best: Int = games.host.session.scores.best(GameKind.chase.rawValue)
        let host = games.host
        return LibraryTool(item: LibraryItem(id: LibraryTools.chase, title: "Platy Chase", systemImage: "hare",
                                             liveLine: best > 0 ? "Best \(best)" : "Arcade maze",
                                             isSetUp: true),
                           tile: nil, view: { AnyView(GamesTab(host: host, pick: .chase)) })
    }
}
