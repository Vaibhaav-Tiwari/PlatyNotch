import AppKit
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
    /// False for a widget with nothing to show in the Today tab (a headless power
    /// feature): the tab skips it and `tileView()` is never laid out. Default true.
    var hasTile: Bool { get }
    /// Where Settings › Widgets lists it (power features under their own heading).
    /// Default `.everyday`.
    var category: WidgetCategory { get }
    /// What is live right now; empty when nothing is.
    var liveActivities: [LiveActivity] { get }
    func start(context: WidgetContext)
    func stop()
    /// The user turned the widget off (after `stop`). Undo work that outlives the process,
    /// e.g. scheduled system notifications. Not called when the app quits (`stop` alone).
    func disabled()
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
    /// Takes drops on the drop zone (the shelf). The panel forwards drags to it only while
    /// the drop zone shows.
    func dropTarget() -> PanelDropTarget?
}

extension NotchWidget {
    public var hasTile: Bool { true }
    public var category: WidgetCategory { .everyday }
    public var liveActivities: [LiveActivity] { [] }
    public func start(context: WidgetContext) {}
    public func stop() {}
    public func disabled() {}
    public func settingsView() -> AnyView? { nil }
    public func peekView(id: String) -> AnyView? { nil }
    public func hudView(kind: HUDKind, level: Double) -> AnyView? { nil }
    public func dropZoneView() -> AnyView? { nil }
    public func dropTarget() -> PanelDropTarget? { nil }
}

/// Receives the drags a display's panel gets while it shows the drop zone. The panel's
/// view is registered for `PanelDrop.types` when it is created, so the first drag-enter
/// after the window starts taking mouse events is never missed.
@MainActor
public protocol PanelDropTarget: AnyObject {
    /// Entered or moved over the drop zone: the operation offered (`[]` refuses).
    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation
    func dragExited()
    func performDrop(_ info: NSDraggingInfo) -> Bool
    /// The drag ended (dropped or not).
    func dragEnded()
}

public enum PanelDrop {
    /// What the panel accepts drags of: files, file promises (Photos, Mail), URLs,
    /// images and text.
    public static let types: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .png, .tiff]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
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

    /// Read-only panel state (whether a full-screen app covers a panel's display).
    public var panel: PanelContextProvider { surfaces }

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
    /// Shows over full screen. Under a pending approval or the open panel it is a ringing
    /// chip ("Stop") in the header instead; the menu bar shows "Stop <title>" meanwhile.
    @discardableResult
    public func ring(id: String, title: String) -> Bool { surfaces.ring(id: id, title: title) }

    public func stopRinging(id: String) { surfaces.stopRinging(id: id) }

    /// What is ringing (games pause while non-empty).
    public var ringing: [String] { surfaces.ringing }

    /// A level HUD for `PanelSurfaces.hudDuration` on `display` (default: the display
    /// under the cursor, else the main one). False when that display's panel does not
    /// show it (full screen, a ringing card, no panel there): let the system HUD show then.
    @discardableResult
    public func showHUD(kind: HUDKind, level: Double, display: CGDirectDisplayID? = nil) -> Bool {
        surfaces.showHUD(kind: kind, level: level, display: display)
    }

    /// The drag detector reports a drag session (Task 5): while active, a panel opens its
    /// drop zone when the cursor comes within `PanelLayout.dragReach` of its notch.
    /// Also true while a panel itself receives a drag the detector missed.
    public func dragSession(active: Bool) { surfaces.setDragSession(active: active) }
}
