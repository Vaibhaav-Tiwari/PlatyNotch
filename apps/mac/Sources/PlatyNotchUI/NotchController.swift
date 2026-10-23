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
    private var displayID: CGDirectDisplayID?

    private var cursor = NSEvent.mouseLocation
    private var fullScreen = false
    private var suppressed = false
    private var lastApprovalCount = 0
    private var lastNotice: Notice?
    private var deadlineTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    public init(store: AppStore, client: CoreClient, plugins: [NotchPlugin],
                minimal: Bool = UserDefaults.standard.bool(forKey: NotchSettings.minimal)) {
        self.store = store
        self.client = client
        self.plugins = plugins
        self.machine = PanelStateMachine(minimal: minimal)
        model.onClick = { [weak self] in self?.handle(.click) }
        tracker.onMove = { [weak self] p in self?.cursorMoved(p) }
    }

    public var mode: PanelMode { machine.mode }
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
        refreshFullScreen()
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
        panel.ignoresMouseEvents = !(visible && PanelLayout.contains(layout.hitRect(for: mode), cursor))
    }

    private func handle(_ event: PanelEvent) {
        machine.handle(event)
        apply()
    }

    // MARK: - Hover

    private func cursorMoved(_ p: CGPoint) {
        cursor = p
        apply()
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
        tracker.engaged = debouncer.isHovering || debouncer.deadline != nil || (fullScreen && !suppressed)
    }

    /// Re-samples the cursor when a pending hover change is due, even if it stopped moving.
    private func scheduleDeadline(now: TimeInterval) {
        deadlineTask?.cancel()
        guard let deadline = debouncer.deadline else { return }
        let delay = max(0, deadline - now) + 0.005
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.cursorMoved(NSEvent.mouseLocation)
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
        let n = store.approvals.count
        if n != lastApprovalCount {
            lastApprovalCount = n
            machine.handle(.approvalsChanged(count: n))
        }
        if let notice = store.notices.last, notice != lastNotice {
            lastNotice = notice
            machine.handle(.notice)
            noticeTask?.cancel()
            noticeTask = Task { [weak self] in
                try? await Task.sleep(for: NotchController.noticeDuration)
                guard !Task.isCancelled else { return }
                self?.handle(.noticeTimeout)
            }
        }
        apply()
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
        var bounds: [CGRect] = []
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for w in info {
                guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                      (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let dict = w[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
                bounds.append(r)
            }
        }
        fullScreen = FullScreenPolicy.isFullScreen(windowBounds: bounds, displayBounds: CGDisplayBounds(displayID))
        apply()
        tracker.engaged = debouncer.isHovering || debouncer.deadline != nil || (fullScreen && !suppressed)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
