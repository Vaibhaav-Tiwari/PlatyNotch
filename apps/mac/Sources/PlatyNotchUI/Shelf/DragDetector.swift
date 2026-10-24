import AppKit
import PlatyNotchKit

/// A left-button event from the monitors.
enum DragButtonEvent: Equatable {
    case down, dragged, up
}

/// The raw signals the drag detector reads: left-button events and two cheap values.
/// A seam so tests and smoke runs never install real event monitors.
@MainActor
protocol DragSignals: AnyObject {
    /// Installs the monitors for left mouse down / dragged / up.
    func start(_ onButton: @escaping @MainActor (DragButtonEvent) -> Void)
    func stop()
    /// The drag pasteboard's change count (never its contents).
    var dragChangeCount: Int { get }
    var leftButtonDown: Bool { get }
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

    func repeatEvery(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        // `.common`: also fires while a drag from our own panel runs its tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

/// Installs nothing and reports nothing (smoke runs).
@MainActor
final class NoDragSignals: DragSignals {
    func start(_ onButton: @escaping @MainActor (DragButtonEvent) -> Void) {}
    func stop() {}
    var dragChangeCount: Int { 0 }
    var leftButtonDown: Bool { false }
    func repeatEvery(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void { {} }
}

/// Reports drag sessions anywhere on screen (Droppy's approach, no code shared): the
/// left button is down and the drag pasteboard's change count moved (`DragPoller`).
///
/// Idle cost: with the button up nothing runs but the monitors' callbacks on clicks.
/// While the button is down (a click, a selection, a window move, a drag) it polls two
/// integers every `pollInterval` and stops at the button-up, which the poll also catches
/// when the up event is not delivered (a drag that ends in another app's window).
/// Dragged events only make sure the poll runs (a missed down); they never read the
/// pasteboard, so a fast mouse costs nothing extra.
@MainActor
final class DragDetector {
    static let pollInterval: TimeInterval = 0.05

    var onEvent: (DragEvent) -> Void = { _ in }
    private(set) var isRunning = false
    var isPolling: Bool { cancelPoll != nil }
    var isDragging: Bool { poller?.isDragging ?? false }

    private let signals: DragSignals
    private var poller: DragPoller?
    private var cancelPoll: (() -> Void)?

    init(signals: DragSignals) {
        self.signals = signals
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        poller = DragPoller(changeCount: signals.dragChangeCount)
        signals.start { [weak self] event in self?.button(event) }
    }

    /// Removes the monitors and the poll; a drag in progress is reported as ended.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        signals.stop()
        stopPolling()
        let event = poller?.cancel(changeCount: signals.dragChangeCount)
        poller = nil
        if let event { onEvent(event) }
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

    /// `mouseDown` from the event, or (poll) the button's current state.
    func sample(mouseDown: Bool?) {
        guard isRunning, var p = poller else { return }
        let down = mouseDown ?? signals.leftButtonDown
        let event = p.sample(changeCount: signals.dragChangeCount, mouseDown: down)
        poller = p
        if !down { stopPolling() }
        if let event { onEvent(event) }
    }

    private func stopPolling() {
        cancelPoll?()
        cancelPoll = nil
    }
}
