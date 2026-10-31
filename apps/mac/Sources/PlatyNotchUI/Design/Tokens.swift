import AppKit
import PlatyNotchKit
import SwiftUI

/// The design tokens (`PlatyNotchKit` Design, Quiet Notch spec 5) as SwiftUI and AppKit
/// values. Views read type, ink, state colours and icons through here, never literals.
enum DS {
    /// A type-scale step as a system font (Rounded or Mono where the step says so).
    static func font(_ t: TypeStyle) -> Font {
        let design: Font.Design = t.mono ? .monospaced : (t.rounded ? .rounded : .default)
        return .system(size: t.size, weight: weight(t.weight), design: design)
    }

    /// A type-scale step's size and weight in another design (the pill's rounded counts,
    /// monospaced commands at the caption size).
    static func font(_ t: TypeStyle, design: Font.Design) -> Font {
        .system(size: t.size, weight: weight(t.weight), design: design)
    }

    static func nsFont(_ t: TypeStyle) -> NSFont {
        let w: NSFont.Weight = switch t.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
        if t.mono { return .monospacedSystemFont(ofSize: t.size, weight: w) }
        let base = NSFont.systemFont(ofSize: t.size, weight: w)
        guard t.rounded, let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: t.size) ?? base
    }

    static func weight(_ w: TypeStyle.Weight) -> Font.Weight {
        switch w {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    /// White ink at one of the `Ink` opacities (the panel is always black).
    static func ink(_ alpha: Double) -> Color { Color.white.opacity(alpha) }

    /// Primary, secondary and tertiary text; hairlines; the one fill (chips, the command
    /// line, buttons, code).
    static let primary = ink(Ink.primary)
    static let secondary = ink(Ink.secondary)
    static let tertiary = ink(Ink.tertiary)
    static let hairline = ink(Ink.hairline)
    static let fill = ink(Ink.fill)

    /// A state colour at its own opacity (done and idle are white ink).
    static func color(_ tone: StateTone, alpha: Double = 1) -> Color {
        Color(tone.rgb).opacity(tone.alpha * alpha)
    }

    /// A state colour as an `NSColor` (layer-backed views). One instance per (tone, alpha),
    /// so `AgentDotNSView.configure` sees an unchanged colour as equal and does not recolour
    /// on every update.
    static func dynamicNSColor(_ tone: StateTone, alpha: Double = 1) -> NSColor {
        let key = ColorKey(tone: tone, alpha: alpha)
        colorLock.lock()
        defer { colorLock.unlock() }
        if let cached = colorCache[key] { return cached }
        let color = NSColor(tone.rgb).withAlphaComponent(CGFloat(tone.alpha * alpha))
        colorCache[key] = color
        return color
    }

    private struct ColorKey: Hashable {
        let tone: StateTone
        let alpha: Double
    }

    private static let colorLock = NSLock()
    /// Guarded by `colorLock`; a handful of entries (five tones, two alphas).
    nonisolated(unsafe) private static var colorCache: [ColorKey: NSColor] = [:]

    /// `color(_:alpha:)` (the name kept for the many call sites that predate the black panel).
    static func dynamicColor(_ tone: StateTone, alpha: Double = 1) -> Color {
        color(tone, alpha: alpha)
    }

    /// An agent's colour (the pill's per-agent dots); one instance per agent.
    static func agentNSColor(_ a: AgentIdentity) -> NSColor {
        colorLock.lock()
        defer { colorLock.unlock() }
        if let cached = agentCache[a] { return cached }
        let color = NSColor(a.rgb)
        agentCache[a] = color
        return color
    }

    /// Guarded by `colorLock`; one entry per agent.
    nonisolated(unsafe) private static var agentCache: [AgentIdentity: NSColor] = [:]

    static let cream = Color(Brand.cream)

    /// An SF Symbol at an `IconSize` step: monochrome, regular weight.
    static func icon(_ systemName: String, size: CGFloat = IconSize.symbol) -> some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: .regular))
    }
}

extension StateTone {
    /// A session's tone as a state: active → working, attention → needs you, idle and
    /// exited → idle.
    init(_ tone: AgentTone) {
        switch tone {
        case .active: self = .working
        case .attention: self = .needsYou
        case .idle, .off: self = .idle
        }
    }
}

extension NSColor {
    convenience init(_ rgb: RGB) {
        self.init(srgbRed: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b), alpha: 1)
    }
}

extension View {
    /// A flat fill on the black panel, never a border (Quiet Notch spec 5.3): white at
    /// `Ink.fill` in a rounded rectangle from the radius scale.
    func panelFill(radius: CGFloat = Radius.medium) -> some View {
        background(DS.fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
