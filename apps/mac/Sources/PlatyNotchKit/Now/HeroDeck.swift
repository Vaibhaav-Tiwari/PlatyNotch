import Foundation

/// The live items Now's hero cycles through with ‹ › or a swipe ("2 of 3"), and which one
/// is selected. Approvals are never in it (spec 6.8), so nothing slides under the pointer
/// when one arrives.
public struct HeroDeck: Equatable, Sendable {
    public private(set) var selectedID: String?

    public init() {}

    /// The deck from ranked items: ambient ones dropped (never the hero), one entry per
    /// widget (its best, i.e. first, item) plus the agents item.
    public static func items(_ ranked: [LiveItem]) -> [LiveItem] {
        var seen = Set<String>()
        return ranked.filter { item in
            guard item.rank != .ambient else { return false }
            guard let widget = item.source.widgetID else { return true }
            return seen.insert(widget).inserted
        }
    }

    /// The selected item's index while it is still in the deck, else the top one; nil for
    /// an empty deck.
    public func current(in deck: [LiveItem]) -> Int? {
        guard !deck.isEmpty else { return nil }
        if let selectedID, let i = deck.firstIndex(where: { $0.id == selectedID }) { return i }
        return 0
    }

    /// Moves the selection by `delta`, wrapping around.
    public mutating func step(_ delta: Int, in deck: [LiveItem]) {
        guard let i = current(in: deck) else { return }
        let count = deck.count
        let next = ((i + delta) % count + count) % count
        selectedID = deck[next].id
    }

    /// Each open starts at the top item.
    public mutating func panelOpened() {
        selectedID = nil
    }

    /// "2 of 3"; nil with fewer than two items.
    public static func position(_ index: Int, of count: Int) -> String? {
        guard count >= 2 else { return nil }
        return "\(index + 1) of \(count)"
    }
}
