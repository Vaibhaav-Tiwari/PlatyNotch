import PlatyNotchKit
import SwiftUI

/// Flappy: the engine's world (the original's pixels) scaled by `GameLayout.flappyScale`.
/// All art is drawn here in code: a sky with drifting clouds and far bushes, capped pipes
/// with a highlight and a shade, a striped ground that scrolls with the world, and a
/// round, Platy-coloured bird with a duck bill and a beating wing that tilts with its speed.
struct FlappyView: View {
    let flappy: Flappy
    /// The wing beats and the bird tilts (both off with Reduce Motion: level, wing still).
    let decorate: Bool

    var body: some View {
        let size = GameLayout.boardSize(.flappy)
        Canvas { ctx, _ in FlappyArt.draw(flappy, in: ctx, size: size, decorate: decorate) }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .accessibilityLabel("Flappy, score \(flappy.score)")
    }
}

enum FlappyArt {
    static let skyTop = Color(platyHex: 0x3F8FCB)
    static let skyBottom = Color(platyHex: 0xB9E3F0)
    static let cloud = Color.white.opacity(0.85)
    static let bush = Color(platyHex: 0x8CCB6A)
    static let bushShade = Color(platyHex: 0x6FB052)
    static let pipe = Color(platyHex: 0x5CB83C)
    static let pipeLight = Color(platyHex: 0x9BE36F)
    static let pipeDark = Color(platyHex: 0x3C8A28)
    static let pipeLine = Color(platyHex: 0x24561A)
    static let grass = Color(platyHex: 0x7CCF4F)
    static let grassDark = Color(platyHex: 0x5EAE39)
    static let grassEdge = Color(platyHex: 0x3F7E2A)
    static let dirt = Color(platyHex: 0xDCCF8E)
    static let dirtLine = Color(platyHex: 0xB9A867)
    static let tailFeather = Color(platyHex: 0x7E5739)

    static let capHeight: Double = 24
    static let capOverhang: Double = 4

    static func draw(_ f: Flappy, in base: GraphicsContext, size: CGSize, decorate: Bool) {
        var ctx = base
        let k: CGFloat = GameLayout.flappyScale
        ctx.scaleBy(x: k, y: k)
        let w: Double = Flappy.width
        let h: Double = Flappy.height
        drawSky(in: ctx, width: w, height: h, distance: f.distance)
        for p in f.pipes { drawPipe(p, in: ctx, height: h) }
        drawGround(in: ctx, width: w, top: h, distance: f.distance)
        let tilt: Double = decorate ? Flappy.tilt(velocity: f.velocity) : 0
        let wing: Flappy.Wing = decorate ? f.wing : .middle
        drawBird(in: ctx, at: CGPoint(x: Flappy.birdX, y: f.birdY), tilt: tilt, wing: wing)
    }

    // MARK: - Scenery

    private static func drawSky(in ctx: GraphicsContext, width w: Double, height h: Double, distance: Double) {
        let sky = CGRect(x: 0, y: 0, width: w, height: h)
        let gradient = Gradient(colors: [skyTop, skyBottom])
        ctx.fill(Path(sky), with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        // Clouds drift at a fifth of the world's speed, bushes at half: depth.
        let cloudShift: Double = (distance * 0.2).truncatingRemainder(dividingBy: 290)
        var x: Double = -cloudShift
        while x < w + 60 {
            drawCloud(in: ctx, x: x + 40, y: 70, scale: 1)
            drawCloud(in: ctx, x: x + 190, y: 130, scale: 0.7)
            x += 290
        }
        let bushShift: Double = (distance * 0.5).truncatingRemainder(dividingBy: 120)
        var b: Double = -bushShift - 40
        while b < w + 60 {
            let big = CGRect(x: b, y: h - 34, width: 80, height: 60)
            let small = CGRect(x: b + 58, y: h - 22, width: 54, height: 40)
            ctx.fill(Path(ellipseIn: big), with: .color(bushShade))
            ctx.fill(Path(ellipseIn: small), with: .color(bush))
            b += 120
        }
    }

    private static func drawCloud(in ctx: GraphicsContext, x: Double, y: Double, scale s: Double) {
        let puffs: [(Double, Double, Double)] = [(0, 8, 22), (20, 0, 28), (46, 6, 22), (64, 12, 16)]
        for (dx, dy, r) in puffs {
            let rect = CGRect(x: x + dx * s, y: y + dy * s, width: r * 2 * s, height: r * 1.6 * s)
            ctx.fill(Path(ellipseIn: rect), with: .color(cloud))
        }
    }

    private static func drawGround(in ctx: GraphicsContext, width w: Double, top: Double, distance: Double) {
        let depth: Double = Flappy.groundDepth
        ctx.fill(Path(CGRect(x: 0, y: top, width: w, height: depth)), with: .color(dirt))
        let band: Double = 10
        ctx.fill(Path(CGRect(x: 0, y: top, width: w, height: band)), with: .color(grass))
        // Diagonal stripes that scroll exactly with the pipes.
        let period: Double = 22
        let shift: Double = distance.truncatingRemainder(dividingBy: period)
        var stripes = Path()
        var x: Double = -shift - period
        while x < w + period {
            stripes.move(to: CGPoint(x: x, y: top + band))
            stripes.addLine(to: CGPoint(x: x + 8, y: top))
            stripes.addLine(to: CGPoint(x: x + 16, y: top))
            stripes.addLine(to: CGPoint(x: x + 8, y: top + band))
            stripes.closeSubpath()
            x += period
        }
        ctx.fill(stripes, with: .color(grassDark))
        var edge = Path()
        edge.move(to: CGPoint(x: 0, y: top))
        edge.addLine(to: CGPoint(x: w, y: top))
        ctx.stroke(edge, with: .color(grassEdge), lineWidth: 3)
        var line = Path()
        line.move(to: CGPoint(x: 0, y: top + band + 1))
        line.addLine(to: CGPoint(x: w, y: top + band + 1))
        ctx.stroke(line, with: .color(dirtLine), lineWidth: 2)
    }

    // MARK: - Pipes

    private static func drawPipe(_ p: Flappy.Pipe, in ctx: GraphicsContext, height h: Double) {
        let top: Double = p.gapY - p.gapHeight / 2
        let bottom: Double = p.gapY + p.gapHeight / 2
        let pw: Double = Flappy.pipeWidth
        let o: Double = capOverhang
        // Upper: the body down to its cap, the cap's lip at the gap.
        drawTube(in: ctx, CGRect(x: p.x, y: -4, width: pw, height: top - capHeight + 4))
        drawTube(in: ctx, CGRect(x: p.x - o, y: top - capHeight, width: pw + o * 2, height: capHeight))
        // Lower: the cap at the gap, the body down to the ground.
        drawTube(in: ctx, CGRect(x: p.x - o, y: bottom, width: pw + o * 2, height: capHeight))
        drawTube(in: ctx, CGRect(x: p.x, y: bottom + capHeight, width: pw, height: h - bottom - capHeight + 2))
    }

    /// A green tube section: base colour, a light stripe on the left, a shade on the right
    /// and a dark outline.
    private static func drawTube(in ctx: GraphicsContext, _ r: CGRect) {
        guard r.height > 0 else { return }
        ctx.fill(Path(r), with: .color(pipe))
        let light = CGRect(x: r.minX + r.width * 0.12, y: r.minY, width: r.width * 0.16, height: r.height)
        ctx.fill(Path(light), with: .color(pipeLight))
        let shade = CGRect(x: r.maxX - r.width * 0.24, y: r.minY, width: r.width * 0.24, height: r.height)
        ctx.fill(Path(shade), with: .color(pipeDark))
        ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(pipeLine), lineWidth: 2.5)
    }

    // MARK: - Bird

    /// The bird, about the original's 34 × 24 size, facing right. `tilt` in degrees
    /// (positive: nose down).
    static func drawBird(in base: GraphicsContext, at c: CGPoint, tilt: Double, wing: Flappy.Wing) {
        var ctx = base
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: .degrees(tilt))
        let line = PlatyPalette.outline
        // Tail feathers (Platy's brown), behind the body.
        var tail = Path()
        tail.move(to: CGPoint(x: -13, y: -2))
        tail.addLine(to: CGPoint(x: -23, y: -7))
        tail.addLine(to: CGPoint(x: -21, y: 1))
        tail.addLine(to: CGPoint(x: -24, y: 6))
        tail.addLine(to: CGPoint(x: -12, y: 5))
        tail.closeSubpath()
        ctx.fill(tail, with: .color(tailFeather))
        ctx.stroke(tail, with: .color(line), lineWidth: 1.6)
        // Body and belly.
        let body = Path(ellipseIn: CGRect(x: -16, y: -13, width: 32, height: 26))
        let bodyGradient = Gradient(colors: [PlatyPalette.bodyTop, PlatyPalette.bodyBottom])
        ctx.fill(body, with: .linearGradient(bodyGradient, startPoint: CGPoint(x: 0, y: -13), endPoint: CGPoint(x: 0, y: 13)))
        var belly = ctx
        belly.clip(to: body)
        belly.fill(Path(ellipseIn: CGRect(x: -6, y: 1, width: 24, height: 16)), with: .color(PlatyPalette.belly))
        ctx.stroke(body, with: .color(line), lineWidth: 1.8)
        // Eye: white with a pupil looking ahead, and a glint.
        let eye = Path(ellipseIn: CGRect(x: 2, y: -11, width: 12, height: 12))
        ctx.fill(eye, with: .color(.white))
        ctx.stroke(eye, with: .color(line), lineWidth: 1.4)
        ctx.fill(Path(ellipseIn: CGRect(x: 8, y: -7.5, width: 5, height: 6)), with: .color(PlatyPalette.eye))
        ctx.fill(Path(ellipseIn: CGRect(x: 9.6, y: -6.8, width: 1.8, height: 1.8)), with: .color(.white))
        drawBill(in: ctx, line: line)
        drawWing(in: ctx, wing, line: line)
    }

    /// A flat, cream duck bill (Platy's), upper and lower halves.
    private static func drawBill(in ctx: GraphicsContext, line: Color) {
        let upper = Path(roundedRect: CGRect(x: 10, y: -1, width: 15, height: 6), cornerRadius: 3)
        let lower = Path(roundedRect: CGRect(x: 10, y: 3.5, width: 12, height: 5), cornerRadius: 2.5)
        ctx.fill(lower, with: .color(PlatyPalette.billLower))
        ctx.stroke(lower, with: .color(line), lineWidth: 1.3)
        ctx.fill(upper, with: .color(PlatyPalette.bill))
        ctx.stroke(upper, with: .color(line), lineWidth: 1.3)
        ctx.fill(Path(ellipseIn: CGRect(x: 20, y: 0.6, width: 1.6, height: 1.4)), with: .color(PlatyPalette.nostril))
    }

    /// The wing: a feathered leaf shape hinged at the shoulder, raised, level or lowered.
    private static func drawWing(in base: GraphicsContext, _ wing: Flappy.Wing, line: Color) {
        var ctx = base
        ctx.translateBy(x: -3, y: 1)
        let angle: Double
        switch wing {
        case .up: angle = 40
        case .middle: angle = 0
        case .down: angle = -36
        }
        ctx.rotate(by: .degrees(angle))
        var p = Path()
        p.move(to: CGPoint(x: 5, y: -3))
        p.addQuadCurve(to: CGPoint(x: -15, y: -1), control: CGPoint(x: -6, y: -8))
        p.addLine(to: CGPoint(x: -11, y: 2))
        p.addLine(to: CGPoint(x: -14, y: 4))
        p.addLine(to: CGPoint(x: -9, y: 5.5))
        p.addQuadCurve(to: CGPoint(x: 5, y: -3), control: CGPoint(x: 2, y: 5))
        ctx.fill(p, with: .color(wingColor(wing)))
        ctx.stroke(p, with: .color(line), lineWidth: 1.5)
    }

    private static func wingColor(_ wing: Flappy.Wing) -> Color {
        wing == .down ? PlatyPalette.belly : wingLight
    }

    static let wingLight = Color(platyHex: 0xB7DDCB)
}
