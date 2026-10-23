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
    let openSettingsHandler: (String?) -> Void

    init(store: AppStore, client: CoreClient, config: ConfigFileStore, events: CoreEventHub,
         runner: CoreRunner, openSettings: @escaping (String?) -> Void) {
        self.store = store; self.client = client; self.config = config; self.events = events
        self.runner = runner; self.openSettingsHandler = openSettings
    }

    /// Runs the bundled core binary (`notch <args>`) and returns its exit status and
    /// combined stdout + stderr.
    public func runCore(_ args: [String]) async -> (status: Int32, output: String) {
        let r = await runner.run(args)
        return (r.status, r.combined)
    }

    /// Opens Settings, at a section id when given (built-in or a plugin's own).
    public func openSettings(section: String? = nil) { openSettingsHandler(section) }
}

/// Runs `notch` subcommands (hooks, statusline, mcp, doctor) for Settings and plugins.
struct CoreRunner: Sendable {
    struct Result: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var combined: String {
            [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    static let maxOutput = 1 << 20

    let binaryURL: URL

    func run(_ args: [String], timeout: Duration = .seconds(60)) async -> Result {
        let url = binaryURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return Result(status: 127, stdout: "", stderr: "notch not found at \(url.path)")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = url
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: Result(status: 126, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let pid = p.processIdentifier
                let killer = DispatchWorkItem { if p.isRunning { kill(pid, SIGKILL) } }
                let seconds = Double(timeout.components.seconds)
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: killer)
                // Read both pipes concurrently so neither fills up and blocks the child.
                let group = DispatchGroup()
                nonisolated(unsafe) var errData = Data()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                killer.cancel()
                func text(_ d: Data) -> String { String(decoding: d.prefix(Self.maxOutput), as: UTF8.self) }
                cont.resume(returning: Result(status: p.terminationStatus, stdout: text(outData), stderr: text(errData)))
            }
        }
    }
}
