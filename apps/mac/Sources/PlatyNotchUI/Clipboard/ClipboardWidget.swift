import AppKit
import ImageIO
import Observation
import os
import PlatyNotchKit
import SwiftUI

/// What the menu bar needs for "Pause clipboard history" (C23).
@MainActor
protocol ClipboardMenuControl: AnyObject {
    /// The widget is on (the item is hidden otherwise).
    var isRunning: Bool { get }
    var paused: Bool { get }
    func setPaused(_ paused: Bool)
}

/// Clipboard history with a ⌥⇧V picker.
///
/// - Off by default (C22): it reads everything the user copies.
/// - While on and not paused, `ClipboardWatcher` checks the pasteboard's change count every
///   0.5 s (the plan's one sub-second poll) and records what `ClipFilter` lets through:
///   never password managers or Memory's excluded apps (by frontmost app, best effort),
///   never items marked concealed, transient or auto-generated, never an item whose
///   `org.nspasteboard.source` is an excluded app.
/// - History lives in `ClipboardStore` (`clipboard.noindex/history.json` 0600, images 0600, folders
///   0700), never in UserDefaults or logs. UserDefaults holds only settings (pause, limit,
///   age, shortcut).
/// - The picker's shortcut is a Carbon hot key (no permission), registered only while the
///   widget runs. Pasting posts ⌘V only with Accessibility; without it the item is copied
///   and a peek says "Copied — press ⌘V". Only Settings' button asks for Accessibility.
///
/// Off: no timer, no hot key, no pasteboard reads, the store is not even opened (unless it
/// was opened before). `disabled()` keeps history; Clear deletes it. Pause stops reads at
/// once and survives a relaunch; what is copied while paused is never recorded.
@MainActor @Observable
final class ClipboardWidget: NotchWidget, ClipboardMenuControl {
    static let widgetID = "clipboard"
    static let copiedPeekID = "clipboard.copied"
    static let copiedPeekDuration: TimeInterval = 2.5
    static let limitChoices = [50, 100, 200, 500]
    static let keepDayChoices = [1, 7, 30]
    /// Re-check expiry at least this often (sleep, clock changes).
    static let maxExpirySleep: TimeInterval = 6 * 60 * 60

    enum Keys {
        static let paused = "clipboard.paused"
        static let limit = "clipboard.limit"
        static let keepDays = "clipboard.keepDays"
    }

    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "clipboard")

    let id = ClipboardWidget.widgetID
    let title = "Clipboard history"
    let systemImage = "doc.on.clipboard"
    let defaultEnabled = false

    /// Newest first (a copy of the store's, for observation).
    private(set) var items: [ClipItem] = []
    private(set) var paused = false
    private(set) var limit = ClipboardHistory.defaultLimit
    private(set) var keepDays = 7
    private(set) var hotKeyChoice = ClipHotKey.default
    /// The shortcut is registered (false: another app holds it, or the widget is off).
    private(set) var hotKeyActive = false
    /// A damaged history file was moved aside (Settings offers to delete it).
    private(set) var hasKeptFiles = false
    /// The last pick that was only copied (Accessibility missing), for the tile.
    private(set) var copiedOnly = false

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private let pasteboard: ClipboardPasteboard
    @ObservationIgnored private let frontmost: FrontmostApp
    @ObservationIgnored private let schedule: ClipboardWatcher.Schedule
    @ObservationIgnored private let makeHotKey: HotKeyMaker
    @ObservationIgnored let trust: AccessibilityTrust
    @ObservationIgnored private let paster: Paster
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var store: ClipboardStore?
    @ObservationIgnored private(set) var watcher: ClipboardWatcher?
    @ObservationIgnored private var hotKey: HotKeyRegistration?
    @ObservationIgnored private var context: WidgetContext?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// The latest image conversion and the latest paste (tests await them).
    @ObservationIgnored private(set) var imageTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pasteTask: Task<Void, Never>?
    @ObservationIgnored private(set) lazy var picker = ClipPickerPanel(widget: self)

    init(directory: URL = CorePaths.clipboard(), persist: Bool = true,
         pasteboard: ClipboardPasteboard = SystemPasteboard(), frontmost: FrontmostApp = SystemFrontmostApp(),
         schedule: @escaping ClipboardWatcher.Schedule = ClipboardWatcher.timer,
         makeHotKey: @escaping HotKeyMaker = HotKey.make,
         poster: PasteEventPosting = SystemPasteEvents(), trust: AccessibilityTrust = .system,
         focusTimeout: Duration = Paster.focusTimeout, clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.persist = persist
        self.pasteboard = pasteboard
        self.frontmost = frontmost
        self.schedule = schedule
        self.makeHotKey = makeHotKey
        self.trust = trust
        self.paster = Paster(poster: poster, trust: trust, frontmost: frontmost, focusTimeout: focusTimeout)
        self.clock = clock
    }

    /// Smoke runs: no pasteboard, no hot key, no events, nothing on disk, never a prompt.
    static func inert() -> ClipboardWidget {
        ClipboardWidget(persist: false, pasteboard: NoPasteboard(), schedule: { _, _ in {} },
                        makeHotKey: { _, _, _ in nil }, poster: NoPasteEvents(), trust: .never)
    }

    var isRunning: Bool { context != nil }
    var history: ClipboardHistory { store?.history ?? ClipboardHistory() }
    var maxAge: TimeInterval { TimeInterval(keepDays) * 86400 }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard self.context == nil else { return }
        self.context = context
        readSettings(context.defaults)
        // Opened on first start, so history that was never on reads nothing.
        let store = self.store ?? ClipboardStore(directory: directory, persist: persist, limit: limit,
                                                 maxAge: maxAge, now: clock)
        self.store = store
        store.markPrivate()
        store.setRetention(limit: limit, maxAge: maxAge)
        store.sweepOrphanImages()
        sync()
        if !paused { startWatching() }
        registerHotKey()
        scheduleExpiry()
    }

    func stop() {
        guard context != nil else { return }
        stopWatching()
        unregisterHotKey()
        picker.close(restoreFocus: true)
        expiryTask?.cancel()
        expiryTask = nil
        imageTask?.cancel()
        pasteTask?.cancel()
        context = nil
    }

    // `disabled()`: nothing beyond `stop`. History is the user's; Clear deletes it.

    func tileView() -> AnyView { AnyView(ClipboardTile(widget: self)) }
    func settingsView() -> AnyView? { AnyView(ClipboardSettings(widget: self)) }

    func peekView(id: String) -> AnyView? {
        guard id == Self.copiedPeekID, isRunning else { return nil }
        return AnyView(ClipCopiedPeek())
    }

    private func readSettings(_ d: UserDefaults) {
        paused = d.bool(forKey: Keys.paused)
        let l = d.integer(forKey: Keys.limit)
        limit = Self.limitChoices.contains(l) ? l : ClipboardHistory.defaultLimit
        let k = d.integer(forKey: Keys.keepDays)
        keepDays = Self.keepDayChoices.contains(k) ? k : 7
        hotKeyChoice = d.string(forKey: ClipHotKey.defaultsKey).flatMap(ClipHotKey.init(rawValue:)) ?? .default
    }

    // MARK: - Watching

    private func startWatching() {
        guard isRunning, !paused, watcher == nil else { return }
        let w = ClipboardWatcher(pasteboard: pasteboard, frontmost: frontmost, schedule: schedule, now: clock)
        w.excluded = { [weak self] in Set(self?.context?.config.config.memory.excludeApps ?? CaptureSettings.defaultExcludeApps) }
        w.onCapture = { [weak self] capture, source in self?.captured(capture, source: source) }
        watcher = w
        w.start()
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Pause (menu bar, tile, Settings): stops all pasteboard reads at once.
    func setPaused(_ on: Bool) {
        paused = on
        context?.defaults.set(on, forKey: Keys.paused)
        if on {
            stopWatching()
            imageTask?.cancel()
        } else {
            startWatching()
        }
    }

    private func captured(_ capture: ClipboardWatcher.Capture, source: String?) {
        guard let store, isRunning, !paused else { return }
        switch capture {
        case .item(let kind):
            if store.record(kind, source: source) != nil { afterChange() }
        case .image(let data, let isPNG):
            imageTask = Task { [weak self] in
                let png = await Task.detached(priority: .utility) { Self.pngAndSize(data, isPNG: isPNG) }.value
                // Paused or turned off meanwhile: dropped.
                guard !Task.isCancelled, let self, let store = self.store, self.isRunning, !self.paused,
                      let png else { return }
                if store.recordImage(png: png.data, width: png.width, height: png.height, source: source) != nil {
                    self.afterChange()
                }
            }
        }
    }

    nonisolated static func pngAndSize(_ data: Data, isPNG: Bool) -> (data: Data, width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let png = isPNG ? data : rep.representation(using: .png, properties: [:])
        guard let png, png.count <= ClipboardStore.maxImageBytes else { return nil }
        return (png, rep.pixelsWide, rep.pixelsHigh)
    }

    // MARK: - Hot key and picker

    private func registerHotKey() {
        unregisterHotKey()
        guard isRunning else { return }
        let choice = hotKeyChoice
        hotKey = makeHotKey(choice.keyCode, choice.carbonModifiers) { [weak self] in self?.openPicker() }
        hotKeyActive = hotKey != nil
        if hotKey == nil { Self.log.error("clipboard shortcut \(choice.rawValue, privacy: .public) is taken") }
    }

    private func unregisterHotKey() {
        hotKey?.unregister()
        hotKey = nil
        hotKeyActive = false
    }

    func setHotKey(_ choice: ClipHotKey) {
        hotKeyChoice = choice
        context?.defaults.set(choice.rawValue, forKey: ClipHotKey.defaultsKey)
        if isRunning { registerHotKey() }
    }

    func openPicker() {
        guard isRunning else { return }
        picker.toggle()
    }

    // MARK: - Copy and paste

    /// Puts `item` on the pasteboard (not recorded again: the watcher skips our write) and
    /// moves it to the top. False when its content is gone (an image file deleted).
    @discardableResult
    func copy(_ item: ClipItem) -> Bool {
        guard let content = content(of: item) else {
            NSSound.beep()
            return false
        }
        let count = pasteboard.write(content)
        watcher?.ignore(changeCount: count)
        store?.touch(item.id)
        sync()
        return true
    }

    /// The picker's ↩: copy, give the keyboard back to `target`, and post ⌘V when
    /// Accessibility allows; otherwise say "Copied — press ⌘V".
    func paste(_ item: ClipItem, to target: PasteTarget?) {
        guard copy(item) else { return }
        // A newer pick wins: an older paste still waiting for focus never posts ⌘V.
        pasteTask?.cancel()
        let paster = self.paster
        pasteTask = Task { [weak self] in
            let outcome = await paster.finish(target: target)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.copiedOnly = outcome == .copied
            if outcome == .copied, let context = self.context {
                context.peek(id: Self.copiedPeekID, until: self.clock().addingTimeInterval(Self.copiedPeekDuration))
            }
        }
    }

    private func content(of item: ClipItem) -> ClipContent? {
        switch item.kind {
        case .text(let t): return .text(t)
        case .url(let u): return .url(u)
        case .files(let urls): return .files(urls)
        case .image:
            guard let url = store?.imageURL(for: item), let data = try? Data(contentsOf: url) else { return nil }
            return .png(data)
        }
    }

    /// The image of an `.image` item (thumbnails).
    func imageURL(for item: ClipItem) -> URL? { store?.imageURL(for: item) }

    // MARK: - Items and settings

    func remove(_ id: UUID) {
        store?.remove(id)
        afterChange()
    }

    func togglePin(_ item: ClipItem) {
        store?.setPinned(item.id, !item.pinned)
        afterChange()
    }

    /// "Clear history" keeps pinned items; "Clear all" does not. Images go with them.
    func clear(keepingPinned: Bool) {
        store?.clear(keepingPinned: keepingPinned)
        afterChange()
    }

    func deleteKeptFiles() {
        store?.deleteKeptFiles()
        sync()
    }

    func setLimit(_ value: Int) {
        guard Self.limitChoices.contains(value) else { return }
        limit = value
        context?.defaults.set(value, forKey: Keys.limit)
        store?.setRetention(limit: limit, maxAge: maxAge)
        afterChange()
    }

    func setKeepDays(_ value: Int) {
        guard Self.keepDayChoices.contains(value) else { return }
        keepDays = value
        context?.defaults.set(value, forKey: Keys.keepDays)
        store?.setRetention(limit: limit, maxAge: maxAge)
        afterChange()
    }

    private func afterChange() {
        sync()
        scheduleExpiry()
    }

    private func sync() {
        let now = store?.items ?? []
        if now != items { items = now }
        let kept = store?.hasKeptFiles ?? false
        if kept != hasKeptFiles { hasKeptFiles = kept }
        picker.historyChanged()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard isRunning, let next = store?.nextExpiry else { return }
        let delay = min(max(next.timeIntervalSince(clock()), 1), Self.maxExpirySleep)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.store?.trim()
            self.afterChange()
        }
    }

    /// The launch cleanup while the widget is off: expired items (and their images) go in
    /// one bounded pass, no timers (the shelf's rule). Reads the saved limit and age.
    static func expireWhileOff(directory: URL = CorePaths.clipboard(), defaults: UserDefaults = .standard) {
        let l = defaults.integer(forKey: Keys.limit)
        let k = defaults.integer(forKey: Keys.keepDays)
        ClipboardStore.expireOnDisk(directory: directory,
                                    limit: limitChoices.contains(l) ? l : ClipboardHistory.defaultLimit,
                                    maxAge: TimeInterval(keepDayChoices.contains(k) ? k : 7) * 86400)
    }
}

// MARK: - Views

/// The Today tile: the latest few items (click copies), pause and the picker.
struct ClipboardTile: View {
    static let shown = 4
    let widget: ClipboardWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Clipboard", systemImage: "doc.on.clipboard").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(widget.paused ? "Resume" : "Pause") { widget.setPaused(!widget.paused) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help(widget.paused ? "Record copies again" : "Stop recording copies")
                Button { widget.openPicker() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Search history (\(widget.hotKeyChoice.display))")
                    .accessibilityLabel("Search clipboard history")
            }
            if widget.paused {
                Text("Paused: nothing you copy is recorded.")
                    .font(.system(size: 11)).foregroundStyle(Theme.color(.attention))
            }
            if widget.items.isEmpty {
                Text("Things you copy appear here. Press \(widget.hotKeyChoice.display) anywhere to search and paste them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            } else {
                ForEach(widget.items.prefix(Self.shown)) { item in
                    Button { widget.copy(item) } label: {
                        ClipRow(item: item, imageURL: widget.imageURL(for: item), compact: true)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
        }
    }
}

/// "Copied — press ⌘V" (Accessibility missing, or the target was PlatyNotch itself).
struct ClipCopiedPeek: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard.fill").font(.system(size: 16)).foregroundStyle(Theme.color(.active))
            Text("Copied — press ⌘V").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One history row (tile and picker).
struct ClipRow: View {
    let item: ClipItem
    let imageURL: URL?
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: compact ? 18 : 28, height: compact ? 18 : 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title)
                    .font(.system(size: compact ? 11 : 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !compact {
                    Text(item.copiedAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .image:
            ClipThumbnail(url: imageURL, side: compact ? 18 : 28)
        case .text: Image(systemName: "text.alignleft").foregroundStyle(.secondary)
        case .url: Image(systemName: "link").foregroundStyle(.secondary)
        case .files: Image(systemName: "doc").foregroundStyle(.secondary)
        }
    }
}

/// An image row's thumbnail, decoded and scaled off the main thread (ImageIO), so a long
/// history of large screenshots never stalls the picker.
struct ClipThumbnail: View {
    let url: URL?
    let side: CGFloat
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            let pixels = Int(side * 2)
            image = await Task.detached(priority: .utility) { ClipThumbnail.load(url, maxPixels: pixels) }.value
        }
    }

    nonisolated static func load(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Settings › Widgets › Clipboard history.
struct ClipboardSettings: View {
    let widget: ClipboardWidget
    @State private var trusted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PlatyNotch keeps what you copy so you can paste it again: press \(widget.hotKeyChoice.display) anywhere to search history, ↩ to paste, ⌘1–9 for the first nine, ⌘P to pin, ⌫ to delete.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Never recorded: anything copied in a password manager (1Password, Bitwarden, LastPass, Keychain Access, Passwords) or in an app on Memory's excluded list, and anything an app marks as a password or as temporary. The app is the one in front when the copy happens, a best guess, since macOS does not say which app copied.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Passwords, keys and card numbers are never saved: copied text that looks like an API key, token, private key or card number is skipped.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("History stays on this Mac in PlatyNotch's private folder. Turning the widget off keeps it; Clear deletes it, images too.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Pause clipboard history", isOn: Binding(get: { widget.paused }, set: { widget.setPaused($0) }))
            HStack {
                Picker("Keep", selection: Binding(get: { widget.keepDays }, set: { widget.setKeepDays($0) })) {
                    ForEach(ClipboardWidget.keepDayChoices, id: \.self) { d in Text(d == 1 ? "1 day" : "\(d) days").tag(d) }
                }
                .fixedSize()
                Picker("Up to", selection: Binding(get: { widget.limit }, set: { widget.setLimit($0) })) {
                    ForEach(ClipboardWidget.limitChoices, id: \.self) { n in Text("\(n) items").tag(n) }
                }
                .fixedSize()
            }
            Text("Pinned items are kept whatever the age or limit.").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Shortcut", selection: Binding(get: { widget.hotKeyChoice }, set: { widget.setHotKey($0) })) {
                ForEach(ClipHotKey.allCases, id: \.self) { k in Text(k.display).tag(k) }
            }
            .fixedSize()
            if widget.isRunning, !widget.hotKeyActive {
                Text("Another app uses \(widget.hotKeyChoice.display). Pick another shortcut.")
                    .foregroundStyle(Theme.color(.attention))
            }
            HStack {
                Button("Clear History") { widget.clear(keepingPinned: true) }
                    .disabled(!widget.items.contains { !$0.pinned })
                    .help("Deletes every unpinned item and its image")
                Button("Clear All, Including Pinned") { widget.clear(keepingPinned: false) }
                    .disabled(widget.items.isEmpty)
            }
            if widget.hasKeptFiles {
                Text("A damaged history file was set aside, with the images it listed, so nothing was lost.")
                    .foregroundStyle(Theme.color(.attention))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.open(widget.directory) }
                    Button("Delete Kept Files") { widget.deleteKeptFiles() }
                }
            }
            Divider()
            if trusted {
                Label("↩ pastes into the app you were using.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("To paste with ↩, PlatyNotch needs Accessibility (to press ⌘V for you). Without it, ↩ copies and you press ⌘V.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow Accessibility…") {
                        widget.trust.request()
                        trusted = widget.trust.isTrusted()
                    }
                    Button("Check Again") { trusted = widget.trust.isTrusted() }
                }
            }
        }
        .font(.system(size: 12))
        .onAppear { trusted = widget.trust.isTrusted() }
    }
}
