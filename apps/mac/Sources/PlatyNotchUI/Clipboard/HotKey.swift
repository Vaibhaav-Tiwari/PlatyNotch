import Carbon.HIToolbox
import Foundation
import os
import PlatyNotchKit

/// A registered global shortcut; `unregister` releases it (also on deinit).
@MainActor
protocol HotKeyRegistration: AnyObject {
    func unregister()
}

/// Makes registrations (a seam: tests and smoke runs never grab a real shortcut).
/// Nil when the shortcut could not be registered (another app holds it).
typealias HotKeyMaker = @MainActor (_ keyCode: UInt32, _ modifiers: UInt32, _ handler: @escaping @MainActor () -> Void)
    -> HotKeyRegistration?

/// Like `HotKeyMaker`, with a handler for the key's release too (hold-to-talk, R6).
typealias HotKeyHoldMaker = @MainActor (_ combo: KeyCombo, _ onPress: @escaping @MainActor () -> Void,
                                        _ onRelease: @escaping @MainActor () -> Void) -> HotKeyRegistration?

/// The press and release handlers of every registered hot key, by id. Separate from
/// Carbon so the routing is testable.
@MainActor
struct HotKeyHandlers {
    private var press: [UInt32: @MainActor () -> Void] = [:]
    private var release: [UInt32: @MainActor () -> Void] = [:]

    mutating func set(_ id: UInt32, press onPress: @escaping @MainActor () -> Void,
                      release onRelease: (@MainActor () -> Void)?) {
        press[id] = onPress
        release[id] = onRelease
    }

    mutating func remove(_ id: UInt32) {
        press[id] = nil
        release[id] = nil
    }

    /// Runs the handler for a press or a release of `id`; false when there is none (a
    /// release of a key registered without one).
    @discardableResult
    func dispatch(_ id: UInt32, released: Bool) -> Bool {
        guard let handler = released ? release[id] : press[id] else { return false }
        handler()
        return true
    }
}

/// A Carbon `RegisterEventHotKey` shortcut. Needs no permission (unlike an event tap or
/// a global key monitor) and sees only its own key combination, nothing else typed.
/// Registered only while the feature that owns it runs (the clipboard widget today).
/// An optional release handler gets `kEventHotKeyReleased` (hold-to-talk).
@MainActor
final class HotKey: HotKeyRegistration {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "hotkey")
    /// 'PLNT'
    private static let signature: OSType = 0x504C_4E54
    private static var handlers = HotKeyHandlers()
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var ref: EventHotKeyRef?
    private let hotKeyID: UInt32

    /// Nil when Carbon refused it (the combination is taken). `onRelease` runs when the
    /// keys are let go (nil: releases are ignored, as before).
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void,
          onRelease: (@MainActor () -> Void)? = nil) {
        guard Self.installHandler() else { return nil }
        hotKeyID = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: hotKeyID),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Self.log.error("hot key not registered (\(status, privacy: .public))")
            return nil
        }
        self.ref = ref
        Self.handlers.set(hotKeyID, press: handler, release: onRelease)
    }

    static let make: HotKeyMaker = { HotKey(keyCode: $0, modifiers: $1, handler: $2) }

    static let makeHold: HotKeyHoldMaker = { combo, onPress, onRelease in
        HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers, handler: onPress, onRelease: onRelease)
    }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        Self.handlers.remove(hotKeyID)
    }

    isolated deinit { unregister() }

    /// One application-target handler for every hot key, pressed and released (Carbon
    /// delivers them on the main thread).
    private static func installHandler() -> Bool {
        if eventHandler != nil { return true }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard got == noErr, id.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
            let hotKeyID = id.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            let handled = MainActor.assumeIsolated { HotKey.handlers.dispatch(hotKeyID, released: released) }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, specs.count, &specs, nil, &eventHandler)
        return status == noErr
    }
}
