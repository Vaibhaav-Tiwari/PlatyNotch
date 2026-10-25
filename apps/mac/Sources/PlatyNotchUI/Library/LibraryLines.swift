import PlatyNotchKit
import SwiftUI

// The built-in tools' Library lines (spec 6.6: "one live line such as '2 timers' or
// '5 items'"), read when the grid draws. Counts only: nothing here asks for data.

/// "1 item" / "3 items"; nil at zero.
@MainActor
func libraryCount(_ n: Int, _ one: String, _ many: String) -> String? {
    n <= 0 ? nil : n == 1 ? "1 \(one)" : "\(n) \(many)"
}

extension MusicWidget: LibraryLiveLine {
    var libraryLine: String? { nowPlaying.title }
}

extension FocusWidget: LibraryLiveLine {
    var libraryLine: String? {
        guard let timer = focus.timer else { return "25, 50 or 90 min" }
        return timer.phase == .paused ? "Paused" : focus.focusActive ? "Focusing" : "Done"
    }
}

extension LoopsWidget: LibraryLiveLine {
    var libraryLine: String? { openCount > 0 ? "\(openCount) open" : nil }
}

extension TimeWidget: LibraryLiveLine {
    var libraryLine: String? {
        if let timers = libraryCount(state.timers.count, "timer", "timers") { return timers }
        return state.stopwatch.isRunning ? "Stopwatch running" : nil
    }
}

extension HUDWidget: LibraryLiveLine {
    var libraryLine: String? { nil }
    var libraryTitle: String? { "Volume HUD" }
}

extension ShelfWidget: LibraryLiveLine {
    var libraryLine: String? { libraryCount(items.count, "item", "items") }
}

extension ClipboardWidget: LibraryLiveLine {
    var libraryLine: String? { libraryCount(items.count, "item", "items") }
    var libraryTitle: String? { "Clipboard" }
}

extension RemindersWidget: LibraryLiveLine {
    var libraryLine: String? { dueCount > 0 ? "\(dueCount) due today" : nil }
}

extension GamesWidget: LibraryLiveLine {
    var libraryLine: String? { "\(GameKind.allCases.count) games" }
}

extension LaunchWidget: LibraryLiveLine {
    var libraryLine: String? { libraryCount(pins.sites.count + pins.shortcuts.count, "pinned", "pinned") }
    var libraryTitle: String? { "Sites" }
}

extension NotesWidget: LibraryLiveLine {
    var libraryLine: String? { libraryCount(tasks.count, "open task", "open tasks") }
}

extension MailWidget: LibraryLiveLine {
    var libraryLine: String? { unreadCount > 0 ? "\(unreadCount) unread" : nil }
}

extension WindowSnapWidget: LibraryLiveLine {
    var libraryLine: String? { status == .on ? "Shortcuts on" : nil }
    var libraryTitle: String? { "Snapping" }
}

extension FileActionsWidget: LibraryLiveLine {
    var libraryLine: String? { "From the shelf" }
}
