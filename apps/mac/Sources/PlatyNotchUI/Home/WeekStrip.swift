import AppKit
import PlatyNotchKit
import SwiftUI

/// Seven days from today (Island spec 3.2): the weekday (11 pt tertiary) over the date
/// (12 pt medium); the marked day wears a 20 pt count-blue circle. A click opens Calendar.
struct WeekStrip: View {
    let days: [WeekDay]
    var onOpen: @MainActor (Date) -> Void = { WeekStrip.openCalendar($0) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                if i > 0 { Spacer(minLength: 0) }
                Button { onOpen(d.date) } label: { cell(d) }
                    .buttonStyle(.plain)
                    .help("Open Calendar")
                    .accessibilityLabel(d.marked ? "\(d.weekday) \(d.day), has events" : "\(d.weekday) \(d.day)")
            }
        }
    }

    private func cell(_ d: WeekDay) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: d.weekday)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(DS.tertiary)
            Text(verbatim: d.day)
                .font(DS.font(TypeScale.secondary).weight(.medium).monospacedDigit())
                .foregroundStyle(d.marked ? Color.white : DS.primary)
                .frame(width: HomeMetrics.weekMark, height: HomeMetrics.weekMark)
                .background { if d.marked { Circle().fill(DS.countBlue) } }
        }
        .frame(width: HomeMetrics.weekDay)
        .contentShape(Rectangle())
    }

    /// Opens the Calendar app (it shows today; no Apple Events, so no prompt).
    static func openCalendar(_ date: Date) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
