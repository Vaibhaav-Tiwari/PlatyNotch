import AppKit
import os
import PlatyNotchKit
import SwiftUI

/// App entry point.
public enum NotchApp {
    @MainActor
    public static func run(coreBinary: String = "notch", plugins: [NotchPlugin] = []) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let options = LaunchOptions(arguments: CommandLine.arguments, env: ProcessInfo.processInfo.environment)
        if let dir = options.renderIconDir { finishRender("RENDER ICON", PlatyRenders.writeIconset(to: url(dir))) }
        if let dir = options.platyGalleryDir { finishRender("PLATY GALLERY", PlatyRenders.writeGallery(to: url(dir))) }
        if options.smokePower { finishPowerSmoke() }
        let delegate = AppDelegate(coreBinary: coreBinary, plugins: plugins, options: options)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    private static func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// `--smoke-power`: every power feature, inert, its views laid out off screen; report and exit.
    @MainActor
    private static func finishPowerSmoke() -> Never {
        switch powerSmoke(BuiltInWidgets.powerWidgets(persist: false)) {
        case .success(let n):
            print("SMOKE-POWER OK widgets=\(n)")
            fflush(stdout)
            exit(0)
        case .failure(let f):
            print("SMOKE-POWER FAIL \(f.message)")
            fflush(stdout)
            exit(1)
        }
    }

    struct PowerSmokeFailure: Error, Equatable {
        let message: String
    }

    /// Checks inert power widgets: each is `.power`, ids are unique, and its views build.
    /// Returns how many were checked.
    @MainActor
    static func powerSmoke(_ list: [any NotchWidget]) -> Result<Int, PowerSmokeFailure> {
        var seen = Set<String>()
        for w in list {
            guard w.category == .power else { return .failure(PowerSmokeFailure(message: "\(w.id) is not a power feature")) }
            guard seen.insert(w.id).inserted else { return .failure(PowerSmokeFailure(message: "\(w.id) listed twice")) }
            guard AppDelegate.buildViews(of: w) else { return .failure(PowerSmokeFailure(message: "widget \(w.id) did not build")) }
        }
        return .success(list.count)
    }

    /// `--render-icon` / `--platy-gallery`: report and exit before anything starts.
    @MainActor
    private static func finishRender(_ label: String, _ result: Result<Int, PlatyRenders.Failure>) -> Never {
        switch result {
        case .success(let n):
            print("\(label) OK files=\(n)")
            fflush(stdout)
            exit(0)
        case .failure(let f):
            print("\(label) FAIL \(f.message)")
            fflush(stdout)
            exit(1)
        }
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
    /// Smoke and perf runs never save the layout (perf-idle forces it through the argument domain).
    private lazy var widgets = WidgetRegistry(persist: !options.smoke && !options.smokeSettings && !options.perfRun)
    /// Clipboard history (off by default). Smoke runs get an inert one: no pasteboard, no
    /// hot key, no events, nothing on disk.
    private lazy var clipboard = options.smoke || options.smokeSettings ? ClipboardWidget.inert() : ClipboardWidget()
    /// Widget peeks, ringing, HUDs and the drag session, shown on every display's panel.
    private lazy var surfaces = PanelSurfaces(registry: widgets)
    /// The one drag monitor (R2), shared by the shelf and later drag features; it writes
    /// the drag session. Installs monitors only while a feature listens; smoke runs get
    /// one that installs nothing.
    private lazy var drags = options.smoke || options.smokeSettings
        ? DragMonitor.inert(surfaces: surfaces)
        : DragMonitor(signals: SystemDragSignals(), surfaces: surfaces)
    /// On-screen text capture (runs only while memory is on) and the Memory tab's search.
    private lazy var capture = CaptureService(client: client)
    private lazy var memory = MemoryServices(client: client, capture: capture)
    /// Sparkle, when this build has an update key; not started during smoke runs.
    private lazy var updater = AppUpdater(start: !options.smoke && !options.smokeSettings)
    private lazy var settingsServices = SettingsServices(config: config, runner: runner, store: store,
                                                         capture: capture, calendar: today.calendar,
                                                         reminders: today.reminders, widgets: widgets, updater: updater)
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
    /// Settings › Appearance; the panels are built from it (`AppearanceStore`, C32).
    private var appearance = AppearanceStore.load(from: .standard)
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
        // Before any widget opens its folder: shelf, clipboard and favicons move to their
        // `.noindex` names (Spotlight). Smoke runs read and write nothing.
        if !options.smoke, !options.smokeSettings { PrivateFolder.migrateToNoIndex(home: CorePaths.home()) }
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
        today.platy.start(store: store)
        Task { await client.start() }

        watchConfig()
        wireSettingsEntryPoints()
        if options.fakeNowPlaying { today.nowPlaying.fakePlaying = true }
        // Smoke runs never script Music or Spotify (an unbundled run's Apple Events would
        // be the terminal's, and could prompt for it).
        if options.smoke || options.smokeSettings { today.nowPlaying.sendsAppleEvents = false }
        BuiltInWidgets.register(in: widgets, store: store, today: today,
                                persist: !options.smoke && !options.smokeSettings, clipboard: clipboard)
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

        menuBar = MenuBarController(capture: capture, updater: updater, surfaces: surfaces, clipboard: clipboard,
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
        capture.revertManualAccessibility(wait: true)
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
            case .shelfAdd, .timerStart, .clipboardOpen: break
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
                                    drags: drags, openPanel: { [weak self] in self?.openPanel(tab: $0) })
        widgets.start(context: context)
        // The shelf's privacy promise holds while it is off: expired copies (7 days) go at
        // launch in one bounded directory pass (no timers, no monitors). Never in smoke runs.
        if !options.smoke, !options.smokeSettings, !widgets.isEnabled(ShelfWidget.widgetID) {
            ShelfStore.expireOnDisk(directory: CorePaths.shelf())
        }
        // The same for clipboard history: past its age or limit, items and images go.
        if !options.smoke, !options.smokeSettings, !widgets.isEnabled(ClipboardWidget.widgetID) {
            ClipboardWidget.expireWhileOff()
        }
    }

    // MARK: - Panels

    /// Settings › Appearance changed (any UserDefaults write lands here): new displays or
    /// pill width rebuild the panels; everything else is applied to them live.
    private func appearanceMayHaveChanged() {
        let now = AppearanceStore.load(from: .standard)
        guard now != appearance else { return }
        let rebuild = now.needsRebuild(from: appearance)
        appearance = now
        if rebuild {
            rebuildControllers()
        } else {
            for c in controllers { c.appearance = now }
        }
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

    /// One controller per target screen: Appearance › Displays (the menu-bar display, all,
    /// or those with a notch). HUDs go to the display under the cursor; one without a
    /// panel lets the system HUD show (`PanelSurfaces.showHUD`).
    /// Panel state carries over per display (falling back to the old primary panel), so a
    /// rebuild neither collapses an open panel nor replays the last notice.
    private func rebuildControllers() {
        appearance = AppearanceStore.load(from: .standard)
        var carry: [CGDirectDisplayID: PanelCarryOver] = [:]
        for c in controllers {
            if let id = c.displayID { carry[id] = c.carryOver }
            c.detach()
        }
        let fallback = controllers.first?.carryOver
        let all = NSScreen.screens
        let screens = appearance.displays.select(hasNotch: all.map(\.hasNotch)).map { all[$0] }
        controllers = screens.enumerated().map { index, screen in
            let state = screen.displayID.flatMap { carry[$0] } ?? (index == 0 ? fallback : nil)
            let c = NotchController(store: store, client: client, plugins: plugins, responder: responder,
                                    today: today, widgets: widgets, surfaces: surfaces, memory: memory,
                                    extraTabs: pluginTabs,
                                    onOpenTerminal: { TerminalFocus.focus(session: $0) },
                                    appearance: appearance,
                                    carryOver: state)
            c.onOpenSettings = { [weak self] in self?.openSettings(section: nil) }
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
        if failure == nil, let problem = Self.checkGameViews() { failure = "games: \(problem)" }
        var renders = ""
        if failure == nil, let dir = options.renderDir {
            switch ThemeRenders.write(to: URL(fileURLWithPath: dir, isDirectory: true)) {
            case .success(let n): renders = " renders=\(n) theme=\(appearance.theme.rawValue)"
            case .failure(let e): failure = "renders: \(e.message)"
            }
        }
        if failure == nil, let menuBar,
           !menuBar.menuTitles.contains("Pause clipboard history") || menuBar.menuAutoenables {
            failure = "menu bar clipboard item missing or menu autoenables"
        }
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
              + " widgets=\(built.count) surfaces=ok sounds=\(sounds) games=\(GameKind.allCases.count)" + renders)
        fflush(stdout)
        exit(0)
    }

    /// Lays out every enabled widget's tile and settings view off screen (no window, so
    /// nothing appears and no tile's `.task` runs). Returns how many built and which did not.
    private func buildEnabledWidgets() -> (count: Int, failed: [String]) {
        var count = 0
        var failed: [String] = []
        for w in widgets.visibleWidgets {
            let built = Self.buildViews(of: w)
            guard widgets.running.contains(w.id), built else { failed.append(w.id); continue }
            count += 1
        }
        return (count, failed)
    }

    /// Lays out `w`'s settings view and, when it has one (`hasTile`), its tile off
    /// screen. False when the tile lays out with no width.
    static func buildViews(of w: any NotchWidget) -> Bool {
        if let settings = w.settingsView() {
            NSHostingView(rootView: settings.frame(width: 480)).layoutSubtreeIfNeeded()
        }
        guard w.hasTile else { return true }
        let tile = NSHostingView(rootView: w.tileView().frame(width: 360).environment(\.colorScheme, .dark))
        tile.layoutSubtreeIfNeeded()
        return tile.fittingSize.width > 0
    }

    /// Lays out the built-in HUD, indicator, drop zone and ringing fallback off screen,
    /// and the HUD widget's views (an inert copy: it is off by default, and smoke never taps keys).
    private func buildSurfaceViews() {
        let hud = HUDWidget.inert()
        // Built up statement by statement: one long `+` chain of arrays was too slow for
        // Xcode 26.3's type checker (CI failed with "unable to type-check in reasonable time").
        var views: [AnyView] = []
        views += HUDKind.allCases.map { AnyView(HUDBar(state: HUDState(kind: $0, level: 0.5, until: Date()))) }
        views += HUDKind.allCases.compactMap { hud.hudView(kind: $0, level: 0.5) }
        views.append(AnyView(HUDView(kind: .volume, level: 0.5, output: "MacBook Pro Speakers")))
        views.append(hud.tileView())
        if let settings = hud.settingsView() { views.append(settings) }
        views.append(AnyView(HUDIndicator(state: HUDState(kind: .volume, level: 0.5, until: Date()))))
        views.append(AnyView(DropZonePlaceholder()))
        views.append(AnyView(RingingFallback(id: "smoke", onStop: {})))
        views.append(AnyView(ShelfDropZone(shelf: ShelfWidget.inert())))
        views.append(AnyView(ClipCopiedPeek()))
        views.append(AnyView(ClipboardTile(widget: ClipboardWidget.inert())))
        views.append(AnyView(ClipboardSettings(widget: ClipboardWidget.inert())))
        views.append(AnyView(ClipPickerView(model: ClipPickerModel(widget: clipboard), onChoose: { _ in },
                                            trusted: { false }, imageURL: { _ in nil })))
        views.append(AnyView(RingingOverlay(title: "Alarm", subtitle: "Alarm · 7:00", isAlarm: true,
                                            onSnooze: {}, onStop: {})))
        views += Self.dayViews()
        views += Self.wellbeingViews()
        views += Self.systemViews()
        views += Self.launchViews()
        views += PlatyMood.allCases.map { AnyView(PlatyView(mood: $0, size: PlatyEarFit.platy)) }
        for v in views {
            NSHostingView(rootView: v.frame(width: 380).environment(\.colorScheme, .dark)).layoutSubtreeIfNeeded()
        }
    }

    /// Task 7's views with inert models (no EventKit, no network): the meeting tile, peek
    /// and settings, the Reminders tile and settings, the weather tile and settings.
    private static func dayViews() -> [AnyView] {
        let calendar = CalendarService(eventKit: false)
        let meeting = MeetingWidget(calendar: calendar)
        let start = Date().addingTimeInterval(5 * 60)
        let sample = CalendarMeeting(id: "smoke", title: "Standup", start: start, end: start.addingTimeInterval(1800),
                                     joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let reminders = RemindersWidget.inert()
        let weather = WeatherWidget.inert()
        return [meeting.tileView(), meeting.settingsView(),
                AnyView(MeetingReminderPeek(reminder: .init(meeting: sample, minutes: 5), join: {})),
                AnyView(CountdownRing(start: start, now: Date())),
                reminders.tileView(), reminders.settingsView(), weather.tileView(), weather.settingsView()]
            .compactMap { $0 }
    }

    /// Task 8's views with an inert widget (no idle reads, nothing saved): the tile, the
    /// settings and the card for each nudge.
    private static func wellbeingViews() -> [AnyView] {
        let w = WellbeingWidget.inert()
        let now = Date()
        let cards = NudgeKind.allCases.map { AnyView(NudgeCard(widget: w, nudge: .init(kind: $0, shownAt: now, until: now))) }
        return [w.tileView(), w.settingsView()].compactMap { $0 } + cards
    }

    /// Task 9's views with an inert widget (no IOKit, no assertion, nothing saved): the
    /// tile and settings, a battery row, the plug-in / unplug peeks and the headphones
    /// peek, row and settings, the downloads settings, notice and row with sample states
    /// (no Bluetooth, no FSEvents, no file touched).
    private static func systemViews() -> [AnyView] {
        let w = SystemWidget.inert()
        let charging = BatteryState(percent: 72, charging: true, pluggedIn: true, minutesRemaining: 48)
        let low = BatteryState(percent: 8, charging: false, pluggedIn: false, minutesRemaining: 12)
        let airPods = HeadphonesInfo(id: "smoke", name: "AirPods Pro", battery: .init(left: 80, right: 75, case: 40))
        let file = URL(fileURLWithPath: "/nonexistent/Quarterly report.pdf")
        return [w.tileView(), w.settingsView(), AnyView(BatteryRow(state: low)),
                AnyView(PowerPeekView(peek: .init(change: .pluggedIn, state: charging))),
                AnyView(PowerPeekView(peek: .init(change: .unplugged, state: low))),
                AnyView(HeadphonesPeekView(info: airPods)), AnyView(HeadphonesRow(info: airPods)),
                AnyView(HeadphonesPeekView(info: .init(id: "smoke2", name: "Headphones", battery: .init()))),
                AnyView(HeadphonesSettings(widget: w)), AnyView(DownloadsSettings(widget: w)),
                AnyView(DownloadPeekView(widget: w, url: file)), AnyView(FinishedDownloadRow(widget: w, url: file))]
            .compactMap { $0 }
    }

    /// Task 11's views with an inert widget holding sample pins in memory (no icon fetch,
    /// no Shortcuts, no Apple Events): the tile, the settings, the result peek and a letter icon.
    private static func launchViews() -> [AnyView] {
        let w = LaunchWidget.inert(sample: true)
        let done = LaunchNotice(text: "“Log water” done", isError: false)
        let failed = LaunchNotice(text: "“Log water” failed (exit 1)", isError: true)
        return [w.tileView(), w.settingsView(), AnyView(LaunchResultPeek(notice: done)),
                AnyView(LaunchResultPeek(notice: failed)), AnyView(SiteIcon(image: nil, letter: "E", size: 26))]
            .compactMap { $0 }
    }

    /// Task 10's views with an inert widget (no scores saved, no frames: nothing plays):
    /// the tile, the settings, the Games tab on every game, and each board. The tab must
    /// lay out within `GameLayout.tabSize` (explicit frames; no ideal size may grow it).
    /// Returns the first problem, nil when all fit.
    static func checkGameViews() -> String? {
        let w = GamesWidget.inert()
        let tab = GameLayout.tabSize
        let small: [AnyView] = [w.tileView(), w.settingsView()].compactMap { $0 }
        for v in small {
            NSHostingView(rootView: v.frame(width: 380).environment(\.colorScheme, .dark)).layoutSubtreeIfNeeded()
        }
        for kind in GameKind.allCases {
            w.host.select(kind)
            let host = NSHostingView(rootView: GamesTab(host: w.host).environment(\.colorScheme, .dark))
            host.layoutSubtreeIfNeeded()
            let fit = host.fittingSize
            if fit.width > tab.width + 1 || fit.height > tab.height + 1 {
                return "\(kind.title) tab is \(Int(fit.width))x\(Int(fit.height)), more than \(Int(tab.width))x\(Int(tab.height))"
            }
            let board = NSHostingView(rootView: GameBoard(session: w.host.session, date: Date(), decorate: true))
            board.layoutSubtreeIfNeeded()
            if board.fittingSize.width > GameLayout.boardArea.width + 1 { return "\(kind.title) board too wide" }
        }
        return nil
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
