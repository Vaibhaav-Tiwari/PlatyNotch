import PlatyNotchKit
import SwiftUI

extension EnvironmentValues {
    /// False while the panel is hidden or suppressed over full screen: timelines in the
    /// pill (countdowns, music bars) stop ticking. True elsewhere (tiles, previews).
    @Entry var panelTicking: Bool = true
    /// Platy's mood for the panel's empty states; nil when Appearance › Show Platy is off.
    @Entry var platyMood: PlatyMood? = nil
}

/// The built-in level HUD: a glyph for `kind` and a level bar. Widgets may supply their own.
struct HUDBar: View {
    let state: HUDState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(state.kind, level: state.level))
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(.primary).frame(width: geo.size.width * state.level)
                }
            }
            .frame(height: 5)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.name(state.kind)) \(Int((state.level * 100).rounded())) percent")
    }

    static func symbol(_ kind: HUDKind, level: Double) -> String {
        switch kind {
        case .volume: level <= 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        case .brightness: "sun.max.fill"
        case .keyboardBacklight: "light.max"
        }
    }

    static func name(_ kind: HUDKind) -> String {
        switch kind {
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .keyboardBacklight: "Keyboard brightness"
        }
    }
}

/// A HUD while an approval or the open panel is showing: a thin level line along the
/// bottom edge. It never covers or moves the approval card and takes no clicks.
struct HUDIndicator: View {
    let state: HUDState

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.primary.opacity(0.7))
                .frame(width: max(2, geo.size.width * state.level), height: 2)
        }
        .frame(width: 80, height: 2)
        .accessibilityLabel("\(HUDBar.name(state.kind)) \(Int((state.level * 100).rounded())) percent")
    }
}

/// The drop zone when no widget supplies one.
struct DropZonePlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(.secondary)
            .overlay {
                Label("Drop here", systemImage: "tray.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Something ringing while an approval or the open panel is up: a bell and Stop, at a
/// fixed place. Clicks work on the first click (`acceptsFirstMouse`); no keyboard
/// shortcut, never focusable, so it cannot take an approval's keys.
struct RingingChip: View {
    let item: RingingItem
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 4) {
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Stop").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.black)   // on the orange chip in every theme
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.color(.attention), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Stop \(item.title)")
        .accessibilityLabel("Stop \(item.title)")
    }
}

/// A ringing card whose widget no longer draws it (turned off mid-ring): always stoppable.
struct RingingFallback: View {
    let id: String
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.color(.attention))
            Text("Ringing").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button("Stop", action: onStop)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}
