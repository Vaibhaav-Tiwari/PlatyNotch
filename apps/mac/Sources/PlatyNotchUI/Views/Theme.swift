import AppKit
import PlatyNotchKit
import SwiftUI

/// Colors, fonts and shapes shared by the panel views. The panel runs in the color
/// scheme Appearance › Theme picks (`scheme`) and the views use semantic colors that
/// resolve against it. Dark draws a black surface (it continues the notch).
enum Theme {
    static let corner: CGFloat = 14
    /// The dark surface (also what the compact pill on a notch always uses).
    static let surface = Color.black
    /// The light surface (`PanelPalette.lightSurface`, the contrast tests' reference).
    static let lightSurface = Color(PanelPalette.lightSurface)
    /// Level tracks (HUD bars) on either surface.
    static let track = Color.primary.opacity(0.18)

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .light ? lightSurface : surface
    }

    /// The amber behind black text (the pill's approval count, the ringing chip): the dark
    /// needs-you amber in every scheme, since black on the light amber is about 3.1:1.
    static let needsYouFill = Color(StateTone.needsYou.rgb(dark: true))

    /// The open panel's dark surface (#0B0D0D, `PanelPalette.panelDark`).
    static let panelDark = Color(PanelPalette.panelDark)

    /// Whether the system glass effect exists (macOS 26 and later).
    static var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// The surface behind a mode's content (spec 7.1): the pill (`.hidden` / `.compact`)
    /// keeps `surface(scheme)`, which is pure black whenever it touches the notch; the open
    /// panel and peeks are `panelDark` in dark and the light surface in light, or the
    /// system glass when `style` is `.glass` (pass `effectiveSurface(glassAvailable:mode:
    /// approvalsShowing:)`, which keeps every approval on an opaque surface). `hasNotch` is
    /// reserved: the notch band is drawn separately (`PanelLayout.notchBand`).
    ///
    /// The opaque surfaces are one shape whose colour changes, so opening and closing
    /// resize (and recolour) the same surface with the panel instead of cross-fading two
    /// surfaces at their own sizes (a seam around the pill while closing).
    @ViewBuilder
    static func surface(_ scheme: ColorScheme, mode: PanelMode, hasNotch: Bool,
                        style: AppearanceSettings.SurfaceStyle) -> some View {
        let pill: Bool = mode == .hidden || mode == .compact
        if !pill, style == .glass, #available(macOS 26, *) {
            Rectangle().fill(Color.clear).glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(surfaceColor(scheme, pill: pill))
        }
    }

    /// The opaque surface's colour: the pill's (black on a notch) or the open panel's.
    static func surfaceColor(_ scheme: ColorScheme, pill: Bool) -> Color {
        if pill { return surface(scheme) }
        return scheme == .light ? lightSurface : panelDark
    }

    /// The Allow button's tint: systemGreen in dark, a darker green in light (4.5:1 on
    /// its tinted fill, `PanelPalette.allowLight`).
    static func allow(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color(PanelPalette.allowLight) : Color(nsColor: .systemGreen)
    }

    /// Small warning text ("Contains hidden characters"): systemOrange in dark, a darker
    /// orange in light so it stays at 4.5:1 or more (`PanelPalette`, AppearanceTests).
    static func warning(_ scheme: ColorScheme) -> Color {
        Color(scheme == .light ? PanelPalette.warningLight : PanelPalette.warningDark)
    }

    /// The panel's color scheme for `theme`. The resting pill on a notch stays dark in
    /// every theme: it continues the black camera housing, which a light pill would show
    /// as a hole.
    static func scheme(_ theme: AppearanceSettings.Theme, system: ColorScheme, mode: PanelMode,
                       hasNotch: Bool) -> ColorScheme {
        if hasNotch, mode == .compact || mode == .hidden { return .dark }
        switch theme {
        case .system: return system
        case .dark: return .dark
        case .light: return .light
        }
    }
    static let card = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    static let codeBackground = Color(nsColor: .textBackgroundColor).opacity(0.55)
    static let divider = Color(nsColor: .separatorColor)

    static let mono = DS.font(TypeScale.caption, design: .monospaced).weight(.regular)
    /// Line height of `mono`, used to size the approval summary.
    static let monoLineHeight: CGFloat = 14

    /// `color(_:)` as an NSColor (layer-backed dots): the state palette (`StateTone`),
    /// resolved against the view's appearance. Exited sessions are a faint idle.
    static func nsColor(_ tone: AgentTone) -> NSColor {
        DS.dynamicNSColor(StateTone(tone), alpha: tone == .off ? 0.35 : 1)
    }

    /// A session's tone in the state palette: working teal, needs-you amber, idle grey.
    static func color(_ tone: AgentTone) -> Color {
        DS.dynamicColor(StateTone(tone), alpha: tone == .off ? 0.35 : 1)
    }

    /// A live activity's tint: neutral is the label colour; accent, warning and critical
    /// are the working, needs-you and error states.
    static func tint(_ tint: LiveTint) -> Color {
        switch tint {
        case .neutral: Color(nsColor: .labelColor)
        case .accent: DS.dynamicColor(.working)
        case .warning: DS.dynamicColor(.needsYou)
        case .critical: DS.dynamicColor(.error)
        }
    }

    /// `tint(_:)` resolved for `scheme` up front. A dynamic colour resolves against the
    /// drawing appearance, which under a clip (the pill's shape) can be the wrong one; the
    /// pill reads the environment's scheme instead.
    static func tint(_ tint: LiveTint, scheme: ColorScheme) -> Color {
        switch tint {
        case .neutral: Color(nsColor: .labelColor)
        case .accent: DS.color(.working, scheme)
        case .warning: DS.color(.needsYou, scheme)
        case .critical: DS.color(.error, scheme)
        }
    }

    /// Usage in the state palette (Task 18): working teal, needs-you amber, error coral.
    static func color(_ level: UsageLevel) -> Color {
        DS.dynamicColor(level.tone)
    }

    static func noticeSymbol(_ kind: String) -> String {
        switch kind {
        case "session-done": "checkmark.circle.fill"
        case "approval-timeout": "exclamationmark.bubble.fill"
        default: "info.circle.fill"
        }
    }

    /// Square top corners against the notch; a fully rounded pill otherwise.
    static func panelShape(hasNotch: Bool) -> UnevenRoundedRectangle {
        let top: CGFloat = hasNotch ? 0 : corner
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: corner,
                                      bottomTrailingRadius: corner, topTrailingRadius: top, style: .continuous)
    }
}

/// A session dot. A `.pulse` dot (working) pulses (1 → 0.45 → 1, 1.8 s) as a Core
/// Animation opacity animation played by the render server: the app does no work per
/// frame. It plays only while the panel ticks and Reduce Motion is off; otherwise it
/// draws solid. Every style is a solid circle: `.dim` (idle, finished) rests at 35%
/// opacity, `.errored` is filled coral instead of the given colour; neither animates.
struct AgentDot: View {
    let color: NSColor
    let style: AgentDotStyle
    var size: CGFloat = 7
    @Environment(\.panelTicking) private var ticking
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(color: NSColor, style: AgentDotStyle, size: CGFloat = 7) {
        self.color = color
        self.style = style
        self.size = size
    }

    /// A state dot in the state palette: working pulses, the rest are solid.
    init(tone: AgentTone, size: CGFloat = 7) {
        self.init(color: Theme.nsColor(tone), style: tone.pulses ? .pulse : .solid, size: size)
    }

    /// What is drawn for `style`: a pulse only while ticking without Reduce Motion.
    static func drawn(_ style: AgentDotStyle, ticking: Bool, reduceMotion: Bool) -> AgentDotStyle {
        guard style == .pulse else { return style }
        return ticking && !reduceMotion ? .pulse : .solid
    }

    var body: some View {
        AgentDotLayer(color: color, style: Self.drawn(style, ticking: ticking, reduceMotion: reduceMotion))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct AgentDotLayer: NSViewRepresentable {
    let color: NSColor
    let style: AgentDotStyle

    func makeNSView(context: Context) -> AgentDotNSView { AgentDotNSView() }

    func updateNSView(_ view: AgentDotNSView, context: Context) {
        view.configure(color: color, style: style)
    }
}

final class AgentDotNSView: NSView {
    static let pulseKey = "dot.pulse"
    private let dot = CALayer()
    private var color: NSColor = .systemGray
    private var style: AgentDotStyle = .solid

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull(),
                       "opacity": NSNull()]
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    /// The old form: `true` pulses, `false` is a solid dot.
    func configure(color: NSColor, pulses: Bool) {
        configure(color: color, style: pulses ? .pulse : .solid)
    }

    func configure(color: NSColor, style: AgentDotStyle) {
        let recolour: Bool = color != self.color || style != self.style
        self.color = color
        self.style = style
        if recolour { applyColor() }
        let pulses: Bool = style == .pulse
        guard pulses != isPulsing else { return }
        dot.removeAnimation(forKey: Self.pulseKey)
        guard pulses else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        dot.add(pulse, forKey: Self.pulseKey)
    }

    var isPulsing: Bool { dot.animation(forKey: Self.pulseKey) != nil }
    /// The dot's resting opacity (`AgentDotStyle.opacity`).
    var restingOpacity: Float { dot.opacity }
    /// The dot's fill, nil when clear.
    var fill: CGColor? { dot.backgroundColor }
    /// The width of any outline (always 0: dots are solid).
    var outlineWidth: CGFloat { dot.borderWidth }

    private func applyColor() {
        let source: NSColor = style == .errored ? DS.dynamicNSColor(.error) : color
        var cg: CGColor = source.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = source.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = cg
        dot.opacity = Float(style.opacity)
        CATransaction.commit()
    }
}

/// Small rounded tag, e.g. the tool name.
struct Tag: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(DS.font(TypeScale.caption, design: .monospaced).weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.card, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}
