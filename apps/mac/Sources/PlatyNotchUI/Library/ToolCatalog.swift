import PlatyNotchKit
import SwiftUI

/// One feature that opens inside the panel (spec 2.4): its name, symbol and full-panel view.
@MainActor
struct PanelTool {
    let id: String
    let title: String
    let systemImage: String
    let view: () -> AnyView
}

/// The features that open inside the panel, found by id: tool widgets in the user's order
/// (Platy Chase right after Games), Memory, then plugin tabs. A widget that is off is not a
/// tool, so a link to it lands on Home (`PanelRoute.legacy`).
@MainActor
enum ToolCatalog {
    static func tools(widgets: WidgetRegistry, extraTabs: [PanelTab], memory: @escaping () -> AnyView) -> [PanelTool] {
        var out: [PanelTool] = []
        for w in widgets.toolWidgets {
            out.append(widgetTool(w))
            if w.id == GamesWidget.widgetID, let games = w as? GamesWidget {
                out.append(chase(games))
            }
        }
        out.append(memoryTool(memory))
        for tab in extraTabs { out.append(pluginTool(tab)) }
        return out
    }

    /// One tool by id without building the others (an open tool redraws often); nil when it
    /// is not available now (its widget was turned off).
    static func tool(_ id: String, widgets: WidgetRegistry, extraTabs: [PanelTab],
                     memory: @escaping () -> AnyView) -> PanelTool? {
        if id == PanelTools.memory { return memoryTool(memory) }
        if let tab = extraTabs.first(where: { PanelTools.plugin($0.id) == id }) { return pluginTool(tab) }
        let gamesID: String = id == PanelTools.chase ? GamesWidget.widgetID : id
        guard let w = widgets.toolWidgets.first(where: { $0.id == gamesID }) else { return nil }
        if id == PanelTools.chase, let games = w as? GamesWidget { return chase(games) }
        return widgetTool(w)
    }

    /// Every tool id (`PanelRoute.legacy`), without building any view.
    static func ids(widgets: WidgetRegistry, extraTabs: [PanelTab]) -> Set<String> {
        var ids: Set<String> = [PanelTools.memory]
        for w in widgets.toolWidgets {
            ids.insert(w.id)
            if w.id == GamesWidget.widgetID { ids.insert(PanelTools.chase) }
        }
        for tab in extraTabs { ids.insert(PanelTools.plugin(tab.id)) }
        return ids
    }

    private static func widgetTool(_ w: any NotchWidget) -> PanelTool {
        PanelTool(id: w.id, title: w.title, systemImage: w.systemImage, view: { [weak w] in
            w?.toolView() ?? AnyView(EmptyView())
        })
    }

    private static func memoryTool(_ memory: @escaping () -> AnyView) -> PanelTool {
        PanelTool(id: PanelTools.memory, title: "Memory", systemImage: "brain", view: memory)
    }

    private static func pluginTool(_ tab: PanelTab) -> PanelTool {
        PanelTool(id: PanelTools.plugin(tab.id), title: tab.title, systemImage: tab.systemImage,
                  view: { pluginView(tab) })
    }

    /// A plugin tab full-panel: centred in the room while it is shorter.
    static func pluginView(_ tab: PanelTab) -> AnyView {
        AnyView(ToolPage { tab.view })
    }

    /// Platy Chase keeps its own entry: the games tool with Chase picked.
    private static func chase(_ games: GamesWidget) -> PanelTool {
        let host = games.host
        return PanelTool(id: PanelTools.chase, title: "Platy Chase", systemImage: "hare",
                         view: { AnyView(GamesTab(host: host, pick: .chase)) })
    }
}
