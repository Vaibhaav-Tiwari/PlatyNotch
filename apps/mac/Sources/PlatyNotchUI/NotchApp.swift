import AppKit
import PlatyNotchKit

/// UserDefaults keys for panel settings (the Settings window arrives in Plan 3 Task 10).
public enum NotchSettings {
    public static let minimal = "appearance.minimal"
    public static let showOnAllDisplays = "appearance.showOnAllDisplays"
}

/// App entry point. Task 10 adds settings, onboarding and the menu bar item.
public enum NotchApp {
    @MainActor
    public static func run(coreBinary: String = "notch", plugins: [NotchPlugin] = []) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let options = LaunchOptions(arguments: CommandLine.arguments, env: ProcessInfo.processInfo.environment)
        let delegate = AppDelegate(coreBinary: coreBinary, plugins: plugins, options: options)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coreBinary: String
    private let plugins: [NotchPlugin]
    private let options: LaunchOptions
    private let store = AppStore()
    private let socketPath = CorePaths.socketPath()
    private lazy var client = CoreClient(socketPath: socketPath)
    private var supervisor: CoreSupervisor?
    private var controllers: [NotchController] = []
    private var pump: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init(coreBinary: String, plugins: [NotchPlugin], options: LaunchOptions) {
        self.coreBinary = coreBinary
        self.plugins = plugins
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !options.externalCore {
            let s = CoreSupervisor(binaryURL: CorePaths.coreBinary(name: coreBinary), logURL: CorePaths.coreLog())
            s.start()
            supervisor = s
        }
        let client = self.client
        let store = self.store
        pump = Task { @MainActor in
            for await event in client.events { store.apply(event) }
        }
        Task { await client.start() }

        rebuildControllers()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildControllers() }
        }

        if options.smoke {
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.options.smokeDelay))
                await self.finishSmoke()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        supervisor?.stop()
    }

    /// One controller per target screen: the primary (menu bar) display, or all
    /// displays when "Show on all displays" is on.
    private func rebuildControllers() {
        for c in controllers { c.detach() }
        let screens = UserDefaults.standard.bool(forKey: NotchSettings.showOnAllDisplays)
            ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        controllers = screens.map { screen in
            let c = NotchController(store: store, client: client, plugins: plugins)
            c.attach(to: screen)
            return c
        }
    }

    /// `--smoke`: report what started and exit (used by automated checks; no screen needed to read it).
    private func finishSmoke() async {
        var failure: String?
        if controllers.isEmpty {
            failure = "no panels (no screens)"
        } else if !controllers.contains(where: \.isOnScreen) {
            failure = "panel window not on screen"
        } else if store.connection != .connected {
            failure = "core not connected at \(socketPath)"
        }
        let mode = controllers.first.map { $0.mode.description } ?? "none"
        await client.stop()
        supervisor?.stop()
        if let failure {
            print("SMOKE FAIL \(failure)")
            fflush(stdout)
            exit(1)
        }
        print("SMOKE OK panels=\(controllers.count) mode=\(mode)")
        fflush(stdout)
        exit(0)
    }
}
