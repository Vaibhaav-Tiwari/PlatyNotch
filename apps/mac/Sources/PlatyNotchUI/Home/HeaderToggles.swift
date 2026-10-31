import PlatyNotchKit
import SwiftUI

/// The header's icon toggles (spec 2.1): the battery badge (only when charging or low), Keep
/// awake, Mirror and Settings. Every icon is 16 pt.
struct HeaderToggles: View {
    static let iconSize: CGFloat = 16
    let services: HeaderServices
    let widgets: WidgetRegistry
    @Binding var route: PanelRoute
    let onOpenSettings: () -> Void
    /// Renders only: the time the keep-awake label counts from.
    var fixedNow: Date?

    /// Mirror: turns the widget on if it is off, then opens it inside the panel. The camera
    /// starts only from the tool itself, after this click.
    static func openMirror(registry: WidgetRegistry, route: inout PanelRoute) {
        if !registry.isEnabled(MirrorWidget.widgetID) { registry.setEnabled(MirrorWidget.widgetID, true) }
        route = ExpandedPanel.route(forTool: MirrorWidget.widgetID)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let badge = HeaderBattery.badge(services.battery) {
                HStack(spacing: 3) {
                    Image(systemName: badge.symbol)
                    Text(verbatim: badge.text)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.dynamicColor(badge.tone))
                .lineLimit(1)
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
            keepAwakeButton
            iconButton("video", label: "Mirror", help: "Mirror") {
                var next: PanelRoute = route
                Self.openMirror(registry: widgets, route: &next)
                route = next
            }
            iconButton("gearshape", label: "Settings", help: "PlatyNotch Settings", action: onOpenSettings)
        }
    }

    private var keepAwakeButton: some View {
        let session: KeepAwakeSession? = services.keepAwake.session
        // A Mac that slept past the deadline shows off at once, before the expiry task runs.
        let on: Bool = session.map { !$0.isExpired(at: fixedNow ?? Date()) } ?? false
        return Button { services.toggleKeepAwake() } label: {
            HStack(spacing: 3) {
                Image(systemName: on ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: Self.iconSize))
                if on { KeepAwakeTime(session: session, fixedNow: fixedNow) }
            }
            .foregroundStyle(on ? AnyShapeStyle(DS.dynamicColor(.needsYou)) : AnyShapeStyle(.secondary))
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(KeepAwakeDuration.allCases, id: \.self) { d in
                Button(d.label) { services.startKeepAwake(d) }
            }
        }
        .help(on ? "Keep awake is on. Click to turn off." : "Keep awake")
        .accessibilityLabel("Keep awake")
        .accessibilityValue(on ? "On" : "Off")
    }

    private func iconButton(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Self.iconSize))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The time left as `h:mm`; ticks only while the panel is open (`panelTicking`).
private struct KeepAwakeTime: View {
    let session: KeepAwakeSession?
    var fixedNow: Date?
    @Environment(\.panelTicking) private var ticking

    var body: some View {
        if ticking, fixedNow == nil {
            TimelineView(.periodic(from: .now, by: 15)) { context in label(context.date) }
        } else {
            label(fixedNow ?? Date())
        }
    }

    @ViewBuilder private func label(_ now: Date) -> some View {
        if let text = KeepAwakeLabel.remaining(session, now: now) {
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
        }
    }
}
