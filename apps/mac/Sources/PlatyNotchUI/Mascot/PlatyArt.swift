import PlatyNotchKit
import SwiftUI

/// Platy's colors (design/platy/README.md lists the same hex values).
enum PlatyPalette {
    static let bodyTop = Color(platyHex: 0x4E8F80)
    static let body = Color(platyHex: 0x3F7D70)
    static let bodyBottom = Color(platyHex: 0x336A5F)
    static let outline = Color(platyHex: 0x1F4640)
    static let belly = Color(platyHex: 0x9BCBB5)
    static let tail = Color(platyHex: 0x7E5739)
    static let tailShade = Color(platyHex: 0x5E3F28)
    static let bill = Color(platyHex: 0xF6E7C6)
    static let billLower = Color(platyHex: 0xE6CFA2)
    static let billLine = Color(platyHex: 0xB8966A)
    static let nostril = Color(platyHex: 0x8E7049)
    static let paw = Color(platyHex: 0xEDCB97)
    static let pawLine = Color(platyHex: 0xB78F5B)
    static let eye = Color(platyHex: 0x1A2124)
    static let glint = Color.white
    static let blush = Color(platyHex: 0xF29C94)
    static let band = Color(platyHex: 0x2A2E35)
    static let cup = Color(platyHex: 0xFF6F59)
    static let cupPad = Color(platyHex: 0xC4493A)
    static let sparkle = Color(platyHex: 0xFFD25A)
    static let sparkleEdge = Color(platyHex: 0xD99A00)
    static let check = Color(platyHex: 0x2FB75A)
    static let zzz = Color(platyHex: 0x9FB8FF)
    static let amber = Color(platyHex: 0xFFB020)
    static let flagPole = Color(platyHex: 0x5E3F28)
    static let water = Color(platyHex: 0x4FC3F7)
    static let shadow = Color.black.opacity(0.22)
}

extension Color {
    /// 0xRRGGBB.
    init(platyHex hex: UInt32) {
        let r: Double = Double((hex >> 16) & 0xFF) / 255
        let g: Double = Double((hex >> 8) & 0xFF) / 255
        let b: Double = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// How much Platy shows at a size: the silhouette is designed for 16–32 pt first.
enum PlatyDetail: Equatable {
    /// Under 28 pt (pill, menu bar, small icons): bigger eyes, no paws, no nostrils or lines.
    case tiny
    /// 28–63 pt: paws and nostrils, no textures.
    case small
    /// 64 pt and up: outline, tail texture, toes, blush.
    case full

    init(points: CGFloat) {
        if points < 28 {
            self = .tiny
        } else if points < 64 {
            self = .small
        } else {
            self = .full
        }
    }
}

/// Platy's shapes in a 100 × 100 box, y down (the same numbers as design/platy/platy.svg).
enum PlatyShapes {
    static let head = CGRect(x: 18, y: 14, width: 64, height: 56)
    static let body = CGRect(x: 19, y: 46, width: 62, height: 48)
    static let belly = CGRect(x: 33, y: 63, width: 34, height: 27)
    static let leftFoot = CGRect(x: 23, y: 87, width: 22, height: 10)
    static let rightFoot = CGRect(x: 55, y: 87, width: 22, height: 10)
    static let bill = CGRect(x: 26, y: 46, width: 48, height: 20)
    static let billPivot = CGPoint(x: 50, y: 53)
    static let leftEye = CGPoint(x: 37, y: 36)
    static let rightEye = CGPoint(x: 63, y: 36)
    static let tailPivot = CGPoint(x: 66, y: 84)
    /// The tail's resting angle (degrees, pointing out to the right and a little up).
    static let tailAngle: Double = -22
    /// Where Platy stands (lean and breath pivot here).
    static let ground = CGPoint(x: 50, y: 95)

    /// Head and body as one shape (built once).
    static let silhouetteShape: Path = Path(ellipseIn: head).union(Path(ellipseIn: body))

    static func silhouette() -> Path { silhouetteShape }

    /// The working water line across Platy's feet.
    static func waterLine() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 4, y: 93))
        for i in 0..<4 {
            let x0: CGFloat = 4 + CGFloat(i) * 23
            p.addQuadCurve(to: CGPoint(x: x0 + 11.5, y: 93), control: CGPoint(x: x0 + 5.75, y: 89))
            p.addQuadCurve(to: CGPoint(x: x0 + 23, y: 93), control: CGPoint(x: x0 + 17.25, y: 97))
        }
        return p
    }

    /// The water below the line (clipped to the 100 box).
    static func waterBody() -> Path {
        var p = waterLine()
        p.addLine(to: CGPoint(x: 96, y: 100))
        p.addLine(to: CGPoint(x: 4, y: 100))
        p.closeSubpath()
        return p
    }

    /// The flat beaver tail along +x from its base at the origin.
    static func tailLocal() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -5))
        p.addCurve(to: CGPoint(x: 30, y: -9), control1: CGPoint(x: 10, y: -7), control2: CGPoint(x: 20, y: -11))
        p.addCurve(to: CGPoint(x: 30, y: 9), control1: CGPoint(x: 38, y: -7), control2: CGPoint(x: 38, y: 7))
        p.addCurve(to: CGPoint(x: 0, y: 5), control1: CGPoint(x: 20, y: 11), control2: CGPoint(x: 10, y: 7))
        p.closeSubpath()
        return p
    }

    static func tailTransform(wag: Double) -> CGAffineTransform {
        let degrees: Double = tailAngle - 18 * wag
        let radians: CGFloat = CGFloat(degrees * Double.pi / 180)
        return CGAffineTransform(rotationAngle: radians)
            .concatenating(CGAffineTransform(translationX: tailPivot.x, y: tailPivot.y))
    }

    static func tail(wag: Double) -> Path {
        tailLocal().applying(tailTransform(wag: wag))
    }

    static func billShape() -> Path {
        Path(roundedRect: bill, cornerRadius: 10, style: .continuous)
    }

    /// The curve between upper and lower bill (a small smile).
    static func mouth() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 33, y: 57.5))
        p.addQuadCurve(to: CGPoint(x: 67, y: 57.5), control: CGPoint(x: 50, y: 63))
        return p
    }

    /// Everything below `mouth` (clipped to the bill when filled).
    static func lowerBill() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 20, y: 56.5))
        p.addQuadCurve(to: CGPoint(x: 80, y: 56.5), control: CGPoint(x: 50, y: 64.5))
        p.addLine(to: CGPoint(x: 80, y: 80))
        p.addLine(to: CGPoint(x: 20, y: 80))
        p.closeSubpath()
        return p
    }

    static func nostrils() -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 42.2, y: 49.6, width: 3, height: 2.2))
        p.addEllipse(in: CGRect(x: 54.8, y: 49.6, width: 3, height: 2.2))
        return p
    }

    static func eyeRadius(_ detail: PlatyDetail) -> CGFloat {
        detail == .tiny ? 6.4 : 5.4
    }

    /// An open (or half-open) eye: the lid comes down from the top.
    static func eye(at c: CGPoint, radius r: CGFloat, open: Double) -> Path {
        let h: CGFloat = 2 * r * CGFloat(open)
        let top: CGFloat = c.y + r - h
        return Path(ellipseIn: CGRect(x: c.x - r, y: top, width: 2 * r, height: h))
    }

    /// A closed eye: a soft downward curve.
    static func closedEye(at c: CGPoint, radius r: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x - r, y: c.y))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x, y: c.y + r))
        return p
    }

    /// A small webbed paw, centered on `c`.
    static func paw(at c: CGPoint) -> Path {
        let palm = Path(ellipseIn: CGRect(x: c.x - 6.5, y: c.y - 5, width: 13, height: 10))
        var toes = Path()
        toes.addEllipse(in: CGRect(x: c.x - 6.5, y: c.y + 0.5, width: 4.6, height: 4.6))
        toes.addEllipse(in: CGRect(x: c.x - 2.3, y: c.y + 1.8, width: 4.6, height: 4.6))
        toes.addEllipse(in: CGRect(x: c.x + 1.9, y: c.y + 0.5, width: 4.6, height: 4.6))
        return palm.union(toes)
    }

    /// The webbing lines between the toes.
    static func pawWebs(at c: CGPoint) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x - 2.2, y: c.y + 2))
        p.addLine(to: CGPoint(x: c.x - 2.2, y: c.y + 4.4))
        p.move(to: CGPoint(x: c.x + 2.2, y: c.y + 2))
        p.addLine(to: CGPoint(x: c.x + 2.2, y: c.y + 4.4))
        return p
    }

    /// Paw centers: paddling moves them up and down in turn; cheering raises both.
    static func pawCenters(paddle: Double, cheer: Bool) -> (CGPoint, CGPoint) {
        if cheer { return (CGPoint(x: 15, y: 46), CGPoint(x: 85, y: 46)) }
        let d: CGFloat = 4 * CGFloat(paddle)
        return (CGPoint(x: 27, y: 71 - d), CGPoint(x: 73, y: 71 + d))
    }

    /// Toe lines on a foot.
    static func toes(in r: CGRect) -> Path {
        var p = Path()
        let y0: CGFloat = r.maxY - 1
        let y1: CGFloat = r.maxY - 4
        let third: CGFloat = r.width / 3
        p.move(to: CGPoint(x: r.minX + third, y: y0))
        p.addLine(to: CGPoint(x: r.minX + third, y: y1))
        p.move(to: CGPoint(x: r.minX + 2 * third, y: y0))
        p.addLine(to: CGPoint(x: r.minX + 2 * third, y: y1))
        return p
    }

    static func headphoneBand() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 18, y: 40))
        p.addQuadCurve(to: CGPoint(x: 82, y: 40), control: CGPoint(x: 50, y: -12))
        return p
    }

    static let leftCup = CGRect(x: 10, y: 30, width: 14, height: 21)
    static let rightCup = CGRect(x: 76, y: 30, width: 14, height: 21)

    /// A four-pointed sparkle.
    static func sparkle(at c: CGPoint, radius r: CGFloat) -> Path {
        let k: CGFloat = r * 0.2
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
        p.closeSubpath()
        return p
    }

    /// The bottom of the waiting flag's pole (it swings about here).
    static let flagBase = CGPoint(x: 85, y: 76)
    static let flagTop = CGPoint(x: 85, y: 3)

    /// The flag's pole.
    static func flagPole() -> Path {
        var p = Path()
        p.move(to: flagBase)
        p.addLine(to: flagTop)
        return p
    }

    /// The amber pennant at the top of the pole, pointing out to the right.
    static func flagCloth() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: flagTop.x, y: flagTop.y))
        p.addLine(to: CGPoint(x: 99, y: flagTop.y + 4))
        p.addLine(to: CGPoint(x: 99, y: flagTop.y + 18))
        p.addLine(to: CGPoint(x: flagTop.x, y: flagTop.y + 24))
        p.closeSubpath()
        return p
    }

    static let checkBadge = CGRect(x: 70, y: 6, width: 26, height: 26)

    static func checkMark() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 76.5, y: 19.5))
        p.addLine(to: CGPoint(x: 81.5, y: 24.5))
        p.addLine(to: CGPoint(x: 89.5, y: 13.5))
        return p
    }

    /// A "z" with its top-left corner at `o`.
    static func zee(at o: CGPoint, size s: CGFloat) -> Path {
        var p = Path()
        p.move(to: o)
        p.addLine(to: CGPoint(x: o.x + s, y: o.y))
        p.addLine(to: CGPoint(x: o.x, y: o.y + s))
        p.addLine(to: CGPoint(x: o.x + s, y: o.y + s))
        return p
    }

    /// Diagonal hatching for the tail (clipped to it).
    static func tailHatch() -> Path {
        var p = Path()
        for i in 0..<6 {
            let x: CGFloat = 6 + CGFloat(i) * 6
            p.move(to: CGPoint(x: x, y: -12))
            p.addLine(to: CGPoint(x: x - 8, y: 12))
            p.move(to: CGPoint(x: x - 8, y: -12))
            p.addLine(to: CGPoint(x: x, y: 12))
        }
        return p
    }
}

/// Draws Platy into a `GraphicsContext` (the `Canvas` of `PlatyView`, the icon and the
/// gallery). The context is in points; Platy fills a `size` × `size` square at the origin.
enum PlatyArt {
    static func draw(in ctx: GraphicsContext, size: CGFloat, pose: PlatyPose, detail: PlatyDetail? = nil) {
        let d: PlatyDetail = detail ?? PlatyDetail(points: size)
        var g = ctx
        let scale: CGFloat = size / 100
        g.scaleBy(x: scale, y: scale)
        if d != .tiny { drawGroundShadow(g, bounce: pose.bounce) }
        var fig = g
        let lift: CGFloat = CGFloat(pose.bounce) * 100
        fig.translateBy(x: 0, y: -lift)
        lean(&fig, degrees: pose.lean, breath: pose.breath)
        drawTail(fig, pose: pose, detail: d)
        drawBody(fig, pose: pose, detail: d)
        drawFace(fig, pose: pose, detail: d)
        if pose.headphones { drawHeadphones(fig, detail: d) }
        if pose.flag { drawFlag(fig, angle: pose.flagAngle, detail: d) }
        drawExtras(g, pose: pose, detail: d)
    }

    private static func lean(_ g: inout GraphicsContext, degrees: Double, breath: Double) {
        let pivot = PlatyShapes.ground
        g.translateBy(x: pivot.x, y: pivot.y)
        g.rotate(by: .degrees(degrees))
        g.scaleBy(x: 1, y: 1 + CGFloat(breath))
        g.translateBy(x: -pivot.x, y: -pivot.y)
    }

    private static func drawGroundShadow(_ g: GraphicsContext, bounce: Double) {
        let shrink: CGFloat = CGFloat(bounce) * 80
        let w: CGFloat = 58 - shrink
        let rect = CGRect(x: 50 - w / 2, y: 93, width: w, height: 6)
        g.fill(Path(ellipseIn: rect), with: .color(PlatyPalette.shadow))
    }

    private static func drawTail(_ g: GraphicsContext, pose: PlatyPose, detail: PlatyDetail) {
        let tail = PlatyShapes.tail(wag: pose.tailWag)
        g.fill(tail, with: .color(PlatyPalette.tail))
        if detail == .full {
            var hatch = g
            hatch.clip(to: tail)
            let lines = PlatyShapes.tailHatch().applying(PlatyShapes.tailTransform(wag: pose.tailWag))
            hatch.stroke(lines, with: .color(PlatyPalette.tailShade.opacity(0.55)), lineWidth: 1)
            g.stroke(tail, with: .color(PlatyPalette.tailShade), lineWidth: 1.6)
        }
        if let tint = pose.tint { g.fill(tail, with: .color(tint.opacity(0.85))) }
    }

    private static func drawBody(_ g: GraphicsContext, pose: PlatyPose, detail: PlatyDetail) {
        let shape = PlatyShapes.silhouette()
        if detail == .tiny {
            g.fill(shape, with: .color(PlatyPalette.body))
        } else {
            let gradient = Gradient(colors: [PlatyPalette.bodyTop, PlatyPalette.body, PlatyPalette.bodyBottom])
            g.fill(shape, with: .linearGradient(gradient, startPoint: CGPoint(x: 50, y: 14), endPoint: CGPoint(x: 50, y: 94)))
        }
        g.fill(Path(ellipseIn: PlatyShapes.belly), with: .color(PlatyPalette.belly.opacity(detail == .tiny ? 0.45 : 0.6)))
        if let tint = pose.tint {
            // Waiting: an amber rim (the body keeps its color; a tinted body looked unwell).
            let rim: CGFloat = detail == .tiny ? 7 : 5
            var edge = g
            edge.clip(to: shape)
            edge.stroke(shape, with: .color(tint), lineWidth: rim)
        } else if detail == .full {
            g.stroke(shape, with: .color(PlatyPalette.outline), lineWidth: 1.6)
        }
        drawFeet(g, detail: detail)
        if detail != .tiny { drawPaws(g, pose: pose, detail: detail) }
    }

    private static func drawFeet(_ g: GraphicsContext, detail: PlatyDetail) {
        for foot in [PlatyShapes.leftFoot, PlatyShapes.rightFoot] {
            g.fill(Path(ellipseIn: foot), with: .color(PlatyPalette.paw))
            if detail == .full {
                g.stroke(PlatyShapes.toes(in: foot), with: .color(PlatyPalette.pawLine), lineWidth: 1.2)
                g.stroke(Path(ellipseIn: foot), with: .color(PlatyPalette.pawLine), lineWidth: 1)
            }
        }
    }

    private static func drawPaws(_ g: GraphicsContext, pose: PlatyPose, detail: PlatyDetail) {
        let centers = PlatyShapes.pawCenters(paddle: pose.paddle, cheer: pose.cheer)
        for c in [centers.0, centers.1] {
            let paw = PlatyShapes.paw(at: c)
            g.fill(paw, with: .color(PlatyPalette.paw))
            if detail == .full {
                g.stroke(paw, with: .color(PlatyPalette.pawLine), lineWidth: 1)
                g.stroke(PlatyShapes.pawWebs(at: c), with: .color(PlatyPalette.pawLine),
                         style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
    }

    private static func drawFace(_ g: GraphicsContext, pose: PlatyPose, detail: PlatyDetail) {
        if detail == .full {
            let blush = PlatyPalette.blush.opacity(0.55)
            g.fill(Path(ellipseIn: CGRect(x: 22, y: 39, width: 9, height: 6)), with: .color(blush))
            g.fill(Path(ellipseIn: CGRect(x: 69, y: 39, width: 9, height: 6)), with: .color(blush))
        }
        drawEyes(g, open: pose.eyesOpen, detail: detail)
        drawBill(g, angle: pose.billAngle, detail: detail)
    }

    private static func drawEyes(_ g: GraphicsContext, open: Double, detail: PlatyDetail) {
        let r: CGFloat = PlatyShapes.eyeRadius(detail)
        for c in [PlatyShapes.leftEye, PlatyShapes.rightEye] {
            if open < 0.15 {
                let width: CGFloat = detail == .tiny ? 3.4 : 2.6
                let style = StrokeStyle(lineWidth: width, lineCap: .round)
                g.stroke(PlatyShapes.closedEye(at: c, radius: r), with: .color(PlatyPalette.eye), style: style)
                continue
            }
            g.fill(PlatyShapes.eye(at: c, radius: r, open: open), with: .color(PlatyPalette.eye))
            if open > 0.5 {
                let gr: CGFloat = r * 0.38
                let glint = CGRect(x: c.x - r * 0.55, y: c.y - r * 0.6, width: 2 * gr, height: 2 * gr)
                g.fill(Path(ellipseIn: glint), with: .color(PlatyPalette.glint))
            }
        }
    }

    private static func drawBill(_ g: GraphicsContext, angle: Double, detail: PlatyDetail) {
        var b = g
        let pivot = PlatyShapes.billPivot
        b.translateBy(x: pivot.x, y: pivot.y)
        b.rotate(by: .degrees(angle))
        b.translateBy(x: -pivot.x, y: -pivot.y)
        let bill = PlatyShapes.billShape()
        b.fill(bill, with: .color(PlatyPalette.bill))
        var lower = b
        lower.clip(to: bill)
        lower.fill(PlatyShapes.lowerBill(), with: .color(PlatyPalette.billLower))
        if detail != .tiny {
            lower.stroke(PlatyShapes.mouth(), with: .color(PlatyPalette.billLine),
                         style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            b.fill(PlatyShapes.nostrils(), with: .color(PlatyPalette.nostril))
        }
        if detail == .full { b.stroke(bill, with: .color(PlatyPalette.billLine), lineWidth: 1.2) }
    }

    private static func drawHeadphones(_ g: GraphicsContext, detail: PlatyDetail) {
        let width: CGFloat = detail == .tiny ? 6 : 4.5
        g.stroke(PlatyShapes.headphoneBand(), with: .color(PlatyPalette.band),
                 style: StrokeStyle(lineWidth: width, lineCap: .round))
        for cup in [PlatyShapes.leftCup, PlatyShapes.rightCup] {
            g.fill(Path(roundedRect: cup, cornerRadius: 6, style: .continuous), with: .color(PlatyPalette.cup))
            if detail != .tiny {
                let pad = cup.insetBy(dx: 3.5, dy: 4.5)
                g.fill(Path(roundedRect: pad, cornerRadius: 3, style: .continuous), with: .color(PlatyPalette.cupPad))
            }
        }
    }

    /// The amber flag Platy holds up when it needs you, swung `angle` degrees about the
    /// bottom of its pole.
    private static func drawFlag(_ g: GraphicsContext, angle: Double, detail: PlatyDetail) {
        var f = g
        let base = PlatyShapes.flagBase
        f.translateBy(x: base.x, y: base.y)
        f.rotate(by: .degrees(angle))
        f.translateBy(x: -base.x, y: -base.y)
        let width: CGFloat = detail == .tiny ? 5 : 3.5
        f.stroke(PlatyShapes.flagPole(), with: .color(PlatyPalette.flagPole),
                 style: StrokeStyle(lineWidth: width, lineCap: .round))
        let cloth = PlatyShapes.flagCloth()
        f.fill(cloth, with: .color(PlatyPalette.amber))
        if detail != .tiny { f.stroke(cloth, with: .color(PlatyPalette.sparkleEdge), lineWidth: 1) }
    }

    /// Sparkles, the done check, the sleepy "z"s and the water: they do not lean or bounce.
    private static func drawExtras(_ g: GraphicsContext, pose: PlatyPose, detail: PlatyDetail) {
        if pose.water {
            g.fill(PlatyShapes.waterBody(), with: .color(PlatyPalette.water.opacity(0.35)))
            let width: CGFloat = detail == .tiny ? 4.5 : 3
            g.stroke(PlatyShapes.waterLine(), with: .color(PlatyPalette.water),
                     style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        if pose.sparkle > 0 { drawSparkles(g, amount: pose.sparkle, detail: detail) }
        if pose.check {
            g.fill(Path(ellipseIn: PlatyShapes.checkBadge), with: .color(PlatyPalette.check))
            let width: CGFloat = detail == .tiny ? 4.4 : 3.4
            g.stroke(PlatyShapes.checkMark(), with: .color(.white),
                     style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        if pose.zzz {
            let width: CGFloat = detail == .tiny ? 3.4 : 2.6
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            g.stroke(PlatyShapes.zee(at: CGPoint(x: 74, y: 10), size: 11), with: .color(PlatyPalette.zzz), style: style)
            if detail != .tiny {
                g.stroke(PlatyShapes.zee(at: CGPoint(x: 88, y: 1), size: 7), with: .color(PlatyPalette.zzz), style: style)
            }
        }
    }

    private static func drawSparkles(_ g: GraphicsContext, amount: Double, detail: PlatyDetail) {
        let v: CGFloat = CGFloat(amount)
        var stars: [(CGPoint, CGFloat)] = [(CGPoint(x: 13, y: 18), 4 + 9 * v)]
        if amount > 0.75 {
            stars.append((CGPoint(x: 87, y: 15), 11 * v))
            stars.append((CGPoint(x: 92, y: 50), 6 * v))
        }
        for (c, r) in stars {
            let star = PlatyShapes.sparkle(at: c, radius: r)
            g.fill(star, with: .color(PlatyPalette.sparkle))
            if detail != .tiny { g.stroke(star, with: .color(PlatyPalette.sparkleEdge), lineWidth: 1) }
        }
    }
}
