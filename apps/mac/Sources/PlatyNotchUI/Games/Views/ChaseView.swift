import PlatyNotchKit
import SwiftUI

/// Platy Chase: the maze (8.5 pt tiles, 238 × 263.5) between the level and dots column
/// (left) and the lives and bonus column (right). Everything is drawn here in code, as a
/// night creek: dark water, sandy banks with a mossy edge (one path, built once), dots
/// and blinking pellets, Platy with a chomping bill, four pond creatures (each its own
/// colour and crest; muddy brown when frightened, pale when flashing, eyes only when
/// eaten), the bonus snacks and the score popups.
struct ChaseView: View {
    let game: PlatyChase
    /// Chomp, wiggle, pellet blink and the death spin (off with Reduce Motion).
    let decorate: Bool

    var body: some View {
        let size = GameLayout.boardSize(.chase)
        let t: CGFloat = GameLayout.chaseTile
        let maze = CGSize(width: t * CGFloat(ChaseMaze.width), height: t * CGFloat(ChaseMaze.height))
        HStack(alignment: .top, spacing: GameLayout.chaseGap) {
            info
                .frame(width: GameLayout.chaseSide, alignment: .topTrailing)
            Canvas { ctx, _ in ChaseArt.draw(game, in: ctx, decorate: decorate) }
                .frame(width: maze.width, height: maze.height)
            extras
                .frame(width: GameLayout.chaseSide, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .accessibilityLabel("Platy Chase, level \(game.level.number), score \(game.score), \(game.lives) lives")
    }

    private var info: some View {
        VStack(alignment: .trailing, spacing: 6) {
            stat("Level", "\(game.level.number)")
            stat("Dots left", "\(game.dotsLeft)")
        }
        .padding(.top, 4)
    }

    private var extras: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lives").font(DS.font(TypeScale.caption).weight(.semibold)).foregroundStyle(.secondary)
            Canvas { ctx, _ in
                let shown = min(max(game.lives - 1, 0), 5)   // the one in play is on the maze
                for i in 0..<shown {
                    let c = CGPoint(x: 9 + CGFloat(i) * 18, y: 9)
                    ChaseArt.drawPlaty(in: ctx, at: c, tile: 9, dir: .right, open: 0.5)
                }
            }
            .frame(width: GameLayout.chaseSide, height: 18)
            Text("Bonus").font(DS.font(TypeScale.caption).weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 6)
            HStack(spacing: 6) {
                Canvas { ctx, size in
                    ChaseArt.drawBonus(game.level.bonus, in: ctx, at: CGPoint(x: size.width / 2, y: size.height / 2), tile: 11)
                }
                .frame(width: 24, height: 24)
                Text(verbatim: "\(game.level.bonus.points)").font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
        }
        .padding(.top, 4)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(title).font(DS.font(TypeScale.caption).weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 15, weight: .medium)).monospacedDigit()
        }
    }
}

/// Platy Chase's drawing, in tile units scaled by `GameLayout.chaseTile`.
enum ChaseArt {
    /// Deep creek water at night.
    static let background = Color(platyHex: 0x0A1A1C)
    /// The banks: a sandy line inside a mossy edge.
    static let wall = Color(platyHex: 0xE2B05A)
    static let wallEdge = Color(platyHex: 0x5E9A55)
    static let wallFlash = Color(platyHex: 0xFFF4DC)
    /// The house door: a row of reeds.
    static let door = Color(platyHex: 0x9CCB6B)
    static let dot = Color(platyHex: 0xF6E7C6)
    static let ready = Color(platyHex: 0x9BCBB5)
    static let points = Color(platyHex: 0xFFD25A)
    /// Frightened: a muddy brown critter with a pale face; flashing turns it pale.
    static let frightBody = Color(platyHex: 0x8A7352)
    static let frightFace = Color(platyHex: 0xF3E6C8)
    static let flashBody = Color(platyHex: 0xF3E6C8)
    static let flashFace = Color(platyHex: 0x6B5236)

    /// Violet, sunflower, cornflower and lime: none of the arcade's four, and far apart in
    /// lightness as well as hue (each also has its own crest shape).
    static func colour(_ kind: ChaserKind) -> Color {
        switch kind {
        case .chaser: Color(platyHex: 0xB98CFF)
        case .ambusher: Color(platyHex: 0xF5D33B)
        case .flanker: Color(platyHex: 0x3D6BFF)
        case .shy: Color(platyHex: 0x86C94A)
        }
    }

    /// The walls' outline: built once. Each wall tile draws its open sides 0.3 tile in,
    /// so neighbouring tiles join into rounded-cornered blocks.
    static let wallPath: Path = buildWalls()

    private static func isWall(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < ChaseMaze.width, y >= 0, y < ChaseMaze.height else { return true }
        return ChaseMaze.tiles[y][x] == .wall
    }

    private static func buildWalls() -> Path {
        var p = Path()
        let i: CGFloat = 0.32
        for y in 0..<ChaseMaze.height {
            for x in 0..<ChaseMaze.width where isWall(x, y) {
                let fx = CGFloat(x)
                let fy = CGFloat(y)
                let up = !isWall(x, y - 1)
                let down = !isWall(x, y + 1)
                let left = !isWall(x - 1, y)
                let right = !isWall(x + 1, y)
                let x0: CGFloat = left ? fx + i : fx
                let x1: CGFloat = right ? fx + 1 - i : fx + 1
                let y0: CGFloat = up ? fy + i : fy
                let y1: CGFloat = down ? fy + 1 - i : fy + 1
                if up { line(&p, CGPoint(x: x0, y: fy + i), CGPoint(x: x1, y: fy + i)) }
                if down { line(&p, CGPoint(x: x0, y: fy + 1 - i), CGPoint(x: x1, y: fy + 1 - i)) }
                if left { line(&p, CGPoint(x: fx + i, y: y0), CGPoint(x: fx + i, y: y1)) }
                if right { line(&p, CGPoint(x: fx + 1 - i, y: y0), CGPoint(x: fx + 1 - i, y: y1)) }
                // Inside corners: both neighbours are wall but the diagonal is open.
                for (dx, dy) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] {
                    guard isWall(x + dx, y), isWall(x, y + dy), !isWall(x + dx, y + dy) else { continue }
                    let cx: CGFloat = dx < 0 ? fx : fx + 1
                    let cy: CGFloat = dy < 0 ? fy : fy + 1
                    let ix: CGFloat = dx < 0 ? fx + i : fx + 1 - i
                    let iy: CGFloat = dy < 0 ? fy + i : fy + 1 - i
                    line(&p, CGPoint(x: cx, y: iy), CGPoint(x: ix, y: iy))
                    line(&p, CGPoint(x: ix, y: iy), CGPoint(x: ix, y: cy))
                }
            }
        }
        return p
    }

    private static func line(_ p: inout Path, _ a: CGPoint, _ b: CGPoint) {
        p.move(to: a)
        p.addLine(to: b)
    }

    // MARK: - Frame

    static func draw(_ g: PlatyChase, in base: GraphicsContext, decorate: Bool) {
        let t: CGFloat = GameLayout.chaseTile
        let w: CGFloat = CGFloat(ChaseMaze.width)
        let h: CGFloat = CGFloat(ChaseMaze.height)
        base.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w * t, height: h * t), cornerRadius: 6), with: .color(background))
        var ctx = base
        ctx.clip(to: Path(CGRect(x: 0, y: 0, width: w * t, height: h * t)))
        ctx.scaleBy(x: t, y: t)
        drawWalls(g, in: ctx, decorate: decorate)
        drawFood(g, in: ctx, decorate: decorate)
        if let b = g.bonus { drawBonus(b.kind, in: ctx, at: CGPoint(x: ChaseMaze.bonusSpot.x, y: ChaseMaze.bonusSpot.y), tile: 1) }
        let deathFrames = g.phase == .dying ? g.phaseFrames : 0
        let freeze = Int(ChaseRules.deathFreeze * 60)
        let eating = g.phase == .chaserEaten
        if deathFrames <= freeze, g.phase != .levelClear {
            // While a chaser's points show, it and Platy give way to the number.
            for c in g.chasers where !(eating && c.state == .eyes) {
                drawChaser(c, game: g, in: ctx, decorate: decorate)
            }
        }
        if !eating { drawPlayer(g, in: ctx, decorate: decorate) }
        drawText(g, in: base, tile: t)
    }

    private static func drawWalls(_ g: PlatyChase, in ctx: GraphicsContext, decorate: Bool) {
        var colour = wall
        if g.phase == .levelClear, decorate, (g.phaseFrames / 12) % 2 == 1 { colour = wallFlash }
        let edge: Color = colour == wallFlash ? wallFlash : wallEdge
        ctx.stroke(wallPath, with: .color(edge.opacity(0.55)), style: StrokeStyle(lineWidth: 0.46, lineCap: .round, lineJoin: .round))
        ctx.stroke(wallPath, with: .color(colour), style: StrokeStyle(lineWidth: 0.16, lineCap: .round, lineJoin: .round))
        // The door: a low line of reeds across the house's mouth.
        var reeds = Path()
        for k in 0..<6 {
            let x: CGFloat = 13.17 + CGFloat(k) * 0.33
            let top: CGFloat = k % 2 == 0 ? 12.22 : 12.32
            reeds.move(to: CGPoint(x: x, y: 12.78))
            reeds.addLine(to: CGPoint(x: x, y: top))
        }
        ctx.stroke(reeds, with: .color(door), style: StrokeStyle(lineWidth: 0.1, lineCap: .round))
    }

    private static func drawFood(_ g: PlatyChase, in ctx: GraphicsContext, decorate: Bool) {
        var dots = Path()
        var pellets = Path()
        for (y, row) in g.food.enumerated() {
            for (x, f) in row.enumerated() {
                let cx = CGFloat(x) + 0.5
                let cy = CGFloat(y) + 0.5
                if f == .dot {
                    dots.addRoundedRect(in: CGRect(x: cx - 0.12, y: cy - 0.12, width: 0.24, height: 0.24),
                                        cornerSize: CGSize(width: 0.06, height: 0.06))
                } else if f == .pellet {
                    pellets.addEllipse(in: CGRect(x: cx - 0.42, y: cy - 0.42, width: 0.84, height: 0.84))
                }
            }
        }
        ctx.fill(dots, with: .color(dot))
        let blinkOff = decorate && g.phase == .playing && (g.frames / 10) % 2 == 1
        if !blinkOff { ctx.fill(pellets, with: .color(dot)) }
    }

    // MARK: - Platy

    private static func drawPlayer(_ g: PlatyChase, in ctx: GraphicsContext, decorate: Bool) {
        let c = CGPoint(x: g.playerX, y: g.playerY)
        let freeze = Int(ChaseRules.deathFreeze * 60)
        if g.phase == .dying, g.phaseFrames > freeze {
            let total: Double = ChaseRules.deathAnimation * 60
            let p: Double = min(1, Double(g.phaseFrames - freeze) / total)
            guard decorate else { return }
            drawDeath(in: ctx, at: c, progress: p, dir: g.playerDir)
            return
        }
        if g.phase == .over { return }
        let open: Double = decorate ? chomp(g) : 0.5
        drawPlaty(in: ctx, at: c, tile: 1, dir: g.playerDir, open: open)
    }

    /// 0 shut … 1 wide: the bill opens and shuts as Platy moves (a chomp every ~0.8 tile).
    static func chomp(_ g: PlatyChase) -> Double {
        let phase: Double = g.travelled * 1.25
        return abs(sin(phase * Double.pi))
    }

    /// Platy from above-ish: a round teal body, a brown paddle tail behind, a cream duck
    /// bill in front whose two halves open by `open`, and an eye. `tile` scales it.
    static func drawPlaty(in base: GraphicsContext, at c: CGPoint, tile k: CGFloat, dir: Direction, open: Double) {
        var ctx = base
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: k, y: k)
        switch dir {
        case .right: break
        case .left: ctx.scaleBy(x: -1, y: 1)
        case .up: ctx.rotate(by: .degrees(-90))
        case .down: ctx.rotate(by: .degrees(90))
        }
        let line = PlatyPalette.outline
        let tail = Path(roundedRect: CGRect(x: -0.95, y: -0.28, width: 0.55, height: 0.56), cornerRadius: 0.2)
        ctx.fill(tail, with: .color(PlatyPalette.tail))
        ctx.stroke(tail, with: .color(line), lineWidth: 0.07)
        let body = Path(ellipseIn: CGRect(x: -0.62, y: -0.6, width: 1.18, height: 1.2))
        ctx.fill(body, with: .color(PlatyPalette.body))
        ctx.stroke(body, with: .color(line), lineWidth: 0.08)
        let angle: Double = 2 + open * 34
        drawJaw(in: ctx, angle: -angle, colour: PlatyPalette.bill, line: line)
        drawJaw(in: ctx, angle: angle, colour: PlatyPalette.billLower, line: line)
        ctx.fill(Path(ellipseIn: CGRect(x: 0.02, y: -0.44, width: 0.3, height: 0.3)), with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: 0.13, y: -0.38, width: 0.15, height: 0.17)), with: .color(PlatyPalette.eye))
    }

    /// One half of the duck bill: a wide, rounded wedge hinged at the face.
    private static func drawJaw(in base: GraphicsContext, angle: Double, colour: Color, line: Color) {
        var ctx = base
        ctx.translateBy(x: 0.4, y: 0)
        ctx.rotate(by: .degrees(angle))
        let upper = angle < 0
        var jaw = Path()
        let edge: CGFloat = upper ? -0.36 : 0.36
        jaw.move(to: CGPoint(x: -0.06, y: 0))
        jaw.addLine(to: CGPoint(x: 0.5, y: 0))
        jaw.addQuadCurve(to: CGPoint(x: 0.42, y: edge), control: CGPoint(x: 0.7, y: edge))
        jaw.addLine(to: CGPoint(x: -0.06, y: edge * 0.8))
        jaw.closeSubpath()
        ctx.fill(jaw, with: .color(colour))
        ctx.stroke(jaw, with: .color(line), style: StrokeStyle(lineWidth: 0.06, lineJoin: .round))
        if upper {
            ctx.fill(Path(ellipseIn: CGRect(x: 0.32, y: -0.22, width: 0.08, height: 0.06)), with: .color(PlatyPalette.nostril))
        }
    }

    /// Caught: Platy spins, shrinks and is gone in a few bubbles.
    static func drawDeath(in base: GraphicsContext, at c: CGPoint, progress p: Double, dir: Direction) {
        var ctx = base
        ctx.translateBy(x: c.x, y: c.y)
        let scale: CGFloat = CGFloat(max(0.001, 1 - p))
        var spun = ctx
        spun.rotate(by: .degrees(p * 540))
        spun.scaleBy(x: scale, y: scale)
        spun.opacity = 1 - p * 0.4
        drawPlaty(in: spun, at: .zero, tile: 1, dir: dir, open: 1)
        guard p > 0.35 else { return }
        let rise: Double = (p - 0.35) / 0.65
        let bubbles: [(Double, Double, Double)] = [(-0.5, 0.1, 0.18), (0.35, -0.1, 0.14), (0.05, 0.3, 0.22), (-0.2, -0.3, 0.12)]
        for (dx, dy, r) in bubbles {
            let y: Double = dy - rise * 1.6
            let rect = CGRect(x: dx - r, y: y - r, width: r * 2, height: r * 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(dot.opacity(1 - rise)), lineWidth: 0.06)
        }
    }

    // MARK: - Chasers

    private static func drawChaser(_ c: Chaser, game g: PlatyChase, in base: GraphicsContext, decorate: Bool) {
        let at = CGPoint(x: c.x, y: c.y)
        if c.state == .eyes || c.state == .entering {
            drawEyes(in: base, at: at, dir: c.dir)
            return
        }
        let wiggle: Bool = decorate && (g.frames / 8) % 2 == 1
        if c.frightened {
            let white = g.flashWhite
            drawFrightened(in: base, at: at, white: white, wiggle: wiggle)
        } else {
            drawCreature(c.kind, in: base, at: at, dir: c.dir, wiggle: wiggle)
        }
    }

    /// A pond creature: a round body on two feet, a crest of its own, a belly patch and big
    /// eyes looking where it goes.
    static func drawCreature(_ kind: ChaserKind, in base: GraphicsContext, at c: CGPoint, dir: Direction, wiggle: Bool) {
        var ctx = base
        ctx.translateBy(x: c.x, y: c.y)
        let colour = colour(kind)
        drawCrest(kind, in: ctx, colour: colour)
        ctx.fill(bodyPath(wiggle: wiggle), with: .color(colour))
        ctx.stroke(bodyPath(wiggle: wiggle), with: .color(.black.opacity(0.35)), lineWidth: 0.06)
        ctx.fill(Path(ellipseIn: CGRect(x: -0.34, y: 0.12, width: 0.68, height: 0.38)), with: .color(.white.opacity(0.28)))
        drawEyes(in: ctx, at: CGPoint(x: 0, y: -0.14), dir: dir)
    }

    /// A round pond critter: a ball of a body on two little feet that step in turn (no
    /// sheet-ghost skirt).
    private static func bodyPath(wiggle: Bool) -> Path {
        var p = Path(ellipseIn: CGRect(x: -0.66, y: -0.62, width: 1.32, height: 1.2))
        let left: CGFloat = wiggle ? 0.46 : 0.52
        let right: CGFloat = wiggle ? 0.52 : 0.46
        p.addEllipse(in: CGRect(x: -0.5, y: left, width: 0.36, height: 0.24))
        p.addEllipse(in: CGRect(x: 0.14, y: right, width: 0.36, height: 0.24))
        return p
    }

    /// Each creature's own crest: horns, a curly feeler, a fin, leaf ears.
    private static func drawCrest(_ kind: ChaserKind, in ctx: GraphicsContext, colour: Color) {
        var p = Path()
        switch kind {
        case .chaser:
            for s in [CGFloat(-1), 1] {
                p.move(to: CGPoint(x: 0.22 * s, y: -0.55))
                p.addLine(to: CGPoint(x: 0.45 * s, y: -0.98))
                p.addLine(to: CGPoint(x: 0.5 * s, y: -0.45))
                p.closeSubpath()
            }
            ctx.fill(p, with: .color(colour))
        case .ambusher:
            p.move(to: CGPoint(x: 0, y: -0.66))
            p.addQuadCurve(to: CGPoint(x: 0.3, y: -1.0), control: CGPoint(x: -0.1, y: -1.0))
            ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: 0.1, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: 0.22, y: -1.1, width: 0.2, height: 0.2)), with: .color(colour))
        case .flanker:
            p.move(to: CGPoint(x: -0.35, y: -0.6))
            p.addQuadCurve(to: CGPoint(x: 0.4, y: -0.55), control: CGPoint(x: 0.1, y: -1.15))
            p.closeSubpath()
            ctx.fill(p, with: .color(colour))
            ctx.stroke(p, with: .color(.black.opacity(0.25)), lineWidth: 0.05)
        case .shy:
            for s in [CGFloat(-1), 1] {
                let ear = CGRect(x: 0.45 * s - 0.17, y: -0.92, width: 0.34, height: 0.5)
                var leaf = ctx
                leaf.translateBy(x: ear.midX, y: ear.midY)
                leaf.rotate(by: .degrees(Double(s) * 25))
                leaf.fill(Path(ellipseIn: CGRect(x: -0.17, y: -0.25, width: 0.34, height: 0.5)), with: .color(colour))
            }
        }
    }

    private static func drawEyes(in base: GraphicsContext, at c: CGPoint, dir: Direction) {
        var ctx = base
        ctx.translateBy(x: c.x, y: c.y)
        let look = CGPoint(x: CGFloat(dir.dx) * 0.1, y: CGFloat(dir.dy) * 0.1)
        for s in [CGFloat(-1), 1] {
            let eye = CGRect(x: 0.28 * s - 0.17 + look.x * 0.5, y: -0.24 + look.y * 0.5, width: 0.34, height: 0.42)
            ctx.fill(Path(ellipseIn: eye), with: .color(.white))
            let pupil = CGRect(x: eye.midX - 0.09 + look.x, y: eye.midY - 0.1 + look.y, width: 0.18, height: 0.2)
            ctx.fill(Path(ellipseIn: pupil), with: .color(Color(platyHex: 0x1B2A6B)))
        }
    }

    private static func drawFrightened(in base: GraphicsContext, at c: CGPoint, white: Bool, wiggle: Bool) {
        var ctx = base
        ctx.translateBy(x: c.x, y: c.y)
        let body: Color = white ? flashBody : frightBody
        let face: Color = white ? flashFace : frightFace
        ctx.fill(bodyPath(wiggle: wiggle), with: .color(body))
        for s in [CGFloat(-1), 1] {
            ctx.fill(Path(ellipseIn: CGRect(x: 0.25 * s - 0.09, y: -0.2, width: 0.18, height: 0.18)), with: .color(face))
        }
        var mouth = Path()
        mouth.move(to: CGPoint(x: -0.45, y: 0.25))
        for k in 1...6 {
            let x: CGFloat = -0.45 + CGFloat(k) * 0.15
            let y: CGFloat = k % 2 == 0 ? 0.25 : 0.12
            mouth.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.stroke(mouth, with: .color(face), style: StrokeStyle(lineWidth: 0.07, lineJoin: .round))
    }

    // MARK: - Bonus snacks

    /// The level's snack, about 1.4 tiles across (`tile` scales it).
    static func drawBonus(_ b: ChaseBonus, in base: GraphicsContext, at c: CGPoint, tile k: CGFloat) {
        var ctx = base
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: k, y: k)
        switch b {
        case .shrimp: drawShrimp(ctx)
        case .snail: drawSnail(ctx)
        case .clam: drawClam(ctx)
        case .crayfish: drawCrayfish(ctx)
        case .frog: drawFrog(ctx)
        case .dragonfly: drawDragonfly(ctx)
        case .lily: drawLily(ctx)
        case .pearl: drawPearl(ctx)
        }
    }

    private static func drawShrimp(_ ctx: GraphicsContext) {
        var p = Path()
        p.addArc(center: .zero, radius: 0.5, startAngle: .degrees(200), endAngle: .degrees(110), clockwise: false)
        ctx.stroke(p, with: .color(Color(platyHex: 0xFF8A7A)), style: StrokeStyle(lineWidth: 0.32, lineCap: .round))
        ctx.stroke(p, with: .color(Color(platyHex: 0xFFC2B8)), style: StrokeStyle(lineWidth: 0.08, lineCap: .round, dash: [0.12, 0.1]))
        var feelers = Path()
        feelers.move(to: CGPoint(x: -0.45, y: -0.2))
        feelers.addLine(to: CGPoint(x: -0.75, y: -0.65))
        ctx.stroke(feelers, with: .color(Color(platyHex: 0xFF8A7A)), lineWidth: 0.05)
    }

    private static func drawSnail(_ ctx: GraphicsContext) {
        let foot = Path(roundedRect: CGRect(x: -0.65, y: 0.2, width: 1.3, height: 0.28), cornerRadius: 0.14)
        ctx.fill(foot, with: .color(Color(platyHex: 0xC9D7A0)))
        let shell = Path(ellipseIn: CGRect(x: -0.45, y: -0.5, width: 0.85, height: 0.85))
        ctx.fill(shell, with: .color(Color(platyHex: 0xC77B3A)))
        var spiral = Path()
        spiral.addArc(center: CGPoint(x: -0.03, y: -0.08), radius: 0.22, startAngle: .degrees(0), endAngle: .degrees(300), clockwise: false)
        ctx.stroke(spiral, with: .color(Color(platyHex: 0x7A4520)), lineWidth: 0.07)
    }

    private static func drawClam(_ ctx: GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: -0.6, y: 0.3))
        p.addQuadCurve(to: CGPoint(x: 0.6, y: 0.3), control: CGPoint(x: 0, y: -1.0))
        p.closeSubpath()
        ctx.fill(p, with: .color(Color(platyHex: 0xE8C9E8)))
        var ribs = Path()
        for x in [-0.3, 0.0, 0.3] {
            ribs.move(to: CGPoint(x: 0, y: 0.3))
            ribs.addLine(to: CGPoint(x: x, y: -0.25))
        }
        ctx.stroke(ribs, with: .color(Color(platyHex: 0xA97BB0)), lineWidth: 0.06)
        ctx.fill(Path(roundedRect: CGRect(x: -0.6, y: 0.28, width: 1.2, height: 0.18), cornerRadius: 0.08), with: .color(Color(platyHex: 0xC9A2CC)))
    }

    private static func drawCrayfish(_ ctx: GraphicsContext) {
        let red = Color(platyHex: 0xD9442E)
        ctx.fill(Path(ellipseIn: CGRect(x: -0.25, y: -0.3, width: 0.5, height: 0.85)), with: .color(red))
        for s in [CGFloat(-1), 1] {
            ctx.fill(Path(ellipseIn: CGRect(x: 0.4 * s - 0.2, y: -0.75, width: 0.4, height: 0.3)), with: .color(red))
            var arm = Path()
            arm.move(to: CGPoint(x: 0.15 * s, y: -0.2))
            arm.addLine(to: CGPoint(x: 0.4 * s, y: -0.55))
            ctx.stroke(arm, with: .color(red), lineWidth: 0.1)
        }
    }

    private static func drawFrog(_ ctx: GraphicsContext) {
        let green = Color(platyHex: 0x58C24A)
        ctx.fill(Path(ellipseIn: CGRect(x: -0.6, y: -0.3, width: 1.2, height: 0.8)), with: .color(green))
        for s in [CGFloat(-1), 1] {
            ctx.fill(Path(ellipseIn: CGRect(x: 0.3 * s - 0.17, y: -0.55, width: 0.34, height: 0.34)), with: .color(green))
            ctx.fill(Path(ellipseIn: CGRect(x: 0.3 * s - 0.08, y: -0.46, width: 0.16, height: 0.16)), with: .color(.black))
        }
        var smile = Path()
        smile.addArc(center: CGPoint(x: 0, y: 0.0), radius: 0.3, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
        ctx.stroke(smile, with: .color(Color(platyHex: 0x2E6B26)), lineWidth: 0.06)
    }

    private static func drawDragonfly(_ ctx: GraphicsContext) {
        let wing = Color(platyHex: 0xBFE9FF).opacity(0.9)
        for (dx, dy, r) in [(-0.38, -0.2, -20.0), (0.38, -0.2, 20.0), (-0.32, 0.12, 15.0), (0.32, 0.12, -15.0)] {
            var w = ctx
            w.translateBy(x: dx, y: dy)
            w.rotate(by: .degrees(r))
            w.fill(Path(ellipseIn: CGRect(x: -0.32, y: -0.1, width: 0.64, height: 0.2)), with: .color(wing))
        }
        ctx.fill(Path(roundedRect: CGRect(x: -0.07, y: -0.55, width: 0.14, height: 1.15), cornerRadius: 0.07),
                 with: .color(Color(platyHex: 0x2E8FD6)))
    }

    private static func drawLily(_ ctx: GraphicsContext) {
        ctx.fill(Path(ellipseIn: CGRect(x: -0.7, y: 0.0, width: 1.4, height: 0.5)), with: .color(Color(platyHex: 0x3E9B4F)))
        for r in stride(from: -60.0, through: 60.0, by: 30.0) {
            var petal = ctx
            petal.translateBy(x: 0, y: 0.1)
            petal.rotate(by: .degrees(r))
            petal.fill(Path(ellipseIn: CGRect(x: -0.13, y: -0.6, width: 0.26, height: 0.6)), with: .color(Color(platyHex: 0xFFB6D5)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: -0.12, y: -0.08, width: 0.24, height: 0.2)), with: .color(Color(platyHex: 0xFFD23F)))
    }

    private static func drawPearl(_ ctx: GraphicsContext) {
        let shell = Path(ellipseIn: CGRect(x: -0.7, y: -0.1, width: 1.4, height: 0.6))
        ctx.fill(shell, with: .color(Color(platyHex: 0x5D6F8C)))
        let pearl = Path(ellipseIn: CGRect(x: -0.32, y: -0.5, width: 0.64, height: 0.64))
        let shine = Gradient(colors: [.white, Color(platyHex: 0xD9D6F5)])
        ctx.fill(pearl, with: .radialGradient(shine, center: CGPoint(x: -0.1, y: -0.3), startRadius: 0, endRadius: 0.45))
    }

    // MARK: - Text

    private static func drawText(_ g: PlatyChase, in ctx: GraphicsContext, tile t: CGFloat) {
        for p in g.popups {
            let label = Text(verbatim: "\(p.points)").font(DS.font(TypeScale.caption).weight(.bold)).foregroundColor(points)
            ctx.draw(label, at: CGPoint(x: CGFloat(p.x) * t, y: CGFloat(p.y) * t))
        }
        if g.phase == .ready {
            let label = Text("Ready!").font(.system(size: 11, weight: .heavy)).foregroundColor(ready)
            ctx.draw(label, at: CGPoint(x: CGFloat(ChaseMaze.bonusSpot.x) * t, y: CGFloat(ChaseMaze.bonusSpot.y) * t))
        }
    }
}
