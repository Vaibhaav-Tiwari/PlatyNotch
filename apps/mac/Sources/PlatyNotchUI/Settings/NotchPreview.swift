import PlatyNotchKit
import SwiftUI

/// Settings › Notch's preview: the top of a 14-inch MacBook Pro's screen at true
/// proportions, zoomed to `scale` — the menu bar, the camera housing with the real pill
/// in its ears, and (Open) the panel hanging from it — drawn from the settings as they are
/// now (pill width, live side, Platy, theme, surface, Minimal). Still unless you switch
/// between Resting and Open, which plays the chosen motion once (a fade with Reduce Motion).
/// Fixed sample content (music and two agents); nothing is read.
struct NotchPreview: View {
    let appearance: AppearanceSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open: Bool

    static let scale: CGFloat = 0.6
    static let height: CGFloat = 268
    /// Resting, the strip is just tall enough for the menu bar, the pill and some desktop.
    static let restingHeight: CGFloat = 96

    init(appearance: AppearanceSettings, open: Bool = false) {
        self.appearance = appearance
        _open = State(initialValue: open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Preview", selection: Binding(get: { open }, set: { show($0) })) {
                Text("Resting").tag(false)
                Text("Open").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ZStack(alignment: .top) {
                Wallpaper()
                menuBar
                if open {
                    openPanel
                        .transition(.scale(scale: 0.3, anchor: .top).combined(with: .opacity))
                } else {
                    restingPill
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: open ? Self.height - 36 : Self.restingHeight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(open ? "Preview: the open panel" : "Preview: the resting pill")
        }
    }

    private var layout: PanelLayout { PillRenders.notchLayout(appearance.pillWidth) }

    /// The menu bar at the preview's scale: faint menus on the left, status items on the right.
    private var menuBar: some View {
        let h: CGFloat = layout.anchor.height * Self.scale
        return HStack(spacing: 8) {
            Image(systemName: "apple.logo").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            ForEach([34, 26, 26, 30], id: \.self) { w in
                Capsule().fill(Color.white.opacity(0.35)).frame(width: CGFloat(w), height: 5)
            }
            Spacer()
            ForEach([14, 14, 30], id: \.self) { w in
                Capsule().fill(Color.white.opacity(0.35)).frame(width: CGFloat(w), height: 5)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: h)
        .background(Color.white.opacity(0.10))
        .accessibilityHidden(true)
    }

    /// The real pill beside the camera housing, at the preview's scale.
    private var restingPill: some View {
        let size: CGSize = layout.contentRect(for: .compact).size
        let (content, mood) = PillRenders.content(.music)
        let pill = CompactPill(content: content, connection: .connected, hasNotch: true,
                               notchWidth: layout.anchor.width, liveSide: appearance.liveSide,
                               earWidth: layout.liveEarWidth, platy: appearance.showPlaty ? mood : nil)
        let minimal: Bool = appearance.mode == .minimal
        return VStack(spacing: 10) {
            ZStack {
                Theme.panelShape(hasNotch: true).fill(Color(PanelPalette.darkSurface))
                if !minimal { pill }
            }
            .frame(width: minimal ? layout.anchor.width : size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.panelTicking, false)
            .scaleEffect(Self.scale, anchor: .top)
            .frame(width: (minimal ? layout.anchor.width : size.width) * Self.scale, height: size.height * Self.scale,
                   alignment: .top)
            if minimal {
                Text("Hidden until something is live")
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    /// The open panel at the preview's scale: the notch band, the destinations, a hero
    /// and four glances.
    private var openPanel: some View {
        let design: CGFloat = MiniPanel.designScale
        let width: CGFloat = PanelLayout.expandedSize.width * design
        let height: CGFloat = PanelLayout.expandedSize.height * design
        let zoom: CGFloat = Self.scale / design
        return MiniPanel(showPlaty: appearance.showPlaty)
            .frame(width: width, height: height)
            .background {
                ZStack(alignment: .top) {
                    Theme.surface
                    Color(PanelPalette.darkSurface).frame(height: MiniPanel.bandHeight)
                }
            }
            .clipShape(Theme.panelShape(hasNotch: true, open: true))
            .environment(\.colorScheme, .dark)
            .scaleEffect(zoom, anchor: .top)
            .frame(width: width * zoom, height: height * zoom, alignment: .top)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    private func show(_ next: Bool) {
        let preset: MotionPreset = appearance.effectiveMotion(reduceMotion: reduceMotion)
        withAnimation(Self.animation(preset, next ? .open : .close)) { open = next }
    }

    static func animation(_ preset: MotionPreset, _ direction: MotionDirection) -> Animation {
        guard let spring = preset.spring(direction) else { return .easeInOut(duration: MotionPreset.reducedFade) }
        return .spring(response: spring.response, dampingFraction: spring.damping)
    }
}

/// A calm desktop behind the preview: pond blues with a soft light at the top.
private struct Wallpaper: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.33, blue: 0.40), Color(red: 0.07, green: 0.16, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.18), .clear], center: .top, startRadius: 4, endRadius: 220)
        }
    }
}

/// The open panel's content in miniature, in shapes only.
private struct MiniPanel: View {
    let showPlaty: Bool
    /// The scale the miniature is drawn at (then zoomed to the preview's).
    static let designScale: CGFloat = 0.38
    static var bandHeight: CGFloat { 38 * designScale }
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
            .padding(.top, MiniPanel.bandHeight + 4)
            // The hero: artwork, a title and a scrubber.
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
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
            .background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
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
