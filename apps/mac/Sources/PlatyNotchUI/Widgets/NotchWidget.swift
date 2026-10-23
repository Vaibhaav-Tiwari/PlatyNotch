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
}

extension NotchWidget {
    public var liveActivities: [LiveActivity] { [] }
    public func start(context: WidgetContext) {}
    public func stop() {}
    public func settingsView() -> AnyView? { nil }
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
    private let openPanelHandler: (String?) -> Void

    public init(store: AppStore, client: CoreClient, config: ConfigFileStore, events: CoreEventHub,
                defaults: UserDefaults = .standard, notify: Notifier, openPanel: @escaping (String?) -> Void) {
        self.store = store
        self.client = client
        self.config = config
        self.events = events
        self.defaults = defaults
        self.notify = notify
        self.openPanelHandler = openPanel
    }

    /// Expands the panel on the main display, at a tab id when given (e.g. "today").
    public func openPanel(tab: String? = nil) { openPanelHandler(tab) }
}
