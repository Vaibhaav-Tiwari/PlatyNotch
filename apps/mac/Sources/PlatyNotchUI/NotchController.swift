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
    private let extraTabs: [PanelTab]
    private let onOpenTerminal: (Session) -> Void
    private let responder: ApprovalResponder
    private let today: TodayServices
    private let widgets: WidgetRegistry
    private let surfaces: PanelSurfaces
    private let memory: MemoryServices

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
    private var expiryTask: Task<Void, Never>?
    /// A drag session is in progress (`PanelSurfaces`): the cursor is polled and the drop
    /// zone opens near the notch.
    private var dragSession = false
    /// Whether the left mouse button is down (a drag cannot be in progress otherwise).
    var mouseDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    private var workspaceObservers: [NSObjectProtocol] = []

    /// `carryOver` restores the panel state of the controller this one replaces (display change).
    /// Without it, notices already in the store count as shown.
    /// `extraTabs` follow the built-in tabs (plugin tabs); `onOpenTerminal` focuses a session's terminal.
    /// Pass one `responder`, one `today` and one `widgets` to every display's controller so
    /// answers, the focus session, loop changes and live activities are shared; likewise one `memory`.
    public init(store: AppStore, client: CoreClient, plugins: [NotchPlugin],
                responder: ApprovalResponder? = nil,
                today: TodayServices? = nil,
                widgets: WidgetRegistry? = nil,
                surfaces: PanelSurfaces? = nil,
                memory: MemoryServices? = nil,
                extraTabs: [PanelTab] = [],
                onOpenTerminal: @escaping (Session) -> Void = { _ in },
                minimal: Bool = UserDefaults.standard.bool(forKey: NotchSettings.minimal),
                carryOver: PanelCarryOver? = nil) {
        self.store = store
        self.client = client
        self.plugins = plugins
        self.extraTabs = extraTabs
        self.onOpenTerminal = onOpenTerminal
        self.responder = responder ?? ApprovalResponder(client: client)
        self.today = today ?? TodayServices(client: client)
        self.widgets = widgets ?? WidgetRegistry(persist: false)
        self.surfaces = surfaces ?? PanelSurfaces(registry: self.widgets)
        self.memory = memory ?? MemoryServices(client: client)
        if let carryOver {
            machine = carryOver.machine
            machine.minimal = minimal
            feed = carryOver.feed
        } else {
            machine = PanelStateMachine(minimal: minimal)
            feed = PanelFeed(noticeSequence: store.noticeSequence)
        }
        // An open panel must still close when the cursor is away after a rebuild.
        debouncer.reset(hovering: machine.mode == .expanded)
        model.onClick = { [weak self] in self?.handle(.click) }
        model.onStopRinging = { [weak self] id in self?.surfaces.stopRinging(id: id) }
        tracker.onMove = { [weak self] _ in self?.sampleCursor() }
        self.surfaces.attach(self)   // replays rings, a current peek / HUD and the drag session
    }

    public var mode: PanelMode { machine.mode }
    /// A HUD drawn as a thin line inside the approval peek or open panel.
    public var hudIndicator: HUDState? { machine.hudIndicator }
    /// Something ringing shown as the header chip (under an approval or the open panel).
    public var ringingChip: RingingItem? {
        machine.ringingChip.map { id in surfaces.rings.first { $0.id == id } ?? RingingItem(id: id, title: "Alarm") }
    }
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

    /// Opens the panel (menu bar "Open PlatyNotch", `platynotch://open`, a widget), at a
    /// tab id when given.
    public func expand(tab: String? = nil) {
        if let tab { model.selectedTab = tab }
        guard machine.mode != .expanded else { return }
        handle(.click)
    }

    /// Removes the panel and stops all monitoring.
    public func detach() {
        surfaces.detach(self)
        tracker.stop()
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObservers = []
        for t in [deadlineTask, noticeTask, recheckTask, expiryTask] { t?.cancel() }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        layout = nil
    }

    // MARK: - Window

    private func makePanel(frame: CGRect) -> NotchPanel {
        let p = NotchPanel(frame: frame)
        let host = NotchHostingView(rootView: PanelRootView(model: model, store: store, responder: responder,
                                                            today: today, widgets: widgets, memory: memory,
                                                            extraTabs: extraTabs, onOpenTerminal: onOpenTerminal))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.onEscape = { [weak self] in self?.handle(.escape) }
        return p
    }

    /// Pushes the current mode, full-screen suppression and cursor into the window.
    private func apply() {
        defer { surfaces.sinkStateChanged() }   // the media-key tap's view of where a HUD would show
        guard let panel, let layout else { return }
        cursor = NSEvent.mouseLocation   // never decide pass-through from a stale position
        let mode = machine.mode
        suppressed = FullScreenPolicy.shouldSuppress(
            fullScreen: fullScreen, mode: mode, cursor: cursor, revealRect: layout.revealRect,
            hitRect: layout.fullScreenHoldRect(for: mode), wasSuppressed: suppressed)
        let visible = mode != .hidden && !suppressed
        model.mode = mode
        model.visible = visible
        model.hud = machine.hud
        model.hudIndicator = machine.hudIndicator
        model.ringingChip = ringingChip
        noteVisibleApprovals(mode: mode, visible: visible)
        panel.hasShadow = mode.hasShadow && visible
        panel.allowsKey = mode.canBecomeKey
        if !mode.canBecomeKey && panel.isKeyWindow {
            // Hand keyboard focus back: ordering out drops key status, then re-show without it.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        // The drop zone takes the whole window as soon as it shows (C20).
        panel.ignoresMouseEvents = PanelLayout.ignoresMouse(mode: mode, visible: visible, layout: layout, cursor: cursor)
        updateEngaged()
    }

    /// Arms approval cards only once they are actually on screen in a fixed position.
    private func noteVisibleApprovals(mode: PanelMode, visible: Bool) {
        let ordered = ApprovalFormat.ordered(store.approvals).map(\.id)
        let ids: [String]
        switch mode {
        case _ where !visible: ids = []
        case .peek(.approval): ids = Array(ordered.prefix(1))
        case .expanded: ids = ordered
        default: ids = []
        }
        var arming = model.arming
        if arming.noteVisible(ids, at: Date()) { model.arming = arming }
    }

    /// Poll the cursor while anything depends on it moving: a hover or pending debounce,
    /// a revealed full-screen panel, or a window currently catching clicks (so leaving
    /// the hit rect always restores pass-through).
    private func updateEngaged() {
        tracker.engaged = debouncer.isHovering || debouncer.deadline != nil
            || (fullScreen && !suppressed) || panel?.ignoresMouseEvents == false
            || dragSession   // drag polling only while a drag is in progress
    }

    private func handle(_ event: PanelEvent) {
        let before = machine.mode
        machine.handle(event)
        // Hovering a peek, ringing card or drop zone never opens the panel, but the
        // debouncer saw the cursor arrive. When that surface goes, start over so hovering
        // the pill afterwards opens the panel.
        if before != machine.mode, Self.isNonOpening(before) { debouncer.reset(hovering: false) }
        apply()
        scheduleExpiry()
    }

    private static func isNonOpening(_ mode: PanelMode) -> Bool {
        switch mode {
        case .peek(.widget), .peek(.ringing), .peek(.drop): true
        default: false
        }
    }

    /// Ends a HUD or widget peek at its `until`, even if nothing else happens.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let due = machine.nextExpiry else { return }
        let delay = max(0, due.timeIntervalSinceNow) + 0.01
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.handle(.expire(now: Date()))
        }
    }

    // MARK: - Hover

    /// Re-reads the cursor (in `apply`) and feeds the hover debouncer.
    private func sampleCursor() {
        apply()
        let p = cursor
        guard let layout else { return }
        if dragSession { dragMoved(to: p) }
        let inside: Bool
        if suppressed {
            inside = false
        } else if fullScreen {
            inside = PanelLayout.contains(layout.fullScreenHoldRect(for: machine.mode), p)
        } else {
            inside = PanelLayout.contains(layout.hitRect(for: machine.mode), p)
        }
        hoverSample(inside: inside, at: ProcessInfo.processInfo.systemUptime)
        updateEngaged()
    }

    /// Feeds one hover sample (`inside` the hit rect at uptime `now`).
    func hoverSample(inside: Bool, at now: TimeInterval) {
        if let hovering = debouncer.update(inside: inside, at: now) {
            handle(hovering ? .hoverEnter : .hoverExit)
        }
        scheduleDeadline(now: now)
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

    // MARK: - Drag

    /// While a drag session is active: the drop zone opens when the cursor comes within
    /// `PanelLayout.dragReach` of the notch and closes when it leaves the drop zone.
    func dragMoved(to p: CGPoint) {
        guard dragSession, let layout else { return }
        // A session whose end was missed (button already up) never opens it on hover.
        let near = mouseDown() && layout.dragHover(p, showing: machine.isDragging)
        if near != machine.isDragging { handle(near ? .dragBegan : .dragEnded) }
    }

    // MARK: - Store

    private func observeStore() {
        withObservationTracking {
            _ = store.approvals.count
            _ = store.sessions
            _ = store.noticeSequence
            _ = store.connection
            _ = widgets.liveActivities   // Minimal mode: music, focus, timers keep the pill up
            _ = widgets.layout
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel != nil else { return }
                self.syncFromStore()
                self.observeStore()
            }
        }
    }

    private func syncFromStore() {
        responder.sync(store: store)
        machine.setLive(PanelMode.hasLive(sessions: store.sessions, activities: widgets.liveActivities, now: Date()))
        // During focus, notices are consumed without peeking; approvals still peek.
        // A session left running while the focus widget is off holds nothing.
        let holdNotices = today.focus.focusActive && widgets.isEnabled(FocusWidget.widgetID)
        for event in feed.update(approvalCount: store.approvals.count, noticeSequence: store.noticeSequence,
                                 holdNotices: holdNotices) {
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
        machine.setFullScreen(fullScreen)
        apply()
    }
}

// MARK: - Transient surfaces

extension NotchController: PanelSurfaceSink {
    public func receive(_ signal: PanelSurfaceSignal) {
        switch signal {
        case .peek(let id, let until): handle(.widgetPeek(id: id, until: until))
        case .endPeek(let id): handle(.widgetPeekEnded(id: id))
        case .ring(let id): handle(.ringStarted(id: id))
        case .stopRinging(let id): handle(.ringStopped(id: id))
        case .hud(let kind, let level, let until): handle(.hud(kind, level: level, until: until))
        case .dragSession(let active):
            dragSession = active
            if active {
                if panel != nil { sampleCursor() }
            } else if machine.isDragging {
                handle(.dragEnded)
            }
            updateEngaged()
        }
    }

    public var showsHUD: Bool {
        !suppressed && (machine.mode.isHUD || machine.hudIndicator != nil)
    }

    public var hudWouldShow: Bool { machine.hudWouldShow }

    /// What tests and `--smoke` feed the controller directly.
    enum DebugInput {
        case event(PanelEvent)
        case setFullScreen(Bool)
        case layout(PanelLayout)
        case display(CGDirectDisplayID)
    }

    func debugHandle(_ input: DebugInput) {
        switch input {
        case .event(let e): handle(e)
        case .setFullScreen(let on):
            fullScreen = on
            machine.setFullScreen(on)
            apply()
        case .layout(let l):
            layout = l
            model.layout = l
        case .display(let id):
            displayID = id
            surfaces.sinkStateChanged()
        }
    }

    /// Drives the panel through every transient surface and the precedence pairs that
    /// matter, then restores it. Returns the first failure, nil when all held.
    /// Used by `--smoke` (on the real panel, for a moment) and by unit tests (no window).
    func runSurfaceSmoke() -> String? {
        let saved = machine
        defer {
            machine = saved
            apply()
            scheduleExpiry()
        }
        let until = Date().addingTimeInterval(30)
        var step = machine
        step.setFullScreen(false)
        step.handle(.approvalsChanged(count: 0))
        step.handle(.hoverExit)
        step.handle(.noticeTimeout)
        // (event, mode after it, ringing chip after it)
        let checks: [(PanelEvent, PanelMode, String?)] = [
            (.widgetPeek(id: "smoke.peek", until: until), .peek(.widget(id: "smoke.peek")), nil),
            (.hud(.volume, level: 0.5, until: until), .peek(.hud(.volume)), nil),
            (.ringStarted(id: "smoke.ring"), .peek(.ringing(id: "smoke.ring")), nil),
            (.approvalsChanged(count: 1), .peek(.approval), "smoke.ring"),
            (.escape, .peek(.approval), "smoke.ring"),
            (.dragBegan, .peek(.approval), "smoke.ring"),
            (.approvalsChanged(count: 0), .peek(.ringing(id: "smoke.ring")), nil),
            (.click, .expanded, "smoke.ring"),
            (.click, .peek(.ringing(id: "smoke.ring")), nil),
            (.ringStopped(id: "smoke.ring"), .peek(.drop), nil),
            (.dragEnded, .peek(.hud(.volume)), nil),
            (.expire(now: until), .compact, nil),   // .hidden in Minimal mode with nothing live
        ]
        for (event, expected, chip) in checks {
            step.handle(event)
            machine = step
            apply()
            let ok = step.mode == expected || (expected == .compact && step.mode == .hidden && step.minimal)
            if !ok { return "after \(event) mode \(step.mode), expected \(expected)" }
            if step.ringingChip != chip { return "after \(event) ringing chip \(step.ringingChip ?? "none")" }
            guard let layout else { continue }
            if !layout.windowFrame.contains(layout.contentRect(for: step.mode)) {
                return "\(step.mode) does not fit the window"
            }
            if chip != nil, layout.ringingChipRect(for: step.mode) == nil { return "no chip place in \(step.mode)" }
        }
        return nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
