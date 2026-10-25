import AppKit
import PlatyNotchKit
import SwiftUI

/// The design tokens (`PlatyNotchKit` Design, spec 7) as SwiftUI and AppKit values.
/// Views read type, state colours and icons through here, never literals.
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

    /// A state colour for the scheme (dark values on the dark surfaces, light ones on light).
    static func color(_ tone: StateTone, _ scheme: ColorScheme) -> Color {
        Color(tone.rgb(dark: scheme != .light))
    }

    static func nsColor(_ tone: StateTone, dark: Bool) -> NSColor {
        NSColor(tone.rgb(dark: dark))
    }

    /// A state colour that follows the drawing appearance (layer-backed views). One
    /// instance per (tone, alpha), so `AgentDotNSView.configure` sees an unchanged colour
    /// as equal and does not recolour on every update.
    static func dynamicNSColor(_ tone: StateTone, alpha: Double = 1) -> NSColor {
        let key = ColorKey(tone: tone, alpha: alpha)
        colorLock.lock()
        defer { colorLock.unlock() }
        if let cached = colorCache[key] { return cached }
        let color = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
            return NSColor(tone.rgb(dark: dark)).withAlphaComponent(CGFloat(alpha))
        }
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

    /// A state colour that follows the environment's scheme (no scheme to hand).
    static func dynamicColor(_ tone: StateTone, alpha: Double = 1) -> Color {
        Color(nsColor: dynamicNSColor(tone, alpha: alpha))
    }

    static func agent(_ a: AgentIdentity, _ scheme: ColorScheme) -> Color {
        Color(a.rgb(dark: scheme != .light))
    }

    static let teal = Color(Brand.teal)
    static let cream = Color(Brand.cream)
    static let pond = Color(Brand.pond)

    /// An SF Symbol at an `IconSize` step: hierarchical rendering, medium weight.
    static func icon(_ systemName: String, size: CGFloat) -> some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size, weight: .medium))
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
