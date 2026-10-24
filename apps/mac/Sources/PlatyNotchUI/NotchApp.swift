import AppKit
import os
import PlatyNotchKit
import SwiftUI

/// UserDefaults keys for panel settings (Settings › Appearance).
public enum NotchSettings {
    public static let minimal = "appearance.minimal"
    public static let showOnAllDisplays = "appearance.showOnAllDisplays"
    /// "left" or "right" (default): the pill ear that shows live activities.
    public static let liveSide = "appearance.liveSide"
}

/// App entry point.
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
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "app")
    private let coreBinary: String
    private let plugins: [NotchPlugin]
    private let options: LaunchOptions
    private let store = AppStore()
    private let socketPath = CorePaths.socketPath()
    private let client: CoreClient
    /// The single reader of `client.events`; everyone else subscribes here.
    private let events = CoreEventHub()
    private lazy var runner = CoreRunner(binaryURL: CorePaths.coreBinary(name: coreBinary))
    /// `config.json`; writes send `config.reload`.
    private let config: ConfigFileStore
    /// Shared by every display's panel: one answer per approval, "Sending…" everywhere.
    private lazy var responder = ApprovalResponder(client: client)
    /// Now playing, calendar, focus and loop actions, shared by every display.
    /// Smoke runs never create a real audio tap (the visualiser gets one that does nothing).
    private lazy var today = TodayServices(client: client, visualiser: MusicVisualiser(makeTap: { [options] in
        options.smoke || options.smokeSettings ? NoAudioTap() as AudioTapping : SystemAudioTap()
    }))
    /// Built-in and plugin widgets. Smoke runs read the saved layout but never write it.
    private lazy var widgets = WidgetRegistry(persist: !options.smoke && !options.smokeSettings)
    /// Widget peeks, ringing, HUDs and the drag session, shown on every display's panel.
    private lazy var surfaces = PanelSurfaces(registry: widgets)
    /// On-screen text capture (runs only while memory is on) and the Memory tab's search.
    private lazy var capture = CaptureService(client: client)
    private lazy var memory = MemoryServices(client: client, capture: capture)
    /// Sparkle, when this build has an update key; not started during smoke runs.
    private lazy var updater = AppUpdater(start: !options.smoke && !options.smokeSettings)
    private lazy var settingsServices = SettingsServices(config: config, runner: runner, store: store,
                                                         capture: capture, calendar: today.calendar,
                                                         widgets: widgets, updater: updater)
    private lazy var settings = SettingsWindowController(services: settingsServices,
                                                         pluginSections: plugins.flatMap { $0.settingsSections() })
    private lazy var onboarding = OnboardingWindowController(services: settingsServices)
    private var menuBar: MenuBarController?
    private var supervisor: CoreSupervisor?
    private var controllers: [NotchController] = []
    private var pluginTabs: [PanelTab] = []
    private var configWatcher: ConfigFileWatcher?
    private var restartTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var appearance = AppearanceState.current
    private var signalSources: [DispatchSourceSignal] = []
    /// What launch did to `<home>/bin/notch` (reported by smoke runs).
    private var hookLink: HookBinaryLink.Outcome?

    init(coreBinary: String, plugins: [NotchPlugin], options: LaunchOptions) {
        self.coreBinary = coreBinary
        self.plugins = plugins
        self.options = options
        let client = CoreClient(socketPath: socketPath)
        self.client = client
        config = ConfigFileStore(url: CorePaths.config(), reload: Self.reloader(client))
    }

    /// Sends `config.reload` (the core replies with a notice; failures are ignored:
    /// the core reads the file again on its next start).
    private nonisolated static func reloader(_ client: CoreClient) -> @Sendable () async -> Void {
        { _ = try? await client.request(Envelope.make(.configReload), timeout: .seconds(5)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleTerminationSignals()
        TerminalFocus.startTracking()
        repointHookBinary()
        if !options.externalCore {
            // Each launch gets the Keychain secrets config.json refers to, so the core
            // never runs /usr/bin/security (whose access prompt is not ours).
            let configURL = config.url
            let s = CoreSupervisor(binaryURL: runner.binaryURL, logURL: CorePaths.coreLog(), secrets: {
                InheritedSecrets.payload(configURL: configURL, lookup: { Keychain.read(account: $0) })
            })
            s.start()
            supervisor = s
        }
        let store = self.store
        events.subscribe { store.apply($0) }
        events.subscribe { [weak self] event in
            guard let self, let ext = event.extMessage else { return }
            for p in self.plugins { p.handle(event: ext) }
        }
        events.start(client.events)
        Task { await client.start() }

        watchConfig()
        wireSettingsEntryPoints()
        BuiltInWidgets.register(in: widgets, store: store, today: today,
                                persist: !options.smoke && !options.smokeSettings)
        startPlugins()
        startWidgets()

        rebuildControllers()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildControllers() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceMayHaveChanged() }
        }

        menuBar = MenuBarController(capture: capture, updater: updater, surfaces: surfaces,
                                    onOpen: { [weak self] in self?.openPanel(tab: nil) },
                                    onSettings: { [weak self] in self?.openSettings(section: nil) })

        if options.smokeSettings {
            Task { @MainActor [weak self] in await self?.runSettingsSmoke() }
        } else if options.smoke {
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.options.smokeDelay))
                await self.finishSmoke()
            }
        } else if !onboarding.isDone {
            onboarding.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        widgets.stopAll()
        supervisor?.stop()
    }

    /// `platynotch://` URLs: settings, onboarding and open; anything else goes to plugins in order.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch AppURL.route(url) {
            case .settings(let section): openSettings(section: section)
            case .onboarding: onboarding.show()
            case .open: openPanel(tab: nil)
            case .plugin(let u): _ = plugins.first { $0.handle(url: u) }
            case nil: break
            }
        }
    }

    /// Points `<home>/bin/notch` (what agent hooks call) at this bundle's `notch`, so hooks
    /// follow the app when it is moved or updated. Only from an installed .app bundle.
    private func repointHookBinary() {
        let outcome = HookBinaryLink.ensureForApp(bundleURL: Bundle.main.bundleURL)
        hookLink = outcome
        switch outcome {
        case .failed(let reason): Self.log.error("hook binary link: \(reason, privacy: .public)")
        case .created, .repointed: Self.log.notice("hook binary link now points at this app")
        default: break
        }
    }

    // MARK: - Config

    /// One watcher for `config.json` (the Go CLI, Pro or a text editor may change it):
    /// capture follows memory settings, and a memory change restarts the core.
    private func watchConfig() {
        let config = self.config
        capture.apply(CaptureSettings(memory: config.config.memory))
        config.observe { [weak self] old, new in
            guard let self else { return }
            self.capture.apply(CaptureSettings(memory: new.memory))
            if ConfigFile.needsCoreRestart(old: old, new: new) { self.scheduleCoreRestart() }
        }
        configWatcher = ConfigFileWatcher(url: config.url) { config.reloadFromDisk() }
    }

    /// `config.reload` does not reopen memory, so memory changes restart the supervised
    /// core (debounced; an external core only gets the reload). Settings also calls this
    /// after a Keychain key the config already refers to is replaced: the core gets
    /// secrets on stdin only at launch.
    private func scheduleCoreRestart() {
        guard let supervisor else { return }
        restartTask?.cancel()
        restartTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            supervisor.restart()
        }
    }

    // MARK: - Settings, onboarding, plugins

    private func wireSettingsEntryPoints() {
        memory.onOpenSettings = { [weak self] in self?.openSettings(section: "memory") }
        today.calendar.onOpenSettings = { [weak self] in self?.openSettings(section: "permissions") }
        settingsServices.showOnboarding = { [weak self] in self?.onboarding.show() }
        settingsServices.restartCore = { [weak self] in self?.scheduleCoreRestart() }
    }

    private func openSettings(section: String?) {
        settings.show(section: section)
    }

    private func openPanel(tab: String?) {
        let primary = NSScreen.screens.first?.displayID
        (controllers.first { $0.displayID == primary } ?? controllers.first)?.expand(tab: tab)
    }

    private func startPlugins() {
        let context = PluginContext(store: store, client: client, config: config, events: events, runner: runner,
                                    widgets: widgets,
                                    openSettings: { [weak self] in self?.openSettings(section: $0) })
        for p in plugins { p.start(context: context) }
        pluginTabs = plugins.flatMap { $0.panelTabs() }
    }

    /// Starts every enabled widget (built-ins and those plugins registered), so live
    /// activities such as music feed the pill from launch.
    private func startWidgets() {
        let context = WidgetContext(store: store, client: client, config: config, events: events,
                                    defaults: .standard, notify: Notifiers.make(), surfaces: surfaces,
                                    openPanel: { [weak self] in self?.openPanel(tab: $0) })
        widgets.start(context: context)
    }

    // MARK: - Panels

    /// The Appearance settings the panels are built from.
    private struct AppearanceState: Equatable {
        var minimal: Bool
        var allDisplays: Bool
        static var current: AppearanceState {
            AppearanceState(minimal: UserDefaults.standard.bool(forKey: NotchSettings.minimal),
                            allDisplays: UserDefaults.standard.bool(forKey: NotchSettings.showOnAllDisplays))
        }
    }

    private func appearanceMayHaveChanged() {
        let now = AppearanceState.current
        guard now != appearance else { return }
        appearance = now
        rebuildControllers()
    }

    /// SIGTERM / SIGINT (kill, Ctrl-C under `swift run`) quit through `terminate`, so the
    /// supervised core gets its SIGTERM instead of being orphaned.
    private func handleTerminationSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.supervisor?.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// One controller per target screen: the primary (menu bar) display, or all
    /// displays when "Show on all displays" is on.
    /// Panel state carries over per display (falling back to the old primary panel), so a
    /// rebuild neither collapses an open panel nor replays the last notice.
    private func rebuildControllers() {
        appearance = AppearanceState.current
        var carry: [CGDirectDisplayID: PanelCarryOver] = [:]
        for c in controllers {
            if let id = c.displayID { carry[id] = c.carryOver }
            c.detach()
        }
        let fallback = controllers.first?.carryOver
        let screens = appearance.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        controllers = screens.enumerated().map { index, screen in
            let state = screen.displayID.flatMap { carry[$0] } ?? (index == 0 ? fallback : nil)
            let c = NotchController(store: store, client: client, plugins: plugins, responder: responder,
                                    today: today, widgets: widgets, surfaces: surfaces, memory: memory,
                                    extraTabs: pluginTabs,
                                    onOpenTerminal: { TerminalFocus.focus(session: $0) },
                                    minimal: appearance.minimal,
                                    carryOver: state)
            c.attach(to: screen)
            return c
        }
    }

    // MARK: - Smoke checks

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
        let built = buildEnabledWidgets()
        if failure == nil, built.failed.first != nil {
            failure = "widget \(built.failed[0]) did not build"
        }
        // Every transient surface through the real controller (a moment on screen), and
        // the built-in surface views laid out off screen.
        if failure == nil, let c = controllers.first, let problem = c.runSurfaceSmoke() {
            failure = "surfaces: \(problem)"
        }
        if failure == nil { buildSurfaceViews() }
        let sounds = TimeSound.allCases.filter { $0.url != nil }.count
        if failure == nil, sounds != TimeSound.allCases.count {
            failure = "bundled sounds missing (\(UIResources.bundleName))"
        }
        widgets.stopAll()
        await client.stop()
        supervisor?.stop()
        if let failure {
            print("SMOKE FAIL \(failure)")
            fflush(stdout)
            exit(1)
        }
        print("SMOKE OK panels=\(controllers.count) mode=\(mode) menubar=\(menuBar != nil)"
              + " updates=\(updater.isEnabled ? "on" : "off") hooklink=\(Self.describe(hookLink))"
              + " widgets=\(built.count) surfaces=ok sounds=\(sounds)")
        fflush(stdout)
        exit(0)
    }

    /// Lays out every enabled widget's tile and settings view off screen (no window, so
    /// nothing appears and no tile's `.task` runs). Returns how many built and which did not.
    private func buildEnabledWidgets() -> (count: Int, failed: [String]) {
        var count = 0
        var failed: [String] = []
        for w in widgets.visibleWidgets {
            let tile = NSHostingView(rootView: w.tileView().frame(width: 360).environment(\.colorScheme, .dark))
            tile.layoutSubtreeIfNeeded()
            if let settings = w.settingsView() {
                NSHostingView(rootView: settings.frame(width: 480)).layoutSubtreeIfNeeded()
            }
            guard widgets.running.contains(w.id), tile.fittingSize.width > 0 else { failed.append(w.id); continue }
            count += 1
        }
        return (count, failed)
    }

    /// Lays out the built-in HUD, indicator, drop zone and ringing fallback off screen,
    /// and the HUD widget's views (an inert copy: it is off by default, and smoke never taps keys).
    private func buildSurfaceViews() {
        let hud = HUDWidget.inert()
        let views: [AnyView] = HUDKind.allCases.map { AnyView(HUDBar(state: HUDState(kind: $0, level: 0.5, until: Date()))) }
            + HUDKind.allCases.compactMap { hud.hudView(kind: $0, level: 0.5) }
            + [AnyView(HUDView(kind: .volume, level: 0.5, output: "MacBook Pro Speakers")),
               hud.tileView()] + [hud.settingsView()].compactMap { $0 }
            + [AnyView(HUDIndicator(state: HUDState(kind: .volume, level: 0.5, until: Date()))),
               AnyView(DropZonePlaceholder()), AnyView(RingingFallback(id: "smoke", onStop: {})),
               AnyView(ShelfDropZone(shelf: ShelfWidget.inert())),
               AnyView(RingingOverlay(title: "Alarm", subtitle: "Alarm · 7:00", isAlarm: true, onSnooze: {}, onStop: {}))]
        for v in views {
            NSHostingView(rootView: v.frame(width: 380).environment(\.colorScheme, .dark)).layoutSubtreeIfNeeded()
        }
    }

    /// `--smoke-settings`: builds the Settings window (every section) and the onboarding
    /// window (every page) invisibly, checks nothing wrote config.json, and exits.
    private func runSettingsSmoke() async {
        let configURL = config.url
        let before = try? Data(contentsOf: configURL)
        var failure: String?

        settings.showForSmoke()
        var sections = 0
        for id in settings.sectionIDs {
            settings.model.selection = id
            try? await Task.sleep(for: .milliseconds(150))
            guard settings.isVisible, let v = settings.hostingView, v.frame.width > 0 else {
                failure = "settings section \(id) not shown"
                break
            }
            sections += 1
        }
        settings.close()

        var pages = 0
        if failure == nil {
            onboarding.showForSmoke()
            for page in 0..<OnboardingWindowController.pageCount {
                onboarding.model.page = page
                try? await Task.sleep(for: .milliseconds(150))
                guard onboarding.isVisible, let v = onboarding.hostingView, v.frame.width > 0 else {
                    failure = "onboarding page \(page) not shown"
                    break
                }
                pages += 1
            }
            onboarding.close()
        }
        if failure == nil, (try? Data(contentsOf: configURL)) != before {
            failure = "config.json changed while only looking"
        }

        await client.stop()
        supervisor?.stop()
        if let failure {
            print("SMOKE SETTINGS FAIL \(failure)")
            fflush(stdout)
            exit(1)
        }
        print("SMOKE SETTINGS OK sections=\(sections) onboarding=\(pages) menubar=\(menuBar != nil)"
              + " updates=\(updater.isEnabled ? "on" : "off")")
        fflush(stdout)
        exit(0)
    }

    private static func describe(_ outcome: HookBinaryLink.Outcome?) -> String {
        switch outcome {
        case nil: return "none"
        case .created: return "created"
        case .repointed: return "repointed"
        case .unchanged: return "unchanged"
        case .keptRegularFile: return "kept-file"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }
}
