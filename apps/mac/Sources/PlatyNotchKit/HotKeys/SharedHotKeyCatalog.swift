import Foundation

/// The app's one runtime `HotKeyCatalog` (final review M1): held by the app delegate and
/// handed to every widget in `WidgetContext.hotKeys`. Window snapping and the basket
/// switcher claim their shortcuts here before registering them and release them when they
/// let go, so a clash between two PlatyNotch features is named ("used by Baskets") instead
/// of being reported as another app's.
@MainActor
public final class SharedHotKeyCatalog {
    public private(set) var catalog = HotKeyCatalog()

    public nonisolated init() {}

    /// Gives `combo` to `feature`; the conflict (and nothing changed) when it is taken.
    @discardableResult
    public func claim(_ combo: KeyCombo, for feature: String) -> HotKeyCatalog.Conflict? {
        catalog.assign(combo, to: feature)
    }

    public func release(_ feature: String) {
        catalog.release(feature)
    }

    /// The name people see for a feature id ("snap.center" → "Window snapping").
    public nonisolated static func featureName(_ id: String) -> String {
        switch id.split(separator: ".").first.map(String.init) ?? id {
        case "snap": "Window snapping"
        case "baskets": "Baskets"
        case "clipboard": "Clipboard"
        default: id
        }
    }

    /// Which PlatyNotch feature a conflict names ("Baskets", "Clipboard"); nil when the
    /// combo is simply not allowed.
    public nonisolated static func owner(of conflict: HotKeyCatalog.Conflict) -> String? {
        switch conflict {
        case .clipboard: "Clipboard"
        case .feature(let id): featureName(id)
        case .invalid: nil
        }
    }
}
