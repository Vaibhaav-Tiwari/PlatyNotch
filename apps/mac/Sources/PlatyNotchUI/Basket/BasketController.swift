import AppKit
import Observation
import os
import PlatyNotchKit

/// What a basket asks before closing with items in it.
enum BasketCloseChoice: Equatable {
    case moveToShelf, discard, cancel
}

/// The system around the baskets (a seam: tests and smoke runs use fakes, so no window,
/// alert, observer or sound is ever made by them).
@MainActor
protocol BasketSystem: AnyObject {
    /// Every display, with the notch panel's region on it (`BasketPlacement`).
    func screens() -> [BasketScreen]
    /// The pointer (screen coordinates); read on a switcher press only.
    var pointer: CGPoint { get }
    /// Calls `changed` when the Space, the frontmost app or the displays change, until the
    /// returned closure is called (notifications only; no polling).
    func observe(_ changed: @escaping @MainActor () -> Void) -> () -> Void
    func beep()
    /// The close question for a basket holding `count` items.
    func confirmClose(name: String, count: Int, canMoveToShelf: Bool) -> BasketCloseChoice
    /// Rename…: the new name, nil when cancelled.
    func askName(current: String) -> String?
    func makeWindow(host: BasketHost, frame: CGRect) -> BasketWindowing
    func makeSwitcher() -> BasketSwitcherShowing
}

/// Floating baskets (v0.2 Task 1): shake a file drag and a basket appears at the pointer,
/// takes the drop and keeps it there until you drag it out.
///
/// - Shake (R3): `ShakeDetector` is fed only during a drag (`DragMonitor`, R2, this is one
///   of its listeners) whose pasteboard *types* say it carries a file or a URL
///   (`ShakeGate`); a text selection being dragged, drawing, a window being moved or a drag
///   of our own items never feeds it. One basket per drag.
/// - Drops: a basket takes only drops released over its own window; the notch drop zone
///   stays the shelf's (baskets are never placed in the notch panel's region, R5).
/// - Windows (R5): `BasketPanel`, placed by `BasketPlacement` (never over the notch panel
///   or the approval card, even while moved), hidden over a full-screen app when
///   Appearance › Hide in full screen is on (shown again by a shake or the switcher).
/// - Switcher: ⌃⌥B (a preset; can be off) brings the next basket forward, like ⌘Tab, with
///   a strip naming them; with no basket it makes one at the pointer.
/// - Idle: while on, nothing runs but the drag monitor's click callbacks, the shortcut and
///   Space/app/display notifications; one sleep while an owned copy is due to expire.
///   While off: nothing at all.
@MainActor @Observable
final class BasketController: DragMonitorListener {
    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "baskets")
    static let switcherShows: TimeInterval = 1.5
    /// After a Space or app change: the notch's own full-screen check settles first (0.7 s).
    static let fullScreenSettle: TimeInterval = 0.9
    static let maxExpirySleep: TimeInterval = 6 * 60 * 60

    private(set) var hosts: [BasketHost] = []
    /// Baskets are ordered out over a full-screen app (Appearance says so).
    private(set) var hiddenForFullScreen = false
    /// The switcher's shortcut is held by another app.
    private(set) var switcherTaken = false
    private(set) var isRunning = false

    @ObservationIgnored let store: BasketStore
    @ObservationIgnored private let system: BasketSystem
    @ObservationIgnored private let makeHotKey: HotKeyMaker
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async -> Void
    @ObservationIgnored private let makeActionCenter: @MainActor () -> FileActionCenter
    @ObservationIgnored private var windows: [UUID: BasketWindowing] = [:]
    @ObservationIgnored private var detector = ShakeDetector()
    @ObservationIgnored private(set) var gateOpen = false
    @ObservationIgnored private var summonedThisDrag = false
    /// Pointer samples the detector was fed (tests: none outside a qualifying drag).
    @ObservationIgnored private(set) var samplesFed = 0
    @ObservationIgnored private weak var drags: DragMonitor?
    @ObservationIgnored private(set) var subscription: DragSubscription?
    @ObservationIgnored private var stopObserving: (() -> Void)?
    @ObservationIgnored private var hotKey: HotKeyRegistration?
    @ObservationIgnored private var combo: KeyCombo?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var fullScreenTask: Task<Void, Never>?
    @ObservationIgnored private var switcher: BasketSwitcherShowing?
    @ObservationIgnored private var switcherTask: Task<Void, Never>?
    @ObservationIgnored private var lastSwitched: UUID?

    /// File actions runs (every basket then has "Actions ›").
    @ObservationIgnored var fileActionsOn: @MainActor () -> Bool = { false }
    /// A full-screen app is in front and Appearance › Hide in full screen is on.
    @ObservationIgnored var hidesForFullScreen: @MainActor () -> Bool = { false }
    /// The shelf's own drag out is in progress (not a drag to keep).
    @ObservationIgnored var shelfOutgoing: @MainActor () -> Bool = { false }

    init(store: BasketStore, system: BasketSystem, makeHotKey: @escaping HotKeyMaker = HotKey.make,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         actions: @escaping @MainActor () -> FileActionCenter = { FileActionCenter() }) {
        self.store = store
        self.system = system
        self.makeHotKey = makeHotKey
        self.clock = clock
        self.sleep = sleep
        makeActionCenter = actions
    }

    // MARK: - Lifecycle

    func start(drags: DragMonitor, sensitivity: Int, switcher combo: KeyCombo?) {
        guard !isRunning else { return }
        isRunning = true
        detector = ShakeDetector(sensitivity: sensitivity)
        self.drags = drags
        store.restore()
        for basket in store.baskets {
            guard let s = store.store(for: basket.id) else { continue }
            let f = BasketPlacement.clamp(CGRect(origin: basket.origin, size: BasketPlacement.size), screens: system.screens())
            open(makeHost(basket, s), frame: f)
        }
        subscription = drags.subscribe(self)
        setSwitcher(combo)
        stopObserving = system.observe { [weak self] in self?.environmentChanged() }
        recheckFullScreen()
        scheduleExpiry()
    }

    /// Quit or turned off: every window closes and every basket that is not kept (pinned,
    /// or holding a pinned item) is cleared; kept ones come back at the next start.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        subscription?.cancel()
        subscription = nil
        hotKey?.unregister()
        hotKey = nil
        switcherTaken = false
        stopObserving?()
        stopObserving = nil
        for t in [expiryTask, fullScreenTask, switcherTask] { t?.cancel() }
        expiryTask = nil
        fullScreenTask = nil
        switcherTask = nil
        switcher?.hide()
        for h in hosts {
            h.cancelWork()
            windows[h.id]?.close()
        }
        windows = [:]
        hosts = []
        store.clearUnkept()
        gateOpen = false
        summonedThisDrag = false
        detector.reset()
        hiddenForFullScreen = false
    }

    func setSensitivity(_ value: Int) {
        detector = ShakeDetector(sensitivity: value)
    }

    /// Holds `combo` (nil: no shortcut), dropping the one held before.
    func setSwitcher(_ combo: KeyCombo?) {
        hotKey?.unregister()
        hotKey = nil
        self.combo = combo
        switcherTaken = false
        guard isRunning, let combo else { return }
        guard HotKeyCatalog().conflict(combo, for: BasketSettings.switcherFeature) == nil,
              let reg = makeHotKey(combo.keyCode, combo.modifiers, { [weak self] in self?.switchNext() }) else {
            switcherTaken = true
            Self.log.error("basket switcher shortcut \(combo.display, privacy: .public) is taken")
            return
        }
        hotKey = reg
    }

    var holdsSwitcher: Bool { hotKey != nil }

    // MARK: - Shake (DragMonitorListener)

    /// Never asks for the notch's drag session (the shelf does, R5). Opens the gate only
    /// for a file or URL drag that is not one of our own.
    func dragBegan() -> Bool {
        detector.reset()
        summonedThisDrag = false
        guard isRunning, let drags else { gateOpen = false; return false }
        let ours = hosts.contains { $0.outgoingDrag } || shelfOutgoing()
        gateOpen = !ours && ShakeGate.shouldFeed(isDragging: drags.isDragging, dragTypes: drags.dragTypes())
        return false
    }

    func dragMoved(to point: CGPoint) {
        guard isRunning, gateOpen, !summonedThisDrag else { return }
        samplesFed += 1
        guard detector.feed(x: point.x, time: clock()) else { return }
        summonedThisDrag = true
        summon(at: point)
    }

    func dragEnded() {
        gateOpen = false
        summonedThisDrag = false
        detector.reset()
    }

    // MARK: - Baskets

    /// A new basket at `point` (moved out of the notch panel's region); nil when six exist
    /// or none fits (a beep).
    @discardableResult
    func summon(at point: CGPoint) -> BasketHost? {
        guard isRunning else { return nil }
        reveal()
        guard let frame = BasketPlacement.frame(centeredAt: point, screens: system.screens()),
              let basket = store.create(at: frame.origin), let s = store.store(for: basket.id) else {
            system.beep()
            return nil
        }
        let host = makeHost(basket, s)
        open(host, frame: frame)
        return host
    }

    func window(for host: BasketHost) -> BasketWindowing? { windows[host.id] }

    private func makeHost(_ basket: Basket, _ s: ShelfStore) -> BasketHost {
        let host = BasketHost(basket: basket, store: s, actions: makeActionCenter)
        host.owner = self
        host.fileActionsOn = { [weak self] in self?.fileActionsOn() ?? false }
        return host
    }

    /// `frame` nil (a kept basket that fits nowhere now): placed at the first screen's center.
    private func open(_ host: BasketHost, frame: CGRect?) {
        let screens = system.screens()
        let center = screens.first.map { CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero
        guard let f = frame ?? BasketPlacement.frame(centeredAt: center, screens: screens) else {
            // No display to put it on (smoke runs): kept in the list, no window.
            hosts.append(host)
            return
        }
        let w = system.makeWindow(host: host, frame: f)
        windows[host.id] = w
        hosts.append(host)
        if !hiddenForFullScreen { w.show() }
    }

    /// The header dragged to `frame`: placed where it may be (never over the panel).
    func basketMoved(_ host: BasketHost, to frame: CGRect) {
        guard let w = windows[host.id], let f = BasketPlacement.clamp(frame, screens: system.screens()) else { return }
        w.place(f)
    }

    /// The header released at `pointer`: over another basket, the two merge (every item
    /// that fits moves there; the empty one closes). Else its place is remembered.
    func basketDropped(_ host: BasketHost, pointer: CGPoint) {
        guard let w = windows[host.id] else { return }
        store.setOrigin(host.id, w.frame.origin)
        guard let target = hosts.first(where: { $0.id != host.id && (windows[$0.id]?.frame.contains(pointer) ?? false) })
        else { return }
        guard !host.isBusy else { return system.beep() }
        let before = host.items.count
        let moved = store.merge(host.id, into: target.id)
        target.afterChange()
        if store.basket(host.id) == nil {
            dropHost(host)
        } else {
            host.afterChange()
            if moved < before { system.beep() }   // the target was full
        }
    }

    /// The close button: with items, asks (Move to Shelf, Discard, Cancel). Refused (a
    /// beep) while a file promise or a file action is still writing into it.
    func requestClose(_ host: BasketHost) {
        guard !host.isBusy else { return system.beep() }
        guard !host.items.isEmpty else { return close(host, keepItems: false) }
        let canMove = store.shelf() != nil
        switch system.confirmClose(name: host.name, count: host.items.count, canMoveToShelf: canMove) {
        case .moveToShelf: close(host, keepItems: true)
        case .discard: close(host, keepItems: false)
        case .cancel: break
        }
    }

    /// `keepItems`: to the shelf first; when that fails the basket stays with what is left.
    func close(_ host: BasketHost, keepItems: Bool) {
        if store.close(host.id, keepItems: keepItems) {
            dropHost(host)
        } else {
            host.afterChange()
            system.beep()
        }
    }

    private func dropHost(_ host: BasketHost) {
        host.cancelWork()
        windows.removeValue(forKey: host.id)?.close()
        hosts.removeAll { $0.id == host.id }
        if lastSwitched == host.id { lastSwitched = nil }
    }

    func moveAllToShelf(_ host: BasketHost) {
        let moved = store.moveAllToShelf(host.id)
        if moved.isEmpty { system.beep() }
        host.afterChange()
    }

    func setPinned(_ host: BasketHost, _ on: Bool) {
        store.setPinned(host.id, on)
        refresh(host)
    }

    func setColor(_ host: BasketHost, _ color: BasketColor) {
        store.setColor(host.id, color)
        refresh(host)
    }

    func rename(_ host: BasketHost) {
        guard let name = system.askName(current: host.name) else { return }
        store.rename(host.id, to: name)
        refresh(host)
    }

    private func refresh(_ host: BasketHost) {
        if let b = store.basket(host.id) { host.update(from: b) }
    }

    /// A host's items changed (records follow pins; expiry follows owned copies).
    func itemsChanged(in host: BasketHost) {
        store.itemsChanged()
        scheduleExpiry()
    }

    // MARK: - The basket menu (right-click on its header)

    func menu(for host: BasketHost) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pinTitle = host.pinned ? "Unpin Basket" : "Pin Basket"
        Self.add(pinTitle, to: menu) { [weak self, weak host] in
            guard let self, let host else { return }
            self.setPinned(host, !host.pinned)
        }
        menu.addItem(colorItem(for: host))
        Self.add("Rename…", to: menu) { [weak self, weak host] in
            guard let self, let host else { return }
            self.rename(host)
        }
        if let actions = actionsItem(for: host) { menu.addItem(actions) }
        menu.addItem(.separator())
        let canMove = !host.items.isEmpty && store.shelf() != nil
        Self.add("Move All to Shelf", enabled: canMove, to: menu) { [weak self, weak host] in
            guard let self, let host else { return }
            self.moveAllToShelf(host)
        }
        let canClear = host.items.contains { !$0.pinned }
        Self.add("Clear", enabled: canClear, to: menu) { [weak host] in host?.clearUnpinned() }
        menu.addItem(.separator())
        Self.add("Close Basket", to: menu) { [weak self, weak host] in
            guard let self, let host else { return }
            self.requestClose(host)
        }
        return menu
    }

    private static func add(_ title: String, enabled: Bool = true, to menu: NSMenu,
                            _ action: @escaping @MainActor () -> Void) {
        let item = ClosureMenuItem(title: title, action: action)
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func colorItem(for host: BasketHost) -> NSMenuItem {
        let colors = NSMenu()
        for c in BasketColor.allCases {
            let item = ClosureMenuItem(title: c.title) { [weak self, weak host] in
                guard let self, let host else { return }
                self.setColor(host, c)
            }
            item.state = c == host.color ? .on : .off
            colors.addItem(item)
        }
        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        color.submenu = colors
        return color
    }

    /// "Actions ›" for every item in the basket, while File actions runs.
    private func actionsItem(for host: BasketHost) -> NSMenuItem? {
        guard let center = host.fileActions, !host.items.isEmpty else { return nil }
        let writers = host.pasteboardWriters(for: host.items)
        let pairs: [(item: ShelfItem, url: URL?)] = writers.map { pair in
            let url: URL? = (pair.1 as? NSURL).flatMap { $0.isFileURL ? $0 as URL : nil }
            return (pair.0, url)
        }
        let entries = center.entries(for: pairs)
        guard !entries.isEmpty else { return nil }
        let actions = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        actions.submenu = ShelfItemView.actionsMenu(entries, center: center, host: host, pairs: pairs)
        return actions
    }

    // MARK: - Switcher (⌃⌥B)

    /// The next basket comes forward (highlighted while the strip shows); with none, a new
    /// one at the pointer.
    func switchNext() {
        guard isRunning else { return }
        guard !hosts.isEmpty else {
            summon(at: system.pointer)
            return
        }
        reveal()
        let current = lastSwitched.flatMap { id in hosts.firstIndex { $0.id == id } }
        let index = current.map { ($0 + 1) % hosts.count } ?? 0
        let host = hosts[index]
        lastSwitched = host.id
        for h in hosts { h.highlighted = h.id == host.id }
        windows[host.id]?.show()
        let switcher = self.switcher ?? system.makeSwitcher()
        self.switcher = switcher
        switcher.show(hosts.map { ($0.name, $0.color) }, selected: index, screens: system.screens())
        switcherTask?.cancel()
        switcherTask = Task { [weak self] in
            await self?.sleep(Self.switcherShows)
            guard !Task.isCancelled, let self else { return }
            self.switcher?.hide()
            for h in self.hosts { h.highlighted = false }
        }
    }

    // MARK: - Full screen and displays

    private func environmentChanged() {
        guard isRunning else { return }
        // Displays may have moved: every basket is placed again (never over a panel).
        let screens = system.screens()
        for h in hosts {
            guard let w = windows[h.id], let f = BasketPlacement.clamp(w.frame, screens: screens) else { continue }
            if f != w.frame { w.place(f) }
        }
        fullScreenTask?.cancel()
        fullScreenTask = Task { [weak self] in
            await self?.sleep(Self.fullScreenSettle)
            guard !Task.isCancelled else { return }
            self?.recheckFullScreen()
        }
    }

    func recheckFullScreen() {
        guard isRunning else { return }
        let hide = hidesForFullScreen()
        guard hide != hiddenForFullScreen else { return }
        hiddenForFullScreen = hide
        for w in windows.values {
            if hide { w.hide() } else { w.show() }
        }
    }

    /// A shake or the switcher shows hidden baskets (the user asked for them).
    private func reveal() {
        guard hiddenForFullScreen else { return }
        hiddenForFullScreen = false
        for w in windows.values { w.show() }
    }

    // MARK: - Expiry (owned copies, 7 days)

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard isRunning, let next = store.nextExpiry() else { return }
        let delay = min(max(next.timeIntervalSinceNow, 1), Self.maxExpirySleep)
        expiryTask = Task { [weak self] in
            await self?.sleep(delay)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.store.expireOwned()
            for h in self.hosts { h.sync() }
            self.scheduleExpiry()
        }
    }
}
