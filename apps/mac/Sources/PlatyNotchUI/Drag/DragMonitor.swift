import AppKit
import PlatyNotchKit

/// A left-button event from the monitors.
enum DragButtonEvent: Equatable, Sendable {
    case down, dragged, up
}

/// The raw signals the drag monitor reads: left-button events and a few cheap values.
/// A seam so tests and smoke runs never install real event monitors.
@MainActor
protocol DragSignals: AnyObject {
    /// Installs the monitors for left mouse down / dragged / up.
    func start(_ onButton: @escaping @MainActor (DragButtonEvent) -> Void)
    func stop()
    /// The drag pasteboard's change count (never its contents).
    var dragChangeCount: Int { get }
    var leftButtonDown: Bool { get }
    /// The pointer in screen coordinates (`NSEvent.mouseLocation`). Read only on the
    /// poll while a drag is in progress.
    var mouseLocation: CGPoint { get }
    /// The drag pasteboard's type identifiers (never its contents). Read only on request
    /// while a drag is in progress (`DragMonitor.dragTypes`).
    var dragTypes: [String] { get }
    /// Calls `tick` every `interval` until the returned closure is called.
    func repeatEvery(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void
}

/// NSEvent monitors for the left button, the drag pasteboard and a run-loop timer.
///
/// Mouse-button monitors need no permission: `addGlobalMonitorForEvents` asks for
/// Accessibility only for key events, so there is no degraded mode and never a prompt.
/// A global monitor sees events sent to other apps; the local one sees our own windows.
@MainActor
final class SystemDragSignals: DragSignals {
    private var monitors: [Any] = []

    init() {}

    func start(_ onButton: @escaping @MainActor (DragButtonEvent) -> Void) {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let handle: (NSEvent) -> Void = { event in
            let e: DragButtonEvent = switch event.type {
            case .leftMouseDown: .down
            case .leftMouseUp: .up
            default: .dragged
            }
            MainActor.assumeIsolated { onButton(e) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handle($0); return $0 }) {
            monitors.append(l)
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    var dragChangeCount: Int { NSPasteboard(name: .drag).changeCount }
    var leftButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
    var mouseLocation: CGPoint { NSEvent.mouseLocation }
    var dragTypes: [String] { (NSPasteboard(name: .drag).types ?? []).map(\.rawValue) }

    func repeatEvery(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        // `.common`: also fires while a drag from our own panel runs its tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

/// Installs nothing and reports nothing (smoke runs, and contexts made without a monitor).
@MainActor
final class NoDragSignals: DragSignals {
    init() {}
    func start(_ onButton: @escaping @MainActor (DragButtonEvent) -> Void) {}
    func stop() {}
    var dragChangeCount: Int { 0 }
    var leftButtonDown: Bool { false }
    var mouseLocation: CGPoint { .zero }
    var dragTypes: [String] { [] }
    func repeatEvery(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void { {} }
}

/// Hears about drag sessions anywhere on screen (`DragMonitor.subscribe`).
@MainActor
public protocol DragMonitorListener: AnyObject {
    /// A drag began. True asks for the notch's drop session (the panel opens its drop
    /// zone near the notch); the monitor opens it when any listener asks.
    func dragBegan() -> Bool
    /// The pointer (screen coordinates) on each poll while the drag lasts.
    func dragMoved(to point: CGPoint)
    /// The drag ended (dropped or not), or the monitor stopped during it.
    func dragEnded()
}

extension DragMonitorListener {
    public func dragBegan() -> Bool { false }
    public func dragMoved(to point: CGPoint) {}
    public func dragEnded() {}
}

/// Keeps a listener subscribed until `cancel` (also on deinit).
@MainActor
public final class DragSubscription {
    private weak var monitor: DragMonitor?
    private let id: Int
    public private(set) var isActive = true

    fileprivate init(monitor: DragMonitor, id: Int) {
        self.monitor = monitor
        self.id = id
    }

    public func cancel() {
        guard isActive else { return }
        isActive = false
        monitor?.unsubscribe(id)
    }

    isolated deinit { cancel() }
}

/// The app's one drag monitor (R2), shared by every feature that reacts to drags (the
/// shelf, baskets). It reports drag sessions anywhere on screen (Droppy's approach, no
/// code shared): the left button is down and the drag pasteboard's change count moved
/// (`DragPoller`).
///
/// - Ref-counted: the first `subscribe` installs the button monitors, the last `cancel`
///   removes them (a drag in progress then ends). With no subscriber nothing is installed.
/// - Fan-out: every subscriber hears began / moved / ended.
/// - The drag session (`PanelSurfaces.setDragSession`) has this one writer (R5): opened at
///   a drag's start when a listener asks (`dragBegan` true), closed at its end, and when
///   the listeners that asked leave mid-drag.
///
/// Idle cost: with the button up nothing runs but the monitors' callbacks on clicks.
/// While the button is down (a click, a selection, a window move, a drag) it polls two
/// integers every `pollInterval` and stops at the button-up, which the poll also catches
/// when the up event is not delivered (a drag that ends in another app's window). Only
/// while a drag is in progress does the poll also read the pointer position. Dragged
/// events only make sure the poll runs (a missed down); they never read the pasteboard,
/// so a fast mouse costs nothing extra.
@MainActor
public final class DragMonitor {
    public static let pollInterval: TimeInterval = 0.05

    private struct Entry {
        let id: Int
        weak var listener: DragMonitorListener?
        weak var subscription: DragSubscription?
    }

    var isRunning: Bool { poller != nil }
    var isPolling: Bool { cancelPoll != nil }
    var isDragging: Bool { poller?.isDragging ?? false }
    var subscriberCount: Int { entries.count }

    private let signals: DragSignals
    private weak var surfaces: PanelSurfaces?
    private var poller: DragPoller?
    private var cancelPoll: (() -> Void)?
    private var entries: [Entry] = []
    private var nextID = 0
    /// Subscribers that asked for the drop session during the current drag.
    private var sessionHolders: Set<Int> = []

    /// `surfaces`: where the drag session goes (nil: nowhere, e.g. a headless test).
    init(signals: DragSignals, surfaces: PanelSurfaces?) {
        self.signals = signals
        self.surfaces = surfaces
    }

    /// Smoke runs and contexts made without one: installs nothing, reports nothing.
    static func inert(surfaces: PanelSurfaces? = nil) -> DragMonitor {
        DragMonitor(signals: NoDragSignals(), surfaces: surfaces)
    }

    /// Adds `listener` (held weakly); the first subscriber starts the monitors. Keep the
    /// subscription and `cancel` it when the feature stops. A listener already subscribed
    /// gets its existing subscription back (it is never counted twice).
    public func subscribe(_ listener: DragMonitorListener) -> DragSubscription {
        if let e = entries.first(where: { $0.listener === listener }), let existing = e.subscription {
            return existing
        }
        let id = nextID
        nextID += 1
        let subscription = DragSubscription(monitor: self, id: id)
        entries.append(Entry(id: id, listener: listener, subscription: subscription))
        if entries.count == 1 { start() }
        return subscription
    }

    /// The drag pasteboard's types (never its contents), only while a drag is in
    /// progress; empty otherwise.
    public func dragTypes() -> [String] {
        isDragging ? signals.dragTypes : []
    }

    fileprivate func unsubscribe(_ id: Int) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: i)
        let held = sessionHolders.remove(id) != nil
        if entries.isEmpty {
            stop()
            surfaces?.setDragSession(active: false)
        } else if held, sessionHolders.isEmpty {
            surfaces?.setDragSession(active: false)
        }
    }

    private func start() {
        guard poller == nil else { return }
        poller = DragPoller(changeCount: signals.dragChangeCount)
        signals.start { [weak self] event in self?.button(event) }
    }

    /// Removes the monitors and the poll; a drag in progress is reported as ended to
    /// whoever is still listening.
    private func stop() {
        guard poller != nil else { return }
        signals.stop()
        stopPolling()
        let event = poller?.cancel(changeCount: signals.dragChangeCount)
        poller = nil
        if let event { handle(event) }
    }

    private func button(_ event: DragButtonEvent) {
        guard isRunning else { return }
        switch event {
        case .down, .dragged:
            guard !isPolling else { return }
            poller?.pressed(changeCount: signals.dragChangeCount)
            cancelPoll = signals.repeatEvery(Self.pollInterval) { [weak self] in self?.sample(mouseDown: nil) }
        case .up:
            sample(mouseDown: false)
        }
    }

    /// `mouseDown` from the event, or (poll) the button's current state. On a poll while
    /// a drag is in progress the pointer goes to every listener.
    func sample(mouseDown: Bool?) {
        guard isRunning, var p = poller else { return }
        let down = mouseDown ?? signals.leftButtonDown
        let event = p.sample(changeCount: signals.dragChangeCount, mouseDown: down)
        poller = p
        if !down { stopPolling() }
        if let event { handle(event) }
        if mouseDown == nil, isDragging {
            let point = signals.mouseLocation
            for l in listeners { l.dragMoved(to: point) }
        }
    }

    private var listeners: [DragMonitorListener] { entries.compactMap(\.listener) }

    private func handle(_ event: DragEvent) {
        switch event {
        case .began:
            sessionHolders = []
            var asked: Set<Int> = []
            for e in entries {
                guard let l = e.listener else { continue }
                if l.dragBegan() { asked.insert(e.id) }
            }
            // A listener may have left (or stopped the monitor) from inside `dragBegan`.
            let present = Set(entries.map(\.id))
            sessionHolders = asked.intersection(present)
            if isRunning, !sessionHolders.isEmpty { surfaces?.setDragSession(active: true) }
        case .ended:
            sessionHolders = []
            for l in listeners { l.dragEnded() }
            surfaces?.setDragSession(active: false)
        }
    }

    private func stopPolling() {
        cancelPoll?()
        cancelPoll = nil
    }
}
