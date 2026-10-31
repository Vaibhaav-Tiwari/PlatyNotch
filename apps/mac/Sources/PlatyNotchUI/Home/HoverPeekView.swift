import PlatyNotchKit
import SwiftUI

/// The hover peek (Peek on hover, open on click): the most important live item in a line or
/// two, or Platy resting. A click anywhere opens the panel.
struct HoverPeekView: View {
    let widgets: WidgetRegistry
    @Environment(\.platyMood) private var mood

    static let nothingLive = "Nothing live"

    /// The line shown: the top live item's title and subtitle, else "Nothing live".
    static func lines(_ activities: [LiveActivity]) -> (title: String, subtitle: String?) {
        guard let top = activities.max(by: { $0.priority < $1.priority }), let title = top.title else {
            return (nothingLive, nil)
        }
        return (title, top.subtitle)
    }

    var body: some View {
        let lines = Self.lines(widgets.liveActivities)
        HStack(spacing: 12) {
            if let mood { PlatyView(mood: mood, size: 36) }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: lines.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                if let subtitle = lines.subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
