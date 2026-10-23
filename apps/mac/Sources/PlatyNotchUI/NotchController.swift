import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Owns the notch panel on one screen: feeds the panel state machine from the
/// store and the hover tracker, and applies the mode to the window.
/// Layout, debouncing and the full-screen rule live in `PlatyNotchKit`.
@MainActor
public final class NotchController {
    public static let noticeDuration: Duration = .seconds(4)
    /// Full-screen state is re-read this long after a space/app switch (the animation settles).
    static let fullScreenRecheck: Duration = .milliseconds(700)

    public let store: AppStore
    public let client: CoreClient
    private let plugins: [NotchPlugin]

    private var machine: PanelStateMachine
    private let model = PanelViewModel()
    private let tracker = HoverTracker()
    private var debouncer = HoverDebouncer()
    private var panel: NotchPanel?
    private var layout: PanelLayout?

    private var cursor = NSEvent.mouseLocation
    private var fullScreen = false
    private var suppressed = false
    private var feed: PanelFeed
    private var topInset: CGFloat = 0
    private var deadlineTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// `carryOver` restores the panel state of the controller this one replaces (display change).
    /// Without it, notices already in the store count as shown.
    public init(store: AppStore, client: CoreClient, plugins: [NotchPlugin],
                minimal: Bool = UserDefaults.standard.bool(forKey: NotchSettings.minimal),
                carryOver: PanelCarryOver? = nil) {
        self.store = store
        self.client = client
        self.plugins = plugins
        if let carryOver {
            machine = carryOver.machine
            machine.minimal = minimal
            feed = carryOver.feed
        } else {
            machine = PanelStateMachine(minimal: minimal)
            feed = PanelFeed(lastNotice: store.notices.last)
        }
        // An open panel must still close when the cursor is away after a rebuild.
        debouncer.reset(hovering: machine.mode == .expanded)
        model.onClick = { [weak self] in self?.handle(.click) }
        tracker.onMove = { [weak self] _ in self?.sampleCursor() }
    }

    public var mode: PanelMode { machine.mode }
    /// State to hand to a replacement controller.
    public var carryOver: PanelCarryOver { PanelCarryOver(machine: machine, feed: feed) }
    /// The display this controller's panel is on.
    public private(set) var displayID: CGDirectDisplayID?
    public var minimal: Bool {
        get { machine.minimal }
        set { machine.minimal = newValue; apply() }
    }
    /// True while the panel window is ordered in (the content may still be hidden).
    public var isOnScreen: Bool { panel?.isVisible ?? false }

    /// Places (or re-places) the panel on `screen`.
    public func attach(to screen: NSScreen) {
        let l = PanelLayout(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                            auxLeft: screen.auxiliaryTopLeftArea, auxRight: screen.auxiliaryTopRightArea)
        layout = l
        displayID = screen.displayID
        topInset = screen.safeAreaInsets.top
        model.layout = l

        let first = panel == nil
        let panel = self.panel ?? makePanel(frame: l.windowFrame)
        self.panel = panel
        panel.setFrame(l.windowFrame, display: true)
        panel.orderFrontRegardless()

        if first {
            tracker.start()
            observeWorkspace()
            observeStore()
        }
        syncFromStore()
        if machine.mode == .peek(.notice) { scheduleNoticeTimeout() }
        refreshFullScreen()
        sampleCursor()
    }

    /// Removes the panel and stops all monitoring.
    public func detach() {
        tracker.stop()
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObservers = []
        for t in [deadlineTask, noticeTask, recheckTask] { t?.cancel() }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        layout = nil
    }

    // MARK: - Window

    private func makePanel(frame: CGRect) -> NotchPanel {
        let p = NotchPanel(frame: frame)
        let host = NotchHostingView(rootView: PanelRootView(model: model, store: store))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.onEscape = { [weak self] in self?.handle(.escape) }
        return p
    }

    /// Pushes the current mode, full-screen suppression and cursor into the window.
    private func apply() {
        guard let panel, let layout else { return }
        cursor = NSEvent.mouseLocation   // never decide pass-through from a stale position
        let mode = machine.mode
        suppressed = FullScreenPolicy.shouldSuppress(
            fullScreen: fullScreen, mode: mode, cursor: cursor, revealRect: layout.revealRect,
            hitRect: layout.fullScreenHoldRect(for: mode), wasSuppressed: suppressed)
        let visible = mode != .hidden && !suppressed
        model.mode = mode
        model.visible = visible
        panel.hasShadow = mode.hasShadow && visible
        panel.allowsKey = mode.canBecomeKey
        if !mode.canBecomeKey && panel.isKeyWindow {
            // Hand keyboard focus back: ordering out drops key status, then re-show without it.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        panel.ignoresMouseEvents = PanelLayout.ignoresMouse(visible: visible, hitRect: layout.hitRect(for: mode),
                                                            cursor: cursor)
        updateEngaged()
    }

    /// Poll the cursor while anything depends on it moving: a hover or pending debounce,
    /// a revealed full-screen panel, or a window currently catching clicks (so leaving
    /// the hit rect always restores pass-through).
    private func updateEngaged() {
        tracker.engaged = debouncer.isHovering || debouncer.deadline != nil
            || (fullScreen && !suppressed) || panel?.ignoresMouseEvents == false
    }

    private func handle(_ event: PanelEvent) {
        machine.handle(event)
        apply()
    }

    // MARK: - Hover

    /// Re-reads the cursor (in `apply`) and feeds the hover debouncer.
    private func sampleCursor() {
        apply()
        let p = cursor
        guard let layout else { return }
        let inside: Bool
        if suppressed {
            inside = false
        } else if fullScreen {
            inside = PanelLayout.contains(layout.fullScreenHoldRect(for: machine.mode), p)
        } else {
            inside = PanelLayout.contains(layout.hitRect(for: machine.mode), p)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let hovering = debouncer.update(inside: inside, at: now) {
            handle(hovering ? .hoverEnter : .hoverExit)
        }
        scheduleDeadline(now: now)
        updateEngaged()
    }

    /// Re-samples the cursor when a pending hover change is due, even if it stopped moving.
    private func scheduleDeadline(now: TimeInterval) {
        deadlineTask?.cancel()
        guard let deadline = debouncer.deadline else { return }
        let delay = max(0, deadline - now) + 0.005
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.sampleCursor()
        }
    }

    // MARK: - Store

    private func observeStore() {
        withObservationTracking {
            _ = store.approvals.count
            _ = store.sessions
            _ = store.notices.last
            _ = store.connection
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel != nil else { return }
                self.syncFromStore()
                self.observeStore()
            }
        }
    }

    private func syncFromStore() {
        machine.setLive(PanelMode.hasLive(sessions: store.sessions))
        for event in feed.update(approvalCount: store.approvals.count, latestNotice: store.notices.last) {
            machine.handle(event)
            if event == .notice { scheduleNoticeTimeout() }
        }
        apply()
    }

    private func scheduleNoticeTimeout() {
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: NotchController.noticeDuration)
            guard !Task.isCancelled else { return }
            self?.handle(.noticeTimeout)
        }
    }

    // MARK: - Full screen

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fullScreenMayHaveChanged() }
            })
        }
    }

    private func fullScreenMayHaveChanged() {
        refreshFullScreen()
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(for: NotchController.fullScreenRecheck)
            guard !Task.isCancelled else { return }
            self?.refreshFullScreen()
        }
    }

    /// Whether the frontmost app has a window covering this display.
    private func refreshFullScreen() {
        guard let displayID else { return }
        let display = CGDisplayBounds(displayID)
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        var bounds: [CGRect] = []
        var menuBarVisible = false
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        for w in info {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue
            if layer == menuBarLevel, abs(r.minY - display.minY) <= 1, r.intersects(display) {
                menuBarVisible = true   // the menu bar is drawn at this display's top
            }
            if layer == 0, let pid, (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
                bounds.append(r)
            }
        }
        fullScreen = FullScreenPolicy.isFullScreen(windowBounds: bounds, displayBounds: display,
                                                   topInset: topInset, menuBarVisible: menuBarVisible)
        apply()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
