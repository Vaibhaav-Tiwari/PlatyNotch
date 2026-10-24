import Foundation
import PlatyNotchKit
import SwiftUI

// The public plugin API. The Pro edition (and later widgets) build on exactly this;
// nothing in PlatyNotchUI may reference Pro.

/// A page in the Settings window. Built-in sections come first; plugins append theirs.
@MainActor
public struct SettingsSection: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let view: AnyView

    public init(id: String, title: String, systemImage: String, view: AnyView) {
        self.id = id; self.title = title; self.systemImage = systemImage; self.view = view
    }

    public init<V: View>(id: String, title: String, systemImage: String, @ViewBuilder content: () -> V) {
        self.init(id: id, title: title, systemImage: systemImage, view: AnyView(content()))
    }
}

/// A tab in the expanded panel. Built-in tabs come first; plugins append theirs.
@MainActor
public struct PanelTab: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let view: AnyView

    public init(id: String, title: String, systemImage: String, view: AnyView) {
        self.id = id; self.title = title; self.systemImage = systemImage; self.view = view
    }

    public init<V: View>(id: String, title: String, systemImage: String, @ViewBuilder content: () -> V) {
        self.init(id: id, title: title, systemImage: systemImage, view: AnyView(content()))
    }
}

/// A plugin hosted by the notch app. Every method but `id` has a default.
@MainActor
public protocol NotchPlugin: AnyObject {
    var id: String { get }
    /// Called once at launch, after the core supervisor and socket client are started.
    func start(context: PluginContext)
    func settingsSections() -> [SettingsSection]
    func panelTabs() -> [PanelTab]
    /// Every `ext.event` from the core (any extension; filter on `event.ext`).
    func handle(event: ExtMessage)
    /// `platynotch://` URLs the core app does not handle, offered to plugins in order.
    /// Return true when handled.
    ///
    /// The URL is attacker-controlled: any web page, document or app can open a
    /// `platynotch://` link without the user meaning to. Treat every part of it as
    /// untrusted input: never run commands, approve or answer anything, change settings,
    /// or send data from a URL alone; at most show UI that asks the user to confirm.
    func handle(url: URL) -> Bool
}

extension NotchPlugin {
    public func start(context: PluginContext) {}
    public func settingsSections() -> [SettingsSection] { [] }
    public func panelTabs() -> [PanelTab] { [] }
    public func handle(event: ExtMessage) {}
    public func handle(url: URL) -> Bool { false }
}

/// What a plugin gets from the app.
@MainActor
public struct PluginContext {
    /// Read-only for plugins (the app feeds it from the core).
    public let store: AppStore
    /// For `send` / `request` only. Its event stream has a single reader (the app) and
    /// is not visible to plugins: use `events` below to receive core events.
    public let client: CoreClient
    /// Read/write `config.json`; writes keep unknown keys and trigger `config.reload`.
    /// Plugins keep their settings under `pro` (`config.update { $0.pro = … }`).
    public let config: ConfigFileStore
    /// Every core event. Subscribe here; never read `client.events` (single consumer).
    public let events: CoreEventHub
    let runner: CoreRunner
    let widgets: WidgetRegistry
    let openSettingsHandler: (String?) -> Void

    init(store: AppStore, client: CoreClient, config: ConfigFileStore, events: CoreEventHub,
         runner: CoreRunner, widgets: WidgetRegistry, openSettings: @escaping (String?) -> Void) {
        self.store = store; self.client = client; self.config = config; self.events = events
        self.runner = runner; self.widgets = widgets; self.openSettingsHandler = openSettings
    }

    /// Adds a widget (Today tile, pill activity, Settings › Widgets entry). Call from
    /// `start(context:)`. A new id is on only when `defaultEnabled`; the user can turn it
    /// off and reorder it, and a disabled widget is never started.
    public func register(widget: any NotchWidget) { widgets.register(widget) }

    /// Runs the bundled core binary (`notch <args>`) and returns its exit status and
    /// combined stdout + stderr. Cancelling the calling task does not stop the command: it
    /// runs to completion or for at most 60 s. Incomplete output counts as a failure
    /// (non-zero status, with a note in the output).
    public func runCore(_ args: [String]) async -> (status: Int32, output: String) {
        let r = await runner.run(args)
        return (r.status, r.combined)
    }

    /// Opens Settings, at a section id when given (built-in or a plugin's own).
    public func openSettings(section: String? = nil) { openSettingsHandler(section) }
}

/// Runs `notch` subcommands (hooks, statusline, mcp, doctor) for Settings and plugins:
/// a `ProcessRunner` for the bundled core binary.
///
/// Cancelling the calling task does not stop the command (a view's `.task` ending must
/// not kill `hooks install` half way): it runs to completion or to `timeout`.
/// Incomplete output (`truncated`, a process the command started kept its output open)
/// is an error: status `truncatedStatus` when the command itself exited 0.
struct CoreRunner: Sendable {
    typealias Result = ProcessRunner.Result

    static let maxOutput = ProcessRunner.maxOutput
    /// EX_IOERR.
    static let truncatedStatus: Int32 = 74

    let binaryURL: URL

    func run(_ args: [String], timeout: Duration = .seconds(60)) async -> Result {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            return Result(status: 127, stdout: "", stderr: "notch not found at \(binaryURL.path)")
        }
        var r = await ProcessRunner(executableURL: binaryURL, stopsOnCancel: false).run(args, timeout: timeout)
        if r.truncated {
            if r.status == 0 { r.status = Self.truncatedStatus }
            let note = "notch output incomplete: a process it started kept the output open"
            r.stderr = r.stderr.isEmpty ? note : r.stderr + "\n" + note
        }
        return r
    }
}
