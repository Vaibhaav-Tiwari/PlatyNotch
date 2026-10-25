import Foundation

/// What a widget is to the panel (spec 6.2): live (has a beginning and an end; the pill,
/// Now's hero, indicator dots), glance (a small always-true fact; Now's glance row) and
/// tool (something opened to use; the Library). A widget can be more than one.
public struct WidgetKind: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let live = WidgetKind(rawValue: 1 << 0)
    public static let glance = WidgetKind(rawValue: 1 << 1)
    public static let tool = WidgetKind(rawValue: 1 << 2)
}
