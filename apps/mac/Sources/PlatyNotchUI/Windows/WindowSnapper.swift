import AppKit
import ApplicationServices
import os
import PlatyNotchKit

/// Another app's focused window, opaque outside the driver (tests use one without an
/// element). Only ever touched by the driver, off the main actor.
final class SnapWindowHandle: @unchecked Sendable {
    let element: AXUIElement?

    init(_ element: AXUIElement?) { self.element = element }
}

/// What the driver read about the focused window: its frame in Accessibility
/// coordinates (top-left origin, y down) and whether its size can be set.
struct SnapWindowInfo: Sendable {
    var handle: SnapWindowHandle
    var frame: CGRect
    var sizeSettable: Bool
    var fullScreen: Bool
}

/// Reads and moves the focused window (a seam: tests and smoke runs never touch a real
/// window). Every call may block up to the messaging timeout: never on the main actor.
protocol SnapWindowDriver: Sendable {
    /// The focused window of the app with `pid`; nil when it has none (or AX refused).
    func focusedWindow(pid: pid_t) -> SnapWindowInfo?
    func setPosition(_ position: CGPoint, of window: SnapWindowHandle) -> Bool
    func setSize(_ size: CGSize, of window: SnapWindowHandle) -> Bool
    /// The window's size now (read once after a resize); nil when it cannot be read.
    func size(of window: SnapWindowHandle) -> CGSize?
}

/// What one snap did.
enum SnapOutcome: Equatable, Sendable {
    /// No frontmost app, no focused window, or no screens.
    case noWindow
    /// A full-screen window is left alone.
    case fullScreen
    /// Moved and resized.
    case snapped
    /// Moved only: its size cannot be set, it was centered, or the app refused the size.
    case moved
    /// The app refused the move.
    case failed
    /// The feature was turned off while the snap ran: nothing more was set.
    case cancelled
}

/// Turned on when snapping stops; a running snap checks it before every set.
final class SnapCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// The Accessibility driver: the focused window through `kAXFocusedWindowAttribute`,
/// moved with `kAXPositionAttribute` and sized with `kAXSizeAttribute`. Reads only
/// position, size and the full-screen flag (never titles or content). Every element gets
/// the 0.25 s messaging timeout, so a hung app costs one snap at most that per call.
struct AXSnapWindowDriver: SnapWindowDriver {
    static let messagingTimeout: Float = 0.25

    func focusedWindow(pid: pid_t) -> SnapWindowInfo? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement   // checked by type id above
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
        guard let origin: CGPoint = Self.read(window, kAXPositionAttribute, .cgPoint),
              let size: CGSize = Self.read(window, kAXSizeAttribute, .cgSize) else { return nil }
        var settable = DarwinBoolean(false)
        let sizeSettable = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success
            && settable.boolValue
        var full: CFTypeRef?
        let isFull = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &full) == .success
            && (full as? Bool) == true
        return SnapWindowInfo(handle: SnapWindowHandle(window), frame: CGRect(origin: origin, size: size),
                              sizeSettable: sizeSettable, fullScreen: isFull)
    }

    func setPosition(_ position: CGPoint, of window: SnapWindowHandle) -> Bool {
        var p = position
        guard let element = window.element, let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }

    func setSize(_ size: CGSize, of window: SnapWindowHandle) -> Bool {
        var s = size
        guard let element = window.element, let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .success
    }

    func size(of window: SnapWindowHandle) -> CGSize? {
        guard let element = window.element else { return nil }
        return Self.read(element, kAXSizeAttribute, .cgSize)
    }

    private static func read<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue   // checked by type id above
        guard AXValueGetType(axValue) == type else { return nil }
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(axValue, type, out) else { return nil }
        return out.pointee
    }
}

/// A driver that never finds a window (smoke runs and the inert widget).
struct NoSnapWindowDriver: SnapWindowDriver {
    func focusedWindow(pid: pid_t) -> SnapWindowInfo? { nil }
    func setPosition(_ position: CGPoint, of window: SnapWindowHandle) -> Bool { false }
    func setSize(_ size: CGSize, of window: SnapWindowHandle) -> Bool { false }
    func size(of window: SnapWindowHandle) -> CGSize? { nil }
}

/// The displays as snapping needs them, read on the main actor.
struct SnapDisplays: Sendable {
    var screens: [SnapScreen]
    /// The primary display's height (the one at the origin), for the AX flip (R15).
    var primaryHeight: CGFloat

    /// `NSScreen.screens`: the first is the primary display.
    @MainActor
    static func system() -> SnapDisplays {
        let all = NSScreen.screens
        let screens = all.map { SnapScreen(frame: $0.frame, visible: $0.visibleFrame) }
        return SnapDisplays(screens: screens, primaryHeight: all.first?.frame.height ?? 0)
    }
}

/// Snaps the frontmost app's focused window (v0.2 Task 5). One attempt per press: set the
/// position, then the size, read the size back once, then set the position again (some
/// apps clamp the position to the old size; one that kept another size is centred in the
/// target instead). A window whose size cannot be set is only moved. Nothing is retried,
/// and a press while a snap is still running is dropped. Never snaps PlatyNotch's own
/// windows, nor anything while a notch panel is key (an approval card has the keyboard).
/// The AX calls run on one serial queue, off the main actor and the cooperative pool.
@MainActor
final class WindowSnapper {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "snap")
    /// Every AX call of every snap: they block (up to the messaging timeout each).
    nonisolated static let queue = DispatchQueue(label: "dev.platynotch.snap", qos: .userInitiated)

    private let driver: SnapWindowDriver
    private let displays: @MainActor () -> SnapDisplays
    private let frontmost: @MainActor () -> pid_t?
    private let blocked: @MainActor () -> Bool
    private let ownPID: pid_t
    /// The gap between windows and screen edges, in points (read at each press).
    var gap: @MainActor () -> CGFloat = { 0 }
    /// The snap still running, if any.
    private(set) var inFlight: Task<SnapOutcome, Never>?
    private var inFlightCancel: SnapCancel?

    /// `blocked`: true while snapping must do nothing (default: a notch panel is key, e.g.
    /// a focused approval card; the panel never activates PlatyNotch, so the frontmost app
    /// is another one then).
    init(driver: SnapWindowDriver = AXSnapWindowDriver(),
         displays: @escaping @MainActor () -> SnapDisplays = { SnapDisplays.system() },
         frontmost: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         blocked: @escaping @MainActor () -> Bool = { WindowSnapper.panelIsKey(in: NSApplication.shared.windows) },
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.driver = driver
        self.displays = displays
        self.frontmost = frontmost
        self.blocked = blocked
        self.ownPID = ownPID
    }

    /// Whether one of `windows` is a notch panel with the keyboard. Scans the windows:
    /// `NSApp.keyWindow` can be nil while PlatyNotch is inactive and the key window is a
    /// nonactivating panel. `isKey` is a seam for tests (stub windows cannot be key).
    static func panelIsKey(in windows: [NSWindow], isKey: (NSWindow) -> Bool = { $0.isKeyWindow }) -> Bool {
        windows.contains { $0 is NotchPanel && isKey($0) }
    }

    /// Snaps the focused window to `target`. Nil (nothing done) while another snap runs,
    /// when no app is in front, when PlatyNotch itself is, or while `blocked`; otherwise
    /// the running snap.
    @discardableResult
    func snap(_ target: SnapTarget) -> Task<SnapOutcome, Never>? {
        guard inFlight == nil, let pid = frontmost(), pid != ownPID, !blocked() else { return nil }
        let d = displays()
        let gap = gap()
        let driver = driver
        let cancel = SnapCancel()
        let task = Task { [weak self] in
            let outcome = await withCheckedContinuation { (c: CheckedContinuation<SnapOutcome, Never>) in
                Self.queue.async {
                    c.resume(returning: Self.perform(target, pid: pid, driver: driver, displays: d, gap: gap,
                                                     cancel: cancel))
                }
            }
            if let self, self.inFlightCancel === cancel {
                self.inFlight = nil
                self.inFlightCancel = nil
            }
            if outcome == .failed { Self.log.notice("snap \(target.rawValue, privacy: .public): the app refused the move") }
            return outcome
        }
        inFlight = task
        inFlightCancel = cancel
        return task
    }

    /// Snapping stopped: a running snap sets nothing more (its AX call in progress, if
    /// any, still finishes) and the next press may start a new one.
    func cancel() {
        inFlightCancel?.cancel()
        inFlightCancel = nil
        inFlight = nil
    }

    /// One snap, synchronously (call on `queue`: AX calls block).
    nonisolated static func perform(_ target: SnapTarget, pid: pid_t, driver: SnapWindowDriver, displays: SnapDisplays,
                                    gap: CGFloat, cancel: SnapCancel = SnapCancel()) -> SnapOutcome {
        guard let window = driver.focusedWindow(pid: pid) else { return .noWindow }
        guard !window.fullScreen else { return .fullScreen }
        guard let plan = SnapLayout.plan(target, windowAX: window.frame, resizable: window.sizeSettable,
                                         screens: displays.screens, primaryScreenHeight: displays.primaryHeight,
                                         gap: gap) else { return .noWindow }
        guard !cancel.isCancelled else { return .cancelled }
        guard driver.setPosition(plan.position, of: window.handle) else { return .failed }
        guard let size = plan.size else { return .moved }
        guard !cancel.isCancelled else { return .cancelled }
        let sized = driver.setSize(size, of: window.handle)
        guard !cancel.isCancelled else { return .cancelled }
        // Read back once: an app that says its size is settable may keep its own (fixed
        // windows). Then one more move, never in a loop: the planned position again (some
        // apps clamp it to the old size), or the kept size centred in the target.
        var outcome: SnapOutcome = sized ? .snapped : .moved
        var again = plan.position
        if let actual = driver.size(of: window.handle),
           abs(actual.width - size.width) > 1 || abs(actual.height - size.height) > 1 {
            again = SnapLayout.position(centering: actual, in: plan)
            outcome = .moved
        }
        guard !cancel.isCancelled else { return .cancelled }
        _ = driver.setPosition(again, of: window.handle)
        return outcome
    }
}
