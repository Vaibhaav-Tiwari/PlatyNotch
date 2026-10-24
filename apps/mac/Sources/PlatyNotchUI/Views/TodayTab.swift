import PlatyNotchKit
import SwiftUI

/// The models behind the built-in widgets, one set shared by every display's panel.
/// Calendar and Reminders are shared because quick add (Reminders widget) also writes
/// events, and Settings › Permissions shows both.
@MainActor
public final class TodayServices {
    public let nowPlaying: NowPlaying
    /// The music bars' live visualiser (off until the user turns it on).
    public let visualiser: MusicVisualiser
    public let calendar: CalendarService
    public let reminders: RemindersService
    public let focus: FocusModel
    public let loops: LoopActions
    /// Platy's timed mood inputs (just finished, celebrating, the hour), one for every display.
    public let platy: PlatyMoodModel

    public init(client: CoreClient, nowPlaying: NowPlaying = NowPlaying(), visualiser: MusicVisualiser? = nil,
                calendar: CalendarService = CalendarService(), reminders: RemindersService = RemindersService(),
                focus: FocusModel = FocusModel(), platy: PlatyMoodModel = PlatyMoodModel()) {
        self.nowPlaying = nowPlaying
        self.visualiser = visualiser ?? MusicVisualiser()
        self.calendar = calendar
        self.reminders = reminders
        self.focus = focus
        loops = LoopActions(client: client)
        self.platy = platy
    }
}

/// One tile per enabled widget that has one (`hasTile`), in the user's order (Settings › Widgets).
struct TodayTab: View {
    let widgets: WidgetRegistry
    @Environment(\.platyMood) private var platyMood

    var body: some View {
        let shown = widgets.tileWidgets
        if shown.isEmpty {
            VStack(spacing: 6) {
                if let platyMood {
                    PlatyView(mood: platyMood, size: 56)
                } else {
                    Image(systemName: "square.grid.2x2").font(.system(size: 20)).foregroundStyle(.tertiary)
                }
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
