import AppKit
import Foundation
import Observation
import PlatyNotchKit
import SwiftUI

/// A notice in the tile (and, for a finished shortcut, a short peek).
struct LaunchNotice: Equatable {
    typealias Help = PermissionHelp

    let id = UUID()
    var text: String
    var isError: Bool
    var help: Help? = nil
}

/// Pinned sites (up to 12, opened in the default browser) and pinned Shortcuts (up to 8,
/// run on a click).
///
/// - On by default, and does no network, process or script work until the user pins
///   something or clicks: `start` only shows saved icons and fetches those that are
///   missing or older than 30 days. A disabled widget is never started.
/// - Sites: only http and https (`SiteURL`), checked when pinned, loaded and opened.
/// - Icons: only after a site is pinned, only from its own https origin
///   (`FaviconURL.candidates`), through `OriginFaviconFetcher` (ephemeral, no cookies,
///   same-origin redirects only) and `FaviconCache` (type, size and decode checks; 30 days;
///   a failure waits a day). Plain http sites get a letter icon.
/// - "Add current tab" is the only Apple Event to a browser (`BrowserTabReading`), so the
///   only possible Automation prompt, and only from its button.
/// - Shortcuts: `list` when the picker opens, `run -- <name>` on a click
///   (`ShortcutsRunning`); one at a time, stopped after 60 s or on Cancel.
/// - Pins live in `UserDefaults.standard` (`LaunchPins.defaultsKey`).
@MainActor @Observable
final class LaunchWidget: NotchWidget {
    static let widgetID = "launch"
    static let resultPeekID = "launch.result"
    static let noticeSeconds: Double = 8
    static let helpNoticeSeconds: Double = 60
    static let peekSeconds: Double = 4
    /// How often a running widget checks for icons past 30 days.
    static let refreshInterval: Duration = .seconds(86_400)

    let id = LaunchWidget.widgetID
    let title = "Sites & Shortcuts"
    let systemImage = "square.grid.2x2"
    let defaultEnabled = true

    private(set) var pins: LaunchPins
    /// By `FaviconURL.cacheKey`.
    private(set) var icons: [String: NSImage] = [:]
    private(set) var notice: LaunchNotice?
    private(set) var runningShortcut: UUID?
    private(set) var readingTab = false
    /// The picker's list: nil while closed.
    private(set) var available: [String]?
    private(set) var listing = false
    private(set) var pickerOpen = false
    private(set) var listMessage: String?
    /// Settings' address field.
    var address = ""

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let faviconDirectory: URL?
    @ObservationIgnored private let makeFetcher: () -> FaviconFetching
    @ObservationIgnored private let shortcuts: ShortcutsRunning
    @ObservationIgnored private let tabs: BrowserTabReading
    @ObservationIgnored private let opener: @MainActor (URL) -> Bool
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// Which build each browser last answered (a refusal after a rebuild is explained).
    @ObservationIgnored private let grants: AutomationGrants
    /// Made at the first start (no session exists while the widget was never on).
    @ObservationIgnored private(set) var cache: FaviconCache?
    @ObservationIgnored private(set) var running = false
    @ObservationIgnored private var context: WidgetContext?
    @ObservationIgnored private var iconTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var tabTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// `defaults: nil` keeps pins in memory only; `faviconDirectory: nil` never stores or
    /// fetches icons (smoke runs).
    init(defaults: UserDefaults? = .standard,
         faviconDirectory: URL? = CorePaths.favicons(),
         fetcher: @escaping () -> FaviconFetching = { OriginFaviconFetcher() },
         shortcuts: ShortcutsRunning = ShortcutsRunner(),
         tabs: BrowserTabReading? = nil,
         open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         clock: @escaping @Sendable () -> Date = Date.init,
         identity: @escaping () -> String = { CodeIdentity.current }) {
        self.defaults = defaults
        self.faviconDirectory = faviconDirectory
        makeFetcher = fetcher
        self.shortcuts = shortcuts
        self.tabs = tabs ?? AppleScriptTabReader()
        opener = open
        self.clock = clock
        grants = AutomationGrants(defaults: defaults, identity: identity)
        pins = defaults.map(LaunchPins.load(from:)) ?? LaunchPins()
    }

    /// No network, processes, scripts or saving (smoke runs). `sample` pins two sites and
    /// a shortcut in memory so the views lay out with content.
    static func inert(sample: Bool = false) -> LaunchWidget {
        let w = LaunchWidget(defaults: nil, faviconDirectory: nil, fetcher: { RefusingFaviconFetcher() },
                             shortcuts: NoShortcuts(), tabs: NoBrowserTabs(), open: { _ in false })
        if sample {
            w.pins.addSite(URL(string: "https://example.com")!)
            w.pins.addSite(URL(string: "http://intranet.example")!)
            w.pins.addShortcut("Log water")
        }
        return w
    }

    var isFull: Bool { pins.sites.count >= LaunchPins.maxSites }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        running = true
        self.context = context
        if cache == nil, let dir = faviconDirectory {
            cache = FaviconCache(directory: dir, fetcher: makeFetcher(), now: clock)
        }
        cache?.reopen()
        tabs.startTracking()
        refreshIcons()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled else { return }
                self?.refreshIcons()
            }
        }
    }

    /// Stops everything: icon fetches, the daily check, the picker's `list` and a running
    /// shortcut (cancelled; its process is stopped).
    func stop() {
        running = false
        context = nil
        cache?.close()
        tabs.stopTracking()
        for t in iconTasks.values { t.cancel() }
        iconTasks = [:]
        refreshTask?.cancel()
        refreshTask = nil
        runTask?.cancel()
        runTask = nil
        runningShortcut = nil
        listTask?.cancel()
        listTask = nil
        listing = false
        tabTask?.cancel()
        tabTask = nil
        readingTab = false
        noticeTask?.cancel()
        noticeTask = nil
    }

    /// Turned off: the icon cache is deleted (pins stay).
    func disabled() {
        icons = [:]
        notice = nil
        closePicker()
        if let cache {
            cache.removeAll()
        } else if let dir = faviconDirectory {
            FaviconCache.removeAll(in: dir)
        }
    }

    // MARK: - Icons

    func icon(for site: PinnedSite) -> NSImage? {
        FaviconURL.cacheKey(for: site.url).flatMap { icons[$0] }
    }

    /// Loads (from disk, or the site's origin when missing or expired) every pinned https
    /// site's icon that is not already loading. Only while running.
    func refreshIcons() {
        guard running else { return }
        for site in pins.sites { loadIcon(for: site.url) }
    }

    private func loadIcon(for url: URL) {
        guard running, let cache, let key = FaviconURL.cacheKey(for: url), iconTasks[key] == nil else { return }
        iconTasks[key] = Task { @MainActor [weak self] in
            let data = await cache.load(for: url)
            guard let self, !Task.isCancelled, self.running else { return }
            self.iconTasks[key] = nil
            self.icons[key] = data.flatMap(NSImage.init(data:))
        }
    }

    /// Waits for the icon loads in flight (tests).
    func iconsSettled() async {
        for t in Array(iconTasks.values) { await t.value }
    }

    // MARK: - Sites

    /// Settings' address field.
    func addAddress() {
        guard let url = SiteURL.parse(address) else {
            show("Only http and https addresses can be pinned.", error: true)
            return
        }
        if pin(url) { address = "" }
    }

    /// Pins `url` (validated again) and fetches its icon. Only while running.
    @discardableResult
    func pin(_ url: URL, from browser: SupportedBrowser? = nil) -> Bool {
        guard running else { return false }
        let result = pins.addSite(url)
        switch result {
        case .added:
            save()
            let title = pins.sites.last?.title ?? SiteURL.defaultTitle(for: url)
            show(browser.map { "Pinned \(title) from \($0.name)" } ?? "Pinned \(title)", error: false)
            loadIcon(for: url)
            return true
        case .duplicate: show("Already pinned.", error: false)
        case .full: show("\(LaunchPins.maxSites) sites pinned: remove one first.", error: true)
        case .invalid: show("Only http and https addresses can be pinned.", error: true)
        }
        return false
    }

    func remove(_ site: PinnedSite) {
        pins.removeSite(id: site.id)
        save()
        guard let key = FaviconURL.cacheKey(for: site.url) else { return }
        let shared = pins.sites.contains { FaviconURL.cacheKey(for: $0.url) == key }
        guard !shared else { return }
        iconTasks[key]?.cancel()
        iconTasks[key] = nil
        icons[key] = nil
        cache?.remove(for: site.url)
    }

    func move(_ site: PinnedSite, by offset: Int) {
        guard let i = pins.sites.firstIndex(of: site) else { return }
        pins.moveSite(id: site.id, to: i + offset)
        save()
    }

    /// Opens a pinned site in the default browser (http and https only).
    func open(_ site: PinnedSite) {
        guard running else { return }
        guard SiteURL.isOpenable(site.url) else {
            show("Only http and https addresses open.", error: true)
            return
        }
        if !opener(site.url) { show("Could not open \(site.title).", error: true) }
    }

    /// "Add current tab": asks the front browser for its tab's address (the only Apple
    /// Event this widget sends) and pins it.
    func addCurrentTab() {
        guard running, !readingTab else { return }
        guard !isFull else {
            show("\(LaunchPins.maxSites) sites pinned: remove one first.", error: true)
            return
        }
        readingTab = true
        let tabs = self.tabs
        tabTask = Task { @MainActor [weak self] in
            let result = await tabs.currentTab()
            guard let self, !Task.isCancelled, self.running else { return }
            self.readingTab = false
            self.tabTask = nil
            self.handle(result)
        }
    }

    private func handle(_ result: TabReadResult) {
        switch result {
        case .url(let url, let browser):
            grants.noteAccepted(browser.rawValue)
            pin(url, from: browser)
        case .noBrowser:
            show("Open Safari, Chrome or Arc first.", error: true)
        case .noWindow(let b):
            show("\(b.name) has no open window.", error: true)
        case .notWebPage(let b):
            show("\(b.name)’s tab is not a web page (only http and https can be pinned).", error: true)
        case .denied(let b):
            let history = grants.history(b.rawValue)
            let text = "Could not read \(b.name)’s tab. " + PermissionAdvice.automationDenied(app: b.name, history: history)
            show(text, error: true, help: .automation(reset: history != .thisBuild))
        case .timedOut(let b):
            show("\(b.name) did not answer.", error: true)
        case .busy(let b):
            show("Still waiting for \(b.name)’s last answer. Try again in a few seconds.", error: true)
        case .failed(let b, let code):
            show("Could not read \(b.name)’s tab (\(code)).", error: true)
        }
    }

    // MARK: - Shortcuts

    /// Opens the picker and lists the user's shortcuts (the only `list` call).
    func openPicker() {
        guard running, !listing else { return }
        pickerOpen = true
        listing = true
        listMessage = nil
        let shortcuts = self.shortcuts
        listTask = Task { @MainActor [weak self] in
            let names = await shortcuts.list()
            guard let self, !Task.isCancelled, self.running else { return }
            self.listing = false
            self.listTask = nil
            self.available = names
            if names == nil {
                self.listMessage = "Could not list your shortcuts."
            } else if names?.isEmpty == true {
                self.listMessage = "No shortcuts yet. Make one in the Shortcuts app."
            }
        }
    }

    func closePicker() {
        listTask?.cancel()
        listTask = nil
        listing = false
        pickerOpen = false
        available = nil
        listMessage = nil
    }

    func pinShortcut(_ name: String) {
        guard running else { return }
        switch pins.addShortcut(name) {
        case .added: save()
        case .duplicate: show("Already pinned.", error: false)
        case .full: show("\(LaunchPins.maxShortcuts) shortcuts pinned: remove one first.", error: true)
        case .invalid: show("Not a shortcut name.", error: true)
        }
    }

    func remove(_ shortcut: PinnedShortcut) {
        pins.removeShortcut(id: shortcut.id)
        save()
    }

    /// Runs a pinned shortcut (one at a time); the result shows as a notice and a peek.
    func run(_ shortcut: PinnedShortcut) {
        guard running, runningShortcut == nil else { return }
        runningShortcut = shortcut.id
        let shortcuts = self.shortcuts
        let name = shortcut.name
        runTask = Task { @MainActor [weak self] in
            let outcome = await shortcuts.run(name)
            guard let self, self.running else { return }
            self.runningShortcut = nil
            self.runTask = nil
            self.show(outcome.message(for: name), error: !outcome.succeeded)
            let until = Date().addingTimeInterval(Self.peekSeconds)
            self.context?.peek(id: Self.resultPeekID, until: until, as: nil)
        }
    }

    /// Stops the running shortcut (its process gets SIGTERM, then SIGKILL).
    func cancelShortcut() {
        runTask?.cancel()
    }

    // MARK: - Notices and saving

    private func show(_ text: String, error: Bool, help: LaunchNotice.Help? = nil) {
        let n = LaunchNotice(text: text, isError: error, help: help)
        notice = n
        noticeTask?.cancel()
        // Steps to follow stay long enough to read and act on.
        let seconds: Double = help == nil ? Self.noticeSeconds : Self.helpNoticeSeconds
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.notice?.id == n.id else { return }
            self.notice = nil
        }
    }

    private func save() {
        if let defaults { pins.save(to: defaults) }
    }

    // MARK: - Views

    func tileView() -> AnyView { AnyView(LaunchTile(widget: self)) }

    func settingsView() -> AnyView? { AnyView(LaunchSettings(widget: self)) }

    func peekView(id: String) -> AnyView? {
        guard id == Self.resultPeekID, let notice else { return nil }
        return AnyView(LaunchResultPeek(notice: notice))
    }
}
