import AppKit
import PlatyNotchKit
import SwiftUI

/// Settings and first-run renders: each page in the real Settings window layout (sidebar
/// and detail) at the window's size, drawn in an off-screen borderless window. Inert
/// services (a config file that does not exist, a registry that never saves); pages read
/// the user's saved settings but write nothing (they save only on a change).
@MainActor
enum SettingsRenders {
    /// (file name, the window's root view, its size)
    static func windows() -> [(String, AnyView, CGSize)] {
        var out: [(String, AnyView, CGSize)] = []
        let size = CGSize(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height)
        for (id, detail) in pages {
            let services = makeServices()
            let model = SettingsModel()
            model.selection = id
            model.detail = detail
            let root = SettingsRootView(model: model, services: services, pluginSections: [])
            let name = "settings-" + id + (detail.map { "-" + $0.lowercased() } ?? "")
            out.append((name, AnyView(root), size))
        }
        return out
    }

    /// Every page, and the sub-pages worth seeing.
    static var pages: [(String, String?)] {
        SettingsModel.builtIn.map { ($0.id, nil) } + [("agents", "approvals"), ("agents", "policy")]
    }

    static func makeServices() -> SettingsServices {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pn-render-settings")
        let defaults = UserDefaults(suiteName: "dev.platynotch.render-settings") ?? .standard
        defaults.removePersistentDomain(forName: "dev.platynotch.render-settings")
        let registry = WidgetRegistry(defaults: defaults, persist: false)
        let store = AppStore()
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, nowPlaying: NowPlaying(),
                                  visualiser: MusicVisualiser(defaults: defaults),
                                  calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults),
                                  focus: FocusModel(defaults: defaults))
        BuiltInWidgets.register(in: registry, store: store, today: today, persist: false)
        return SettingsServices(config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                runner: CoreRunner(binaryURL: dir.appendingPathComponent("notch")),
                                store: store, capture: nil, calendar: today.calendar, reminders: today.reminders,
                                widgets: registry, updater: AppUpdater(start: false, enabled: false))
    }

    /// `view` filling a borderless window of `size` at (-10000, 10000), drawn after the run
    /// loop settles, in `scheme`'s appearance.
    static func render(_ view: AnyView, size: CGSize, scheme: ColorScheme, settle: TimeInterval = 0.3) -> Data? {
        let appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        host.display()
        guard host.bounds.width > 0, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
