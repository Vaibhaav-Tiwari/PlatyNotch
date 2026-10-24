import Foundation
import PlatyNotchKit
import SwiftUI

/// The expanded panel's Games tab: game picker, score and the board.
///
/// Frames come from a `TimelineView(.animation)` capped at 60 fps and paused whenever
/// `GameHost.isRunning` is false (not playing, paused, blocked, or 2048): a paused game
/// costs nothing per frame. Keys reach the game only after a click on the board
/// (`GameKeyCatcher`). While an approval is pending the board is replaced by a one-line
/// note, so the approval cards keep their room and every key.
/// Every size is explicit (`GameLayout`): no ideal size ever reaches the window.
struct GamesTab: View {
    let host: GameHost
    @Environment(\.gamePanel) private var panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var surfaceID = UUID()
    @State private var focused = false

    var body: some View {
        Group {
            if host.approvalPending {
                approvalNote
            } else {
                game
            }
        }
        .onAppear { report() }
        .onChange(of: panel) { report() }
        .onDisappear { host.surfaceGone(surfaceID) }
    }

    private func report() {
        let surface = GameSurface(shown: panel.expanded && panel.visible, fullScreen: panel.fullScreen,
                                  focused: focused)
        host.surfaceChanged(surfaceID, surface)
    }

    private var approvalNote: some View {
        Label("Game paused while an approval is waiting", systemImage: "pause.circle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var game: some View {
        let area = GameLayout.boardArea
        let tab = GameLayout.tabSize
        return VStack(spacing: GameLayout.spacing) {
            header
                .frame(width: area.width, height: GameLayout.headerHeight)
            board
                .frame(width: area.width, height: area.height)
        }
        .frame(width: tab.width, height: tab.height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var header: some View {
        let session = host.session
        return HStack(spacing: 4) {
            ForEach(GameKind.allCases) { kind in
                let selected = kind == session.kind
                Button { host.select(kind) } label: {
                    Text(verbatim: kind.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(selected ? Theme.card : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 8)
            Text(verbatim: "Score \(session.score)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
            Text(verbatim: "Best \(session.best)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var board: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !host.isRunning)) { timeline in
                GameBoard(session: host.session, date: timeline.date, decorate: !reduceMotion)
                    .onChange(of: timeline.date) { _, date in
                        host.frame(now: date.timeIntervalSinceReferenceDate, from: surfaceID)
                    }
            }
            GameKeyCatcher(onKey: { host.handle($0, from: surfaceID) },
                           onFocus: { setFocused($0) },
                           onClick: {})
            overlay
                .allowsHitTesting(false)
        }
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
    }

    private func setFocused(_ on: Bool) {
        guard focused != on else { return }
        focused = on
        report()
    }

    @ViewBuilder private var overlay: some View {
        if let text = overlayText {
            GameOverlayCard(title: text.title, detail: text.detail)
                .transition(overlayTransition)
        }
    }

    /// Snake's game-over card waits for the death animation; everything else (and every
    /// card with Reduce Motion) appears at once.
    private var overlayTransition: AnyTransition {
        let s = host.session
        guard !reduceMotion, s.kind == .snake, s.phase == .over else { return .identity }
        let delayed = Animation.easeIn(duration: 0.18).delay(SnakeCanvas.deathDuration)
        return .asymmetric(insertion: .opacity.animation(delayed), removal: .identity)
    }

    private var overlayText: (title: String, detail: String)? {
        let s = host.session
        if s.blockers.ringing { return ("Paused", "Something is ringing") }
        if s.blockers.fullScreen { return ("Paused", "A full-screen app is in front") }
        if s.phase == .playing, focused, !s.blockers.isBlocked { return nil }
        if !focused {
            let detail = s.phase == .paused ? "then Space to resume" : s.kind.help
            return ("Click to play", detail)
        }
        switch s.phase {
        case .ready: return ("Press Space", s.kind.help)
        case .paused: return ("Paused", "Press Space to resume")
        case .over:
            let title = s.newBest != nil ? "New best: \(s.score)!" : "Game over · \(s.score)"
            return (title, "Press Space to play again")
        case .playing: return nil
        }
    }
}

/// The shown game's board, centred in the board area.
struct GameBoard: View {
    let session: GameSession
    let date: Date
    /// Decorative motion (food pulse, wing beat and tilt, 2048 slides, Snake's death);
    /// false with Reduce Motion.
    let decorate: Bool

    var body: some View {
        content
            .frame(width: GameLayout.boardArea.width, height: GameLayout.boardArea.height)
    }

    @ViewBuilder private var content: some View {
        switch session.kind {
        case .snake: SnakeView(snake: session.snake, deaths: session.snakeDeaths, pulse: pulse, animate: decorate)
        case .tetris: TetrisView(tetris: session.tetris)
        case .twenty48: Game2048View(game: session.game2048, moves: session.moves2048, animate: decorate)
        case .flappy: FlappyView(flappy: session.flappy, decorate: decorate)
        case .chase: ChaseView(game: session.chase, decorate: decorate)
        }
    }

    private var pulse: Double {
        guard decorate, session.isRunning else { return 0 }
        let t: Double = date.timeIntervalSinceReferenceDate * 5
        return (sin(t) + 1) / 2
    }
}

/// The card over a board: "Press Space", "Paused", "Game over".
struct GameOverlayCard: View {
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 3) {
            Text(verbatim: title).font(.system(size: 13, weight: .semibold))
            Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface(scheme).opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
    }
}
