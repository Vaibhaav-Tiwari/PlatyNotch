import Foundation
import PlatyNotchKit
import SwiftUI

/// A feature of the notch: a tile in the Today tab, optional live activities for the
/// compact pill, and an optional settings view. Built-ins and plugins
/// (`PluginContext.register(widget:)`) use the same API.
///
/// Implementations are usually `@Observable`, so the pill and tiles follow
/// `liveActivities` and the tile's state. A widget does no work until `start` and stops
/// all of it (timers, polls, taps, processes) in `stop`: the registry never starts a
/// disabled widget and stops one when the user turns it off.
@MainActor
public protocol NotchWidget: AnyObject {
    /// Stable and unique, e.g. "music" (plugins: prefix with the plugin id).
    var id: String { get }
    var title: String { get }
    var systemImage: String { get }
    /// Whether a newly seen widget starts enabled. Widgets that use the network, read
    /// private data or need a permission default to false.
    var defaultEnabled: Bool { get }
    /// What is live right now; empty when nothing is.
    var liveActivities: [LiveActivity] { get }
    func start(context: WidgetContext)
    func stop()
    func tileView() -> AnyView
    /// Shown in Settings › Widgets under the widget's name while it is enabled.
    func settingsView() -> AnyView?
    /// The content of a peek or ringing card this widget asked for with
    /// `WidgetContext.peek(id:until:)` / `ring(id:)`; nil for ids that are not its own.
    /// Drawn below the notch at `PanelLayout.widgetPeekHeight` / `ringingHeight`. Buttons
    /// work with a click; the panel never takes keyboard focus for it.
    func peekView(id: String) -> AnyView?
    /// The HUD for `kind` at `level` (0…1); nil draws the built-in level bar.
    func hudView(kind: HUDKind, level: Double) -> AnyView?
    /// The drop zone shown while a drag is near the notch (the shelf, Task 5); expanded size.
    func dropZoneView() -> AnyView?
}

extension NotchWidget {
    public var liveActivities: [LiveActivity] { [] }
    public func start(context: WidgetContext) {}
    public func stop() {}
    public func settingsView() -> AnyView? { nil }
    public func peekView(id: String) -> AnyView? { nil }
    public func hudView(kind: HUDKind, level: Double) -> AnyView? { nil }
    public func dropZoneView() -> AnyView? { nil }
}

/// What a widget gets from the app when it starts.
@MainActor
public struct WidgetContext {
    /// Read-only (the app feeds it from the core).
    public let store: AppStore
    /// For `send` / `request`; never read `client.events` (use `events`).
    public let client: CoreClient
    /// `config.json` (e.g. `memory.exclude_apps`); writes keep unknown keys.
    public let config: ConfigFileStore
    /// Every core event.
    public let events: CoreEventHub
    /// Small widget state: the app's own domain (`UserDefaults.standard`).
    public let defaults: UserDefaults
    /// System notifications (a no-op when the app is not bundled).
    public let notify: Notifier
    /// Peeks, ringing, HUDs and the drag session, shown on every display's panel.
    public let surfaces: PanelSurfaces
    private let openPanelHandler: (String?) -> Void

    public init(store: AppStore, client: CoreClient, config: ConfigFileStore, events: CoreEventHub,
                defaults: UserDefaults = .standard, notify: Notifier, surfaces: PanelSurfaces? = nil,
                openPanel: @escaping (String?) -> Void) {
        self.store = store
        self.client = client
        self.config = config
        self.events = events
        self.defaults = defaults
        self.notify = notify
        self.surfaces = surfaces ?? PanelSurfaces()
        self.openPanelHandler = openPanel
    }

    /// Expands the panel on the main display, at a tab id when given (e.g. "today").
    public func openPanel(tab: String? = nil) { openPanelHandler(tab) }

    // MARK: - Transient surfaces (precedence: PanelPrecedence in PlatyNotchKit)

    /// Peeks the widget's `peekView(id:)` below the notch until `until` (e.g. a nudge for
    /// 10 s). A pending approval, a ringing card, the open panel, a HUD or an agent notice
    /// shows first; over full screen the peek waits. Returns false (nothing shown) when no
    /// running widget supplies a view for `id`.
    @discardableResult
    public func peek(id: String, until: Date) -> Bool { surfaces.peek(id: id, until: until) }

    /// Closes the peek early (e.g. after "+1 glass").
    public func endPeek(id: String) { surfaces.endPeek(id: id) }

    /// A ringing alarm or timer: `peekView(id:)` at ringing height until `stopRinging(id:)`.
    /// Shows over full screen and over the open panel; only a pending approval goes first.
    @discardableResult
    public func ring(id: String) -> Bool { surfaces.ring(id: id) }

    public func stopRinging(id: String) { surfaces.stopRinging(id: id) }

    /// What is ringing (games pause while non-empty).
    public var ringing: [String] { surfaces.ringing }

    /// A level HUD for `PanelSurfaces.hudDuration`. False when no panel shows it (full
    /// screen, a ringing card): let the system HUD show then.
    @discardableResult
    public func showHUD(kind: HUDKind, level: Double) -> Bool { surfaces.showHUD(kind: kind, level: level) }

    /// The drag detector reports a drag session (Task 5): while active, a panel opens its
    /// drop zone when the cursor comes within `PanelLayout.dragReach` of its notch.
    public func dragSession(active: Bool) { surfaces.setDragSession(active: active) }
}
