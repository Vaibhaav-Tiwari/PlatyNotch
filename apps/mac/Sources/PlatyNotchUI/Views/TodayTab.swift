import PlatyNotchKit
import SwiftUI

/// The models behind the built-in widgets, one set shared by every display's panel.
/// A thin holder until the widgets own their models (Plan 3b Task 7).
@MainActor
public final class TodayServices {
    public let nowPlaying: NowPlaying
    /// The music bars' live visualiser (off until the user turns it on).
    public let visualiser: MusicVisualiser
    public let calendar: CalendarService
    public let focus: FocusModel
    public let loops: LoopActions

    public init(client: CoreClient, nowPlaying: NowPlaying = NowPlaying(), visualiser: MusicVisualiser? = nil,
                calendar: CalendarService = CalendarService(), focus: FocusModel = FocusModel()) {
        self.nowPlaying = nowPlaying
        self.visualiser = visualiser ?? MusicVisualiser()
        self.calendar = calendar
        self.focus = focus
        loops = LoopActions(client: client)
    }
}

/// One tile per enabled widget, in the user's order (Settings › Widgets).
struct TodayTab: View {
    let widgets: WidgetRegistry

    var body: some View {
        let shown = widgets.visibleWidgets
        if shown.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.system(size: 20)).foregroundStyle(.tertiary)
                Text("No widgets are on.")
                    .font(.system(size: 12, weight: .semibold))
                Text("Turn them on in Settings › Widgets.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown.map(\.id), id: \.self) { id in
                        widgets.widget(id)?.tileView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }
}
