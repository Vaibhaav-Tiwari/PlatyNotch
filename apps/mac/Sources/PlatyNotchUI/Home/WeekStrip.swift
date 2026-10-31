import AppKit
import PlatyNotchKit
import SwiftUI

/// Seven days from today (Island spec 3.2): the weekday (11 pt tertiary) over the date
/// (12 pt medium); the marked day wears a 20 pt count-blue circle. The whole strip is one
/// "Open Calendar" button (Calendar opens on today: a date would need Apple Events).
struct WeekStrip: View {
    let days: [WeekDay]
    var onOpen: @MainActor () -> Void = { WeekStrip.openCalendar() }

    var body: some View {
        Button { onOpen() } label: {
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    if i > 0 { Spacer(minLength: 0) }
                    cell(d)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Calendar")
        .accessibilityLabel("Open Calendar")
        .accessibilityValue(Self.spoken(days))
    }

    /// "Mo 2 has events" for the marked day, for VoiceOver.
    static func spoken(_ days: [WeekDay]) -> String {
        days.first(where: \.marked).map { "\($0.weekday) \($0.day) marked" } ?? ""
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
    }

    /// Opens the Calendar app (it shows today; no Apple Events, so no prompt).
    static func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
