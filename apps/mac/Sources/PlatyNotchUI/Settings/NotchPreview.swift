import PlatyNotchKit
import SwiftUI

/// Settings › Notch's live preview: the resting pill beside a notch and the open panel
/// below it, drawn from the settings as they are now (pill width, live side, Platy,
/// theme, surface, Minimal). Changing Motion replays the open with that motion; so does
/// a click. Fixed sample content (music and two agents); nothing is read.
struct NotchPreview: View {
    let appearance: AppearanceSettings
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = true

    static let height: CGFloat = 188

    init(appearance: AppearanceSettings) {
        self.appearance = appearance
    }

    var body: some View {
        HStack(spacing: 14) {
            vignette(caption: appearance.mode == .minimal ? "Resting (hidden until something is live)" : "Resting") {
                restingPill
            }
            vignette(caption: "Open") { openPanel }
                .contentShape(Rectangle())
                .onTapGesture { replay() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Replays opening with the chosen motion")
        }
        .frame(height: Self.height)
        .onChange(of: appearance.motion) { replay() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of the notch")
    }

    // MARK: - Pieces

    private func vignette<Content: View>(caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                Wallpaper()
                content()
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height - 26)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            Text(verbatim: caption)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The notch's real pill at the chosen width, scaled to the vignette.
    private var restingPill: some View {
        let layout = PillRenders.notchLayout(appearance.pillWidth)
        let size: CGSize = layout.contentRect(for: .compact).size
        let scale: CGFloat = Self.pillScale
        let (content, mood) = PillRenders.content(.music)
        let pill = CompactPill(content: content, connection: .connected, hasNotch: true,
                               notchWidth: layout.anchor.width, liveSide: appearance.liveSide,
                               earWidth: layout.liveEarWidth, platy: appearance.showPlaty ? mood : nil)
        return ZStack {
            Theme.panelShape(hasNotch: true).fill(Color(PanelPalette.darkSurface))
            pill
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        .environment(\.panelTicking, false)
        .scaleEffect(scale, anchor: .top)
        .frame(width: size.width * scale, height: size.height * scale, alignment: .top)
        .opacity(appearance.mode == .minimal ? 0.35 : 1)
    }

    /// The open panel in miniature: the notch band, the destinations, a hero and four glances.
    private var openPanel: some View {
        let scheme: ColorScheme = Theme.scheme(appearance.theme, system: systemScheme, mode: .expanded, hasNotch: true)
        let width: CGFloat = PanelLayout.expandedSize.width * Self.panelScale
        let height: CGFloat = PanelLayout.expandedSize.height * Self.panelScale
        return MiniPanel(showPlaty: appearance.showPlaty)
            .frame(width: width, height: height)
            .background {
                ZStack(alignment: .top) {
                    Theme.surface(scheme, mode: .expanded, hasNotch: true, style: appearance.surface)
                    Color(PanelPalette.darkSurface).frame(height: Self.bandHeight)
                }
            }
            .clipShape(Theme.panelShape(hasNotch: true))
            .environment(\.colorScheme, scheme)
            .scaleEffect(x: 1, y: open ? 1 : 0.18, anchor: .top)
            .opacity(open ? 1 : 0)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }

    private func replay() {
        let preset: MotionPreset = appearance.effectiveMotion(reduceMotion: reduceMotion)
        withAnimation(Self.animation(preset, .close)) { open = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            withAnimation(Self.animation(preset, .open)) { open = true }
        }
    }

    static func animation(_ preset: MotionPreset, _ direction: MotionDirection) -> Animation {
        guard let spring = preset.spring(direction) else { return .easeInOut(duration: MotionPreset.reducedFade) }
        return .spring(response: spring.response, dampingFraction: spring.damping)
    }

    static let pillScale: CGFloat = 0.72
    static let panelScale: CGFloat = 0.38
    static var bandHeight: CGFloat { 38 * panelScale }
}

/// A calm desktop behind the preview: pond blues with a soft light at the top.
private struct Wallpaper: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.33, blue: 0.40), Color(red: 0.07, green: 0.16, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.18), .clear], center: .top, startRadius: 4, endRadius: 160)
            // The menu bar.
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 10)
        }
    }
}

/// The open panel's content in miniature, in shapes only.
private struct MiniPanel: View {
    let showPlaty: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink: Color = scheme == .light ? .black : .white
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Capsule().fill(ink.opacity(0.16)).frame(width: 26, height: 8)
                Capsule().fill(ink.opacity(0.07)).frame(width: 26, height: 8)
                Capsule().fill(ink.opacity(0.07)).frame(width: 26, height: 8)
                Spacer()
            }
            .padding(.top, NotchPreview.bandHeight + 4)
            // The hero: artwork, a title and a scrubber.
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [DS.dynamicColor(.working), Color(red: 0.11, green: 0.23, blue: 0.29)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(ink.opacity(0.55)).frame(width: 74, height: 5)
                    Capsule().fill(ink.opacity(0.25)).frame(width: 50, height: 4)
                    Capsule().fill(DS.dynamicColor(.working)).frame(width: 96, height: 2)
                }
                Spacer(minLength: 0)
                if showPlaty {
                    PlatyView(mood: .workingToMusic, size: 22)
                }
            }
            .padding(7)
            .background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ink.opacity(0.06))
                        .frame(height: 22)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .accessibilityHidden(true)
    }
}
