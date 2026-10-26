import AppKit
import PlatyNotchKit
import QuartzCore
import SwiftUI

/// Platy's pond behind Now's idle hero (spec 8.2): a sky and water that follow the time of
/// day (`PondPalette`), stars at night, a sun or moon with its light on the water, a soft
/// horizon haze, and a ripple at Platy's feet. Drawn with Core Animation layers only;
/// SwiftUI draws nothing per frame. One 1.8 s ripple plays each time the panel opens (shown,
/// Reduce Motion off); otherwise the scene is a still picture.
struct PondSceneView: View {
    let phase: DayPhase
    /// Where Platy's centre sits from the trailing edge (the ripple goes under it).
    var platyInset: CGFloat = 68
    @Environment(\.panelTicking) private var ticking
    @Environment(\.gamePanel) private var panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PondLayerView(phase: phase, platyInset: platyInset,
                      animates: Self.animates(ticking: ticking, expanded: panel.expanded, reduceMotion: reduceMotion))
            .accessibilityHidden(true)
    }

    /// The ripple runs only while the open panel is really shown and Reduce Motion is off.
    static func animates(ticking: Bool, expanded: Bool, reduceMotion: Bool) -> Bool {
        ticking && expanded && !reduceMotion
    }
}

private struct PondLayerView: NSViewRepresentable {
    let phase: DayPhase
    let platyInset: CGFloat
    let animates: Bool

    func makeNSView(context: Context) -> PondSceneNSView { PondSceneNSView() }

    func updateNSView(_ view: PondSceneNSView, context: Context) {
        view.platyInset = platyInset
        view.configure(phase: phase, animates: animates)
    }
}

/// The pond's layers. `configure` is cheap when nothing changed.
final class PondSceneNSView: NSView {
    static let rippleKey = "pond.ripple"
    /// The share of the height that is sky; the rest is water.
    static let horizon: CGFloat = 0.6
    /// One ripple per open (spec 9: no animation over 2 seconds).
    static let rippleLength: CFTimeInterval = 1.8

    private let sky = CAGradientLayer()
    private let water = CAGradientLayer()
    private let haze = CAGradientLayer()
    private let shoreline = CALayer()
    private let glow = CAGradientLayer()
    /// The sun (morning, day) or the moon (night); none at dusk, where the glow is the sunset.
    private let orb = CALayer()
    /// The orb's light on the water: a soft vertical streak below it.
    private let orbReflection = CAGradientLayer()
    private let reflection = CAGradientLayer()
    private let ripple = CAShapeLayer()
    private var stars: [CALayer] = []
    private var phase: DayPhase?
    private var animating = false
    var platyInset: CGFloat = 68 { didSet { if platyInset != oldValue { needsLayout = true } } }

    /// Fixed star positions (fractions of the sky), so the night is the same every time.
    private static let starSpots: [(x: CGFloat, y: CGFloat, size: CGFloat, alpha: Float)] = [
        (0.08, 0.18, 1.5, 0.55), (0.19, 0.42, 1.0, 0.4), (0.31, 0.12, 1.2, 0.5),
        (0.44, 0.30, 1.0, 0.35), (0.53, 0.10, 1.6, 0.6), (0.62, 0.38, 1.0, 0.4),
        (0.71, 0.16, 1.2, 0.45), (0.86, 0.28, 1.0, 0.35), (0.93, 0.08, 1.3, 0.5),
    ]

    /// Where the orb sits (fraction of the width, points above the horizon) and its size. It
    /// stays in the open sky between the greeting (left) and Platy (right).
    static func orbPlacement(_ phase: DayPhase) -> (x: CGFloat, lift: CGFloat, size: CGFloat)? {
        switch phase {
        case .morning: (0.60, 5, 24)     // low, warm and large, just risen
        case .day: (0.50, 44, 16)        // high, small and pale
        case .evening: nil               // the warm glow behind Platy is the sunset
        case .night: (0.58, 40, 11)      // a small moon
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(),
                                         "opacity": NSNull(), "hidden": NSNull(), "path": NSNull(),
                                         "backgroundColor": NSNull(), "frame": NSNull()]
        for l in [sky, water, orbReflection, haze, shoreline, glow, orb, reflection, ripple] as [CALayer] {
            l.actions = still
            layer?.addSublayer(l)
        }
        for radial in [glow, reflection, orbReflection] {
            radial.type = .radial
            radial.startPoint = CGPoint(x: 0.5, y: 0.5)
            radial.endPoint = CGPoint(x: 1, y: 1)
        }
        haze.startPoint = CGPoint(x: 0.5, y: 1)
        haze.endPoint = CGPoint(x: 0.5, y: 0)
        ripple.fillColor = nil
        ripple.lineWidth = 1
        ripple.opacity = 0
        for spot in Self.starSpots {
            let star = CALayer()
            star.actions = still
            star.backgroundColor = NSColor.white.cgColor
            star.opacity = spot.alpha
            star.cornerRadius = spot.size / 2
            layer?.insertSublayer(star, above: sky)
            stars.append(star)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Whether the ripple is running (tests).
    var isAnimating: Bool { ripple.animation(forKey: Self.rippleKey) != nil }
    /// The ripple's length in seconds (tests).
    var rippleDuration: CFTimeInterval { ripple.animation(forKey: Self.rippleKey)?.duration ?? 0 }
    /// How often the ripple plays (tests): once.
    var rippleRepeatCount: Float { ripple.animation(forKey: Self.rippleKey)?.repeatCount ?? 0 }
    /// Stars drawn now (tests).
    var visibleStarCount: Int { stars.filter { !$0.isHidden }.count }
    /// Whether the sun or moon shows (tests).
    var showsOrb: Bool { !orb.isHidden }

    func configure(phase new: DayPhase, animates: Bool) {
        if new != phase {
            phase = new
            paint(new)
            needsLayout = true
        }
        if animates != animating {
            animating = animates
            // One ripple each time the panel opens; closing removes any that is still running.
            animates ? startRipple() : ripple.removeAnimation(forKey: Self.rippleKey)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b: CGRect = bounds
        let waterHeight: CGFloat = (b.height * (1 - Self.horizon)).rounded()
        // AppKit layers are not flipped: y = 0 is the bottom (the water).
        water.frame = CGRect(x: 0, y: 0, width: b.width, height: waterHeight)
        sky.frame = CGRect(x: 0, y: waterHeight, width: b.width, height: b.height - waterHeight)
        let hazeHeight: CGFloat = 10
        haze.frame = CGRect(x: 0, y: waterHeight - hazeHeight / 2, width: b.width, height: hazeHeight)
        shoreline.frame = CGRect(x: 0, y: waterHeight - 0.25, width: b.width, height: 0.5)
        let cx: CGFloat = b.width - platyInset
        let glowSize: CGFloat = 180
        glow.frame = CGRect(x: cx - glowSize / 2, y: waterHeight - glowSize / 2 + 26, width: glowSize, height: glowSize)
        if let phase, let place = Self.orbPlacement(phase) {
            let ox: CGFloat = b.width * place.x
            orb.frame = CGRect(x: ox - place.size / 2, y: waterHeight + place.lift - place.size / 2,
                               width: place.size, height: place.size)
            orb.cornerRadius = place.size / 2
            let streak: CGFloat = place.size * 1.6
            orbReflection.frame = CGRect(x: ox - streak / 2, y: waterHeight - 34, width: streak, height: 32)
        }
        // Platy's feet stand in the shallows near the bottom: a soft light pool and the ripple there.
        let feet: CGFloat = 18
        reflection.frame = CGRect(x: cx - 60, y: feet - 12, width: 120, height: 24)
        let rippleRect = CGRect(x: cx - 44, y: feet - 8, width: 88, height: 16)
        ripple.frame = rippleRect
        ripple.path = CGPath(ellipseIn: CGRect(origin: .zero, size: rippleRect.size), transform: nil)
        let skyHeight: CGFloat = b.height - waterHeight
        for (star, spot) in zip(stars, Self.starSpots) {
            star.frame = CGRect(x: b.width * spot.x, y: waterHeight + skyHeight * (1 - spot.y),
                                width: spot.size, height: spot.size)
        }
        CATransaction.commit()
    }

    private func paint(_ phase: DayPhase) {
        let p = PondPalette.of(phase)
        let night: Bool = phase == .night
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sky.colors = [NSColor(p.skyTop).cgColor, NSColor(p.skyBottom).cgColor]
        // CAGradientLayer runs bottom to top in AppKit's unflipped layers.
        sky.startPoint = CGPoint(x: 0.5, y: 1)
        sky.endPoint = CGPoint(x: 0.5, y: 0)
        let waterTop: NSColor = NSColor(p.water).blended(withFraction: 0.18, of: NSColor(p.skyBottom)) ?? NSColor(p.water)
        water.colors = [waterTop.cgColor, NSColor(p.water).cgColor]
        water.startPoint = CGPoint(x: 0.5, y: 1)
        water.endPoint = CGPoint(x: 0.5, y: 0)
        let cream = NSColor(Brand.cream)
        // Warm morning light; pale daylight; moonlight.
        let light: NSColor = switch phase {
        case .morning: NSColor(srgbRed: 0.96, green: 0.78, blue: 0.56, alpha: 1)
        case .day: NSColor(srgbRed: 0.98, green: 0.95, blue: 0.86, alpha: 1)
        case .evening, .night: cream
        }
        // The horizon is a soft haze, not a hard line.
        let hazeAlpha: CGFloat = night ? 0.06 : 0.12
        haze.colors = [light.withAlphaComponent(0).cgColor, light.withAlphaComponent(hazeAlpha).cgColor,
                       light.withAlphaComponent(0).cgColor]
        shoreline.backgroundColor = cream.withAlphaComponent(night ? 0.06 : 0.10).cgColor
        // The glow behind Platy: warm at dusk (the sunset), faint otherwise.
        let strength: CGFloat = switch phase {
        case .night: 0.06
        case .evening: 0.16
        case .morning: 0.07
        case .day: 0.09
        }
        glow.colors = [cream.withAlphaComponent(strength).cgColor, cream.withAlphaComponent(0).cgColor]
        let hasOrb: Bool = Self.orbPlacement(phase) != nil
        orb.isHidden = !hasOrb
        orbReflection.isHidden = !hasOrb
        let orbAlpha: CGFloat = switch phase {
        case .morning: 0.55
        case .day: 0.35
        case .evening: 0
        case .night: 0.75
        }
        orb.backgroundColor = light.withAlphaComponent(orbAlpha).cgColor
        orb.shadowColor = light.cgColor
        orb.shadowOpacity = Float(orbAlpha * 0.8)
        orb.shadowRadius = phase == .morning ? 14 : 6
        orb.shadowOffset = .zero
        orbReflection.colors = [light.withAlphaComponent(orbAlpha * 0.22).cgColor, light.withAlphaComponent(0).cgColor]
        reflection.colors = [cream.withAlphaComponent(night ? 0.06 : 0.10).cgColor, cream.withAlphaComponent(0).cgColor]
        ripple.strokeColor = cream.withAlphaComponent(0.35).cgColor
        for star in stars { star.isHidden = !p.stars }
        CATransaction.commit()
    }

    /// One soft ring that widens and fades under Platy, once, in the render server.
    private func startRipple() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.55
        scale.toValue = 1.25
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0, 0]
        fade.keyTimes = [0, 0.15, 0.75, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Self.rippleLength
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = 1
        group.isRemovedOnCompletion = true
        ripple.add(group, forKey: Self.rippleKey)
    }
}
