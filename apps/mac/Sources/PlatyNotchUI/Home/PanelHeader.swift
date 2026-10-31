import PlatyNotchKit
import SwiftUI

/// The header row of both views (spec 2.1): Platy (20 pt), the view switcher, a flexible
/// space, the view's status text, then the icon toggles.
struct PanelHeader<Nav: View, Controls: View>: View {
    let status: String?
    let nav: Nav
    let controls: Controls
    @Environment(\.platyMood) private var mood

    init(status: String?, @ViewBuilder nav: () -> Nav, @ViewBuilder controls: () -> Controls) {
        self.status = status
        self.nav = nav()
        self.controls = controls()
    }

    /// Home's status text: `Fri 31 · 14° Clear`, or `Fri 31` without a weather reading.
    static func homeStatus(now: Date, weather: String?, calendar: Calendar = .current,
                           locale: Locale = .current) -> String {
        HeaderDate.text(now: now, weather: weather, calendar: calendar, locale: locale)
    }

    var body: some View {
        HStack(spacing: 14) {
            if let mood {
                PlatyView(mood: mood, size: 20)
                    .frame(width: 20, height: 20)
            }
            nav
            Spacer(minLength: 4)
            if let status {
                Text(verbatim: status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            controls
        }
    }
}
