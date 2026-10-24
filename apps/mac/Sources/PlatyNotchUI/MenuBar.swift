import AppKit
import Observation
import PlatyNotchKit

/// The menu bar item: Platy's silhouette as a template icon (`PlatyMenuIcon`) with a dot
/// while capture is running. Menu: Open PlatyNotch, Settings…, Check for Updates… (or the
/// GitHub Releases page when updates are off), Pause/Resume capture, Pause/Resume
/// clipboard history (only while that widget is on, C23), Quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let capture: CaptureService?
    private let onOpen: () -> Void
    private let onSettings: () -> Void
    private let updater: AppUpdater?
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause capture for 1 hour", action: nil, keyEquivalent: "")
    private let clipboardItem = NSMenuItem(title: "Pause clipboard history", action: nil, keyEquivalent: "")
    private let clipboard: ClipboardMenuControl?
    private var observing = false
    private let surfaces: PanelSurfaces?
    /// "Stop <title>" items at the top while anything rings, then a separator.
    private var stopMenuItems: [NSMenuItem] = []

    init(capture: CaptureService?, updater: AppUpdater? = nil, surfaces: PanelSurfaces? = nil,
         clipboard: ClipboardMenuControl? = nil,
         onOpen: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.capture = capture
        self.clipboard = clipboard
        self.updater = updater
        self.surfaces = surfaces
        self.onOpen = onOpen
        self.onSettings = onSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.setAccessibilityLabel("PlatyNotch")
        buildMenu()
        observeCapture()
        observeRinging()
    }

    /// One "Stop <title>" item per ringing alarm or timer, oldest first.
    static func stopItems(_ rings: [RingingItem]) -> [(title: String, id: String)] {
        rings.map { ("Stop \($0.title)", $0.id) }
    }

    /// Keeps the Stop items in step with `PanelSurfaces.rings` (also while the menu is open).
    private func observeRinging() {
        guard let surfaces, let menu = item.menu else { return }
        let rings = withObservationTracking {
            surfaces.rings
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeRinging() }
        }
        for old in stopMenuItems { menu.removeItem(old) }
        stopMenuItems = []
        let items = Self.stopItems(rings)
        guard !items.isEmpty else { return }
        for (i, entry) in items.enumerated() {
            let mi = NSMenuItem(title: entry.title, action: #selector(stopRinging(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = entry.id
            menu.insertItem(mi, at: i)
            stopMenuItems.append(mi)
        }
        let sep = NSMenuItem.separator()
        menu.insertItem(sep, at: items.count)
        stopMenuItems.append(sep)
    }

    @objc private func stopRinging(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        surfaces?.stopRinging(id: id)
    }

    /// Whether the icon currently shows the capture dot (for smoke checks).
    private(set) var showsDot = false

    /// A menu whose items keep the `isEnabled` this controller sets (AppKit's automatic
    /// enabling would turn on every item that has a target).
    static func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    /// The pause item: off and missing Accessibility mean there is nothing to pause.
    static func pauseItemState(_ status: CaptureStatus) -> (title: String, enabled: Bool) {
        switch status {
        case .paused(let until):
            let f = DateFormatter()
            f.timeStyle = .short
            return ("Resume capture (paused until \(f.string(from: until)))", true)
        case .capturing:
            return ("Pause capture for 1 hour", true)
        case .off, .needsAccessibility:
            return ("Pause capture for 1 hour", false)
        }
    }

    /// The clipboard item: hidden while the clipboard widget is off (nothing to pause).
    static func clipboardItemState(running: Bool, paused: Bool) -> (title: String, hidden: Bool) {
        (paused ? "Resume clipboard history" : "Pause clipboard history", !running)
    }

    /// The updates item: Sparkle's own check when updates are on (disabled while a check
    /// is already running), otherwise a link to GitHub Releases that always works.
    static func updatesItemState(isEnabled: Bool, canCheck: Bool) -> (title: String, enabled: Bool) {
        isEnabled ? ("Check for Updates…", canCheck) : ("Download Updates from GitHub Releases…", true)
    }

    private func buildMenu() {
        let menu = Self.newMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open PlatyNotch", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        if let updater {
            updatesItem.title = Self.updatesItemState(isEnabled: updater.isEnabled, canCheck: false).title
            updatesItem.action = #selector(checkForUpdates)
            updatesItem.target = self
            menu.addItem(updatesItem)
        }
        menu.addItem(.separator())
        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        menu.addItem(pauseItem)
        clipboardItem.action = #selector(toggleClipboardPause)
        clipboardItem.target = self
        clipboardItem.isHidden = true
        menu.addItem(clipboardItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PlatyNotch", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let updater {
            let state = Self.updatesItemState(isEnabled: updater.isEnabled, canCheck: updater.canCheckForUpdates)
            updatesItem.title = state.title
            updatesItem.isEnabled = state.enabled
        }
        let clip = Self.clipboardItemState(running: clipboard?.isRunning ?? false, paused: clipboard?.paused ?? false)
        clipboardItem.title = clip.title
        clipboardItem.isHidden = clip.hidden
        clipboardItem.isEnabled = !clip.hidden
        guard let capture else { pauseItem.isHidden = true; return }
        let state = Self.pauseItemState(capture.status)
        pauseItem.title = state.title
        pauseItem.isEnabled = state.enabled
    }

    @objc private func open() { onOpen() }
    @objc private func settings() { onSettings() }
    @objc private func checkForUpdates() { updater?.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleClipboardPause() {
        guard let clipboard, clipboard.isRunning else { return }
        clipboard.setPaused(!clipboard.paused)
    }

    /// The menu as built (smoke checks and tests): item titles, hidden ones included.
    var menuTitles: [String] { item.menu?.items.map(\.title) ?? [] }
    var menuAutoenables: Bool { item.menu?.autoenablesItems ?? true }

    @objc private func togglePause() {
        guard let capture else { return }
        if case .paused = capture.status { capture.resume() } else { capture.pause(for: 3600) }
    }

    private func observeCapture() {
        let capturing = capture?.isCapturing ?? false
        updateIcon(capturing: capturing)
        guard let capture else { return }
        withObservationTracking {
            _ = capture.status
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCapture() }
        }
    }

    private func updateIcon(capturing: Bool) {
        showsDot = capturing
        item.button?.image = Self.icon(dot: capturing)
        item.button?.toolTip = capturing ? "PlatyNotch — capturing on-screen text" : "PlatyNotch"
    }

    /// Platy's monochrome silhouette with an optional dot, as a template image.
    static func icon(dot: Bool) -> NSImage {
        PlatyMenuIcon.image(dot: dot)
    }
}
