import Foundation

/// The user's widget order and which widgets are on. Persisted as JSON in
/// `UserDefaults.standard` under `key` (the app's own domain, like the other settings).
public struct WidgetLayout: Codable, Equatable, Sendable {
    public static let key = "widgets.layout"

    /// Every widget id ever seen, in the user's order. Ids of widgets that are not
    /// available right now (a plugin not loaded) are kept so they get their place back.
    public var order: [String]
    public var enabled: Set<String>

    public init(order: [String] = [], enabled: Set<String> = []) {
        self.order = order
        self.enabled = enabled
    }

    /// Records a widget id. A new id goes to the end and is enabled only when
    /// `defaultEnabled`; a known id keeps the user's choice.
    public mutating func adopt(id: String, defaultEnabled: Bool) {
        guard !order.contains(id) else { return }
        order.append(id)
        if defaultEnabled { enabled.insert(id) }
    }

    public mutating func setEnabled(_ id: String, _ on: Bool) {
        if on { enabled.insert(id) } else { enabled.remove(id) }
        if !order.contains(id) { order.append(id) }
    }

    /// Moves `id` to `index` in `order` (clamped); an id not yet in `order` is inserted.
    public mutating func move(_ id: String, to index: Int) {
        order.removeAll { $0 == id }
        order.insert(id, at: min(max(index, 0), order.count))
    }

    /// Puts `ids` first in the given order; other known ids keep their relative order after them.
    public mutating func reorder(_ ids: [String]) {
        let listed = Set(ids)
        order = ids + order.filter { !listed.contains($0) }
    }

    /// Enabled ids to show, in order: known ids first (unavailable ones dropped), then
    /// available ids not yet ordered that are enabled.
    public func visible(available: [String]) -> [String] {
        let availableSet = Set(available)
        let known = order.filter { availableSet.contains($0) && enabled.contains($0) }
        let ordered = Set(order)
        let new = available.filter { !ordered.contains($0) && enabled.contains($0) }
        return known + new
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// nil for missing or unreadable data (the caller starts from defaults).
    public static func decode(_ data: Data?) -> WidgetLayout? {
        data.flatMap { try? JSONDecoder().decode(WidgetLayout.self, from: $0) }
    }
}
