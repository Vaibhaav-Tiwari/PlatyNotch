import AppKit
import PlatyNotchKit
import SwiftUI

/// Colours, fonts and shapes shared by the panel views. The panel is always black (Quiet
/// Notch spec 1) and runs in the dark scheme; text is white ink at three opacities.
enum Theme {
    /// The pill's bottom corners (unchanged); the open panel uses `Radius.panelBottom`.
    static let corner: CGFloat = 14
    /// Every panel surface: the pill, the open panel, peeks.
    static let surface = Color(PanelPalette.panel)
    /// Level tracks (HUD bars).
    static let track = DS.ink(0.18)

    /// The amber behind black text (the pill's approval count, the ringing chip).
    static let needsYouFill = Color(StateTone.needsYou.rgb)

    /// The approval card's fill (#111111).
    static let approvalCard = Color(PanelPalette.approvalCard)

    /// The Allow button's green (green text on green at 0.12).
    static let allow = DS.color(.working)

    /// Small warning text ("Contains hidden characters"): needs-you amber.
    static let warning = DS.color(.needsYou)

    /// The one fill (chips, the command line, buttons, code): white at `Ink.fill`.
    static let card = DS.fill
    static let codeBackground = DS.fill
    static let divider = DS.hairline

    /// The diff box's and the peek row's mono (11 pt; the diff box is unchanged).
    static let mono = DS.font(TypeScale.caption, design: .monospaced).weight(.regular)
    /// Line height of `mono`, used to size the diff box.
    static let monoLineHeight: CGFloat = 14

    /// `color(_:)` as an NSColor (layer-backed dots): the state palette (`StateTone`),
    /// resolved against the view's appearance. Exited sessions are a faint idle.
    static func nsColor(_ tone: AgentTone) -> NSColor {
        DS.dynamicNSColor(StateTone(tone))
    }

    /// A session's tone in the state palette: working green, needs-you amber, idle ink.
    static func color(_ tone: AgentTone) -> Color {
        DS.dynamicColor(StateTone(tone))
    }

    /// A live activity's tint: neutral and accent are primary ink (the panel has no accent
    /// colour); warning and critical are the needs-you and error states.
    static func tint(_ tint: LiveTint) -> Color {
        switch tint {
        case .neutral, .accent: DS.primary
        case .warning: DS.color(.needsYou)
        case .critical: DS.color(.error)
        }
    }

    /// `tint(_:)` (the scheme is always dark; kept for the pill's call sites).
    static func tint(_ tint: LiveTint, scheme: ColorScheme) -> Color {
        Self.tint(tint)
    }

    /// Usage in the state palette: working green, needs-you amber, error red.
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

    /// Square top corners against the notch; a fully rounded pill otherwise. The open panel
    /// (`open`) has 22 pt bottom corners; the pill and peeks keep 14.
    static func panelShape(hasNotch: Bool, open: Bool = false) -> UnevenRoundedRectangle {
        let bottom: CGFloat = open ? Radius.panelBottom : corner
        let top: CGFloat = hasNotch ? 0 : bottom
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                      bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
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

/// A small capsule tag on the fill, e.g. the approval's tool (11 pt, padding 1 × 7).
struct Tag: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(DS.font(TypeScale.caption))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(DS.fill, in: Capsule())
            .foregroundStyle(DS.primary)
    }
}

/// A keyboard shortcut in a keycap: 11 pt mono, a 1 px hairline border, padding 0 × 4.
struct Keycap: View {
    let text: String
    var color: Color = DS.tertiary

    var body: some View {
        Text(verbatim: text)
            .font(DS.font(TypeScale.caption, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous)
                .stroke(DS.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}
