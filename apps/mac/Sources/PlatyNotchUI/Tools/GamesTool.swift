import PlatyNotchKit
import SwiftUI

/// The Games tool (Island spec 4): one row per game with its hint and best score; a click
/// opens the game in the panel.
struct GamesTool: View {
    let host: GameHost
    @Environment(\.openPanelRoute) private var openRoute

    /// A row: pick the game and open its board full-panel (`games.play`).
    static func play(_ kind: GameKind, host: GameHost, openRoute: ((PanelRoute) -> Void)?) {
        host.select(kind)
        openRoute?(PanelRoute(destination: .home, tool: CommandRunner.gameTool(kind)))
    }

    static func hint(_ kind: GameKind) -> String {
        switch kind {
        case .snake: "Eat, grow, don't bite"
        case .tetris: "Clear the lines"
        case .twenty48: "Slide to 2048"
        case .flappy: "Flap through the gaps"
        case .chase: "Arcade maze"
        }
    }

    static func symbol(_ kind: GameKind) -> String {
        switch kind {
        case .snake: "scribble.variable"
        case .tetris: "square.stack.3d.up"
        case .twenty48: "square.grid.2x2"
        case .flappy: "bird"
        case .chase: "hare"
        }
    }

    /// Title and "<hint> · best 4,120" ("best" left out at 0).
    static func rows(_ scores: HighScores, locale: Locale = .current) -> [(title: String, detail: String)] {
        GameKind.allCases.map { kind in
            let best = scores.best(kind.rawValue)
            let detail = best > 0 ? "\(hint(kind)) · best \(best.formatted(.number.locale(locale)))" : hint(kind)
            return (kind.title, detail)
        }
    }

    var body: some View {
        let rows = Self.rows(host.session.scores)
        ToolList(items: Array(zip(GameKind.allCases, rows))) { pair in
            Button {
                // The board takes the whole panel (its own surface, no card).
                Self.play(pair.0, host: host, openRoute: openRoute)
            } label: {
                ToolRow(symbol: Self.symbol(pair.0), icon: nil, title: pair.1.title, detail: pair.1.detail,
                        selected: false) {
                    Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(DS.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
