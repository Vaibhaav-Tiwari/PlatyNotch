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

/// Decides for the tap callback, on whatever thread it runs, without touching the main
/// actor: the gate (`MediaKeyGate`, kept current by `HUDWidget`) is read under a lock,
/// and the work for a taken key goes to the main queue asynchronously, in order.
final class MediaKeyRouter: Sendable {
    private let gate = OSAllocatedUnfairLock(initialState: MediaKeyGate())
    private let onAction: @Sendable (MediaKeyAction, CGDirectDisplayID) -> Void

    /// `onAction` runs on the tap's thread; it must only hand off (`DispatchQueue.main.async`).
    init(onAction: @escaping @Sendable (MediaKeyAction, CGDirectDisplayID) -> Void) {
        self.onAction = onAction
    }

    func update(_ change: @Sendable (inout MediaKeyGate) -> Void) {
        gate.withLock { change(&$0) }
    }

    var gateSnapshot: MediaKeyGate { gate.withLock { $0 } }

    /// True: swallow the event (PlatyNotch handles it and shows its HUD).
    func route(_ event: MediaKeyEvent?, modifiers: MediaKeyModifiers, display: CGDirectDisplayID) -> Bool {
        let decision = gate.withLock { $0.decide(event, modifiers: modifiers, display: display) }
        if case .swallow(let action?) = decision { onAction(action, display) }
        return decision.swallows
    }
}

/// An active (`.defaultTap`) Quartz event tap for `NX_SYSDEFINED`, so a taken key does
/// not also show the system HUD. Needs Accessibility: `CGEvent.tapCreate` returns nil
/// without it (checked on macOS 26.4 with `AXIsProcessTrusted` and
/// `CGPreflightPostEventAccess` false; Input Monitoring only covers listen-only taps).
///
/// Failure is safe by construction:
/// - The tap's run-loop source is on the main run loop, so if the app hangs the callback
///   is not serviced, the window server times the tap out and delivers keys to the
///   system unchanged (system HUD works); on recovery `tapDisabledByTimeout` arrives and
///   the tap is re-enabled. A crash takes the tap's mach port with it.
/// - The callback does no work on the main actor: it decodes, asks the router (a lock),
///   and returns. Volume and brightness changes run afterwards from the main queue.
/// - `tapDisabledByTimeout` / `tapDisabledByUserInput` pass through and re-enable.
@MainActor
final class SystemMediaKeyTap: MediaKeyTapping {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "MediaKeyTap")
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var box: Unmanaged<TapBox>?

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
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        self.box = box
        Self.log.notice("media key tap started")
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        // Same run loop as the callback: none can be running or arrive after this point.
        box?.release()
        self.port = nil
        source = nil
        box = nil
        Self.log.notice("media key tap stopped")
    }
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

/// Keep this short: it runs for every `NX_SYSDEFINED` event system-wide.
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
    guard type.rawValue == MediaKeyEvent.systemDefinedEventType, let ns = NSEvent(cgEvent: event),
          let key = MediaKeyEvent.decode(subtype: Int(ns.subtype.rawValue), data1: ns.data1),
          key.kind != .other else { return pass }
    let display = MediaKeyDisplay.at(event.location)
    let swallow = box.router.route(key, modifiers: MediaKeyModifiers(flags: event.flags.rawValue), display: display)
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
