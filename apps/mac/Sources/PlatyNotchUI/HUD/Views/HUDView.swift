import PlatyNotchKit
import SwiftUI

/// The level HUD that grows out of the notch: a glyph, a 16-step bar and, for volume,
/// the output device ("AirPods Pro"). Takes no clicks or focus.
struct HUDView: View {
    let kind: HUDKind
    let level: Double
    let output: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: HUDBar.symbol(kind, level: level))
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(.primary).frame(width: geo.size.width * min(max(level, 0), 1))
                }
            }
            .frame(height: 5)
            if let output {
                Text(verbatim: output)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let percent = "\(HUDBar.name(kind)) \(Int((level * 100).rounded())) percent"
        return output.map { "\(percent), \($0)" } ?? percent
    }
}

/// The Today tab tile: whether our HUD is on, and why not when it is not.
struct HUDTile: View {
    let widget: HUDWidget
    @State private var probe = WindowProbe()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: widget.status == .on ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(widget.status == .on ? Color.primary : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(widget.status == .on ? "Volume & brightness HUD on" : "Volume & brightness HUD off")
                    .font(.system(size: 12, weight: .semibold))
                if let why = widget.explanation {
                    Text(verbatim: why)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HUDAccessButtons(widget: widget, probe: probe)
                } else if let output = widget.outputName {
                    Text(verbatim: "Output: \(output)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowReader(probe: probe))
        .task(id: widget.status) { await HUDAccessButtons.watch(widget, probe: probe) }
    }
}

/// Settings › Widgets › Volume & brightness HUD.
struct HUDSettingsView: View {
    let widget: HUDWidget
    @State private var probe = WindowProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let why = widget.explanation {
                Label { Text(verbatim: why).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                HUDAccessButtons(widget: widget, probe: probe)
            } else if widget.status == .on {
                Label("On: volume, brightness and keyboard-backlight keys show this HUD instead of the system's.",
                      systemImage: "checkmark.circle.fill")
                if let note = widget.unavailableNote {
                    Text(verbatim: note).foregroundStyle(.secondary)
                }
            }
            Text("""
            Over a full-screen app, under a ringing alarm, while an approval or the open \
            panel is showing, on a display without the notch panel, or for an external \
            display's brightness, the system HUD shows instead. ⌥⇧ with a key moves in \
            quarter steps; ⌥ alone opens the system setting as usual.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .background(WindowReader(probe: probe))
        .task(id: widget.status) { await HUDAccessButtons.watch(widget, probe: probe) }
    }
}

/// "Allow…" (the only place the Accessibility prompt is shown from for the HUD),
/// "Open System Settings" and, after a refused tap, "Retry".
struct HUDAccessButtons: View {
    let widget: HUDWidget
    let probe: WindowProbe

    var body: some View {
        HStack(spacing: 8) {
            switch widget.status {
            case .needsAccessibility:
                Button("Allow Accessibility…") { widget.requestAccess(isOnScreen: { [probe] in probe.isOnScreen }) }
                Button("Open System Settings") { Permissions.open(.accessibility) }
            case .tapRefused:
                Button("Retry") { widget.retry() }
                Button("Open System Settings") { Permissions.open(.accessibility) }
            case .on, .stopped:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    /// Re-reads trust every couple of seconds while "Allow" is on screen (a grant made in
    /// System Settings shows up without reopening anything).
    static func watch(_ widget: HUDWidget, probe: WindowProbe) async {
        guard widget.status == .needsAccessibility else { return }
        await widget.watchTrustWhileVisible(isOnScreen: { probe.isOnScreen })
    }
}
