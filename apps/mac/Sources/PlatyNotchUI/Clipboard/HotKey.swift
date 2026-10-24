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

/// A Carbon `RegisterEventHotKey` shortcut. Needs no permission (unlike an event tap or
/// a global key monitor) and sees only its own key combination, nothing else typed.
/// Registered only while the clipboard widget runs.
@MainActor
final class HotKey: HotKeyRegistration {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "hotkey")
    /// 'PLNT'
    private static let signature: OSType = 0x504C_4E54
    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var ref: EventHotKeyRef?
    private let hotKeyID: UInt32

    /// Nil when Carbon refused it (the combination is taken).
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) {
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
        Self.handlers[hotKeyID] = handler
    }

    static let make: HotKeyMaker = { HotKey(keyCode: $0, modifiers: $1, handler: $2) }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        Self.handlers[hotKeyID] = nil
    }

    isolated deinit { unregister() }

    /// One application-target handler for every hot key (Carbon delivers them on the
    /// main thread).
    private static func installHandler() -> Bool {
        if eventHandler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard got == noErr, id.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
            let hotKeyID = id.id
            MainActor.assumeIsolated { HotKey.handlers[hotKeyID]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        return status == noErr
    }
}
