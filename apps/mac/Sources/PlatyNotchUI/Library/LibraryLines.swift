import PlatyNotchKit
import SwiftUI

// The built-in tools' Library lines (spec 6.6: "one live line such as '2 timers' or
// '5 items'"), read when the grid draws. Never empty, short enough for a tile
// (`LibraryViewTests.testEveryTileHasALine`). Nothing here asks for data.
//
// `needsSetup` is true only while a widget cannot work at all until it is set up; having
// nothing right now is a calm line ("No timers"), not a dimmed "Set up" tile.

/// "1 item" / "3 items", or `none` at zero.
@MainActor
func libraryCount(_ n: Int, _ one: String, _ many: String, none: String) -> String {
    n <= 0 ? none : n == 1 ? "1 \(one)" : "\(n) \(many)"
}

extension MusicWidget: LibraryLiveLine {
    var libraryLine: String? {
        guard let title = nowPlaying.title else { return "Nothing playing" }
        guard let artist = nowPlaying.artist, !artist.isEmpty else { return title }
        return "\(title) \u{2014} \(artist)"
    }
}

extension MeetingWidget: LibraryLiveLine {
    var libraryLine: String? {
        if needsSetup { return "Needs access" }
        return glanceMeeting?.title ?? "No meetings"
    }

    /// Without calendar access there is nothing it can show.
    var needsSetup: Bool { calendar.access == .notAsked || calendar.access == .denied }
}

extension FocusWidget: LibraryLiveLine {
    var libraryLine: String? {
        guard let timer = focus.timer else { return "25, 50 or 90 min" }
        return timer.phase == .paused ? "Paused" : focus.focusActive ? "Focusing" : "Done"
    }
}

extension LoopsWidget: LibraryLiveLine {
    var libraryLine: String? { openCount > 0 ? "\(openCount) open" : "No open loops" }
}

extension TimeWidget: LibraryLiveLine {
    var libraryLine: String? {
        if !state.timers.isEmpty { return libraryCount(state.timers.count, "timer", "timers", none: "") }
        return state.stopwatch.isRunning ? "Stopwatch running" : "No timers"
    }
}

extension HUDWidget: LibraryLiveLine {
    var libraryLine: String? {
        switch status {
        case .on: "On"
        case .needsAccessibility: "Needs access"
        case .tapRefused, .stopped: "Off"
        }
    }

    var libraryTitle: String? { "Volume HUD" }
    /// Without Accessibility the system HUD shows: Settings has the one path to it.
    var needsSetup: Bool { status == .needsAccessibility }
}

extension ShelfWidget: LibraryLiveLine {
    var libraryLine: String? { libraryCount(items.count, "item", "items", none: "Empty") }
}

extension ClipboardWidget: LibraryLiveLine {
    var libraryLine: String? {
        paused ? "Paused" : libraryCount(items.count, "item", "items", none: "Empty")
    }

    var libraryTitle: String? { "Clipboard" }
}

extension RemindersWidget: LibraryLiveLine {
    var libraryLine: String? {
        if needsSetup { return "Needs access" }
        return dueCount > 0 ? "\(dueCount) due today" : "Nothing due"
    }

    /// Without Reminders access there is nothing it can list or add.
    var needsSetup: Bool { reminders.access == .notAsked || reminders.access == .denied }
}

extension WeatherWidget: LibraryLiveLine {
    var libraryLine: String? {
        guard place != nil else { return "Choose a city" }
        guard let weather else { return "Updating" }
        let d = WeatherCode.describe(weather.code, isDay: weather.isDay)
        return "\(WeatherFormat.temperature(weather.temperatureC, unit: unit)) \(d.text)"
    }

    /// No city: nothing to forecast until one is chosen in Settings.
    var needsSetup: Bool { place == nil }
}

extension WellbeingWidget: LibraryLiveLine {
    var libraryLine: String? { "Water \(glassesToday()) of \(settings.dailyWaterGoal)" }
}

extension SystemWidget: LibraryLiveLine {
    /// The battery on a laptop; a desktop has none, so keep-awake speaks instead.
    var libraryLine: String? {
        if let battery { return "Battery \(battery.percent)%" }
        return liveActivities.isEmpty ? "Keep awake" : "Keeping awake"
    }
}

extension GamesWidget: LibraryLiveLine {
    var libraryLine: String? { "\(GameKind.allCases.count) games" }
}

extension LaunchWidget: LibraryLiveLine {
    var libraryLine: String? {
        libraryCount(pins.sites.count + pins.shortcuts.count, "pinned", "pinned", none: "Nothing pinned")
    }

    var libraryTitle: String? { "Sites" }
}

extension NotesWidget: LibraryLiveLine {
    var libraryLine: String? {
        if !tasks.isEmpty { return libraryCount(tasks.count, "task", "tasks", none: "") }
        return vault?.lastPathComponent ?? "Quick notes"
    }
}

extension MirrorWidget: LibraryLiveLine {
    var libraryLine: String? {
        switch tileState {
        case .live: "On"
        case .denied, .restricted: "Needs access"
        default: "Click to show"
        }
    }

    /// The camera was refused: only System Settings can turn it back on. Never asked yet is
    /// not this: the tool's Show Mirror button is where macOS asks.
    var needsSetup: Bool {
        switch tileState {
        case .denied, .restricted: true
        default: false
        }
    }

    var setupAction: WidgetSetupAction { .run { [weak self] in self?.openCameraSettings() } }
}

extension MailWidget: LibraryLiveLine {
    var libraryLine: String? {
        switch phase {
        case .off, .notOpen: "Mail is not open"
        case .loading: "Reading Mail"
        case .needsAllow, .denied: "Needs access"
        case .failed: "No answer"
        case .inbox(let inbox): inbox.unread > 0 ? "\(inbox.unread) unread" : "No unread mail"
        }
    }

    /// Automation never allowed (or refused): it cannot read Mail until it is.
    var needsSetup: Bool {
        switch phase {
        case .needsAllow, .denied: true
        default: false
        }
    }

    /// Allow asks macOS (the only place the prompt appears); a refusal opens System Settings.
    var setupAction: WidgetSetupAction {
        .run { [weak self] in
            guard let self else { return }
            if case .denied = self.phase { self.openAutomationSettings() } else { Task { await self.allow() } }
        }
    }
}

extension WindowSnapWidget: LibraryLiveLine {
    var libraryLine: String? { "\u{2303}\u{2325} arrows" }
    var libraryTitle: String? { "Snapping" }
    /// The shortcuts do nothing without Accessibility.
    var needsSetup: Bool { status == .needsAccessibility }
}

extension FileActionsWidget: LibraryLiveLine {
    var libraryLine: String? { "Right-click items" }
}

extension BasketsWidget: LibraryLiveLine {
    var libraryLine: String? { "Drag, then shake" }
}
