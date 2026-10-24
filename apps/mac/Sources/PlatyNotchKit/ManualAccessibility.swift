import Foundation

/// The accessibility calls behind `AXManualAccessibility` on one process.
public protocol ManualAccessibilityAX: Sendable {
    /// Whether the app accepts the attribute (Chromium and Electron apps do).
    func isSettable(pid: pid_t) -> Bool
    func set(_ on: Bool, pid: pid_t)
}

/// Turns `AXManualAccessibility` on, once per process and only where the app says it
/// is settable, so Chromium and Electron apps expose their text; and turns it off
/// again for every process it turned on when capture stops, pauses or the app quits.
/// Not thread-safe: confined to the capture walk queue.
public final class ManualAccessibility: @unchecked Sendable {
    private let ax: ManualAccessibilityAX
    /// Processes it turned the attribute on for.
    public private(set) var enabled: Set<pid_t> = []
    /// Processes already asked (settable or not), so each is asked once.
    private var asked: Set<pid_t> = []

    public init(ax: ManualAccessibilityAX) {
        self.ax = ax
    }

    public func enable(pid: pid_t) {
        guard asked.insert(pid).inserted, ax.isSettable(pid: pid) else { return }
        ax.set(true, pid: pid)
        enabled.insert(pid)
    }

    /// Undoes every `enable` (a process that has quit ignores it).
    public func disableAll() {
        for pid in enabled.sorted() { ax.set(false, pid: pid) }
        enabled = []
        asked = []
    }
}
