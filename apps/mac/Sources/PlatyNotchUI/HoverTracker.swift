import AppKit

/// Reports the cursor position from global and local mouse-moved monitors.
/// While `engaged` (hovering, a debounce pending, or a full-screen reveal) it also
/// polls, because moves over other apps are not always delivered to a global monitor.
@MainActor
final class HoverTracker {
    static let pollInterval: TimeInterval = 1.0 / 15

    var onMove: (CGPoint) -> Void = { _ in }
    var engaged = false {
        didSet { if engaged != oldValue { updateTimer() } }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.fire() }
            return event
        }
        updateTimer()
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        timer?.invalidate()
        timer = nil
    }

    private func fire() { onMove(NSEvent.mouseLocation) }

    private func updateTimer() {
        if engaged && globalMonitor != nil {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}
