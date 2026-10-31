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
    /// Platy's timed mood inputs (just finished, the hour), one for every display.
    public let platy: PlatyMoodModel
    /// The app's one session tracker: finishes and failures in the last 10 minutes.
    let agentActivity: AgentActivityModel

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
        agentActivity = AgentActivityModel()
        platy.follow(agentActivity)
    }
}
