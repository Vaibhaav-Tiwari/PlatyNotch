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
        let onboarding = CGSize(width: OnboardingWindowController.size.width,
                                height: OnboardingWindowController.size.height)
        for (index, page) in OnboardingFlow.firstRun.pages.enumerated() {
            out.append(("onboarding-\(index + 1)-\(Self.slug(page))", Self.onboarding(page: index), onboarding))
        }
        out.append(("onboarding-4-try-it-done", Self.onboarding(page: 3, tryItDone: true), onboarding))
        out.append(("onboarding-tour-1", Self.onboarding(page: 0, flow: .tour), onboarding))
        return out
    }

    static func slug(_ page: OnboardingFlow.Page) -> String {
        switch page {
        case .meetPlaty: "meet-platy"
        case .pickSetup: "pick-setup"
        case .permissions: "permissions"
        case .tryIt: "try-it"
        }
    }

    /// An onboarding page as its window shows it (inert: it never opens the notch).
    static func onboarding(page: Int, flow: OnboardingFlow = .firstRun, tryItDone: Bool = false) -> AnyView {
        let model = OnboardingWindowController.Model()
        model.inert = true
        model.flow = flow
        model.page = page
        model.visible = false
        model.tryItDone = tryItDone
        let view = OnboardingView(model: model, services: makeServices(), onFinish: {})
            .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
            .tint(SettingsTint.accent)
            .environment(\.panelTicking, false)
        return AnyView(view)
    }

    /// Every page, and the sub-pages worth seeing.
    static var pages: [(String, String?)] {
        SettingsModel.builtIn.map { ($0.id, nil) } + [("agents", "approvals"), ("agents", "policy"), ("widgets", "weather"), ("widgets", "baskets")]
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
        // Drawn as the key window would be: teal controls, not the inactive grey.
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).environment(\.controlActiveState, .key))
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
