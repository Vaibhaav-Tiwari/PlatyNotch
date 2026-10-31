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
    private let model: PanelViewModel = PanelViewModel()
    private let tracker = HoverTracker()
    private var debouncer = HoverDebouncer()
    private var panel: NotchPanel?
    private var layout: PanelLayout?
    private var reportedBody: CGFloat?
    /// A content shrink waiting for the pointer to leave the band it removes.
    private(set) var shrinkPending = false
    /// Where the upgrade hint's open count lives (the app's defaults); nil in tests and
    /// renders: no hint, nothing counted.
    var hintDefaults: UserDefaults?
    /// The panel was open at the last `apply` (the hint counts opens, not redraws).
    private var wasExpanded = false
    /// The drop target while the Shelf is off: AirDrop only.
    private let airDropTarget = AirDropDropTarget()

    private var cursor = NSEvent.mouseLocation
    /// A full-screen app covers this display (games pause, nudges wait, HUDs drop).
    private var fullScreen = false
    /// Settings › Appearance (`AppearanceStore`), applied live except the pill width
    /// (the app rebuilds the panels for that and for the displays).
    public var appearance: AppearanceSettings {
        didSet { if appearance != oldValue { applyAppearance() } }
    }
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
    /// This panel started the drag session itself: a drag reached its window that the
    /// shelf's detector did not report (it ends the session when the drag ends).
    private var windowStartedSession = false
    /// The button was released over the drop zone: it stays (and takes mouse events)
    /// until the drop arrives (`panelDragEnded`) or `dropGrace` passes.
    private var dropGraceTask: Task<Void, Never>?
    /// The drop (or the drag's end) reached this panel before the release was seen.
    private var dropDelivered = false
    static let dropGrace: Duration = .milliseconds(300)
    /// True while the drop zone waits for the drop after a release over it.
    var awaitingDrop: Bool { dropGraceTask != nil }
    /// Whether the left mouse button is down (a drag cannot be in progress otherwise).
    var mouseDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Where the cursor is now (tests pin it, so no result depends on the real mouse).
    var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Waits out `dropGrace` (tests inject one they release by hand).
    var graceSleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The clock approval arming notes cards against (tests move it).
    var armingClock: () -> Date = { Date() }
    /// Called each time Now comes on screen: the panel opens, or the hover peek shows its
    /// hero (the first run's "Try it"). After the view model has the new mode.
    var onExpanded: () -> Void = {}
    /// Called when Now leaves the screen again.
    var onCollapsed: () -> Void = {}
    private var nowShown = false

    /// The newest of `fresh` notices that may open the notch now: an agent notice by its row
    /// of Settings › Notifications, the app's own info notices unless a focus session holds them.
    static func toast(_ fresh: [Notice], policy: NotificationPolicy, focusActive: Bool) -> Notice? {
        fresh.last { n in
            guard let kind = NotificationPolicy.kind(noticeKind: n.kind) else { return !focusActive }
            return policy.mayOpen(kind, focusActive: focusActive)
        }
    }

    /// The modes that show Now's hero.
    static func showsHome(_ mode: PanelMode) -> Bool { mode == .expanded || mode == .peek(.hover) }
    /// The open panel's gear (the menu bar icon may be hidden): the app shows Settings.
    var onOpenSettings: () -> Void = {}
    /// The header toggles' services (the app's one); set before the panel first shows.
    var header: HeaderServices? { didSet { model.header = header } }
    /// The Agents empty state's "Connect an agent": the app shows Settings › Agents.
    var onOpenAgentSettings: () -> Void = {}
    /// What the panel's views read (tests press its buttons through it).
    var panelModel: PanelViewModel { model }
    private var workspaceObservers: [NSObjectProtocol] = []

    /// `carryOver` restores the panel state of the controller this one replaces (display change).
    /// Without it, notices already in the store count as shown.
    /// `extraTabs` are plugin tabs (Library tools); `onOpenTerminal` focuses a session's terminal.
    /// Pass one `responder`, one `today` and one `widgets` to every display's controller so
    /// answers, the focus session, loop changes and live activities are shared; likewise one `memory`.
    /// `appearance` is `AppearanceStore.load` in the app; tests pass their own.
    public init(store: AppStore, client: CoreClient, plugins: [NotchPlugin],
                responder: ApprovalResponder? = nil,
                today: TodayServices? = nil,
                widgets: WidgetRegistry? = nil,
                surfaces: PanelSurfaces? = nil,
                memory: MemoryServices? = nil,
                extraTabs: [PanelTab] = [],
                onOpenTerminal: @escaping (Session) -> Void = { _ in },
                appearance: AppearanceSettings = AppearanceSettings(),
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
        let settings = appearance.clamped()
        self.appearance = settings
        if let carryOver {
            machine = carryOver.machine
            machine.minimal = settings.mode == .minimal
            feed = carryOver.feed
        } else {
            machine = PanelStateMachine(minimal: settings.mode == .minimal)
            feed = PanelFeed(noticeSequence: store.noticeSequence)
        }
        machine.openOnHover = settings.openOn == .hover
        machine.peekOnHover = settings.openOn == .peekOnHover
        debouncer = HoverDebouncer(enterDelay: settings.hoverDelay)
        model.appearance = settings
        // An open panel must still close when the cursor is away after a rebuild.
        debouncer.reset(hovering: machine.mode == .expanded)
        model.onClick = { [weak self] in self?.handle(.click) }
        model.onBodyHeight = { [weak self] in self?.bodyHeightReported($0) }
        model.onStopRinging = { [weak self] id in self?.surfaces.stopRinging(id: id) }
        model.onOpenSettings = { [weak self] in self?.onOpenSettings() }
        model.onConnectAgent = { [weak self] in self?.onOpenAgentSettings() }
        tracker.onMove = { [weak self] _ in self?.sampleCursor() }
        self.surfaces.attach(self)   // replays rings, a current peek / HUD and the drag session
    }

    public var mode: PanelMode { machine.mode }
    /// A HUD drawn as a thin line inside the approval peek or open panel.
    public var hudIndicator: HUDState? { machine.hudIndicator }
    /// The current HUD (its own surface, or under the indicator).
    var hud: HUDState? { machine.hud }
    /// Something ringing shown as the header chip (under an approval or the open panel).
    public var ringingChip: RingingItem? {
        machine.ringingChip.map { id in surfaces.rings.first { $0.id == id } ?? RingingItem(id: id, title: "Alarm") }
    }
    /// State to hand to a replacement controller.
    public var carryOver: PanelCarryOver { PanelCarryOver(machine: machine, feed: feed) }
    /// The display this controller's panel is on.
    public private(set) var displayID: CGDirectDisplayID?
    /// True while the panel window is ordered in (the content may still be hidden).
    public var isOnScreen: Bool { panel?.isVisible ?? false }
    /// Whether the panel's content shows (not hidden, not suppressed over full screen).
    var contentVisible: Bool { model.visible }

    /// Mode, open trigger, hover delay, live side, theme, spring and full-screen hiding.
    private func applyAppearance() {
        let settings = appearance.clamped()
        machine.minimal = settings.mode == .minimal
        machine.openOnHover = settings.openOn == .hover
        machine.peekOnHover = settings.openOn == .peekOnHover
        if debouncer.enterDelay != settings.hoverDelay {
            let hovering = debouncer.isHovering
            debouncer = HoverDebouncer(enterDelay: settings.hoverDelay)
            debouncer.reset(hovering: hovering)
        }
        model.appearance = settings
        apply()
    }

    /// The open panel's body height as `ExpandedPanel.reportedBody` reports it (header,
    /// approvals region, Home or Agents), or nil while a tool is open: the panel is then full height.
    func bodyHeightReported(_ body: CGFloat?) {
        reportedBody = body
        applyBodyHeight()
    }

    /// Sizes the open panel to the reported body (clamped 160...380) and refreshes the
    /// window's mouse region. A shrink caused by the panel's own content (suggestions
    /// narrowing, a suggestion run, an approval answered) waits while the pointer rests in the
    /// band it would remove: shrinking there would read as a hover exit, close the panel and
    /// drop a half-typed command. It applies once the pointer is inside the smaller panel or
    /// has left the panel (`sampleCursor`).
    private func applyBodyHeight() {
        guard let current = layout else { return }
        var l = current
        let target: CGFloat = reportedBody.map { l.expandedHeight(forBody: $0) } ?? PanelLayout.expandedHeights.upperBound
        l.expandedContentHeight = target
        guard l != current else { shrinkPending = false; return }
        if Self.defersShrink(from: current, to: l, mode: machine.mode, cursor: cursorLocation()) {
            shrinkPending = true
            return
        }
        shrinkPending = false
        layout = l
        model.layout = l
        apply()
    }

    /// A content shrink waits while the open panel's pointer sits in the band it removes.
    static func defersShrink(from old: PanelLayout, to new: PanelLayout, mode: PanelMode, cursor: CGPoint) -> Bool {
        guard mode == .expanded else { return false }
        let before: CGRect = old.hitRect(for: .expanded)
        let after: CGRect = new.hitRect(for: .expanded)
        guard after.height < before.height else { return false }
        return PanelLayout.contains(before, cursor) && !PanelLayout.contains(after, cursor)
    }

    /// Full screen hides the panel only when Appearance says so (C32).
    private var hidesForFullScreen: Bool { fullScreen && appearance.hideInFullScreen }

    /// Places (or re-places) the panel on `screen`.
    public func attach(to screen: NSScreen) {
        let l = PanelLayout(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                            auxLeft: screen.auxiliaryTopLeftArea, auxRight: screen.auxiliaryTopRightArea,
                            pillWidth: appearance.pillWidth)
        layout = l
        displayID = screen.displayID
        topInset = screen.safeAreaInsets.top
        model.layout = l
        applyBodyHeight()

        let first = panel == nil
        let panel = self.panel ?? makePanel(frame: l.windowFrame)
        self.panel = panel
        panelIsKey = { [weak panel] in panel?.isKeyWindow ?? false }
        textFieldFocused = { [weak panel] in panel?.firstResponder is NSText }
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
    /// tab id when given: today's ids keep working through `PanelRoute.legacy` (`now`, `today`,
    /// `library` → Home, `focus`, `memory`, `games` → that feature inside Home, a plugin's tab id →
    /// its feature).
    public func expand(tab: String? = nil) {
        if let tab {
            model.route = PanelRoute.legacy(tab: tab, tools: ToolCatalog.ids(widgets: widgets, extraTabs: extraTabs))
        }
        guard machine.mode != .expanded else { return }
        handle(.click)
    }

    /// Settings › Home changed (or the panel was built): the right column.
    public func homeSettingsChanged(_ settings: HomeSettings) {
        if model.homeSettings != settings { model.homeSettings = settings }
    }

    /// Closes the open panel (the first run's "Meet Platy" demo).
    public func collapse() {
        guard machine.mode == .expanded else { return }
        handle(.click)
    }

    /// Escape: an open feature goes back to Home first; otherwise the state
    /// machine's `.escape` (the open panel closes).
    func escapePressed() {
        // The command line first: Esc clears its text, then leaves it; only then the panel.
        if machine.mode == .expanded, !model.commandText.isEmpty || model.commandFocused {
            if !model.commandText.isEmpty {
                model.commandText = ""
                model.commandMessage = nil
            } else {
                model.commandFocused = false
                model.commandActive = false
            }
            return
        }
        if machine.mode == .expanded, model.route.destination == .home, let tool = model.route.tool {
            // Back only from a tool that shows: one whose widget was turned off already
            // shows Home, so Esc closes (and the route is written back to Home).
            model.route = model.route.back()
            if ToolCatalog.ids(widgets: widgets, extraTabs: extraTabs).contains(tool) { return }
        }
        handle(.escape)
    }

    /// ⌘1 / ⌘2 in the open panel: Home, Agents (only while it shows). False (not used)
    /// elsewhere, so the approval peek and other modes keep their keys.
    @discardableResult
    func commandDigit(_ digit: Int) -> Bool {
        guard machine.mode == .expanded else { return false }
        let shown: [PanelDestination] = ExpandedPanel.destinations(agentsVisible: today.agentActivity.agentsVisibility.isVisible)
        let all: [PanelDestination] = [.home, .agents]
        guard (1...all.count).contains(digit) else { return false }
        let target: PanelDestination = all[digit - 1]
        guard shown.contains(target) else { return false }
        model.route = PanelRoute(destination: target)
        return true
    }

    /// Whether the panel has the keyboard (tests replace it; there is no window then).
    var panelIsKey: () -> Bool = { false }
    /// Whether a text field has focus (a typed key then belongs to it).
    var textFieldFocused: () -> Bool = { false }

    /// ⌘K in the open panel: Home, with the command line focused. False elsewhere, so the
    /// approval peek and other modes keep their keys.
    @discardableResult
    func commandK() -> Bool {
        guard machine.mode == .expanded, panelIsKey() else { return false }
        if model.route != PanelRoute(destination: .home) { model.route = PanelRoute(destination: .home) }
        model.commandFocused = true
        model.commandActive = true
        return true
    }

    /// A printable key while no text field has focus: it starts the command line (Home only:
    /// a tool such as a game keeps its keys).
    @discardableResult
    func typed(_ s: String) -> Bool {
        guard machine.mode == .expanded, panelIsKey(), !textFieldFocused(), !s.isEmpty,
              s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return false }
        if model.route.tool != nil, model.route.destination == .home { return false }
        if model.route.destination != .home { model.route = PanelRoute(destination: .home) }
        model.commandText += s
        model.commandFocused = true
        model.commandActive = true
        return true
    }

    /// The global command shortcut (⌥⌘K): from anywhere, opens Home with the command line
    /// focused and gives the panel the keyboard; pressed again while the command line has
    /// focus, closes the panel. Returns whether the panel is now open.
    @discardableResult
    func commandHotKey() -> Bool {
        if machine.mode == .expanded, model.commandFocused, panelIsKey() {
            collapse()
            return false
        }
        return openCommandLine()
    }

    /// Opens Home with the command line focused and the keyboard given: its list of
    /// everything it can do shows (the global shortcut, the menu's "What Platy can do…").
    @discardableResult
    func openCommandLine() -> Bool {
        if machine.mode != .expanded { handle(.click) }
        guard machine.mode == .expanded else { return false }
        if model.route != PanelRoute(destination: .home) { model.route = PanelRoute(destination: .home) }
        model.commandText = ""
        makePanelKey()
        model.commandFocused = true
        model.commandActive = true
        return true
    }

    /// The global shortcut changed: the command line's keycap and placeholder follow it.
    func commandHintChanged(_ hint: String) {
        if model.commandHint != hint { model.commandHint = hint }
    }

    /// Gives the open panel the keyboard on purpose (the global shortcut, a click in the
    /// command line). Hover never does: only these explicit gestures.
    func makePanelKey() {
        guard machine.mode == .expanded else { return }
        keyRequests += 1
        guard let panel else { return }
        panel.grantKey()
        panel.makeKey()
    }

    /// How often the panel was given the keyboard on purpose (tests: there is no window).
    private(set) var keyRequests = 0

    /// Removes the panel and stops all monitoring.
    public func detach() {
        surfaces.detach(self)
        tracker.stop()
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObservers = []
        for t in [deadlineTask, noticeTask, recheckTask, expiryTask, dropGraceTask] { t?.cancel() }
        dropGraceTask = nil
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
        // The drag destination exists from the start, so the first drag-enter after the
        // window stops ignoring mouse events reaches it (verify-widgets #16).
        host.registerForDraggedTypes(PanelDrop.types)
        host.dropRouter = self
        p.contentView = host
        p.onEscape = { [weak self] in self?.escapePressed() }
        model.requestKey = { [weak self] in self?.makePanelKey() }
        p.onCommandDigit = { [weak self] in self?.commandDigit($0) ?? false }
        p.onCommandK = { [weak self] in self?.commandK() ?? false }
        p.onTyped = { [weak self] in self?.typed($0) ?? false }
        return p
    }

    /// Pushes the current mode, full-screen suppression and cursor into the view model and
    /// the window. Without a window (tests) only the view model.
    private func apply() {
        // Now shows (open, or the hover peek's hero): told after the view model has the mode.
        let showsHome: Bool = Self.showsHome(machine.mode)
        let shownBefore: Bool = nowShown
        nowShown = showsHome
        defer {
            surfaces.sinkStateChanged()   // the media-key tap's view of where a HUD would show
            if showsHome, !shownBefore { onExpanded() } else if !showsHome, shownBefore { onCollapsed() }
        }
        let expanded: Bool = machine.mode == .expanded
        if expanded, !wasExpanded, let d = hintDefaults {
            // The one-line hint under the command line, on the first three opens.
            model.showCommandHint = CommandCatalog.showsHint(d)
            CommandCatalog.notePanelOpened(d)
        }
        wasExpanded = expanded
        if machine.mode != .expanded,
           model.commandFocused || model.commandActive || !model.commandText.isEmpty || model.commandMessage != nil {
            model.commandText = ""   // a closed panel keeps no half-typed command
            model.commandFocused = false
            model.commandActive = false
            model.commandMessage = nil
        }
        guard let layout else { return }
        cursor = cursorLocation()   // never decide pass-through from a stale position
        let mode = machine.mode
        // Approvals, ringing, the open panel and the drop zone are never suppressed.
        suppressed = FullScreenPolicy.shouldSuppress(
            fullScreen: fullScreen, hideInFullScreen: appearance.hideInFullScreen, mode: mode, cursor: cursor,
            revealRect: layout.revealRect, hitRect: layout.fullScreenHoldRect(for: mode), wasSuppressed: suppressed)
        let visible = mode != .hidden && !suppressed
        model.mode = mode
        model.visible = visible
        model.fullScreen = fullScreen
        model.hud = machine.hud
        model.hudIndicator = machine.hudIndicator
        model.ringingChip = ringingChip
        noteVisibleApprovals(mode: mode, visible: visible)
        guard let panel else { updateEngaged(); return }
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
    /// The key includes the placement (peek, open panel, header above the list), so a move
    /// between them re-arms every card (A1b).
    private func noteVisibleApprovals(mode: PanelMode, visible: Bool) {
        let ordered = ApprovalFormat.ordered(store.approvals).map(\.id)
        let placement = visible ? ApprovalPlacement(mode: mode, count: ordered.count) : nil
        let ids: [String]
        switch placement {
        case .peek: ids = Array(ordered.prefix(1))
        case .expanded: ids = ordered
        case nil: ids = []
        }
        var arming = model.arming
        if arming.noteVisible(ids, placement: placement ?? .peek, at: armingClock()) { model.arming = arming }
    }

    /// Approval arming for this panel (tests).
    var arming: ApprovalArming { model.arming }

    /// Poll the cursor while anything depends on it moving: a hover or pending debounce,
    /// a revealed full-screen panel, or a window currently catching clicks (so leaving
    /// the hit rect always restores pass-through).
    private func updateEngaged() {
        tracker.engaged = debouncer.isHovering || debouncer.deadline != nil
            || (hidesForFullScreen && !suppressed) || panel?.ignoresMouseEvents == false
            || dragSession   // drag polling only while a drag is in progress
    }

    private func handle(_ event: PanelEvent) {
        let before = machine.mode
        machine.handle(event)
        // Hovering a peek, ringing card or drop zone never opens the panel, but the
        // debouncer saw the cursor arrive. When that surface goes, start over so hovering
        // the pill afterwards opens the panel.
        // A drop that gives back the open panel counts as hovering it, so moving away closes it.
        if before != machine.mode, Self.isNonOpening(before) {
            let mode: PanelMode = machine.mode
            debouncer.reset(hovering: mode == .expanded || mode == .peek(.hover))
        }
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
    func sampleCursor() {
        if shrinkPending { applyBodyHeight() }
        apply()
        let p = cursor
        guard let layout else { return }
        if dragSession { dragMoved(to: p) }
        let inside: Bool
        if suppressed {
            inside = false
        } else if hidesForFullScreen {
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
        let down = mouseDown()
        // A session this window started (the detector missed the drag) ends at the
        // button-up, so it can never stay stuck and keep the cursor polled.
        if windowStartedSession, !down {
            endDrag(at: p, released: true)
            windowStartedSession = false
            surfaces.setDragSession(active: false)
            return
        }
        if awaitingDrop {
            guard down else { return }   // released on the zone: waiting for the drop
            cancelDropGrace()            // pressed again: a new drag, not the old drop
        }
        let near = down && layout.dragHover(p, showing: machine.isDragging)
        guard near != machine.isDragging else { return }
        if near {
            dropDelivered = false
            handle(.dragBegan)
        } else {
            endDrag(at: p, released: !down)
        }
    }

    /// Closes the drop zone. Left it (button down) or released elsewhere: at once, the
    /// panel rests. Released on it: the drop zone stays, still taking mouse events, until
    /// the drop reaches the panel (`panelDragEnded`) or `dropGrace` passes, because the
    /// button-up is often seen (monitor, poll, cursor sample) before AppKit delivers
    /// `performDragOperation`. Then a panel that was open when the drag began opens again.
    private func endDrag(at p: CGPoint, released: Bool) {
        guard machine.isDragging else { return }
        let onZone = layout.map { PanelLayout.contains($0.contentRect(for: .peek(.drop)), p) } ?? false
        guard released, onZone else {
            cancelDropGrace()
            handle(.dragEnded)
            return
        }
        if dropDelivered {
            finishDrop()
            return
        }
        guard dropGraceTask == nil else { return }
        let sleep = graceSleep
        dropGraceTask = Task { [weak self] in
            await sleep(NotchController.dropGrace)
            guard !Task.isCancelled else { return }
            self?.finishDrop()
        }
        updateEngaged()
    }

    /// The drop arrived or the grace passed: close the drop zone, giving back an open panel.
    private func finishDrop() {
        cancelDropGrace()
        dropDelivered = false
        if machine.isDragging { handle(.dragEndedInside) }
    }

    private func cancelDropGrace() {
        dropGraceTask?.cancel()
        dropGraceTask = nil
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
            _ = surfaces.notificationPolicy   // Settings › Notifications: the pill's hidden kinds
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
        // What the pill shows keeps Minimal up (approvals, sessions working or waiting,
        // non-ambient live items), from the same `PillContent` the pill draws.
        let policy: NotificationPolicy = surfaces.notificationPolicy
        let hidden: Set<NotificationKind> = policy.hiddenInPill
        if model.hiddenKinds != hidden { model.hiddenKinds = hidden }
        let pill = PillContent(activities: widgets.liveActivities, sessions: store.sessions,
                               approvals: store.approvals.count, hiddenKinds: hidden, now: Date())
        machine.setLive(pill.keepsMinimalUp)
        // A focus session left running while the focus widget is off holds nothing.
        let focus: Bool = today.focus.focusActive && widgets.isEnabled(FocusWidget.widgetID)
        // An agent notice follows its row of Settings › Notifications (can open, quiet
        // during Focus); the app's own info notices keep today's focus hold. Approvals
        // are never gated.
        // Of the notices that arrived since the last look, the newest one that may open is
        // the toast; none may: nothing peeks.
        let fresh: Int = min(max(store.noticeSequence - feed.noticeSequence, 0), store.notices.count)
        let shown: Notice? = Self.toast(Array(store.notices.suffix(fresh)), policy: policy, focusActive: focus)
        for event in feed.update(approvalCount: store.approvals.count, noticeSequence: store.noticeSequence,
                                 holdNotices: false, allowNotice: shown != nil) {
            machine.handle(event)
            if event == .notice {
                model.toastNotice = shown
                scheduleNoticeTimeout()
            }
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
                // A new drag inside the grace after a release: it owns the drop zone now,
                // so the old grace must not close it.
                cancelDropGrace()
                dropDelivered = false
                if panel != nil { sampleCursor() }
            } else {
                windowStartedSession = false
                endDrag(at: cursorLocation(), released: true)
            }
            updateEngaged()
        }
    }

    public var showsHUD: Bool {
        !suppressed && (machine.mode.isHUD || machine.hudIndicator != nil)
    }

    public var hudWouldShow: Bool { machine.hudWouldShow }

    public var coveredByFullScreen: Bool { fullScreen }

    /// What tests and `--smoke` feed the controller directly.
    enum DebugInput {
        case event(PanelEvent)
        case setFullScreen(Bool)
        case layout(PanelLayout)
        case display(CGDirectDisplayID)
        /// Re-reads the store and live activities now (the store observer's work; tests
        /// have no window, so nothing observes the store).
        case syncStore
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
        case .syncStore:
            syncFromStore()
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
            // Answered mid-drag: the drop zone, carrying the ringing chip (Task 5).
            (.approvalsChanged(count: 0), .peek(.drop), "smoke.ring"),
            (.click, .expanded, "smoke.ring"),
            (.click, .peek(.drop), "smoke.ring"),
            (.ringStopped(id: "smoke.ring"), .peek(.drop), nil),
            (.dragEnded, .peek(.hud(.volume)), nil),
            (.click, .expanded, nil),
            (.dragBegan, .peek(.drop), nil),
            (.dragEndedInside, .expanded, nil),   // a drop gives the open panel back
            (.click, .peek(.hud(.volume)), nil),
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
            // A notch too wide for the chip has none (the menu's Stop item remains).
            let roomy = !layout.hasNotch || layout.contentRect(for: step.mode).maxX - layout.anchor.maxX >= 64
            if chip != nil, roomy, layout.ringingChipRect(for: step.mode) == nil { return "no chip place in \(step.mode)" }
        }
        return nil
    }
}

// MARK: - Drops (the hosting view's drag destination)

extension NotchController: PanelDropRouting {
    /// The shelf's target (Shelf and AirDrop), else AirDrop alone while AirDrop exists.
    func dropTarget() -> PanelDropTarget? {
        widgets.dropTarget() ?? (ShelfActions.canAirDrop ? airDropTarget : nil)
    }

    /// Drags reach the window only where it takes mouse events: the drop zone (whole
    /// window), or the pill / open panel / approval peek under the cursor. A drag the
    /// shelf's detector missed starts the session here, so the drop zone still opens;
    /// the drop itself is taken only while the drop zone shows (never on an approval).
    func panelDragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        // Our own drags (a shelf item dragged out of the open panel) never open the drop
        // zone over the panel they come from, and are never dropped back.
        guard info.draggingSource == nil else { return [] }
        // No running widget takes drops (the shelf is off): no session, no placeholder.
        guard let target = dropTarget() else { return [] }
        if !dragSession, !surfaces.dragActive {
            windowStartedSession = true
            surfaces.setDragSession(active: true)
        }
        guard machine.mode.acceptsDrops else { return [] }
        return target.dragUpdated(info)
    }

    func panelDragExited() {
        dropTarget()?.dragExited()
    }

    func panelPerformDrop(_ info: NSDraggingInfo) -> Bool {
        guard machine.mode.acceptsDrops, let target = dropTarget() else { return false }
        return target.performDrop(info)
    }

    /// After `performDragOperation` (or a cancelled drag over the window): the drop zone
    /// waiting after a release closes now.
    func panelDragEnded() {
        dropTarget()?.dragEnded()
        if awaitingDrop {
            finishDrop()
        } else if machine.isDragging {
            dropDelivered = true   // the release has not been seen yet; close at once then
        }
        if windowStartedSession {
            windowStartedSession = false
            surfaces.setDragSession(active: false)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Whether this display has a camera notch (the same test `PanelLayout` uses).
    var hasNotch: Bool {
        NotchGeometry.notchRect(screenFrame: frame, auxLeft: auxiliaryTopLeftArea,
                                auxRight: auxiliaryTopRightArea) != nil
    }
}
