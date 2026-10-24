import Foundation

/// The accessibility calls behind `AXManualAccessibility` on one process.
public protocol ManualAccessibilityAX: Sendable {
    /// Whether the app accepts the attribute (Chromium and Electron apps do).
    func isSettable(pid: pid_t) -> Bool
    /// Whether the attribute is already true (another assistive tool may have set it).
    func isOn(pid: pid_t) -> Bool
    func set(_ on: Bool, pid: pid_t)
}

/// Turns `AXManualAccessibility` on, once per process and only where the app says it
/// is settable, so Chromium and Electron apps expose their text; and turns it off
/// again for every process it turned on when capture stops, pauses or the app quits.
/// A process where the attribute was already true is left as it was found.
/// Not thread-safe: confined to the capture walk queue.
public final class ManualAccessibility: @unchecked Sendable {
    private let ax: ManualAccessibilityAX
    /// Processes it changed the attribute from off (or absent) to on for.
    public private(set) var enabled: Set<pid_t> = []
    /// Processes already asked (settable or not), so each is asked once.
    private var asked: Set<pid_t> = []

    public init(ax: ManualAccessibilityAX) {
        self.ax = ax
    }

    public func enable(pid: pid_t) {
        guard asked.insert(pid).inserted, ax.isSettable(pid: pid), !ax.isOn(pid: pid) else { return }
        ax.set(true, pid: pid)
        enabled.insert(pid)
    }

    /// Undoes `enable` for one process (an app newly excluded), if it was ours to undo.
    public func disable(pid: pid_t) {
        if enabled.remove(pid) != nil { ax.set(false, pid: pid) }
        asked.remove(pid)
    }

    /// Drops a process that has quit, so its pid can be reused without a stale entry.
    public func forget(pid: pid_t) {
        enabled.remove(pid)
        asked.remove(pid)
    }

    /// Undoes every `enable` it made (a process that has quit ignores it).
    public func disableAll() {
        for pid in enabled.sorted() { ax.set(false, pid: pid) }
        enabled = []
        asked = []
    }
}
