import CoreGraphics
import Foundation

public enum GameKind: String, CaseIterable, Identifiable, Sendable {
    case snake, tetris, twenty48 = "2048", flappy, chase

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .snake: "Snake"
        case .tetris: "Tetris"
        case .twenty48: "2048"
        case .flappy: "Flappy"
        case .chase: "Platy Chase"
        }
    }

    /// The Today tile's narrow buttons.
    public var shortTitle: String { self == .chase ? "Chase" : title }

    /// Real-time games need the frame loop; 2048 is turn-based and draws only on a move.
    public var usesFrames: Bool { self != .twenty48 }

    /// What the keys do, for the "Press Space" overlay.
    public var help: String {
        switch self {
        case .snake: "Arrows or WASD steer"
        case .tetris: "←→ move · ↑ rotate · ↓ drop · Space slams"
        case .twenty48: "Arrows or WASD slide the tiles"
        case .flappy: "Space or ↑ flaps"
        case .chase: "Arrows or WASD steer · turns wait for the next opening"
        }
    }
}

/// The keys games take: arrows, WASD, Space and Escape. Nothing with ⌘, ⌃ or ⌥ is ever a
/// game key: ⌘↩ / ⌘⌫ belong to the approval cards (C30). `isRepeat` marks an auto-repeat
/// of a held key: it never starts, restarts or resumes a game (or slams another piece).
public struct GameKey: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable { case up, down, left, right, space, escape }

    public enum Modifier: Hashable, Sendable { case shift, command, control, option }

    public var kind: Kind
    public var isRepeat: Bool

    public init(_ kind: Kind, isRepeat: Bool = false) {
        self.kind = kind
        self.isRepeat = isRepeat
    }

    public static let up = GameKey(.up)
    public static let down = GameKey(.down)
    public static let left = GameKey(.left)
    public static let right = GameKey(.right)
    public static let space = GameKey(.space)
    public static let escape = GameKey(.escape)

    public init?(keyCode: UInt16, characters: String?, modifiers: Set<Modifier>, isRepeat: Bool = false) {
        guard modifiers.isDisjoint(with: [.command, .control, .option]),
              let kind = Self.kind(keyCode: keyCode, characters: characters) else { return nil }
        self.init(kind, isRepeat: isRepeat)
    }

    private static func kind(keyCode: UInt16, characters: String?) -> Kind? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 49: return .space
        case 53: return .escape
        default:
            switch characters?.lowercased() {
            case "w": return .up
            case "a": return .left
            case "s": return .down
            case "d": return .right
            default: return nil
            }
        }
    }

    public var direction: Direction? {
        switch kind {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .space, .escape: nil
        }
    }

    public var description: String { isRepeat ? "\(kind) (repeat)" : "\(kind)" }
}

public enum GamePhase: Equatable, Sendable {
    /// Not started: "Press Space".
    case ready
    case playing
    /// Stopped where it was; Space resumes exactly there.
    case paused
    case over
}

/// Why a game may not run now. Any one pauses a playing game at once (Task 10 ruling):
/// a pending approval, something ringing, the panel collapsed (or the games tab not on
/// screen), keyboard focus lost (the panel resigned key or the board lost first
/// responder), a full-screen app on the panel's display.
public struct GameBlockers: Equatable, Sendable {
    public var approval: Bool
    public var ringing: Bool
    public var collapsed: Bool
    public var keyLost: Bool
    public var fullScreen: Bool

    public init(approval: Bool = false, ringing: Bool = false, collapsed: Bool = false,
                keyLost: Bool = false, fullScreen: Bool = false) {
        self.approval = approval
        self.ringing = ringing
        self.collapsed = collapsed
        self.keyLost = keyLost
        self.fullScreen = fullScreen
    }

    public var isBlocked: Bool { approval || ringing || collapsed || keyLost || fullScreen }

    /// The reason shown on the paused board, most important first.
    public var reason: String? {
        if approval { return "Paused: an approval is waiting" }
        if ringing { return "Paused: something is ringing" }
        if fullScreen { return "Paused over full screen" }
        if keyLost || collapsed { return "Click to play" }
        return nil
    }
}

/// A finished game's score.
public struct GameResult: Equatable, Sendable {
    public var kind: GameKind
    public var score: Int

    public init(kind: GameKind, score: Int) {
        self.kind = kind
        self.score = score
    }
}

/// The five games and what the player is doing with them: which one is shown, each one's
/// phase, the high scores, and the frame clock. Pure and deterministic for a seed; the UI
/// (`GameHost`) feeds it blockers, keys and frame times.
///
/// Each game advances only through its engine (C30): Snake `step`, Tetris `tick` /
/// `apply`, 2048 `move`, Flappy `step(dt:)`, Platy Chase `frame` / `turn`. A blocked game takes no frame; keys reach it
/// only while it plays and nothing blocks it, and never while an approval is pending.
public struct GameSession: Equatable, Sendable {
    /// Seconds per Snake step at the start (`Snake.stepInterval` shortens it as it grows).
    public static let snakeStep: Double = Snake.slowestStep
    /// Flappy's fixed physics step.
    public static let flappyStep: Double = 1.0 / 120.0
    /// Platy Chase advances in arcade frames.
    public static let chaseStep: Double = ChaseRules.frame
    /// The most time one frame may add (a hitch never teleports the game).
    public static let maxFrameGap: Double = 0.25

    public private(set) var kind: GameKind
    public var snake: Snake
    public var tetris: Tetris
    public var game2048: Game2048
    public var flappy: Flappy
    public var chase: PlatyChase
    public private(set) var phases: [GameKind: GamePhase] = [:]
    /// Collapsed until a panel reports otherwise.
    public private(set) var blockers = GameBlockers(collapsed: true)
    public var scores: HighScores
    /// The last game over was a new best (Platy celebrates, Task 13); cleared by the next game.
    public private(set) var newBest: GameResult?
    /// Snake deaths and 2048 moves so far, across games: they only go up (a new game
    /// keeps them), so the views' one-shot animations, which play when these change,
    /// never play for a new game.
    public private(set) var snakeDeaths = 0
    public private(set) var moves2048 = 0
    private var rng: SeededRNG
    private var lastTime: Double?
    private var accumulator: Double = 0

    public init(kind: GameKind = .snake, seed: UInt64, scores: HighScores = HighScores()) {
        var rng = SeededRNG(seed: seed)
        self.kind = kind
        snake = Snake(seed: rng.next())
        tetris = Tetris(seed: rng.next())
        game2048 = Game2048(seed: rng.next())
        flappy = Flappy(seed: rng.next())
        chase = PlatyChase(seed: rng.next())
        self.scores = scores
        self.rng = rng
    }

    public var phase: GamePhase { phases[kind] ?? .ready }

    /// Whether frames should come: playing a real-time game with nothing blocking it.
    public var isRunning: Bool { phase == .playing && !blockers.isBlocked && kind.usesFrames }

    /// The shown game's score.
    public var score: Int {
        switch kind {
        case .snake: snake.score
        case .tetris: tetris.score
        case .twenty48: game2048.score
        case .flappy: flappy.score
        case .chase: chase.score
        }
    }

    public var best: Int { scores.best(kind.rawValue) }

    /// Shows another game; a playing one pauses (each keeps its state).
    public mutating func select(_ k: GameKind) {
        guard k != kind else { return }
        pauseIfPlaying()
        kind = k
        resetClock()
    }

    public mutating func setBlockers(_ b: GameBlockers) {
        blockers = b
        if b.isBlocked { pauseIfPlaying() }
    }

    /// Handles a key; false when the game does not take it (it then goes on to the panel:
    /// Escape closes it). While an approval is pending no key is the game's.
    public mutating func key(_ k: GameKey) -> Bool {
        if blockers.approval { return false }
        switch k.kind {
        case .escape:
            guard phase == .playing else { return false }
            pauseIfPlaying()
            return true
        case .space:
            guard !blockers.isBlocked else { return true }   // taken, but nothing resumes
            // A held Space auto-repeats: it must not skip the game-over screen into a new
            // game, resume right after a pause, or slam piece after piece.
            guard !k.isRepeat || (phase == .playing && kind == .flappy) else { return true }
            switch phase {
            case .ready, .over: newGame()
            case .paused:
                phases[kind] = .playing
                resetClock()
            case .playing: act(k)
            }
            return true
        case .up, .down, .left, .right:
            if phase == .playing, !blockers.isBlocked { act(k) }
            return true
        }
    }

    /// A frame at `time` (seconds, any monotonic clock). The first frame after a start,
    /// resume or block only sets the clock: time spent paused never counts.
    public mutating func advance(to time: Double) {
        guard isRunning else {
            resetClock()
            return
        }
        guard let last = lastTime else {
            lastTime = time
            return
        }
        lastTime = time
        accumulator += min(max(time - last, 0), Self.maxFrameGap)
        switch kind {
        case .snake:
            // The interval is read before every step: eating shortens the next one.
            while accumulator >= snake.stepInterval, !snake.isOver {
                let interval = snake.stepInterval
                snake.step()
                accumulator -= interval
            }
        case .tetris:
            let interval = tetris.tickInterval
            while accumulator >= interval, !tetris.isOver {
                tetris.tick()
                accumulator -= interval
            }
        case .flappy:
            while accumulator >= Self.flappyStep, !flappy.isOver {
                flappy.step(dt: Self.flappyStep)
                accumulator -= Self.flappyStep
            }
        case .chase:
            while accumulator >= Self.chaseStep, !chase.isOver {
                chase.frame()
                accumulator -= Self.chaseStep
            }
        case .twenty48:
            break
        }
        finishIfOver()
    }

    // MARK: - Private

    private mutating func act(_ k: GameKey) {
        switch kind {
        case .snake:
            if let d = k.direction { snake.turn(d) }
        case .tetris:
            switch k.kind {
            case .left: tetris.apply(.left)
            case .right: tetris.apply(.right)
            case .up: tetris.apply(.rotate)
            case .down: tetris.apply(.softDrop)
            case .space: tetris.apply(.hardDrop)
            case .escape: break
            }
        case .twenty48:
            let before = game2048.lastMove?.serial
            if let d = k.direction { game2048.move(d) }
            if game2048.lastMove?.serial != before { moves2048 += 1 }
        case .flappy:
            if k.kind == .space || k.kind == .up { flappy.flap() }
        case .chase:
            if let d = k.direction { chase.turn(d) }
        }
        finishIfOver()
    }

    private mutating func newGame() {
        let seed = rng.next()
        switch kind {
        case .snake: snake = Snake(seed: seed)
        case .tetris: tetris = Tetris(seed: seed)
        case .twenty48: game2048 = Game2048(seed: seed)
        case .flappy: flappy = Flappy(seed: seed)
        case .chase: chase = PlatyChase(seed: seed)
        }
        newBest = nil
        phases[kind] = .playing
        resetClock()
    }

    private var engineOver: Bool {
        switch kind {
        case .snake: snake.isOver
        case .tetris: tetris.isOver
        case .twenty48: game2048.isOver
        case .flappy: flappy.isOver
        case .chase: chase.isOver
        }
    }

    private mutating func finishIfOver() {
        guard phase == .playing, engineOver else { return }
        phases[kind] = .over
        resetClock()
        if kind == .snake { snakeDeaths += 1 }
        let result = GameResult(kind: kind, score: score)
        if scores.record(game: kind.rawValue, score: result.score) { newBest = result }
    }

    private mutating func pauseIfPlaying() {
        if phase == .playing {
            phases[kind] = .paused
            if kind == .chase { chase.cancelTurn() }   // a turn pressed before the pause is forgotten
        }
        resetClock()
    }

    private mutating func resetClock() {
        lastTime = nil
        accumulator = 0
    }
}

/// Sizes of the games in the expanded panel's tab (explicit frames: SwiftUI ideal sizes
/// must never size the panel's window). Checked against `PanelLayout.expandedSize` in tests.
public enum GameLayout {
    /// Game picker, score and best.
    public static let headerHeight: CGFloat = 20
    public static let spacing: CGFloat = 4
    /// Where a board (and its overlay) sits: all the room the Games tool has below its
    /// picker (`PanelLayout.expandedSize` less the notch inset, padding, the tool header
    /// and its gap; checked in tests). 264 fits Platy Chase's 263.5 pt maze.
    public static let boardArea = CGSize(width: 528, height: 264)
    public static var tabSize: CGSize {
        let h: CGFloat = headerHeight + spacing + boardArea.height
        return CGSize(width: boardArea.width, height: h)
    }

    public static let snakeCell: CGFloat = 21
    /// 13 pt cells: a 130 × 260 portrait well, nearly the board area's full height.
    public static let tetrisCell: CGFloat = 13
    /// The stats column (left) and the next-pieces column (right) of the Tetris well.
    public static let tetrisSide: CGFloat = 96
    public static let tetrisGap: CGFloat = 14
    public static let tile: CGFloat = 58
    /// 6 keeps the 4 × 4 grid (262 pt) inside the Games tool's 264 pt board area.
    public static let tileGap: CGFloat = 6
    /// Flappy world units (the original's pixels) to points.
    public static let flappyScale: CGFloat = 0.6
    /// Platy Chase: 8.5 pt tiles, a 238 × 263.5 maze between two info columns.
    public static let chaseTile: CGFloat = 8.5
    public static let chaseSide: CGFloat = 104
    public static let chaseGap: CGFloat = 14

    public static func boardSize(_ kind: GameKind) -> CGSize {
        switch kind {
        case .snake:
            return CGSize(width: snakeCell * 24, height: snakeCell * 8)
        case .tetris:
            let well: CGFloat = tetrisCell * 10
            let sides: CGFloat = (tetrisSide + tetrisGap) * 2
            return CGSize(width: well + sides, height: tetrisCell * 20)
        case .twenty48:
            let side: CGFloat = tile * 4 + tileGap * 5
            return CGSize(width: side, height: side)
        case .chase:
            let maze: CGFloat = chaseTile * CGFloat(ChaseMaze.width)
            let sides: CGFloat = (chaseSide + chaseGap) * 2
            return CGSize(width: maze + sides, height: chaseTile * CGFloat(ChaseMaze.height))
        case .flappy:
            let w: CGFloat = CGFloat(Flappy.width) * flappyScale
            let h: CGFloat = CGFloat(Flappy.height + Flappy.groundDepth) * flappyScale
            return CGSize(width: w, height: h)
        }
    }
}
