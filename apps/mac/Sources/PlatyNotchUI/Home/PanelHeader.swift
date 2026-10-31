import PlatyNotchKit
import SwiftUI

/// The header row of both views (Island spec 2): Platy, the view switcher, a flexible space,
/// the view's status text (Agents' usage only; Home has none: the weather is the Today
/// card), then the icon toggles, 14 pt apart.
struct PanelHeader<Nav: View, Controls: View>: View {
    let status: [String]
    var mono = false
    let nav: Nav
    let controls: Controls
    @Environment(\.platyMood) private var mood

    init(status: [String], mono: Bool = false, @ViewBuilder nav: () -> Nav, @ViewBuilder controls: () -> Controls) {
        self.status = status
        self.mono = mono
        self.nav = nav()
        self.controls = controls()
    }

    var body: some View {
        HStack(spacing: Space.header) {
            if let mood {
                PlatyView(mood: mood, size: 20)
                    .frame(width: 20, height: 20)
            }
            nav
                .fixedSize()
            Spacer(minLength: 4)
            ForEach(Array(status.enumerated()), id: \.offset) { _, part in
                Text(verbatim: part)
                    .font(DS.font(mono ? TypeScale.mono : TypeScale.secondary))
                    .foregroundStyle(DS.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            controls
                .fixedSize()
        }
    }
}
