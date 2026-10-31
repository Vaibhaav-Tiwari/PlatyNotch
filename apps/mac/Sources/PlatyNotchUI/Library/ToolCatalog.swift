import PlatyNotchKit
import SwiftUI

/// One feature that opens inside the panel (spec 2.4): its name, symbol and full-panel view.
@MainActor
struct PanelTool {
    let id: String
    let title: String
    let systemImage: String
    let view: () -> AnyView
    /// A dock tool whose widget is off: its view is "Turn on <title>", which enables this widget.
    var offWidgetID: String?
    /// Controls in the header before the panel's own (the Timer tool's mode chips).
    var accessory: (() -> AnyView)?
    /// The panel hugs the tool's card (Timer, "Turn on") instead of taking the full height.
    var fitsContent = false
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
                     memory: @escaping () -> AnyView, fixedNow: Date? = nil) -> PanelTool? {
        if id == PanelTools.memory { return memoryTool(memory) }
        if id == PanelTools.timer || id == PanelTools.timerFocus { return timerTool(id, widgets: widgets, fixedNow: fixedNow) }
        if let off = offDockTool(id, widgets: widgets) { return off }
        if let tab = extraTabs.first(where: { PanelTools.plugin($0.id) == id }) { return pluginTool(tab) }
        let gamesID: String = id == PanelTools.chase ? GamesWidget.widgetID : id
        guard let w = widgets.toolWidgets.first(where: { $0.id == gamesID }) else { return nil }
        if id == PanelTools.chase, let games = w as? GamesWidget { return chase(games) }
        return widgetTool(w)
    }

    /// Every tool id (`PanelRoute.legacy`), without building any view.
    static func ids(widgets: WidgetRegistry, extraTabs: [PanelTab]) -> Set<String> {
        // The dock's tools always resolve (an off one to "Turn on"), and the search.
        var ids: Set<String> = Set(DockTool.allCases.map(\.toolID))
        ids.insert(PanelTools.timerFocus)
        for w in widgets.toolWidgets {
            ids.insert(w.id)
            if w.id == GamesWidget.widgetID { ids.insert(PanelTools.chase) }
        }
        for tab in extraTabs { ids.insert(PanelTools.plugin(tab.id)) }
        return ids
    }

    private static func widgetTool(_ w: any NotchWidget) -> PanelTool {
        PanelTool(id: w.id, title: dockTitle(w.id) ?? w.title, systemImage: w.systemImage, view: { [weak w] in
            w?.toolView() ?? AnyView(EmptyView())
        })
    }

    /// A dock tool's own name in its header ("Note", "Remind").
    static func dockTitle(_ id: String) -> String? {
        DockTool.allCases.first { $0.toolID == id }?.title
    }

    /// The dock tool `id` while its widget is registered but off: "Turn on <title>".
    static func offDockTool(_ id: String, widgets: WidgetRegistry) -> PanelTool? {
        guard let t = DockTool.allCases.first(where: { $0.toolID == id }), !t.widgetIDs.isEmpty,
              !t.widgetIDs.contains(where: { widgets.isEnabled($0) }),
              let widgetID = t.widgetIDs.first(where: { widgets.widget($0) != nil }) else { return nil }
        return PanelTool(id: id, title: t.title, systemImage: t.symbol, view: { [weak widgets] in
            AnyView(ToolOffView(title: t.title, onTurnOn: { widgets?.setEnabled(widgetID, true) }))
        }, offWidgetID: widgetID, fitsContent: true)
    }

    /// "Turn on" for an off dock tool.
    static func turnOn(_ tool: PanelTool, widgets: WidgetRegistry) {
        guard let id = tool.offWidgetID else { return }
        widgets.setEnabled(id, true)
    }

    /// The Timer tool (Timer, Focus, Stopwatch) while Time or Focus is on; `timer.focus`
    /// opens it in Focus.
    static func timerTool(_ id: String, widgets: WidgetRegistry, fixedNow: Date? = nil) -> PanelTool? {
        if let off = offDockTool(PanelTools.timer, widgets: widgets) { return off }
        let time = widgets.isEnabled(TimeWidget.widgetID) ? widgets.widget(TimeWidget.widgetID) as? TimeWidget : nil
        let focus = widgets.isEnabled(FocusWidget.widgetID) ? (widgets.widget(FocusWidget.widgetID) as? FocusWidget)?.focus : nil
        guard time != nil || focus != nil else { return nil }
        let initial: TimerMode? = id == PanelTools.timerFocus ? .focus : nil
        return PanelTool(id: id, title: DockTool.timer.title, systemImage: DockTool.timer.symbol, view: {
            AnyView(TimerTool(time: time, focus: focus, initial: initial, fixedNow: fixedNow))
        }, accessory: { AnyView(TimerModeChips()) }, fitsContent: true)
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
