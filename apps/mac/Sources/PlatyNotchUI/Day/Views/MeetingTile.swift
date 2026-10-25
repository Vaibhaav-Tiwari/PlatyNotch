import AppKit
import PlatyNotchKit
import SwiftUI

/// The meeting tile: the meeting in progress, the next one (with a countdown ring in its
/// last 10 minutes), then up to two more in the next 12 hours.
struct MeetingTile: View {
    let widget: MeetingWidget
    static let laterCount = 2

    var body: some View {
        let calendar = widget.calendar
        switch calendar.access {
        case .notAsked:
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text("See your next meetings here").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Allow Calendar Access") { Task { await calendar.requestAccess(); widget.tick() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        case .denied:
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.secondary)
                Text("Calendar access is off").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Open Settings") { calendar.openSettings() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        case .unavailable:
            Label("Calendar needs the installed app.", systemImage: "calendar")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .granted:
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                content(now: ctx.date)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let meetings = widget.calendar.meetings
        let current = MeetingTimeline.current(meetings, now: now)
        let ahead = MeetingTimeline.upcoming(meetings, now: now).filter { $0.start > now }
        if current == nil, ahead.isEmpty {
            Label("No meetings in the next 12 hours", systemImage: "calendar")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let current { MeetingCard(meeting: current, color: color(current), now: now, inProgress: true, join: join) }
                if let next = ahead.first { MeetingCard(meeting: next, color: color(next), now: now, inProgress: false, join: join) }
                ForEach(ahead.dropFirst().prefix(Self.laterCount)) { m in
                    HStack(spacing: 6) {
                        Text(m.start.formatted(date: .omitted, time: .shortened))
                            .font(DS.font(TypeScale.caption, design: .monospaced).weight(.regular))
                            .foregroundStyle(.secondary)
                        Text(verbatim: m.title).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 0)
                        if m.joinURL != nil {
                            Image(systemName: "video").font(DS.font(TypeScale.caption)).foregroundStyle(.tertiary)
                                .accessibilityLabel("Has a join link")
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private func color(_ m: CalendarMeeting) -> Color {
        Color(cgColor: widget.calendar.colors[m.id] ?? NSColor.systemBlue.cgColor)
    }

    private func join(_ m: CalendarMeeting) { widget.join(m) }
}

private struct MeetingCard: View {
    /// The calendar-colour bar: fully rounded ends.
    static let barHeight: CGFloat = 28
    let meeting: CalendarMeeting
    let color: Color
    let now: Date
    let inProgress: Bool
    let join: (CalendarMeeting) -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: Self.barHeight / 2)
                .fill(color)
                .frame(width: 3, height: Self.barHeight)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: meeting.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(inProgress ? Theme.tint(.accent) : .secondary)
            }
            Spacer(minLength: 4)
            if !inProgress, meeting.start.timeIntervalSince(now) <= LivePriority.meetingSoonWindow {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    CountdownRing(start: meeting.start, now: ctx.date)
                }
            }
            if meeting.joinURL != nil {
                Button("Join") { join(meeting) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Join \(meeting.title)")
            }
        }
        .padding(6)
        .dsCard()
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        if inProgress {
            let left = Int((meeting.end.timeIntervalSince(now) / 60).rounded(.up))
            return "In meeting · ends in \(left) min"
        }
        return TodayFormat.meetingWhen(start: meeting.start, now: now) + " · "
            + meeting.start.formatted(date: .omitted, time: .shortened)
    }
}

/// A ring that fills over the last 10 minutes before a meeting, with the minutes left.
struct CountdownRing: View {
    let start: Date
    let now: Date
    var size: CGFloat = 26

    var body: some View {
        let progress = MeetingReminderSchedule.progress(start: start, now: now)
        let minutes = max(0, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress)
                .stroke(Theme.tint(.warning), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(minutes)").font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Starts in \(minutes) minutes")
    }
}

/// The 10 / 5 / 1-minute reminder below the notch.
struct MeetingReminderPeek: View {
    let reminder: MeetingWidget.Reminder
    let join: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 10) {
                CountdownRing(start: reminder.meeting.start, now: ctx.date, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: reminder.meeting.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(TodayFormat.meetingWhen(start: reminder.meeting.start, now: ctx.date) + " · "
                         + reminder.meeting.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if reminder.meeting.joinURL != nil {
                    Button("Join", action: join)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .accessibilityLabel("Join \(reminder.meeting.title)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Settings › Widgets › Meetings.
struct MeetingSettings: View {
    let calendar: CalendarService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Calendar access")
                Spacer()
                switch calendar.access {
                case .granted: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(DS.font(TypeScale.caption))
                case .notAsked: Button("Allow Calendar Access") { Task { await calendar.requestAccess() } }
                case .denied: Button("Open System Settings") { NSWorkspace.shared.open(CalendarService.settingsURL) }
                case .unavailable: Text("Needs the installed app.").foregroundStyle(.secondary).font(DS.font(TypeScale.caption))
                }
            }
            Text("Reminders peek at 10, 5 and 1 minutes before a meeting (not during a focus session). "
                 + "Join opens the meeting link only when you click it.")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { calendar.refreshAccess() }
    }
}
