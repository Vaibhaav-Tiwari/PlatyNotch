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
    /// The light surface.
    static let lightSurface = Color(nsColor: .windowBackgroundColor)

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .light ? lightSurface : surface
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

    static let mono = Font.system(size: 11, design: .monospaced)
    /// Line height of `mono`, used to size the approval summary.
    static let monoLineHeight: CGFloat = 14

    static func color(_ tone: AgentTone) -> Color {
        switch tone {
        case .active: Color(nsColor: .systemGreen)
        case .attention: Color(nsColor: .systemOrange)
        case .idle: Color(nsColor: .systemGray)
        case .off: Color(nsColor: .systemGray).opacity(0.35)
        }
    }

    static func tint(_ tint: LiveTint) -> Color {
        switch tint {
        case .neutral: Color(nsColor: .labelColor)
        case .accent: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        }
    }

    static func color(_ level: UsageLevel) -> Color {
        switch level {
        case .normal: Color(nsColor: .systemGreen)
        case .high: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        }
    }

    /// SF Symbol for an agent id ("claude-code", "codex", ...).
    static func agentSymbol(_ agent: String) -> String {
        switch agent {
        case "claude-code": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        default: "terminal"
        }
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

/// A session state dot; working sessions pulse.
struct AgentDot: View {
    let tone: AgentTone
    var size: CGFloat = 7
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Theme.color(tone))
            .frame(width: size, height: size)
            .opacity(tone.pulses && pulse ? 0.45 : 1)
            .onAppear { startPulse() }
            .onChange(of: tone) { startPulse() }
            .accessibilityHidden(true)
    }

    private func startPulse() {
        guard tone.pulses else { pulse = false; return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// Small rounded tag, e.g. the tool name.
struct Tag: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.card, in: Capsule())
            .foregroundStyle(.secondary)
    }
}
