import Foundation

/// Where a widget is listed in Settings › Widgets (R1, v0.2). Everyday widgets are the
/// list at the top; power features (camera mirror, window snapping and the like) are
/// grouped below them under "Power features", a heading shown only when there are any.
/// The category changes nothing else: on/off, start and stop work the same for both.
public enum WidgetCategory: String, CaseIterable, Codable, Equatable, Sendable {
    case everyday
    case power

    /// The heading above the group in Settings; nil for the first (unheaded) group.
    public var heading: String? {
        switch self {
        case .everyday: nil
        case .power: "Power features"
        }
    }

    /// `ids` in order, re-grouped so every category's ids follow the previous category's
    /// (`allCases` order), each group keeping its own relative order. `category(id)`
    /// names each id's group. Settings reorders one group with this, so moving a row
    /// never moves a widget across groups.
    public static func grouped(_ ids: [String], category: (String) -> WidgetCategory) -> [String] {
        allCases.flatMap { c in ids.filter { category($0) == c } }
    }

    /// The full order after `group` was reordered to `reordered` (ids of that group, in
    /// their new order); the other groups keep theirs from `current`.
    public static func replacing(_ group: WidgetCategory, with reordered: [String], in current: [String],
                                 category: (String) -> WidgetCategory) -> [String] {
        allCases.flatMap { c in c == group ? reordered : current.filter { category($0) == c } }
    }
}
