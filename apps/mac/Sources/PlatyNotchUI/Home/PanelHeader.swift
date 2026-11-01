import PlatyNotchKit
import SwiftUI

/// The header row of both views (Island spec 2): Platy, the view switcher, a flexible space,
/// Agents' usage rings (Home has none: the weather is the Today card), then the icon
/// toggles, 14 pt apart.
struct PanelHeader<Nav: View, Controls: View>: View {
    /// Agents' usage rings (Island spec 8), before the controls.
    var rings: [UsageRing] = []
    let nav: Nav
    let controls: Controls
    @Environment(\.platyMood) private var mood

    init(rings: [UsageRing] = [], @ViewBuilder nav: () -> Nav, @ViewBuilder controls: () -> Controls) {
        self.rings = rings
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
            if !rings.isEmpty {
                UsageRingsView(rings: rings)
                    .layoutPriority(-1)
            }
            controls
                .fixedSize()
        }
    }
}
