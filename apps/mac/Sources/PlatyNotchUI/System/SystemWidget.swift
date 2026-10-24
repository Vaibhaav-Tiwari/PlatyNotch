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
/// Open, Show in Finder and, when the shelf is on, Move to Shelf) need the Downloads
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
    static let downloadPeekID = "system.download"
    static let downloadActivityID = "system.download"
    static let downloadPeekDuration: TimeInterval = 8

    /// What the downloads sub-feature uses; tests pass fakes for all of it.
    struct DownloadsServices {
        /// `~/Downloads`, canonical.
        var folder: String
        var watch: FolderWatcherFactory
        /// A stat of a path from a batch, never a read.
        var exists: (String) -> Bool
        /// Lists the folder once (the macOS prompt), from the Turn On button only.
        var probe: @MainActor (String) async -> Bool
        var files: FileActions
        /// Adds a file to the shelf, or nil while the shelf is off.
        var shelf: @MainActor () -> (@MainActor (URL) -> Bool)?

        static func system(shelf: @escaping @MainActor () -> (@MainActor (URL) -> Bool)? = { nil }) -> DownloadsServices {
            DownloadsServices(folder: DownloadsMonitor.defaultFolder(),
                              watch: { FSEventsWatcher.make(folders: $0, onPaths: $1) },
                              exists: { FileManager.default.fileExists(atPath: $0) },
                              probe: { await DownloadsMonitor.probeAccess($0) },
                              files: WorkspaceFileActions(), shelf: shelf)
        }

        /// Watches nothing, touches nothing (smoke runs).
        static var none: DownloadsServices {
            DownloadsServices(folder: "/nonexistent", watch: { _, _ in nil }, exists: { _ in false },
                              probe: { _ in false }, files: WorkspaceFileActions(), shelf: { nil })
        }
    }
    static let headphonesPeekDuration: TimeInterval = 5
    /// After the Bluetooth prompt, how long to watch for the answer (once a second).
    static let accessWatch = 60

    /// Which opt-in sub-features are on (`UserDefaults`, key `system.options`).
    struct Options: Codable, Equatable {
        static let key = "system.options"
        var headphones = false
        var downloads = false
        /// A second folder to watch for downloads (chosen in Settings), as a path.
        var extraFolder: String?

        init(headphones: Bool = false, downloads: Bool = false, extraFolder: String? = nil) {
            self.headphones = headphones
            self.downloads = downloads
            self.extraFolder = extraFolder
        }

        static func load(_ d: UserDefaults) -> Options {
            d.data(forKey: key).flatMap { try? JSONDecoder().decode(Options.self, from: $0) } ?? Options()
        }
    }
    /// How long the plug-in / unplug peek stays.
    static let powerPeekDuration: TimeInterval = 4

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
    /// Downloads are on but macOS refused the folder.
    private(set) var downloadsDenied = false
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
        // A desktop Mac has no battery and never gets one: no source at all.
        if battery != nil {
            power.start { [weak self] in self?.powerChanged() }
        }
        if options.headphones { startHeadphones(prompting: false) }
        // Turned on from its button before, so already asked; no listing here.
        if options.downloads { startDownloads() }
    }

    func stop() {
        guard let context else { return }
        power.stop()
        keepAwake.stop()
        stopHeadphones()
        stopDownloads()
        if powerPeek != nil { context.endPeek(id: Self.powerPeekID) }
        powerPeek = nil
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
        guard let change = BatteryState.change(from: old, to: new), let new else { return }
        powerPeek = PowerPeek(change: change, state: new)
        if !context.peek(id: Self.powerPeekID, until: clock().addingTimeInterval(Self.powerPeekDuration)) {
            powerPeek = nil
        }
    }

    func dismissPowerPeek() {
        guard powerPeek != nil else { return }
        powerPeek = nil
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

    /// The settings button. Turning on lists the folder once (the macOS prompt shows here).
    func setDownloads(_ on: Bool) {
        updateOptions { $0.downloads = on }
        guard on else {
            stopDownloads()
            return
        }
        guard isRunning else { return }
        downloadsTask?.cancel()
        let folder = downloads.folder
        let probe = downloads.probe
        downloadsTask = Task { @MainActor [weak self] in
            let granted = await probe(folder)
            guard let self, !Task.isCancelled, self.isRunning, self.options.downloads else { return }
            if granted { self.startDownloads() } else { self.downloadsDenied = true }
        }
    }

    /// A second folder to watch (Settings › Choose…), or nil to remove it.
    func setExtraFolder(_ path: String?) {
        updateOptions { $0.extraFolder = path }
        if monitor != nil {
            monitor?.stop()
            monitor = nil
            startDownloads()
        }
    }

    var downloadFolders: [String] {
        [downloads.folder] + [options.extraFolder].compactMap { $0 }.filter { $0 != downloads.folder }
    }

    private func startDownloads() {
        guard monitor == nil, isRunning else { return }
        downloadsDenied = false
        monitor = DownloadsMonitor(folders: downloadFolders, factory: downloads.watch, exists: downloads.exists,
                                   clock: clock) { [weak self] events, tracker in
            self?.downloadEvents(events, tracker)
        }
    }

    private func stopDownloads() {
        downloadsTask?.cancel()
        downloadsTask = nil
        monitor?.stop()
        monitor = nil
        downloadsActive = []
        downloadsDenied = false
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

    /// Adds the file to the shelf (it stays where it is; the shelf keeps a bookmark).
    @discardableResult
    func moveDownloadToShelf() -> Bool {
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
