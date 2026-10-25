import PlatyNotchKit
import SwiftUI

/// Now's hero with nothing live (spec 6.4): the greeting, the date, the time in the display
/// style (redrawn once a minute, only while the panel is shown), the next meeting (with
/// calendar access only; never asks) and Platy idle at 96 pt.
struct TodaySummaryHero: View {
    let calendar: CalendarService
    /// Fixed time for renders; nil follows the clock.
    var fixedNow: Date?
    @Environment(\.panelTicking) private var ticking
    @Environment(\.platyMood) private var platyMood

    var body: some View {
        if let fixedNow {
            content(at: fixedNow)
        } else if ticking {
            TimelineView(.everyMinute) { ctx in content(at: ctx.date) }
        } else {
            content(at: Date())
        }
    }

    private func content(at now: Date) -> some View {
        let hour: Int = Calendar.current.component(.hour, from: now)
        return HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: DayPhase.at(hour: hour).greeting)
                    .font(DS.font(TypeScale.headline))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(DS.font(TypeScale.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: now.formatted(date: .omitted, time: .shortened))
                    .font(DS.font(TypeScale.display))
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if let line = Self.nextLine(calendar: calendar, now: now) {
                    Label {
                        Text(verbatim: line)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } icon: {
                        DS.icon("calendar", size: TypeScale.caption.size)
                    }
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let platyMood {
                PlatyView(mood: platyMood, size: 96, morphID: MorphID.platy)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Next: 10:30 Design review"; "No more events today" with access and nothing left
    /// today; nil without calendar access (never asks).
    static func nextLine(calendar: CalendarService, now: Date, in cal: Calendar = .current) -> String? {
        guard calendar.access == .granted else { return nil }
        guard let next = MeetingTimeline.next(calendar.meetings, now: now), cal.isDate(next.start, inSameDayAs: now) else {
            return "No more events today"
        }
        return "Next: \(MeetingWidget.time(next.start)) \(next.title)"
    }
}
