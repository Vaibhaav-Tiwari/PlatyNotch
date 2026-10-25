import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Battery, keep-awake and, as opt-in sub-features, headphones and downloads.
///
/// On by default with only the parts that need no permission: the battery (plug-in and
/// unplug peeks with the percent; a low-battery live activity at `LivePriority.batteryLow`;
/// charging is ambient, C9) and keep-awake (30 min / 1 h / 2 h / until off; a live
/// activity counting down the time left at `LivePriority.keepAwake`).
///
/// Turned off it does nothing: no power-source run-loop source and no assertion
/// (`stop` releases it; so do `disabled()` and quit). A keep-awake is never persisted,
/// so nothing is re-created on launch. Desktop Macs have no battery: no source, no rows.
///
/// Headphones (AirPods connect peek with the battery, best effort) need Bluetooth access:
/// off until turned on from its button in Settings, the only place the prompt can appear.
/// At launch it registers only when access was already allowed; otherwise the settings
/// show the button again. Off (or the widget off): no Bluetooth notifications.
///
/// Downloads (an in-progress live activity with the file name; a finished notice with
/// Open, Show in Finder and, when the shelf is on, Add to Shelf) need the Downloads
/// folder: off until its Turn On button, which lists the folder once so macOS asks
/// there. One FSEvents stream on `~/Downloads` (and an optional folder the user chose;
/// no Safari-container lookup, C29), coalesced; names and existence only, never file
/// contents, and nothing is done to a file without a click. Off: no stream.
@MainActor @Observable
final class SystemWidget: NotchWidget {
    static let widgetID = "system"
    static let powerPeekID = "system.power"
    static let batteryActivityID = "system.battery"
    static let keepAwakeActivityID = "system.keepAwake"
    static let headphonesPeekID = "system.headphones"
    static let downloadPeekID = "system.download.finished"
    static let downloadActivityID = "system.download.active"
    static let downloadPeekDuration: TimeInterval = 8

    /// What the downloads sub-feature uses; tests pass fakes for all of it.
    struct DownloadsServices {
        /// `~/Downloads` as a path, not resolved (no file-system access).
        var folder: String
        /// Resolves symlinks (`realpath`); only called when downloads start with a
        /// matching stamp (or from the Turn On button), never at construction.
        var resolve: @MainActor (String) -> String
        var watch: FolderWatcherFactory
        /// A stat of a path from a batch (type and size), never a read. May run off main.
        var stat: @Sendable (String) -> FileStat?
        /// Lists the folder once (the macOS prompt), from the Turn On button only.
        var probe: @MainActor (String) async -> Bool
        /// This build's code identity (`CodeIdentity`), saved with a grant.
        var identity: @MainActor () -> String
        /// The user's home (for `WatchFolderPolicy`).
        var home: String
        var files: FileActions
        /// Adds a file to the shelf, or nil while the shelf is off.
        var shelf: @MainActor () -> (@MainActor (URL) -> Bool)?

        static func system(shelf: @escaping @MainActor () -> (@MainActor (URL) -> Bool)? = { nil }) -> DownloadsServices {
            DownloadsServices(folder: DownloadsMonitor.defaultFolderPath(), resolve: { DownloadsMonitor.canonical($0) },
                              watch: { FSEventsWatcher.make(folders: $0, onPaths: $1) },
                              stat: { DownloadsMonitor.statFile($0) },
                              probe: { await DownloadsMonitor.probeAccess($0) },
                              identity: { CodeIdentity.current }, home: NSHomeDirectory(),
                              files: WorkspaceFileActions(), shelf: shelf)
        }

        /// Watches nothing, touches nothing (smoke runs).
        static var none: DownloadsServices {
            DownloadsServices(folder: "/nonexistent", resolve: { $0 }, watch: { _, _ in nil }, stat: { _ in nil },
                              probe: { _ in false }, identity: { CodeIdentity.unsigned }, home: "/nonexistent",
                              files: WorkspaceFileActions(), shelf: { nil })
        }
    }
    static let headphonesPeekDuration: TimeInterval = 5
    /// After the Bluetooth prompt, how long to watch for the answer (once a second).
    static let accessWatch = 60

    /// Which opt-in sub-features are on (`UserDefaults`, key `system.options`).
    struct Options: Codable, Equatable {
        static let key = "system.options"
        var headphones = false
        /// Saved true only after macOS granted the folder, with `downloadsStamp`.
        var downloads = false
        /// A second folder to watch for downloads (chosen in Settings), as a path.
        var extraFolder: String?
        /// The `CodeIdentity` that was granted the Downloads folder.
        var downloadsStamp: String?
        /// macOS refused the folder at the last Turn On.
        var downloadsDenied = false
        /// Turned off at launch because this build is not the one that was granted.
        var downloadsNeedReenable = false

        init(headphones: Bool = false, downloads: Bool = false, extraFolder: String? = nil,
             downloadsStamp: String? = nil, downloadsDenied: Bool = false, downloadsNeedReenable: Bool = false) {
            self.headphones = headphones
            self.downloads = downloads
            self.extraFolder = extraFolder
            self.downloadsStamp = downloadsStamp
            self.downloadsDenied = downloadsDenied
            self.downloadsNeedReenable = downloadsNeedReenable
        }

        /// Missing keys take their defaults (options saved by an older build).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            headphones = try c.decodeIfPresent(Bool.self, forKey: .headphones) ?? false
            downloads = try c.decodeIfPresent(Bool.self, forKey: .downloads) ?? false
            extraFolder = try c.decodeIfPresent(String.self, forKey: .extraFolder)
            downloadsStamp = try c.decodeIfPresent(String.self, forKey: .downloadsStamp)
            downloadsDenied = try c.decodeIfPresent(Bool.self, forKey: .downloadsDenied) ?? false
            downloadsNeedReenable = try c.decodeIfPresent(Bool.self, forKey: .downloadsNeedReenable) ?? false
        }

        static func load(_ d: UserDefaults) -> Options {
            d.data(forKey: key).flatMap { try? JSONDecoder().decode(Options.self, from: $0) } ?? Options()
        }
    }
    /// How long the plug-in / unplug peek stays.
    static let powerPeekDuration: TimeInterval = 4
    /// Changes this soon after a peek update that peek in place (no new peek).
    static let powerPeekDebounce: TimeInterval = 2
    /// No battery at start: read once more after this (a slow IOPS at login).
    static let batteryRetryDelay: Duration = .seconds(5)

    struct PowerPeek: Equatable {
        let change: BatteryState.Change
        let state: BatteryState
    }

    let id = SystemWidget.widgetID
    let title = "System"
    let systemImage = "bolt.batteryblock"
    let defaultEnabled = true

    /// nil on a desktop Mac, and while the widget is off.
    private(set) var battery: BatteryState?
    /// The plug-in / unplug peek on show.
    private(set) var powerPeek: PowerPeek?
    let keepAwake: KeepAwake
    private(set) var options: Options
    /// Connected headphones (headphones on and running).
    private(set) var headphones: [HeadphonesInfo] = []
    /// The connect peek on show.
    private(set) var headphonesPeek: HeadphonesInfo?
    /// Headphones are on but Bluetooth is not allowed (not asked since launch, or denied).
    private(set) var headphonesNeedAccess = false
    /// Downloads in progress, oldest first.
    private(set) var downloadsActive: [DownloadTracker.Active] = []
    /// The last finished download (the notice and the tile).
    private(set) var finishedDownload: URL?
    /// macOS refused the folder at the last Turn On (saved, so Settings never says "on").
    var downloadsDenied: Bool { options.downloadsDenied }
    /// Turn On was pressed and the answer is pending.
    private(set) var downloadsAsking = false
    /// Why the chosen second folder was not taken (or was dropped at launch).
    private(set) var extraFolderRejection: String?
    /// The access check after Turn On (tests await it).
    @ObservationIgnored private(set) var downloadsTask: Task<Void, Never>?
    /// Mirrors `headphoneSource.access` for the settings (refreshed on changes).
    private(set) var bluetoothAccess: BluetoothAccess = .notDetermined

    @ObservationIgnored private let power: PowerSourceReading
    @ObservationIgnored private let headphoneSource: HeadphonesSource
    @ObservationIgnored private var headphonesWatching = false
    @ObservationIgnored private var accessTask: Task<Void, Never>?
    @ObservationIgnored let downloads: DownloadsServices
    @ObservationIgnored private var monitor: DownloadsMonitor?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let persist: Bool
    @ObservationIgnored let clock: () -> Date
    @ObservationIgnored private(set) var context: WidgetContext?
    /// When the current burst's peek was shown (the debounce window starts there).
    @ObservationIgnored private var powerPeekShownAt: Date?
    @ObservationIgnored private(set) var powerPeekUntil: Date?
    @ObservationIgnored private var powerPeekExpiry: Task<Void, Never>?
    @ObservationIgnored private var batteryRetryTask: Task<Void, Never>?

    init(power: PowerSourceReading = SystemPowerSource(), asserter: PowerAsserting = SystemPowerAsserter(),
         headphones: HeadphonesSource = SystemHeadphones(), downloads: DownloadsServices = .system(),
         defaults: UserDefaults = .standard, persist: Bool = true, clock: @escaping () -> Date = Date.init) {
        self.power = power
        headphoneSource = headphones
        self.downloads = downloads
        options = Options.load(defaults)
        self.defaults = defaults
        self.persist = persist
        self.clock = clock
        keepAwake = KeepAwake(asserter: asserter, clock: clock)
    }

    /// Reads no battery, asserts nothing and saves nothing (smoke runs).
    static func inert() -> SystemWidget {
        SystemWidget(power: NoPowerSource(), asserter: NoPowerAsserter(), headphones: NoHeadphones(), downloads: .none,
                     defaults: UserDefaults(suiteName: "dev.platynotch.inert-system") ?? .standard, persist: false)
    }

    var isRunning: Bool { context != nil }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard self.context == nil else { return }
        self.context = context
        battery = power.read()
        // A desktop Mac has no battery and never gets one: no source at all. A laptop
        // whose first read failed gets one more read a little later.
        if battery != nil {
            startPowerSource()
        } else {
            batteryRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.batteryRetryDelay)
                guard !Task.isCancelled else { return }
                self?.retryBatteryRead()
            }
        }
        if options.headphones { startHeadphones(prompting: false) }
        if options.downloads { resumeDownloads() }
    }

    private func startPowerSource() {
        power.start { [weak self] in self?.powerChanged() }
    }

    /// The one retry when there was no battery at start (the retry sleep; tests call it).
    func retryBatteryRead() {
        batteryRetryTask = nil
        guard isRunning, battery == nil, let b = power.read() else { return }
        battery = b
        startPowerSource()
    }

    func stop() {
        guard let context else { return }
        power.stop()
        batteryRetryTask?.cancel()
        batteryRetryTask = nil
        if powerPeek != nil { context.endPeek(id: Self.powerPeekID) }
        clearPowerPeek()
        keepAwake.stop()
        stopHeadphones()
        stopDownloads()
        battery = nil
        self.context = nil
    }

    /// Turned off: the assertion is already released by `stop`; again for safety.
    func disabled() {
        keepAwake.stop()
    }

    // MARK: - Battery

    private func powerChanged() {
        guard let context else { return }
        let old = battery
        let new = power.read()
        battery = new
        guard let change = BatteryState.change(from: old, to: new), let new else {
            if let p = powerPeek, let new { powerPeek = PowerPeek(change: p.change, state: new) }
            return
        }
        let now = clock()
        // A burst (a loose connector): within the window that started at the burst's first
        // peek, the peek follows the last state; shown again if something replaced it.
        if powerPeek != nil, let shown = powerPeekShownAt, let until = powerPeekUntil,
           now.timeIntervalSince(shown) < Self.powerPeekDebounce, until > now {
            powerPeek = PowerPeek(change: change, state: new)
            if !context.peek(id: Self.powerPeekID, until: until) { clearPowerPeek() }
            return
        }
        clearPowerPeek()
        let until = now.addingTimeInterval(Self.powerPeekDuration)
        powerPeek = PowerPeek(change: change, state: new)
        guard context.peek(id: Self.powerPeekID, until: until) else {
            powerPeek = nil
            return
        }
        powerPeekShownAt = now
        powerPeekUntil = until
        powerPeekExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.powerPeekDuration))
            guard !Task.isCancelled else { return }
            self?.powerPeekExpired(until)
        }
    }

    /// The peek's time is up (the expiry sleep; tests call it).
    func powerPeekExpired(_ until: Date) {
        guard powerPeekUntil == until else { return }
        clearPowerPeek()
    }

    private func clearPowerPeek() {
        powerPeekExpiry?.cancel()
        powerPeekExpiry = nil
        powerPeek = nil
        powerPeekShownAt = nil
        powerPeekUntil = nil
    }

    func dismissPowerPeek() {
        guard powerPeek != nil else { return }
        clearPowerPeek()
        context?.endPeek(id: Self.powerPeekID)
    }

    // MARK: - Headphones

    /// The settings button (turn on / off). Turning on may show the Bluetooth prompt.
    func setHeadphones(_ on: Bool) {
        updateOptions { $0.headphones = on }
        if on {
            if isRunning { startHeadphones(prompting: true) }
        } else {
            stopHeadphones()
        }
    }

    /// "Allow Bluetooth" in settings (headphones on, not asked since launch).
    func requestHeadphonesAccess() {
        guard isRunning, options.headphones else { return }
        startHeadphones(prompting: true)
    }

    /// Re-reads battery (the tile appearing).
    func refreshHeadphones() {
        guard headphonesWatching else { return }
        headphoneSource.refreshBattery()
    }

    /// `prompting`: from the button, so registering may ask for Bluetooth. At launch only
    /// an allowed access registers.
    private func startHeadphones(prompting: Bool) {
        let access = headphoneSource.access
        bluetoothAccess = access
        guard access == .allowed || (prompting && access == .notDetermined) else {
            headphonesNeedAccess = true
            return
        }
        headphonesNeedAccess = false
        registerHeadphones()
        if access == .notDetermined { watchAccess() }
    }

    private func registerHeadphones() {
        guard !headphonesWatching else { return }
        headphonesWatching = true
        headphoneSource.start { [weak self] event in self?.headphonesEvent(event) }
    }

    private func stopHeadphones() {
        accessTask?.cancel()
        accessTask = nil
        headphonesNeedAccess = false
        if headphonesWatching { headphoneSource.stop() }
        headphonesWatching = false
        headphones = []
        if headphonesPeek != nil { context?.endPeek(id: Self.headphonesPeekID) }
        headphonesPeek = nil
    }

    /// The prompt is up: once allowed, register afresh (a registration made before the
    /// answer may have been refused) so connected headphones show. Bounded, button-only.
    private func watchAccess() {
        accessTask?.cancel()
        accessTask = Task { @MainActor [weak self] in
            for _ in 0..<Self.accessWatch {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.headphonesWatching else { return }
                let access = self.headphoneSource.access
                guard access != .notDetermined else { continue }
                self.bluetoothAccess = access
                self.headphoneSource.stop()
                self.headphonesWatching = false
                if access == .allowed { self.registerHeadphones() } else { self.headphonesNeedAccess = true }
                return
            }
        }
    }

    private func headphonesEvent(_ event: HeadphonesEvent) {
        guard headphonesWatching, let context else { return }
        switch event {
        case .present(let h):
            upsert(h)
        case .connected(let h):
            let known = headphones.contains { $0.id == h.id }
            upsert(h)
            guard !known else { return }
            headphonesPeek = h
            if !context.peek(id: Self.headphonesPeekID, until: clock().addingTimeInterval(Self.headphonesPeekDuration)) {
                headphonesPeek = nil
            }
        case .updated(let h):
            upsert(h)
            if headphonesPeek?.id == h.id { headphonesPeek = h }
        case .disconnected(let id):
            headphones.removeAll { $0.id == id }
            if headphonesPeek?.id == id {
                headphonesPeek = nil
                context.endPeek(id: Self.headphonesPeekID)
            }
        }
    }

    private func upsert(_ h: HeadphonesInfo) {
        if let i = headphones.firstIndex(where: { $0.id == h.id }) { headphones[i] = h } else { headphones.append(h) }
    }

    // MARK: - Downloads

    /// The settings button. Turning on lists the folder once (the macOS prompt shows here)
    /// and is saved only when macOS grants it, with this build's identity. Quitting while
    /// the prompt is up leaves it off.
    func setDownloads(_ on: Bool) {
        guard on else {
            updateOptions {
                $0.downloads = false
                $0.downloadsStamp = nil
                $0.downloadsDenied = false
                $0.downloadsNeedReenable = false
            }
            stopDownloads()
            return
        }
        guard isRunning, !options.downloads, !downloadsAsking else { return }
        downloadsTask?.cancel()
        downloadsAsking = true
        let folder = downloads.folder
        let probe = downloads.probe
        downloadsTask = Task { @MainActor [weak self] in
            let granted = await probe(folder)
            guard let self, !Task.isCancelled, self.isRunning, self.downloadsAsking else { return }
            self.downloadsAsking = false
            let stamp = self.downloads.identity()
            self.updateOptions {
                $0.downloads = granted
                $0.downloadsStamp = granted ? stamp : nil
                $0.downloadsDenied = !granted
                $0.downloadsNeedReenable = false
            }
            if granted { self.startDownloads() }
        }
    }

    /// At launch: only a grant made by this very build is used; anything else (an update,
    /// a reinstall, an ad-hoc rebuild, a missing stamp) turns the sub-feature off with no
    /// file-system access, until its button is pressed again.
    private func resumeDownloads() {
        guard CodeIdentity.grantHolds(options.downloadsStamp, current: downloads.identity()) else {
            updateOptions {
                $0.downloads = false
                $0.downloadsStamp = nil
                $0.downloadsNeedReenable = true
            }
            return
        }
        startDownloads()
    }

    /// A second folder to watch (Settings › Choose…), or nil to remove it. False (and
    /// `extraFolderRejection` says why) for a folder macOS guards with a prompt.
    @discardableResult
    func setExtraFolder(_ path: String?) -> Bool {
        if let path, case .rejected(let why) = WatchFolderPolicy.check(path, home: downloads.home) {
            extraFolderRejection = why
            return false
        }
        extraFolderRejection = nil
        updateOptions { $0.extraFolder = path }
        if monitor != nil {
            monitor?.stop()
            monitor = nil
            startDownloads()
        }
        return true
    }

    /// The folders for a start: `~/Downloads` resolved, and the saved second folder only
    /// when it passes `WatchFolderPolicy` as written and again after resolving its
    /// symlinks (resolved only when the written path passed). A failing one is dropped
    /// with the reason. Runs on every start, so nothing saved by an older build slips in.
    private func foldersForStart() -> [String] {
        let main = downloads.resolve(downloads.folder)
        guard let extra = options.extraFolder else { return [main] }
        let home = downloads.home
        var verdict = WatchFolderPolicy.check(extra, home: home)
        var resolved = extra
        if verdict == .allowed {
            resolved = downloads.resolve(extra)
            verdict = WatchFolderPolicy.check(resolved, home: home)
        }
        if case .rejected(let why) = verdict {
            updateOptions { $0.extraFolder = nil }
            extraFolderRejection = why
            return [main]
        }
        return resolved == main ? [main] : [main, resolved]
    }

    private func startDownloads() {
        guard monitor == nil, isRunning else { return }
        monitor = DownloadsMonitor(folders: foldersForStart(), factory: downloads.watch, stat: downloads.stat,
                                   clock: clock) { [weak self] events, tracker in
            self?.downloadEvents(events, tracker)
        }
    }

    /// The monitor's latest off-main batch (tests await it).
    var downloadsPendingBatch: Task<Void, Never>? { monitor?.pendingBatch }

    private func stopDownloads() {
        downloadsTask?.cancel()
        downloadsTask = nil
        downloadsAsking = false
        monitor?.stop()
        monitor = nil
        downloadsActive = []
        if finishedDownload != nil { context?.endPeek(id: Self.downloadPeekID) }
        finishedDownload = nil
    }

    private func downloadEvents(_ events: [DownloadTracker.Event], _ tracker: DownloadTracker) {
        guard monitor != nil, let context else { return }
        downloadsActive = tracker.active
        guard let done = events.last(where: { $0.kind == .finished }) else { return }
        finishedDownload = URL(fileURLWithPath: done.path)
        context.peek(id: Self.downloadPeekID, until: clock().addingTimeInterval(Self.downloadPeekDuration))
    }

    /// The notice and tile buttons: the only ways a downloaded file is acted on.
    func openDownload() {
        guard let url = finishedDownload else { return }
        downloads.files.open(url)
        context?.endPeek(id: Self.downloadPeekID)
    }

    func revealDownload() {
        guard let url = finishedDownload else { return }
        downloads.files.reveal(url)
        context?.endPeek(id: Self.downloadPeekID)
    }

    var canMoveToShelf: Bool { downloads.shelf() != nil }

    /// "Add to Shelf": the file stays where it is; the shelf keeps a bookmark.
    @discardableResult
    func addDownloadToShelf() -> Bool {
        guard let url = finishedDownload, let add = downloads.shelf() else { return false }
        let added = add(url)
        if added { context?.endPeek(id: Self.downloadPeekID) }
        return added
    }

    /// Closes the notice (it stays in the tile).
    func dismissDownloadPeek() {
        context?.endPeek(id: Self.downloadPeekID)
    }

    // MARK: - Options

    func updateOptions(_ change: (inout Options) -> Void) {
        var next = options
        change(&next)
        guard next != options else { return }
        options = next
        if persist, let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Options.key) }
    }

    // MARK: - Keep awake (tile buttons)

    func startKeepAwake(_ duration: KeepAwakeDuration) {
        guard isRunning else { return }
        keepAwake.start(duration)
    }

    func stopKeepAwake() {
        keepAwake.stop()
    }

    // MARK: - Live activities

    var liveActivities: [LiveActivity] {
        guard isRunning else { return [] }
        var out: [LiveActivity] = []
        if let s = keepAwake.session {
            out.append(LiveActivity(id: Self.keepAwakeActivityID, widgetID: id, priority: LivePriority.keepAwake,
                                    glyph: .symbol("cup.and.saucer.fill"), trailing: s.until == nil ? "On" : nil,
                                    tint: .accent, expiresAt: s.until, countdownTo: s.until,
                                    accessibilityLabel: "Keeping the display awake"))
        }
        if let latest = downloadsActive.last {
            let more = downloadsActive.count - 1
            out.append(LiveActivity(id: Self.downloadActivityID, widgetID: id, priority: LivePriority.download,
                                    glyph: .symbol("arrow.down.circle"),
                                    trailing: DownloadDetector.shortName(latest.name) + (more > 0 ? " +\(more)" : ""),
                                    tint: .accent,
                                    accessibilityLabel: "Downloading \(latest.name)"
                                        + (more > 0 ? " and \(more) more" : "")))
        }
        if let b = battery {
            if b.isLow {
                out.append(LiveActivity(id: Self.batteryActivityID, widgetID: id, priority: LivePriority.batteryLow,
                                        glyph: .symbol(b.symbolName), trailing: "\(b.percent)%", tint: .critical,
                                        accessibilityLabel: "Battery low, \(b.percent) percent"))
            } else if b.pluggedIn, b.charging {
                out.append(LiveActivity(id: Self.batteryActivityID, widgetID: id,
                                        priority: LivePriority.batteryCharging, glyph: .symbol("bolt.fill"),
                                        trailing: "\(b.percent)%", tint: .accent,
                                        accessibilityLabel: "Charging, \(b.percent) percent"))
            }
        }
        return out
    }

    // MARK: - Views

    var kind: WidgetKind { [.glance, .live, .tool] }

    /// This Mac has a battery (desktops have none).
    var hasContent: Bool { battery != nil }

    /// "Battery 82%".
    func glanceView() -> AnyView? { AnyView(SystemGlance(widget: self)) }

    /// Keep-awake, a download or low battery: no primary control (spec 6.4).
    func heroView() -> AnyView? {
        AnyView(TopActivityHero(activities: { [weak self] in self?.liveActivities ?? [] }, action: { _ in nil }))
    }

    func tileView() -> AnyView { AnyView(SystemTile(widget: self)) }

    func settingsView() -> AnyView? { AnyView(SystemSettings(widget: self)) }

    func peekView(id: String) -> AnyView? {
        switch id {
        case Self.powerPeekID: powerPeek.map { AnyView(PowerPeekView(peek: $0)) }
        case Self.headphonesPeekID: headphonesPeek.map { AnyView(HeadphonesPeekView(info: $0)) }
        case Self.downloadPeekID: finishedDownload.map { AnyView(DownloadPeekView(widget: self, url: $0)) }
        default: nil
        }
    }
}

/// The battery glance.
private struct SystemGlance: View {
    let widget: SystemWidget

    var body: some View {
        let b = widget.battery
        GlanceChip(systemImage: b?.symbolName ?? "battery.100", value: b.map { "\($0.percent)%" } ?? "—",
                   label: "Battery", tint: (b?.isLow ?? false) ? DS.dynamicColor(.error) : nil)
    }
}
