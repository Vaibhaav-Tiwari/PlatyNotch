import AppKit
import PlatyNotchKit
import SwiftUI

/// The app icon: the macOS (Big Sur and later) grid, an 824 × 824 rounded square in a
/// 1024 canvas with a soft shadow, a deep blue to night-blue gradient, a notch at the
/// top (the product) and Platy in the middle. Drawn at any size; Platy simplifies below
/// 28 pt like everywhere else.
enum PlatyAppIcon {
    static let canvas: CGFloat = 1024
    static let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let plateRadius: CGFloat = 185
    static let notch = CGRect(x: 352, y: 100, width: 320, height: 78)
    /// Platy's square in the 1024 canvas.
    static let platy = CGRect(x: 197, y: 268, width: 630, height: 630)
    /// At 64 px and below Platy fills more of the plate (Dock lists, Finder, Spotlight).
    static let smallPlaty = CGRect(x: 132, y: 196, width: 760, height: 760)

    static func platyRect(pixels: CGFloat) -> CGRect { pixels <= 64 ? smallPlaty : platy }

    static let top = Color(platyHex: 0x1F4E78)
    static let bottom = Color(platyHex: 0x0A1630)
    static let glow = Color(platyHex: 0x3A7FA8)
    static let notchColor = Color(platyHex: 0x05080C)

    static func draw(in ctx: GraphicsContext, size: CGFloat) {
        var g = ctx
        let s: CGFloat = size / canvas
        g.scaleBy(x: s, y: s)
        let plateShape = Path(roundedRect: plate, cornerRadius: plateRadius, style: .continuous)
        drawShadow(g, plate: plateShape)
        var inside = g
        inside.clip(to: plateShape)
        drawBackground(inside)
        drawNotch(inside)
        drawPlaty(inside, pixels: size)
        drawRim(g, plate: plateShape)
    }

    private static func drawShadow(_ g: GraphicsContext, plate: Path) {
        var shadow = g
        shadow.addFilter(.shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 10))
        shadow.fill(plate, with: .color(bottom))
    }

    private static func drawBackground(_ g: GraphicsContext) {
        let gradient = Gradient(colors: [top, bottom])
        g.fill(Path(plate), with: .linearGradient(gradient, startPoint: CGPoint(x: 512, y: 100),
                                                  endPoint: CGPoint(x: 512, y: 924)))
        let glowGradient = Gradient(colors: [glow.opacity(0.45), glow.opacity(0)])
        g.fill(Path(plate), with: .radialGradient(glowGradient, center: CGPoint(x: 512, y: 600),
                                                  startRadius: 0, endRadius: 400))
    }

    private static func drawNotch(_ g: GraphicsContext) {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 34, bottomTrailingRadius: 34, style: .continuous)
        g.fill(shape.path(in: notch), with: .color(notchColor))
    }

    private static func drawPlaty(_ g: GraphicsContext, pixels: CGFloat) {
        var p = g
        let rect = platyRect(pixels: pixels)
        p.translateBy(x: rect.minX, y: rect.minY)
        // Detail by Platy's size in the final image, not in the 1024 canvas.
        let shown: CGFloat = rect.width * pixels / canvas
        PlatyArt.draw(in: p, size: rect.width, pose: .rest(.idle), detail: PlatyDetail(points: shown))
    }

    /// A faint light edge so the plate reads on a dark Dock.
    private static func drawRim(_ g: GraphicsContext, plate: Path) {
        g.stroke(plate, with: .color(.white.opacity(0.12)), lineWidth: 3)
    }
}

struct PlatyAppIconView: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, _ in PlatyAppIcon.draw(in: ctx, size: size) }
            .frame(width: size, height: size)
    }
}

/// The menu bar icon: Platy in side profile as a one-color template image (macOS tints
/// it for light and dark menu bars). Facing left: the flat duck bill sticks out in front,
/// then the head, the long low body on flat webbed feet and the beaver tail behind. The
/// eye and a thin gap round the bill are cut out. An optional dot (top right, with a
/// cut-out ring) while capture runs.
enum PlatyMenuIcon {
    static let size = NSSize(width: 18, height: 18)
    /// The profile's box: 36 × 36 units, y down (2 units per point).
    static let box: CGFloat = 36

    static func image(dot: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: cg, rect: rect, dot: dot)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = dot ? "PlatyNotch, capturing" : "PlatyNotch"
        return image
    }

    // MARK: Shapes (box units)

    static let eye = CGPoint(x: 13, y: 15.6)
    /// Flat webbed feet splayed under the body (front forward, back backward).
    static let frontFoot = CGRect(x: 7.6, y: 22.6, width: 8.6, height: 3.4)
    static let backFoot = CGRect(x: 20.6, y: 23, width: 8.6, height: 3.4)

    /// Head and body in one long, low, streamlined shape (a platypus has no neck).
    static func profile() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 7.5, y: 17))
        p.addCurve(to: CGPoint(x: 18, y: 12.6), control1: CGPoint(x: 8.5, y: 13), control2: CGPoint(x: 13, y: 12.4))
        p.addCurve(to: CGPoint(x: 28.5, y: 17.6), control1: CGPoint(x: 23, y: 12.8), control2: CGPoint(x: 27.5, y: 14.5))
        p.addCurve(to: CGPoint(x: 26, y: 23.2), control1: CGPoint(x: 29.2, y: 20), control2: CGPoint(x: 28.4, y: 22.6))
        p.addCurve(to: CGPoint(x: 7.5, y: 21), control1: CGPoint(x: 19, y: 24.8), control2: CGPoint(x: 10, y: 24.4))
        p.closeSubpath()
        return p.union(tail())
    }

    /// The duck bill: long, flat and wider at the rounded tip.
    static func bill() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 9.2, y: 16.2))
        p.addLine(to: CGPoint(x: 2.6, y: 15.4))
        p.addQuadCurve(to: CGPoint(x: 2.6, y: 21), control: CGPoint(x: -0.9, y: 18.2))
        p.addLine(to: CGPoint(x: 9.2, y: 20.2))
        p.closeSubpath()
        return p
    }

    /// The flat beaver tail: a paddle behind, narrow where it joins the body.
    static func tail() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 27, y: 18.6))
        p.addCurve(to: CGPoint(x: 35.4, y: 18), control1: CGPoint(x: 30, y: 17.6), control2: CGPoint(x: 34.6, y: 15.8))
        p.addCurve(to: CGPoint(x: 27, y: 22.4), control1: CGPoint(x: 36.2, y: 21), control2: CGPoint(x: 30.5, y: 23.8))
        p.closeSubpath()
        return p
    }

    /// Draws in black on clear into a y-down context.
    static func draw(in cg: CGContext, rect: CGRect, dot: Bool) {
        cg.saveGState()
        let scale: CGFloat = rect.width / box
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: scale, y: scale)
        cg.setFillColor(NSColor.black.cgColor)
        cg.translateBy(x: 0, y: 0.5)
        fill(cg, profile())
        fill(cg, Path(ellipseIn: frontFoot))
        fill(cg, Path(ellipseIn: backFoot))
        // The bill is set off by a thin gap: cut its outline, then fill it again.
        clear(cg, stroke: bill(), width: 2.4)
        fill(cg, bill())
        clear(cg, ellipse: CGRect(x: eye.x - 1.7, y: eye.y - 1.7, width: 3.4, height: 3.4))
        cg.restoreGState()
        if dot { drawDot(cg, rect: rect) }
    }

    private static func fill(_ cg: CGContext, _ path: Path) {
        cg.addPath(path.cgPath)
        cg.fillPath()
    }

    private static func clear(_ cg: CGContext, stroke path: Path, width: CGFloat) {
        cg.saveGState()
        cg.setBlendMode(.clear)
        cg.setLineWidth(width)
        cg.setLineJoin(.round)
        cg.addPath(path.cgPath)
        cg.strokePath()
        cg.restoreGState()
    }

    private static func clear(_ cg: CGContext, ellipse: CGRect) {
        cg.saveGState()
        cg.setBlendMode(.clear)
        cg.fillEllipse(in: ellipse)
        cg.restoreGState()
    }

    /// The capture dot, top right, with a cut-out ring so it stands apart.
    private static func drawDot(_ cg: CGContext, rect: CGRect) {
        let d: CGFloat = 6
        let dot = CGRect(x: rect.maxX - d - 0.5, y: rect.minY + 1, width: d, height: d)
        clear(cg, ellipse: dot.insetBy(dx: -1.5, dy: -1.5))
        cg.setFillColor(NSColor.black.cgColor)
        cg.fillEllipse(in: dot)
    }
}
