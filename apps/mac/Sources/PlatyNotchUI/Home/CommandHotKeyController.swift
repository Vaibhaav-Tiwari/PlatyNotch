import Foundation
import os
import PlatyNotchKit

/// Holds the global command shortcut (⌥⌘K by default, `CommandHotKey`): claimed in the app's
/// one `SharedHotKeyCatalog` before it is registered, so a clash with another PlatyNotch
/// feature is named, and released when changed or turned off. A press opens Home with the
/// command line focused (`onPress`). A Carbon hot key: no permission, no polling, no idle work.
@MainActor @Observable
final class CommandHotKeyController {
    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "command-hotkey")
    /// The shortcut asked for; nil when turned off.
    private(set) var combo: KeyCombo?
    /// Asked for but not held: another app holds it, or a PlatyNotch feature (`usedBy`).
    private(set) var taken = false
    private(set) var usedBy: String?
    @ObservationIgnored private var registration: HotKeyRegistration?
    @ObservationIgnored private let catalog: SharedHotKeyCatalog
    @ObservationIgnored private let makeHotKey: HotKeyMaker
    @ObservationIgnored var onPress: @MainActor () -> Void = {}

    init(catalog: SharedHotKeyCatalog, makeHotKey: @escaping HotKeyMaker = HotKey.make) {
        self.catalog = catalog
        self.makeHotKey = makeHotKey
    }

    var holds: Bool { registration != nil }

    /// Registers `combo` (or nothing), replacing the current one. Unchanged: nothing happens.
    func apply(_ next: KeyCombo?) {
        if next == combo, (registration != nil || taken || next == nil) { return }
        registration?.unregister()
        registration = nil
        catalog.release(CommandHotKey.feature)
        combo = next
        taken = false
        usedBy = nil
        guard let next else { return }
        if let conflict = catalog.claim(next, for: CommandHotKey.feature) {
            taken = true
            usedBy = SharedHotKeyCatalog.owner(of: conflict)
            Self.log.error("command shortcut \(next.display, privacy: .public) is used in PlatyNotch")
            return
        }
        guard let reg = makeHotKey(next.keyCode, next.modifiers, { [weak self] in self?.onPress() }) else {
            catalog.release(CommandHotKey.feature)
            taken = true
            Self.log.error("command shortcut \(next.display, privacy: .public) is taken by another app")
            return
        }
        registration = reg
    }

    /// Why the shortcut is not held, for Settings.
    var takenNote: String? {
        guard taken, let combo else { return nil }
        if let usedBy { return "\(combo.display) is used by \(usedBy) in PlatyNotch." }
        return "\(combo.display) is taken by another app. Pick another."
    }
}
