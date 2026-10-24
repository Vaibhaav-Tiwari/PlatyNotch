import Foundation
import os
import PlatyNotchKit

/// The 15 window-snapping shortcuts (`SnapTarget.defaultCombo`: ⌃⌥ with arrows, U I J K,
/// D F G, E T, ↩ and C). Registered only while snapping is on and Accessibility is
/// allowed; Carbon hot keys see only their own combinations, nothing else typed.
@MainActor
final class SnapHotKeys {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "snap")

    private let make: HotKeyMaker
    private var registrations: [SnapTarget: HotKeyRegistration] = [:]
    /// Targets whose shortcut another app (or a clipboard preset) holds, in `allCases` order.
    private(set) var taken: [SnapTarget] = []

    init(make: @escaping HotKeyMaker = HotKey.make) {
        self.make = make
    }

    var isRegistered: Bool { !registrations.isEmpty }
    var registeredCount: Int { registrations.count }

    /// Registers every shortcut (after dropping any held), each calling `handler` with its target.
    func register(_ handler: @escaping @MainActor (SnapTarget) -> Void) {
        unregister()
        let catalog = HotKeyCatalog()
        var taken: [SnapTarget] = []
        for target in SnapTarget.allCases {
            let combo = target.defaultCombo
            guard catalog.conflict(combo, for: target.hotKeyFeature) == nil,
                  let reg = make(combo.keyCode, combo.modifiers, { handler(target) }) else {
                Self.log.error("snap shortcut \(combo.display, privacy: .public) is taken")
                taken.append(target)
                continue
            }
            registrations[target] = reg
        }
        self.taken = taken
    }

    /// Releases every shortcut.
    func unregister() {
        for reg in registrations.values { reg.unregister() }
        registrations = [:]
        taken = []
    }
}
