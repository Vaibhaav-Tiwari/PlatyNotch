import Foundation
import Observation
import os
import PlatyNotchKit
import SwiftUI

/// Every widget (built-in and plugin), the user's order and on/off choices, and which
/// widgets are running. One instance, shared by every display's panel and Settings.
///
/// A disabled widget does no work: `start` is never called for it, and turning a running
/// widget off calls `stop`. Nothing starts before the app calls `start(context:)`.
@MainActor @Observable
public final class WidgetRegistry {
    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "widgets")

    /// In registration order.
    public private(set) var widgets: [any NotchWidget] = []
    public private(set) var layout: WidgetLayout
    /// Ids of widgets whose `start` ran and whose `stop` has not.
    public private(set) var running: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private var context: WidgetContext?
    /// Peek views of the app itself (the URL routes' confirm card and notices), asked
    /// after every running widget. Set by the app; nil in tests.
    @ObservationIgnored var appPeeks: (@MainActor (String) -> AnyView?)?
    /// Opens Settings at a route such as "widgets/<id>" (a widget's "Set up"). Set by the app.
    @ObservationIgnored public var openSettingsHandler: (@MainActor (String) -> Void)?

    /// `persist: false` reads the saved layout but never writes it (smoke runs).
    public init(defaults: UserDefaults = .standard, persist: Bool = true) {
        self.defaults = defaults
        self.persist = persist
        layout = WidgetLayout.decode(defaults.data(forKey: WidgetLayout.key)) ?? WidgetLayout()
    }

    /// Adds a widget. A new id is enabled only when `defaultEnabled`; a duplicate id is
    /// ignored. After `start(context:)`, an enabled widget starts at once.
    public func register(_ widget: any NotchWidget) {
        guard !widgets.contains(where: { $0.id == widget.id }) else {
            Self.log.error("widget id \(widget.id, privacy: .public) registered twice; keeping the first")
            return
        }
        widgets.append(widget)
        update { $0.adopt(id: widget.id, defaultEnabled: widget.defaultEnabled) }
        if context != nil, isEnabled(widget.id) { start(widget) }
    }

    /// Starts every enabled widget (once, at launch).
    public func start(context: WidgetContext) {
        self.context = context
        for w in widgets where isEnabled(w.id) { start(w) }
    }

    /// Stops every running widget (app quit).
    public func stopAll() {
        for w in widgets where running.contains(w.id) { stop(w) }
    }

    public func isEnabled(_ id: String) -> Bool { layout.enabled.contains(id) }

    public func widget(_ id: String) -> (any NotchWidget)? { widgets.first { $0.id == id } }

    /// Turns a widget on (starts it) or off (stops it, then `disabled()`).
    public func setEnabled(_ id: String, _ on: Bool) {
        guard isEnabled(id) != on else { return }
        update { $0.setEnabled(id, on) }
        guard let w = widget(id) else { return }
        if on, context != nil { start(w) }
        if !on {
            if running.contains(id) { stop(w) }
            w.disabled()
        }
    }

    public func move(_ id: String, to index: Int) {
        update { $0.move(id, to: index) }
    }

    /// Sets the order of the listed ids (Settings' list); others keep their place after them.
    public func reorder(_ ids: [String]) {
        update { $0.reorder(ids) }
    }

    /// Enabled widgets in the user's order (the Today tab's tiles).
    public var visibleWidgets: [any NotchWidget] {
        layout.visible(available: widgets.map(\.id)).compactMap { widget($0) }
    }

    /// The Today tab's tiles: enabled widgets that have one (`hasTile`), in the user's order.
    public var tileWidgets: [any NotchWidget] {
        visibleWidgets.filter(\.hasTile)
    }

    /// Every widget of `category` in the user's order, enabled or not (one group of
    /// Settings › Widgets).
    public func orderedWidgets(in category: WidgetCategory) -> [any NotchWidget] {
        orderedWidgets.filter { $0.category == category }
    }

    /// Sets the order of one Settings group (`ids`: that group's ids). The stored order
    /// becomes every group in `WidgetCategory.allCases` order, so a row never moves into
    /// another group; ids of widgets that are not loaded keep their place after them.
    public func reorder(_ ids: [String], in category: WidgetCategory) {
        let current = orderedWidgets.map(\.id)
        reorder(WidgetCategory.replacing(category, with: ids, in: current, category: categoryOf))
    }

    /// A loaded widget's category (`.everyday` for an unknown id).
    public func categoryOf(_ id: String) -> WidgetCategory {
        widget(id)?.category ?? .everyday
    }

    /// Every widget in the user's order, enabled or not (Settings › Widgets).
    public var orderedWidgets: [any NotchWidget] {
        let ids = widgets.map(\.id)
        let known = layout.order.filter { ids.contains($0) }
        return (known + ids.filter { !known.contains($0) }).compactMap { widget($0) }
    }

    /// Live activities of running widgets, in the user's order (ties in the arbiter
    /// go to the widget placed first).
    public var liveActivities: [LiveActivity] {
        visibleWidgets.filter { running.contains($0.id) }.flatMap(\.liveActivities)
    }

    // MARK: - Kinds (spec 6.2)

    /// The Library's tools: enabled widgets that are tools, in the user's order.
    public var toolWidgets: [any NotchWidget] {
        visibleWidgets.filter { $0.kind.contains(.tool) }
    }

    /// Glances that can show now: enabled, running, glance widgets with content.
    public var glanceWidgets: [any NotchWidget] {
        visibleWidgets.filter { running.contains($0.id) && $0.kind.contains(.glance) && $0.hasContent }
    }

    /// Every registered glance widget, on or off, in the user's order: Now's default
    /// glance slots (saved once, so turning a widget off never backfills its slot).
    public var registeredGlanceIDs: [String] {
        orderedWidgets.filter { $0.kind.contains(.glance) }.map(\.id)
    }

    /// Every enabled glance widget, in the user's order.
    public var glanceCapableIDs: [String] {
        visibleWidgets.filter { $0.kind.contains(.glance) }.map(\.id)
    }

    /// Running widgets' live activities and the agents item through the one priority model.
    public func rankedLive(agents: AgentsLive?, now: Date) -> [LiveItem] {
        PriorityModel.rank(liveActivities, agents: agents, now: now)
    }

    /// A widget's "Set up": its own action, else its settings page.
    public func runSetup(_ id: String) {
        guard let w = widget(id) else { return }
        switch w.setupAction {
        case .openSettings: openSettingsHandler?("widgets/\(id)")
        case .run(let action): action()
        }
    }

    // MARK: - Surface views (first running widget that supplies one)

    public func peekView(id: String) -> AnyView? {
        runningWidgets.lazy.compactMap { $0.peekView(id: id) }.first ?? appPeeks?(id)
    }

    public func hudView(kind: HUDKind, level: Double) -> AnyView? {
        runningWidgets.lazy.compactMap { $0.hudView(kind: kind, level: level) }.first
    }

    public func dropZoneView() -> AnyView? {
        runningWidgets.lazy.compactMap { $0.dropZoneView() }.first
    }

    public func dropTarget() -> PanelDropTarget? {
        runningWidgets.lazy.compactMap { $0.dropTarget() }.first
    }

    private var runningWidgets: [any NotchWidget] { widgets.filter { running.contains($0.id) } }

    private func start(_ w: any NotchWidget) {
        guard let context, !running.contains(w.id) else { return }
        running.insert(w.id)
        w.start(context: context)
    }

    private func stop(_ w: any NotchWidget) {
        guard running.contains(w.id) else { return }
        running.remove(w.id)
        w.stop()
    }

    private func update(_ change: (inout WidgetLayout) -> Void) {
        var next = layout
        change(&next)
        guard next != layout else { return }
        layout = next
        if persist { defaults.set(next.encoded(), forKey: WidgetLayout.key) }
    }
}
