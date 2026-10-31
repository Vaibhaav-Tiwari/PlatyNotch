import Foundation
import PlatyNotchKit

/// What the command line can do, as closures so tests spy on them (spec 3). A String
/// return is the row's message (a reason it did not run); nil means done.
struct CommandActions {
    var startTimer: (TimeInterval, String?) -> Bool = { _, _ in false }
    var startFocus: (Int) -> String? = { _ in nil }
    var remind: (QuickAdd) -> String? = { _ in nil }
    var note: (String) -> String? = { _ in nil }
    var search: (String) -> Void = { _ in }
    var open: (PanelRoute) -> Void = { _ in }
    var selectGame: (GameKind) -> Void = { _ in }
}

/// Runs the suggestion the user chose with Return or a click. Nothing runs from typing.
@MainActor
final class CommandRunner {
    private let actions: CommandActions

    init(actions: CommandActions) {
        self.actions = actions
    }

    /// Runs `s`; the message to show in its row, or nil when it ran. An explanation row
    /// (no command) never runs and has no message of its own to add.
    func run(_ s: CommandSuggestion) -> String? {
        guard let command = s.command else { return nil }
        switch command {
        case .timer(let duration, let label):
            return actions.startTimer(duration, label) ? nil : "Turn on Time in Settings, or clear a finished timer"
        case .focus(let minutes):
            return actions.startFocus(minutes)
        case .remind(let q):
            return actions.remind(q)
        case .note(let text):
            return actions.note(text)
        case .search(let query):
            actions.search(query)
            actions.open(PanelRoute(destination: .home, tool: PanelTools.memory))
            return nil
        case .play(let kind):
            if let kind { actions.selectGame(kind) }
            actions.open(PanelRoute(destination: .home, tool: kind == .chase ? PanelTools.chase : GamesWidget.widgetID))
            return nil
        case .open(let tool):
            actions.open(PanelRoute(destination: .home, tool: tool))
            return nil
        }
    }
}
