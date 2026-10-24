import AppKit
import CoreGraphics
import os
import PlatyNotchKit

/// Something that delivers media keys to a `MediaKeyRouter` and swallows the ones it
/// takes. The real one is `SystemMediaKeyTap`; tests and smoke runs use fakes and never
/// create an event tap.
@MainActor
protocol MediaKeyTapping: AnyObject {
    /// Creates and enables the tap. False when macOS refuses it (no Accessibility).
    func start(router: MediaKeyRouter) -> Bool
    /// Removes the tap; afterwards every key reaches the system again.
    func stop()
}

/// Decides for the tap callback, on the tap's own thread, without touching the main
/// actor: the gate (`MediaKeyGate`, kept current by `HUDWidget`) is read under a lock,
/// and the work for a taken key goes to the main queue asynchronously, in order. Each
/// hand-off is counted until it runs; while the oldest has waited longer than
/// `MediaKeyGate.handOffDeadline` (the app is hung or far behind), keys pass through.
final class MediaKeyRouter: Sendable {
    private let gate = OSAllocatedUnfairLock(initialState: MediaKeyGate())
    private let onMain: @MainActor @Sendable (MediaKeyAction, CGDirectDisplayID) -> Void
    private let now: @Sendable () -> TimeInterval
    private let toMain: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// `onMain` runs on the main actor for each taken key-down. `now` is monotonic
    /// seconds; `toMain` posts to the main queue (tests may hold the posts back).
    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         toMain: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         onMain: @escaping @MainActor @Sendable (MediaKeyAction, CGDirectDisplayID) -> Void) {
        self.now = now
        self.toMain = toMain
        self.onMain = onMain
    }

    func update(_ change: @Sendable (inout MediaKeyGate) -> Void) {
        gate.withLock { change(&$0) }
    }

    var gateSnapshot: MediaKeyGate { gate.withLock { $0 } }

    /// True: swallow the event (PlatyNotch handles it and shows its HUD).
    func route(_ event: MediaKeyEvent?, modifiers: MediaKeyModifiers, display: CGDirectDisplayID) -> Bool {
        let t = now()
        let decision = gate.withLock { $0.decide(event, modifiers: modifiers, display: display, now: t) }
        if case .swallow(let action?) = decision {
            let onMain = self.onMain
            toMain { [self] in
                gate.withLock { $0.handOffRan() }
                MainActor.assumeIsolated { onMain(action, display) }
            }
        }
        return decision.swallows
    }
}

/// An active (`.defaultTap`) Quartz event tap for `NX_SYSDEFINED`, so a taken key does
/// not also show the system HUD. Needs Accessibility: `CGEvent.tapCreate` returns nil
/// without it (checked on macOS 26.4 with `AXIsProcessTrusted` and
/// `CGPreflightPostEventAccess` false; Input Monitoring only covers listen-only taps).
///
/// The tap runs on its own thread and run loop, so `NX_SYSDEFINED` events (media keys,
/// and aux mouse-button events on every click) never wait for the main thread. Failure
/// is safe by construction:
/// - The callback only reads a locked gate; it never waits for the main thread. If the
///   app hangs, the gate sees its hand-offs going unserved for 250 ms and passes every
///   key through (system HUD). If even the tap thread stalled, the window server would
///   time the tap out and deliver keys unchanged; `tapDisabledByTimeout` re-enables it.
/// - A crash takes the tap's mach port with it.
/// - `tapDisabledByTimeout` / `tapDisabledByUserInput` pass through and re-enable.
@MainActor
final class SystemMediaKeyTap: MediaKeyTapping {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "MediaKeyTap")
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var box: Unmanaged<TapBox>?
    private var loop: TapThreadLoop?

    func start(router: MediaKeyRouter) -> Bool {
        stop()
        let box = Unmanaged.passRetained(TapBox(router: router))
        let mask = CGEventMask(1) << CGEventMask(MediaKeyEvent.systemDefinedEventType)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: mediaKeyTapCallback,
                                           userInfo: box.toOpaque()) else {
            box.release()
            Self.log.notice("media key tap refused (Accessibility not allowed)")
            return false
        }
        box.takeUnretainedValue().setPort(port)
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
        let loop = TapThreadLoop()
        let tap = TapParts(source: source, port: port)
        // Returns once the thread's run loop has the source and the tap is enabled.
        loop.run(source: source) { CGEvent.tapEnable(tap: tap.port, enable: true) }
        self.port = port
        self.source = source
        self.box = box
        self.loop = loop
        Self.log.notice("media key tap started")
        return true
    }

    /// Disable, remove the source, stop the run loop, wait for the thread to leave it,
    /// and only then free the callback's box: no callback can run after the free.
    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { loop?.stop(removing: source) }
        CFMachPortInvalidate(port)
        box?.release()
        self.port = nil
        source = nil
        box = nil
        loop = nil
        Self.log.notice("media key tap stopped")
    }
}

/// The tap's thread: a run loop that holds only the tap's source.
final class TapThreadLoop: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private let runLoop = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
    private let done = OSAllocatedUnfairLock(initialState: false)

    /// True once the thread has left its run loop.
    var hasExited: Bool { done.withLock { $0 } }

    /// Starts the thread, adds `source` to its run loop, runs `onThread` there, and
    /// returns once that is done.
    func run(source: CFRunLoopSource, onThread: @escaping @Sendable () -> Void) {
        let src = SourceRef(source: source)
        let thread = Thread { [self] in
            let rl = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(rl, src.source, .commonModes)
            onThread()
            runLoop.withLockUnchecked { $0 = rl }
            ready.signal()
            // Returns when stopped, or at once if the source was already removed.
            CFRunLoopRun()
            done.withLock { $0 = true }
            exited.signal()
        }
        thread.name = "PlatyNotch media keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// Blocks until the thread has left its run loop (a callback in flight finishes first).
    func stop(removing source: CFRunLoopSource) {
        guard let rl = runLoop.withLockUnchecked({ $0 }) else { return }
        CFRunLoopRemoveSource(rl, source, .commonModes)   // a loop without sources returns
        CFRunLoopStop(rl)
        CFRunLoopWakeUp(rl)
        exited.wait()
    }
}

private struct SourceRef: @unchecked Sendable {
    let source: CFRunLoopSource
}

private struct TapParts: @unchecked Sendable {
    let source: CFRunLoopSource
    let port: CFMachPort
}

/// What the C callback gets as `userInfo`.
private final class TapBox: @unchecked Sendable {
    let router: MediaKeyRouter
    private let port = OSAllocatedUnfairLock<CFMachPort?>(uncheckedState: nil)

    init(router: MediaKeyRouter) { self.router = router }

    func setPort(_ p: CFMachPort) { port.withLockUnchecked { $0 = p } }
    func reenable() {
        port.withLockUnchecked { p in if let p { CGEvent.tapEnable(tap: p, enable: true) } }
    }
}

/// `NSEvent.subtype` as stored in the `CGEvent` (undocumented fields 99 and 83, both
/// holding it on macOS 26.4). Only a pre-filter: a mismatch passes the event through,
/// so if a future macOS moved the field the keys would simply go to the system.
private let subtypeFields: [CGEventField] = [99, 83].compactMap { CGEventField(rawValue: $0) }

/// Keep this short: it runs on the tap thread for every `NX_SYSDEFINED` event system-wide.
private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    guard let refcon else { return pass }
    let box = Unmanaged<TapBox>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        box.reenable()   // keys went to the system meanwhile; take them again from now on
        return pass
    default:
        break
    }
    guard type.rawValue == MediaKeyEvent.systemDefinedEventType else { return pass }
    // Cheap check before allocating an NSEvent: aux mouse buttons (subtype 7) and the
    // like leave here.
    let subtype = MediaKeyEvent.systemDefinedSubtype
    guard subtypeFields.contains(where: { event.getIntegerValueField($0) == Int64(subtype) }) else { return pass }
    // The tap thread's run loop never drains a pool of its own; NSEvent autoreleases.
    let swallow: Bool = autoreleasepool {
        guard let ns = NSEvent(cgEvent: event),
              let key = MediaKeyEvent.decode(subtype: Int(ns.subtype.rawValue), data1: ns.data1),
              key.kind != .other else { return false }
        let display = MediaKeyDisplay.at(event.location)
        return box.router.route(key, modifiers: MediaKeyModifiers(flags: event.flags.rawValue), display: display)
    }
    return swallow ? nil : pass
}

enum MediaKeyDisplay {
    /// The display containing `point` (global, top-left origin), else the main display.
    static func at(_ point: CGPoint) -> CGDirectDisplayID {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 { return id }
        return CGMainDisplayID()
    }
}

/// Smoke runs: never creates a tap.
@MainActor
final class NoMediaKeyTap: MediaKeyTapping {
    func start(router: MediaKeyRouter) -> Bool { false }
    func stop() {}
}

/// Accessibility trust, read without prompting; `request` shows the system prompt and is
/// only ever called from an "Allow" button.
@MainActor
struct AccessibilityTrust {
    var isTrusted: () -> Bool
    var request: () -> Void

    static let system = AccessibilityTrust(
        isTrusted: { AXIsProcessTrusted() },
        request: { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) })

    /// Smoke runs: never trusted, never prompts.
    static let never = AccessibilityTrust(isTrusted: { false }, request: {})
}
