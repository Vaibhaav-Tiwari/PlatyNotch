import AppKit
import PlatyNotchKit
import QuartzCore
import SwiftUI

/// The Today card's sky (Island spec 5): the condition's gradient as a `CAGradientLayer`,
/// plus one motion sublayer per `SkyMotion` (drift, streaks, flash, flakes). Motion is Core
/// Animation only (the render server runs it, the app does no per-frame work) and only while
/// `animating` (the panel is open and Reduce Motion is off); otherwise every animation is
/// removed and the sky is still.
struct WeatherSkyView: NSViewRepresentable {
    let sky: WeatherSky
    let animating: Bool

    func makeNSView(context: Context) -> SkyLayerView {
        let v = SkyLayerView()
        v.configure(sky: sky, animating: animating)
        return v
    }

    func updateNSView(_ v: SkyLayerView, context: Context) {
        v.configure(sky: sky, animating: animating)
    }

    /// Every animation key on `layer` and its sublayers (tests: none while not animating).
    static func animationKeys(layer: CALayer) -> [String] {
        (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap { animationKeys(layer: $0) }
    }

    /// CAGradientLayer start and end points for a CSS `linear-gradient` angle on a `size`
    /// box, as CSS draws it: 180° runs top to bottom, 160° leans to the bottom right, and the
    /// gradient line is long enough that the 0 and 1 stops meet the far corners. Unit
    /// coordinates, y up (a gradient's points ignore its superlayer's flip).
    static func points(angle: Double, size: CGSize) -> (start: CGPoint, end: CGPoint) {
        let r = angle * .pi / 180
        let dir = CGPoint(x: sin(r), y: -cos(r))   // CSS space: y grows downwards
        let w = max(size.width, 1), h = max(size.height, 1)
        let length = abs(w * dir.x) + abs(h * dir.y)
        let dx = dir.x * length / 2 / w, dy = dir.y * length / 2 / h
        return (CGPoint(x: 0.5 - dx, y: 0.5 + dy), CGPoint(x: 0.5 + dx, y: 0.5 - dy))
    }
}

/// The layer-hosting view behind `WeatherSkyView`.
final class SkyLayerView: NSView {
    private let gradient = CAGradientLayer()
    /// Holds the motion layer, clipped to the sky.
    private let clip = CALayer()
    private var motionLayer: CALayer?
    private var sky: WeatherSky?
    private var animating = false
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.masksToBounds = true
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        root.addSublayer(gradient)
        clip.masksToBounds = true
        root.addSublayer(clip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(sky: WeatherSky, animating: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if sky != self.sky {
            gradient.colors = sky.stops.map { NSColor($0).cgColor }
            gradient.locations = sky.locations.map { NSNumber(value: $0) }
            let motionChanged = sky.motion != self.sky?.motion
            self.sky = sky
            if motionChanged { rebuildMotion() }
        }
        self.animating = animating
        aimGradient()
        applyAnimations()
    }

    private func aimGradient() {
        guard let sky else { return }
        let p = WeatherSkyView.points(angle: sky.angle, size: bounds.size)
        gradient.startPoint = p.start
        gradient.endPoint = p.end
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        aimGradient()
        clip.frame = bounds
        if bounds.size != builtSize {
            rebuildMotion()
            applyAnimations()
        }
        CATransaction.commit()
    }

    // MARK: - Motion

    private func rebuildMotion() {
        motionLayer?.removeFromSuperlayer()
        motionLayer = nil
        builtSize = bounds.size
        guard let sky, bounds.width > 0, bounds.height > 0 else { return }
        let l: CALayer?
        switch sky.motion {
        case .none: l = nil
        case .drift: l = SkyMotionLayers.drift(size: bounds.size)
        case .streaks: l = SkyMotionLayers.streaks(size: bounds.size)
        case .flash: l = SkyMotionLayers.flash(size: bounds.size)
        case .flakes: l = SkyMotionLayers.flakes(size: bounds.size)
        }
        if let l {
            clip.addSublayer(l)
            motionLayer = l
        }
    }

    /// Adds the motion's animations while animating, else strips every animation (and an
    /// emitter stops making flakes).
    private func applyAnimations() {
        guard let motion = motionLayer, let sky else { return }
        if animating {
            SkyMotionLayers.start(sky.motion, layer: motion, size: bounds.size)
        } else {
            SkyMotionLayers.stop(motion)
        }
    }
}

/// The four motion layers and their animations (spec 5 timings).
@MainActor
enum SkyMotionLayers {
    static let driftSeconds: CFTimeInterval = 40
    static let streakSeconds: CFTimeInterval = 0.8
    static let streakTile = CGSize(width: 14, height: 22)
    static let streakOpacity: Float = 0.55
    static let flashSeconds: CFTimeInterval = 0.25
    /// Seconds between flashes, 9–15, a fixed (seeded) sequence that repeats.
    static let flashGaps: [CFTimeInterval] = [11, 9, 14, 12, 15, 10]
    static let flakeLifetime: Float = 6
    static let flakeBirthRate: Float = 3

    // MARK: Drift: two soft cloud banks sliding across, 40 s a pass.

    static func drift(size: CGSize) -> CALayer {
        let layer = CALayer()
        layer.name = "drift"
        layer.frame = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height)
        layer.contents = cloudImage(size: CGSize(width: size.width * 2, height: size.height))
        layer.opacity = 0.9
        return layer
    }

    /// Soft white puffs, drawn twice a width apart so sliding by one width loops seamlessly.
    private static func cloudImage(size: CGSize) -> CGImage? {
        let scale: CGFloat = 2
        let w = Int(size.width * 2 * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let puffs: [(x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)] = [
            (0.12, 0.70, 0.60, 0.12), (0.48, 0.85, 0.45, 0.09), (0.78, 0.40, 0.55, 0.08),
        ]
        for copy in 0..<2 {
            for p in puffs {
                let center = CGPoint(x: (p.x + CGFloat(copy)) * size.width, y: p.y * size.height)
                let colors = [CGColor(gray: 1, alpha: p.a), CGColor(gray: 1, alpha: 0)] as CFArray
                guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors,
                                         locations: [0, 1]) else { continue }
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.scaleBy(x: 2.2, y: 1)
                ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                       endRadius: p.r * size.height, options: [])
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()
    }

    // MARK: Streaks: a 14 × 22 pt pattern of thin slanted lines falling, 0.8 s a tile.

    static func streaks(size: CGSize) -> CALayer {
        let tile = streakTile
        let cell = CALayer()
        cell.frame = CGRect(origin: .zero, size: tile)
        cell.contents = streakImage(tile)
        let row = CAReplicatorLayer()
        row.instanceCount = Int((size.width / tile.width).rounded(.up)) + 1
        row.instanceTransform = CATransform3DMakeTranslation(tile.width, 0, 0)
        row.frame = CGRect(x: 0, y: 0, width: size.width + tile.width, height: tile.height)
        row.addSublayer(cell)
        let grid = CAReplicatorLayer()
        grid.instanceCount = Int((size.height / tile.height).rounded(.up)) + 2
        grid.instanceTransform = CATransform3DMakeTranslation(0, tile.height, 0)
        grid.frame = CGRect(x: 0, y: -tile.height, width: size.width + tile.width, height: size.height + 2 * tile.height)
        grid.addSublayer(row)
        grid.name = "streaks"
        grid.opacity = streakOpacity
        return grid
    }

    private static func streakImage(_ tile: CGSize) -> CGImage? {
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(tile.width * scale), height: Int(tile.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.24))
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        // Wireframe B: a 105° hairline through the middle of each tile.
        ctx.move(to: CGPoint(x: tile.width * 0.62, y: tile.height * 0.95))
        ctx.addLine(to: CGPoint(x: tile.width * 0.42, y: tile.height * 0.30))
        ctx.strokePath()
        return ctx.makeImage()
    }

    // MARK: Flash: a soft white wash, 0.25 s, every 9–15 s.

    static func flash(size: CGSize) -> CALayer {
        let layer = CALayer()
        layer.name = "flash"
        layer.frame = CGRect(origin: .zero, size: size)
        layer.backgroundColor = CGColor(gray: 1, alpha: 1)
        layer.opacity = 0
        return layer
    }

    // MARK: Flakes: three a second, six seconds to fall.

    static func flakes(size: CGSize) -> CALayer {
        let emitter = CAEmitterLayer()
        emitter.name = "flakes"
        emitter.frame = CGRect(origin: .zero, size: size)
        emitter.emitterShape = .line
        emitter.emitterPosition = CGPoint(x: size.width / 2, y: -4)
        emitter.emitterSize = CGSize(width: size.width, height: 1)
        let cell = CAEmitterCell()
        cell.contents = flakeImage()
        cell.birthRate = flakeBirthRate
        cell.lifetime = flakeLifetime
        cell.velocity = CGFloat(Double(size.height + 8) / Double(flakeLifetime))
        cell.velocityRange = cell.velocity * 0.25
        cell.emissionLongitude = .pi / 2   // down (the view is flipped)
        cell.emissionRange = .pi / 14
        cell.scale = 0.5
        cell.scaleRange = 0.25
        cell.alphaRange = 0.3
        cell.spin = 0.3
        cell.spinRange = 0.6
        emitter.emitterCells = [cell]
        emitter.birthRate = 0
        return emitter
    }

    private static func flakeImage() -> CGImage? {
        let d = 8
        guard let ctx = CGContext(data: nil, width: d, height: d, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: d - 2, height: d - 2))
        return ctx.makeImage()
    }

    // MARK: Start and stop

    static func start(_ motion: SkyMotion, layer: CALayer, size: CGSize) {
        switch motion {
        case .none:
            return
        case .drift:
            guard layer.animation(forKey: "drift") == nil else { return }
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = size.width
            a.toValue = 0
            a.duration = driftSeconds
            a.repeatCount = .infinity
            layer.add(a, forKey: "drift")
        case .streaks:
            guard layer.animation(forKey: "streaks") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = 0
            a.toValue = streakTile.height
            a.duration = streakSeconds
            a.repeatCount = .infinity
            layer.add(a, forKey: "streaks")
        case .flash:
            guard layer.animation(forKey: "flash") == nil else { return }
            var pulses: [CAAnimation] = []
            var t: CFTimeInterval = 0
            for gap in flashGaps {
                t += gap
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [0, 0.32, 0.08, 0.22, 0]
                pulse.keyTimes = [0, 0.2, 0.45, 0.6, 1]
                pulse.duration = flashSeconds
                pulse.beginTime = t
                pulses.append(pulse)
            }
            let group = CAAnimationGroup()
            group.animations = pulses
            group.duration = t + 1
            group.repeatCount = .infinity
            layer.add(group, forKey: "flash")
        case .flakes:
            guard let emitter = layer as? CAEmitterLayer, emitter.birthRate == 0 else { return }
            emitter.beginTime = CACurrentMediaTime()
            emitter.birthRate = 1
        }
    }

    static func stop(_ layer: CALayer) {
        layer.removeAllAnimations()
        if let emitter = layer as? CAEmitterLayer { emitter.birthRate = 0 }
    }
}
