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
    /// Targets whose shortcut is not held, in `allCases` order: another app holds it, or
    /// another PlatyNotch feature does (`usedBy`).
    private(set) var taken: [SnapTarget] = []
    /// Targets whose shortcut another PlatyNotch feature holds: that feature's name.
    private(set) var usedBy: [SnapTarget: String] = [:]
    /// The app's one runtime catalog (`WidgetContext.hotKeys`), set when the widget starts.
    var catalog: SharedHotKeyCatalog

    init(make: @escaping HotKeyMaker = HotKey.make, catalog: SharedHotKeyCatalog = SharedHotKeyCatalog()) {
        self.make = make
        self.catalog = catalog
    }

    var isRegistered: Bool { !registrations.isEmpty }
    var registeredCount: Int { registrations.count }

    /// Registers every shortcut (after dropping any held), each calling `handler` with its
    /// target. Each is claimed in the shared catalog first and released when Carbon refuses it.
    func register(_ handler: @escaping @MainActor (SnapTarget) -> Void) {
        unregister()
        var taken: [SnapTarget] = []
        var usedBy: [SnapTarget: String] = [:]
        for target in SnapTarget.allCases {
            let combo = target.defaultCombo
            let feature = target.hotKeyFeature
            if let conflict = catalog.claim(combo, for: feature) {
                Self.log.error("snap shortcut \(combo.display, privacy: .public) is used in PlatyNotch")
                taken.append(target)
                usedBy[target] = SharedHotKeyCatalog.owner(of: conflict)
                continue
            }
            guard let reg = make(combo.keyCode, combo.modifiers, { handler(target) }) else {
                Self.log.error("snap shortcut \(combo.display, privacy: .public) is taken")
                catalog.release(feature)
                taken.append(target)
                continue
            }
            registrations[target] = reg
        }
        self.taken = taken
        self.usedBy = usedBy
    }

    /// Releases every shortcut (and its claim in the catalog).
    func unregister() {
        for (target, reg) in registrations {
            reg.unregister()
            catalog.release(target.hotKeyFeature)
        }
        registrations = [:]
        taken = []
        usedBy = [:]
    }
}
