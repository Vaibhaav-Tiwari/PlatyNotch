import Foundation

/// The four chasers' personalities (the classic's four targeting rules).
public enum ChaserKind: Int, CaseIterable, Equatable, Sendable {
    /// Targets the player's tile; speeds up as the dots run out.
    case chaser
    /// Targets four tiles ahead of the player.
    case ambusher
    /// Doubles the vector from the chaser to two tiles ahead of the player.
    case flanker
    /// Chases when 8 or more tiles away, retreats to its corner when closer.
    case shy

    /// The scatter corner: a tile outside the maze near its home corner.
    public var scatterTarget: Point {
        switch self {
        case .chaser: Point(x: 25, y: -3)
        case .ambusher: Point(x: 2, y: -3)
        case .flanker: Point(x: 27, y: 32)
        case .shy: Point(x: 0, y: 32)
        }
    }
}

public enum ChaserState: Equatable, Sendable {
    /// Waiting in the house (bobbing).
    case home
    /// Going out through the door.
    case leaving
    /// In the maze.
    case active
    /// Eaten: eyes going back to the house.
    case eyes
    /// Eyes going down into the house (then out again, revived).
    case entering
}

/// A chaser: position in tiles (centre at +0.5), heading and state.
public struct Chaser: Equatable, Sendable {
    public let kind: ChaserKind
    public var x: Double
    public var y: Double
    public var dir: Direction
    public var state: ChaserState
    /// Blue and running (frightened mode).
    public var frightened = false
    /// Its personal ghost-house dot counter.
    public var dotCounter = 0
    /// A mode changed while it was inside: it leaves to the right.
    public var exitRight = false
    /// A forced reversal is due: it turns round on entering its next tile.
    public var reversePending = false

    public init(kind: ChaserKind, x: Double, y: Double, dir: Direction, state: ChaserState) {
        self.kind = kind
        self.x = x
        self.y = y
        self.dir = dir
        self.state = state
    }

    public var tile: Point { PlatyChase.tile(x, y) }
}

public enum ChaseMode: Equatable, Sendable { case scatter, chase }

public enum ChasePhase: Equatable, Sendable {
    /// "Ready!": a pause before play (start, after a lost life, each level).
    case ready
    case playing
    /// Everything stops for a moment while the eaten chaser's points show.
    case chaserEaten
    /// Caught: a freeze, then the death animation.
    case dying
    /// Every dot eaten: the maze flashes, then the next level.
    case levelClear
    case over
}

/// Points shown where something was eaten.
public struct ChasePopup: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var points: Int
    public var framesLeft: Int
}

/// A bonus item on the maze.
public struct ChaseBonusItem: Equatable, Sendable {
    public var kind: ChaseBonus
    public var framesLeft: Int
}

/// Platy Chase: a maze game with the classic arcade rules, timings and chaser AI (see
/// `ChaseRules` for every number and its source), on our own maze (`ChaseMaze`).
/// Pure and deterministic for a seed; advanced one arcade frame (1/60 s) at a time by
/// `frame()`, steered by `turn(_:)` (buffered: a turn pressed early is taken at the next
/// opening).
public struct PlatyChase: Equatable, Sendable {
    public private(set) var level: ChaseLevel
    /// Dots and pellets left (`.dot`, `.pellet`; eaten ones are `.empty`).
    public private(set) var food: [[ChaseTile]]
    public private(set) var dotsEaten = 0
    public private(set) var dotsLeft: Int
    public private(set) var score = 0
    public private(set) var lives = ChaseRules.startLives
    public private(set) var isOver = false
    public private(set) var phase: ChasePhase = .ready
    /// Frames spent in the current phase (animations).
    public private(set) var phaseFrames = 0
    /// Frames played in total (animations).
    public private(set) var frames = 0

    public private(set) var playerX: Double
    public private(set) var playerY: Double
    public private(set) var playerDir: Direction = .left
    public private(set) var playerMoving = true
    /// The buffered turn.
    public private(set) var wanted: Direction?
    /// Distance travelled (the bill's chomp).
    public private(set) var travelled: Double = 0
    private var pauseFrames = 0

    public private(set) var chasers: [Chaser]
    public private(set) var mode: ChaseMode = .scatter
    /// Frames of scatter/chase so far this life (paused while frightened).
    public private(set) var modeClock = 0
    /// The frame (`frames`) of the last forced reversal (mode change or power pellet).
    public private(set) var lastReversal = -1
    public private(set) var frightFrames = 0
    private var eatenInFright = 0
    /// nil: personal counters; a value: the global counter (after a lost life).
    private var globalCounter: Int?
    private var sinceDotFrames = 0
    private var elroySuspended = false
    private var extraLifeGiven = false
    public private(set) var bonus: ChaseBonusItem?
    public private(set) var popups: [ChasePopup] = []
    private var rng: SeededRNG
    /// Frightened turns: restarted from `frightSeed` each level and after a lost life.
    private var frightRNG: SeededRNG
    private let frightSeed: UInt64

    public init(seed: UInt64, level: Int = 1) {
        rng = SeededRNG(seed: seed)
        frightSeed = seed ^ 0x5DEE_CE66_D1CE_F00D
        frightRNG = SeededRNG(seed: frightSeed)
        self.level = ChaseRules.level(level)
        food = ChaseMaze.tiles
        dotsLeft = ChaseMaze.dotCount + ChaseMaze.pelletCount
        playerX = ChaseMaze.playerStart.x
        playerY = ChaseMaze.playerStart.y
        chasers = Self.startChasers()
    }

    // MARK: - Public helpers

    /// The tile under a position (x wraps through the tunnel).
    public static func tile(_ x: Double, _ y: Double) -> Point {
        let w = ChaseMaze.width
        let tx = ((Int(floor(x)) % w) + w) % w
        return Point(x: tx, y: Int(floor(y)))
    }

    public var playerTile: Point { Self.tile(playerX, playerY) }

    /// The direct chaser is in "Elroy" mode 1 or 2 (0: not).
    public var elroy: Int {
        guard !elroySuspended else { return 0 }
        if dotsLeft <= level.elroy2Dots { return 2 }
        if dotsLeft <= level.elroy1Dots { return 1 }
        return 0
    }

    /// The end of a fright: blue and white in turn.
    public var frightFlashing: Bool { Self.flashing(frightFrames: frightFrames, flashes: level.frightFlashes) }

    /// While flashing: the white half of a flash.
    public var flashWhite: Bool { Self.white(frightFrames: frightFrames, flashes: level.frightFlashes) }

    /// The last `flashes` flashes of a fright (14 frames each) flash.
    public static func flashing(frightFrames: Int, flashes: Int) -> Bool {
        frightFrames > 0 && frightFrames <= flashes * frames(ChaseRules.flashTime)
    }

    /// Each flash is 7 frames white, then 7 blue.
    public static func white(frightFrames: Int, flashes: Int) -> Bool {
        let half = max(frames(ChaseRules.flashTime) / 2, 1)
        return flashing(frightFrames: frightFrames, flashes: flashes) && ((frightFrames - 1) / half) % 2 == 1
    }

    /// Steer: kept until it can be taken.
    public mutating func turn(_ d: Direction) {
        guard !isOver else { return }
        wanted = d
    }

    // MARK: - Targeting (pure)

    /// A chaser's target tile in scatter or chase: the classic four rules, including the
    /// arcade's quirk where "ahead" while facing up is also as far to the left.
    public static func target(kind: ChaserKind, mode: ChaseMode, player: Point, playerDir: Direction,
                              chaserTile: Point, own: Point, elroy: Int) -> Point {
        let scatter = mode == .scatter && !(kind == .chaser && elroy > 0)
        if scatter { return kind.scatterTarget }
        switch kind {
        case .chaser:
            return player
        case .ambusher:
            return ahead(player, playerDir, 4)
        case .flanker:
            let pivot = ahead(player, playerDir, 2)
            return Point(x: pivot.x * 2 - chaserTile.x, y: pivot.y * 2 - chaserTile.y)
        case .shy:
            let dx = own.x - player.x
            let dy = own.y - player.y
            return dx * dx + dy * dy >= 64 ? player : kind.scatterTarget
        }
    }

    private static func ahead(_ p: Point, _ d: Direction, _ n: Int) -> Point {
        var t = Point(x: p.x + d.dx * n, y: p.y + d.dy * n)
        if d == .up { t.x -= n }   // the arcade's overflow: up also means left
        return t
    }

    /// The classic's tie-break order.
    public static let turnOrder: [Direction] = [.up, .left, .down, .right]

    /// The exit from `tile` closest (straight line) to `target`, never back the way it came;
    /// ties go up, left, down, right.
    public static func choose(from tile: Point, heading: Direction, target: Point,
                              allowed: (Direction) -> Bool) -> Direction {
        var best: Direction?
        var bestDistance = Int.max
        for d in turnOrder where d != heading.opposite && allowed(d) {
            let dx = tile.x + d.dx - target.x
            let dy = tile.y + d.dy - target.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                best = d
                bestDistance = distance
            }
        }
        return best ?? heading.opposite
    }

    // MARK: - Frame

    /// One arcade frame (1/60 s).
    public mutating func frame() {
        guard !isOver else { return }
        frames += 1
        phaseFrames += 1
        for i in popups.indices { popups[i].framesLeft -= 1 }
        popups.removeAll { $0.framesLeft <= 0 }
        switch phase {
        case .ready:
            if phaseFrames >= Self.frames(ChaseRules.readyTime) { enter(.playing) }
        case .chaserEaten:
            if phaseFrames >= Self.frames(ChaseRules.chaserEatenFreeze) { enter(.playing) }
        case .dying:
            if phaseFrames >= Self.frames(ChaseRules.deathFreeze + ChaseRules.deathAnimation) { loseLife() }
        case .levelClear:
            if phaseFrames >= Self.frames(ChaseRules.levelClearTime) { nextLevel() }
        case .playing:
            tick()
        case .over:
            break
        }
    }

    static func frames(_ seconds: Double) -> Int { Int((seconds * 60).rounded()) }

    private mutating func enter(_ p: ChasePhase) {
        phase = p
        phaseFrames = 0
    }

    private mutating func tick() {
        timers()
        release()
        movePlayer()
        guard phase == .playing else { return }
        if collide() { return }
        for i in chasers.indices { moveChaser(i) }
        _ = collide()
    }

    // MARK: - Timers and modes

    private mutating func timers() {
        if frightFrames > 0 {
            frightFrames -= 1
            if frightFrames == 0 {
                for i in chasers.indices { chasers[i].frightened = false }
            }
        } else {
            modeClock += 1
            let next = ChaseRules.mode(afterFrames: modeClock, schedule: level.schedule)
            if next != mode {
                mode = next
                reverseChasers()
            }
        }
        if var b = bonus {
            b.framesLeft -= 1
            bonus = b.framesLeft > 0 ? b : nil
        }
        sinceDotFrames += 1
    }

    /// A mode change (or a power pellet): every chaser in the maze turns round as it enters
    /// its next tile; those in the house will leave to the right.
    private mutating func reverseChasers() {
        lastReversal = frames
        for i in chasers.indices {
            switch chasers[i].state {
            case .active: chasers[i].reversePending = true
            case .home, .leaving: chasers[i].exitRight = true
            case .eyes, .entering: break
            }
        }
    }

    // MARK: - Ghost house

    private var preferredHome: Int? {
        let order: [ChaserKind] = [.ambusher, .flanker, .shy]
        for kind in order {
            if let i = chasers.firstIndex(where: { $0.kind == kind && $0.state == .home }) { return i }
        }
        return nil
    }

    private mutating func release() {
        if globalCounter == nil, let i = preferredHome {
            let limit = level.houseDotLimits[chasers[i].kind.rawValue - 1]
            if chasers[i].dotCounter >= limit { letOut(i) }
        }
        if sinceDotFrames >= Self.frames(level.dotTimerLimit) {
            sinceDotFrames = 0
            if let i = preferredHome { letOut(i) }
        }
    }

    private mutating func letOut(_ i: Int) {
        guard chasers[i].state == .home else { return }
        chasers[i].state = .leaving
        if chasers[i].kind == .shy { elroySuspended = false }
    }

    private mutating func countDot() {
        sinceDotFrames = 0
        if let g = globalCounter {
            let count = g + 1
            globalCounter = count
            let rule = ChaseRules.globalRelease
            if count == rule[0], let i = homeIndex(.ambusher) { letOut(i) }
            if count == rule[1], let i = homeIndex(.flanker) { letOut(i) }
            if count == rule[2], let i = homeIndex(.shy) {
                letOut(i)
                globalCounter = nil
            }
        } else if let i = preferredHome {
            chasers[i].dotCounter += 1
        }
    }

    private func homeIndex(_ kind: ChaserKind) -> Int? {
        chasers.firstIndex { $0.kind == kind && $0.state == .home }
    }

    // MARK: - Player

    private func playerCanEnter(_ t: Point) -> Bool {
        let tile = ChaseMaze.tile(t.x, t.y)
        return tile != .wall && tile != .door && tile != .house
    }

    private mutating func movePlayer() {
        if pauseFrames > 0 {
            pauseFrames -= 1
            return
        }
        let speed: Double = frightFrames > 0 ? level.playerFrightSpeed : level.playerSpeed
        let dist: Double = speed * ChaseRules.maxSpeed * ChaseRules.frame
        tryTurn()
        guard playerMoving else { return }
        let horizontal = playerDir.dx != 0
        let s = Double(horizontal ? playerDir.dx : playerDir.dy)
        var along = horizontal ? playerX : playerY
        let t = playerTile
        let next = Point(x: t.x + playerDir.dx, y: t.y + playerDir.dy)
        if playerCanEnter(next) {
            along += s * dist
        } else {
            // A wall ahead: go on only to the tile's centre, then stop.
            let centre = floor(along) + 0.5
            let toCentre = (centre - along) * s
            if toCentre <= dist {
                along = centre
                playerMoving = false
            } else {
                along += s * dist
            }
        }
        // Cornering: the other axis closes on its centre at the same speed (diagonal).
        var perp = horizontal ? playerY : playerX
        let perpCentre = floor(perp) + 0.5
        perp = perp < perpCentre ? min(perp + dist, perpCentre) : max(perp - dist, perpCentre)
        if horizontal {
            playerX = along
            playerY = perp
        } else {
            playerY = along
            playerX = perp
        }
        playerX = Self.wrap(playerX)
        travelled += dist
        eat()
    }

    /// Takes the buffered turn if it can: a reversal at once; a turn into an open side
    /// anywhere before the centre (pre-turn) or up to 3 pixels past it (post-turn).
    private mutating func tryTurn() {
        guard let w = wanted else { return }
        let t = playerTile
        let open = playerCanEnter(Point(x: t.x + w.dx, y: t.y + w.dy))
        if !playerMoving {
            if open {
                playerDir = w
                playerMoving = true
            }
            return
        }
        if w == playerDir { return }
        if w == playerDir.opposite {
            playerDir = w
            return
        }
        guard open else { return }
        let horizontal = playerDir.dx != 0
        let along = horizontal ? playerX : playerY
        let s = Double(horizontal ? playerDir.dx : playerDir.dy)
        let past = (along - (floor(along) + 0.5)) * s
        if Self.cornerAllowed(pastCentre: past, moving: playerDir) { playerDir = w }
    }

    /// Can a turn be taken this far past the tile's centre (negative: before it) while
    /// moving `d`? The pre-turn and post-turn windows of `ChaseRules.cornerWindow`.
    public static func cornerAllowed(pastCentre: Double, moving d: Direction) -> Bool {
        let w = ChaseRules.cornerWindow(d)
        return pastCentre >= -w.pre - 1e-9 && pastCentre <= w.post + 1e-9
    }

    private static func wrap(_ x: Double) -> Double {
        let w = Double(ChaseMaze.width)
        if x < 0 { return x + w }
        if x >= w { return x - w }
        return x
    }

    private mutating func eat() {
        let t = playerTile
        guard t.y >= 0, t.y < ChaseMaze.height else { return }
        switch food[t.y][t.x] {
        case .dot:
            food[t.y][t.x] = .empty
            add(ChaseRules.dotPoints)
            pauseFrames = ChaseRules.dotPauseFrames
            ateDot()
        case .pellet:
            food[t.y][t.x] = .empty
            add(ChaseRules.pelletPoints)
            pauseFrames = ChaseRules.pelletPauseFrames
            frighten()
            ateDot()
        default:
            break
        }
        if let b = bonus, t.y == Int(ChaseMaze.bonusSpot.y), abs(playerX - ChaseMaze.bonusSpot.x) < 0.75 {
            add(b.kind.points)
            popups.append(ChasePopup(x: ChaseMaze.bonusSpot.x, y: ChaseMaze.bonusSpot.y, points: b.kind.points,
                                     framesLeft: Self.frames(2)))
            bonus = nil
        }
    }

    private mutating func ateDot() {
        dotsEaten += 1
        dotsLeft -= 1
        countDot()
        if ChaseRules.bonusAtDots.contains(dotsEaten) {
            let span = ChaseRules.bonusTime
            let seconds = span.lowerBound + rng.unit() * (span.upperBound - span.lowerBound)
            bonus = ChaseBonusItem(kind: level.bonus, framesLeft: Self.frames(seconds))
        }
        if dotsLeft == 0 { enter(.levelClear) }
    }

    private mutating func add(_ points: Int) {
        score += points
        if !extraLifeGiven, score >= ChaseRules.extraLifeAt {
            extraLifeGiven = true
            lives += 1
        }
    }

    private mutating func frighten() {
        eatenInFright = 0
        reverseChasers()
        guard level.frightTime > 0 else { return }
        frightFrames = Self.frames(level.frightTime)
        for i in chasers.indices where chasers[i].state != .eyes && chasers[i].state != .entering {
            chasers[i].frightened = true
        }
    }

    // MARK: - Chasers

    private func speed(of c: Chaser) -> Double {
        switch c.state {
        case .eyes, .entering: return ChaseRules.eyesSpeed
        case .home, .leaving: return ChaseRules.houseSpeed
        case .active: break
        }
        let t = c.tile
        if ChaseMaze.isTunnel(t.x, t.y) { return level.chaserTunnelSpeed }
        if c.frightened { return level.chaserFrightSpeed }
        if c.kind == .chaser {
            switch elroy {
            case 2: return level.elroy2Speed
            case 1: return level.elroy1Speed
            default: break
            }
        }
        return level.chaserSpeed
    }

    private mutating func moveChaser(_ i: Int) {
        let dist: Double = speed(of: chasers[i]) * ChaseRules.maxSpeed * ChaseRules.frame
        switch chasers[i].state {
        case .home: bob(i, dist)
        case .leaving: leave(i, dist)
        case .entering: enterHouse(i, dist)
        case .active, .eyes: roam(i, dist)
        }
    }

    private mutating func bob(_ i: Int, _ dist: Double) {
        var c = chasers[i]
        let top = ChaseMaze.houseCentre.y - 0.5
        let bottom = ChaseMaze.houseCentre.y + 0.5
        if c.dir != .up && c.dir != .down { c.dir = .up }
        c.y += Double(c.dir.dy) * dist
        if c.y <= top {
            c.y = top
            c.dir = .down
        } else if c.y >= bottom {
            c.y = bottom
            c.dir = .up
        }
        chasers[i] = c
    }

    private mutating func leave(_ i: Int, _ dist: Double) {
        var c = chasers[i]
        let door = ChaseMaze.doorTop
        if abs(c.x - door.x) > 1e-9 {
            c.dir = c.x < door.x ? .right : .left
            c.x = c.x < door.x ? min(c.x + dist, door.x) : max(c.x - dist, door.x)
        } else {
            c.dir = .up
            c.y = max(c.y - dist, door.y)
            if c.y <= door.y {
                c.state = .active
                c.dir = c.exitRight ? .right : .left
                c.exitRight = false
            }
        }
        chasers[i] = c
    }

    private mutating func enterHouse(_ i: Int, _ dist: Double) {
        var c = chasers[i]
        c.x = ChaseMaze.doorTop.x
        c.dir = .down
        c.y = min(c.y + dist, ChaseMaze.houseCentre.y)
        if c.y >= ChaseMaze.houseCentre.y {
            c.state = .leaving
            c.frightened = false
        }
        chasers[i] = c
    }

    /// Moves along the maze, choosing a direction at each tile centre.
    private mutating func roam(_ i: Int, _ dist: Double) {
        var c = chasers[i]
        var remaining = dist
        while remaining > 1e-12 {
            let horizontal = c.dir.dx != 0
            let s = Double(horizontal ? c.dir.dx : c.dir.dy)
            let along = horizontal ? c.x : c.y
            var toCentre = (floor(along) + 0.5 - along) * s
            if toCentre <= 1e-9 { toCentre += 1 }
            if c.reversePending {
                // Turn round on entering the next tile (the edge comes before the centre).
                var toEdge = s > 0 ? floor(along) + 1 - along : along - floor(along)
                if toEdge <= 1e-9 { toEdge += 1 }
                if toEdge < toCentre, toEdge <= remaining {
                    let edge = (along + s * toEdge).rounded()
                    if horizontal { c.x = Self.wrap(edge) } else { c.y = edge }
                    remaining -= toEdge
                    c.dir = c.dir.opposite
                    c.reversePending = false
                    continue
                }
            }
            if toCentre > remaining {
                if horizontal { c.x = Self.wrap(c.x + s * remaining) } else { c.y += s * remaining }
                break
            }
            remaining -= toCentre
            if horizontal {
                c.x = Self.wrap(floor(c.x + s * toCentre) + 0.5)
            } else {
                c.y = floor(c.y + s * toCentre) + 0.5
            }
            let t = c.tile
            if c.state == .eyes, t.y == Int(ChaseMaze.doorTop.y), t.x == 13 || t.x == 14 {
                c.state = .entering
                c.x = ChaseMaze.doorTop.x
                break
            }
            c.dir = decide(c, at: t)
            if horizontal == (c.dir.dx != 0) { continue }
            // Turned: line up on the new axis's centre line.
            if c.dir.dx != 0 { c.y = floor(c.y) + 0.5 } else { c.x = floor(c.x) + 0.5 }
        }
        chasers[i] = c
    }

    private mutating func decide(_ c: Chaser, at t: Point) -> Direction {
        let frightened = c.frightened && c.state == .active
        let noUp = !frightened && c.state == .active && ChaseMaze.noUpTiles.contains(t)
        let allowed: (Direction) -> Bool = { d in
            if noUp && d == .up { return false }
            let tile = ChaseMaze.tile(t.x + d.dx, t.y + d.dy)
            return tile != .wall && tile != .door && tile != .house
        }
        if frightened {
            let order = ChaseRules.clockwise
            let start = frightRNG.below(4)
            for k in 0..<4 {
                let d = order[(start + k) % 4]
                if d != c.dir.opposite && allowed(d) { return d }
            }
            return c.dir.opposite
        }
        let goal: Point
        if c.state == .eyes {
            goal = Point(x: 13, y: Int(ChaseMaze.doorTop.y))
        } else {
            let red = chasers.first { $0.kind == .chaser }?.tile ?? t
            goal = Self.target(kind: c.kind, mode: mode, player: playerTile, playerDir: playerDir,
                               chaserTile: red, own: t, elroy: elroy)
        }
        return Self.choose(from: t, heading: c.dir, target: goal, allowed: allowed)
    }

    // MARK: - Collisions, lives, levels

    /// Player and chaser on one tile: a frightened one is eaten, any other catches.
    private mutating func collide() -> Bool {
        let p = playerTile
        for i in chasers.indices where chasers[i].state == .active && chasers[i].tile == p {
            if chasers[i].frightened {
                let points = ChaseRules.chaserPoints[min(eatenInFright, ChaseRules.chaserPoints.count - 1)]
                eatenInFright += 1
                add(points)
                popups.append(ChasePopup(x: chasers[i].x, y: chasers[i].y, points: points,
                                         framesLeft: Self.frames(ChaseRules.chaserEatenFreeze)))
                chasers[i].state = .eyes
                chasers[i].frightened = false
                chasers[i].reversePending = false
                enter(.chaserEaten)
            } else {
                enter(.dying)
            }
            return true
        }
        return false
    }

    private mutating func loseLife() {
        lives -= 1
        if lives <= 0 {
            isOver = true
            enter(.over)
            return
        }
        resetActors()
        globalCounter = 0
        elroySuspended = true
        frightRNG = SeededRNG(seed: frightSeed)
        enter(.ready)
    }

    private mutating func nextLevel() {
        level = ChaseRules.level(level.number + 1)
        food = ChaseMaze.tiles
        dotsEaten = 0
        dotsLeft = ChaseMaze.dotCount + ChaseMaze.pelletCount
        globalCounter = nil
        elroySuspended = false
        frightRNG = SeededRNG(seed: frightSeed)
        resetActors()
        enter(.ready)
    }

    private mutating func resetActors() {
        playerX = ChaseMaze.playerStart.x
        playerY = ChaseMaze.playerStart.y
        playerDir = .left
        playerMoving = true
        wanted = nil
        pauseFrames = 0
        let counters = chasers.map(\.dotCounter)
        chasers = Self.startChasers()
        if globalCounter != nil || phase == .dying {
            for i in chasers.indices { chasers[i].dotCounter = counters[i] }   // a lost life keeps them
        }
        mode = .scatter
        modeClock = 0
        frightFrames = 0
        sinceDotFrames = 0
        bonus = nil
        popups = []
    }

    private static func startChasers() -> [Chaser] {
        [
            Chaser(kind: .chaser, x: ChaseMaze.doorTop.x, y: ChaseMaze.doorTop.y, dir: .left, state: .active),
            Chaser(kind: .ambusher, x: ChaseMaze.houseCentre.x, y: ChaseMaze.houseCentre.y, dir: .down, state: .home),
            Chaser(kind: .flanker, x: ChaseMaze.houseLeft.x, y: ChaseMaze.houseLeft.y, dir: .up, state: .home),
            Chaser(kind: .shy, x: ChaseMaze.houseRight.x, y: ChaseMaze.houseRight.y, dir: .up, state: .home),
        ]
    }

    // MARK: - Test seams

    /// Places the player (tests).
    public mutating func placePlayer(x: Double, y: Double, dir: Direction, moving: Bool = true) {
        playerX = x
        playerY = y
        playerDir = dir
        playerMoving = moving
    }

    /// Replaces a chaser (tests).
    public mutating func setChaser(_ c: Chaser) {
        if let i = chasers.firstIndex(where: { $0.kind == c.kind }) { chasers[i] = c }
    }

    /// Skips the "Ready!" pause (tests).
    public mutating func skipReady() {
        if phase == .ready { enter(.playing) }
    }

    /// Counts a dot as eaten without moving (tests: house counters, bonus items).
    public mutating func simulateDotEaten() {
        ateDot()
    }

    /// Adds points (tests: the extra life).
    public mutating func addPoints(_ points: Int) {
        add(points)
    }

    /// Clears every dot but `keep` (tests: Elroy, the last dot).
    public mutating func clearFood(keeping keep: Int) {
        var left = 0
        for y in food.indices {
            for x in food[y].indices where food[y][x] == .dot || food[y][x] == .pellet {
                if left < keep { left += 1 } else { food[y][x] = .empty }
            }
        }
        dotsEaten += dotsLeft - left
        dotsLeft = left
    }
}
