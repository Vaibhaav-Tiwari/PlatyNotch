import AppKit
import Observation
import PlatyNotchKit

/// The menu bar item: a template icon (placeholder until the Platy icon) with a dot
/// while capture is running. Menu: Open PlatyNotch, Settings…, Check for Updates… (or the
/// GitHub Releases page when updates are off), Pause/Resume capture, Quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let capture: CaptureService?
    private let onOpen: () -> Void
    private let onSettings: () -> Void
    private let updater: AppUpdater?
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause capture for 1 hour", action: nil, keyEquivalent: "")
    private var observing = false

    init(capture: CaptureService?, updater: AppUpdater? = nil,
         onOpen: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.capture = capture
        self.updater = updater
        self.onOpen = onOpen
        self.onSettings = onSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.setAccessibilityLabel("PlatyNotch")
        buildMenu()
        observeCapture()
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

    private func buildMenu() {
        let menu = Self.newMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open PlatyNotch", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        if let updater {
            updatesItem.title = updater.isEnabled ? "Check for Updates…" : "Download Updates from GitHub Releases…"
            updatesItem.action = #selector(checkForUpdates)
            updatesItem.target = self
            menu.addItem(updatesItem)
        }
        menu.addItem(.separator())
        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PlatyNotch", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let updater, updater.isEnabled { updatesItem.isEnabled = updater.canCheckForUpdates }
        guard let capture else { pauseItem.isHidden = true; return }
        let state = Self.pauseItemState(capture.status)
        pauseItem.title = state.title
        pauseItem.isEnabled = state.enabled
    }

    @objc private func open() { onOpen() }
    @objc private func settings() { onSettings() }
    @objc private func checkForUpdates() { updater?.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

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

    /// Placeholder glyph (a notch outline) with an optional dot, as a template image.
    static func icon(dot: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 4), xRadius: 3, yRadius: 3)
            body.lineWidth = 1.5
            body.stroke()
            let notch = NSBezierPath(roundedRect: NSRect(x: 6, y: 10.5, width: 6, height: 3.5), xRadius: 1.2, yRadius: 1.2)
            notch.fill()
            if dot {
                NSBezierPath(ovalIn: NSRect(x: 12.5, y: 0, width: 5.5, height: 5.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = dot ? "PlatyNotch, capturing" : "PlatyNotch"
        return image
    }
}
