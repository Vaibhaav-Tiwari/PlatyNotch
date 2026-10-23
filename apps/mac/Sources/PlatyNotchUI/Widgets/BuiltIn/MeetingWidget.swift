import AppKit
import EventKit
import Observation
import PlatyNotchKit
import SwiftUI

/// The next meeting: a tile with a Join button, and a countdown in the pill during the
/// last 10 minutes before it starts. Calendar access is asked for only when the tile is
/// first shown (Plan 3 behaviour); while enabled and allowed, the meeting refreshes every
/// 30 s so the pill works with the panel closed.
@MainActor @Observable
final class MeetingWidget: NotchWidget {
    static let widgetID = "meeting"
    static let refreshInterval: TimeInterval = 30

    let id = MeetingWidget.widgetID
    let title = "Next meeting"
    let systemImage = "calendar"
    let defaultEnabled = true
    @ObservationIgnored let calendar: CalendarService

    /// Advanced by the refresh loop so `liveActivities` follows the clock.
    private var now = Date()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(calendar: CalendarService) {
        self.calendar = calendar
    }

    var liveActivities: [LiveActivity] {
        guard calendar.access == .granted, let start = calendar.next?.startDate else { return [] }
        let lead = start.timeIntervalSince(now)
        guard lead > 0, lead <= LivePriority.meetingSoonWindow else { return [] }
        return [LiveActivity(id: "meeting:next", widgetID: id, priority: LivePriority.meetingSoon,
                             glyph: .symbol("calendar"), tint: .warning, expiresAt: start, countdownTo: start,
                             accessibilityLabel: "Meeting \(TodayFormat.meetingWhen(start: start, now: now).lowercased())")]
    }

    func start(context: WidgetContext) {
        task?.cancel()
        task = Task { [weak self] in
            // Never prompts here: `requestAccess` asks only when not yet asked, so skip it then.
            if let self, self.calendar.access == .granted { await self.calendar.requestAccess() }
            while !Task.isCancelled {
                guard let self else { return }
                self.calendar.refresh()
                self.now = Date()
                try? await Task.sleep(for: .seconds(self.nextWake()))
            }
        }
    }

    /// 30 s, or sooner when the pill must appear (10 min before) or go (at the start).
    private func nextWake() -> TimeInterval {
        guard let start = calendar.next?.startDate else { return Self.refreshInterval }
        let lead = start.timeIntervalSince(now)
        let edges = [lead - LivePriority.meetingSoonWindow, lead].filter { $0 > 0 }
        return min(Self.refreshInterval, (edges.min() ?? Self.refreshInterval) + 0.05)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func tileView() -> AnyView {
        let calendar = self.calendar
        return AnyView(MeetingCard(calendar: calendar)
            .task { await calendar.requestAccess() })   // first appearance asks (if never asked)
    }
}

struct MeetingCard: View {
    let calendar: CalendarService

    var body: some View {
        switch calendar.access {
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
        case .notAsked:
            EmptyView()
        case .granted:
            if let event = calendar.next {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    meeting(event, now: ctx.date)
                }
            } else {
                Label("No meetings in the next 12 hours", systemImage: "calendar")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func meeting(_ event: EKEvent, now: Date) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(cgColor: event.calendar?.cgColor ?? NSColor.systemBlue.cgColor))
                .frame(width: 3, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.title?.isEmpty == false ? event.title! : "Untitled event")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(TodayFormat.meetingWhen(start: event.startDate, now: now) + " · "
                     + event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let url = calendar.joinURL {
                Button("Join") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Join \(event.title ?? "meeting")")
            }
        }
        .padding(6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
