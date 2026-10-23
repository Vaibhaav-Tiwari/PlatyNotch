import AppKit
import EventKit
import PlatyNotchKit
import SwiftUI

/// The Today tab's models, one set shared by every display's panel.
@MainActor
public final class TodayServices {
    public let nowPlaying: NowPlaying
    public let calendar: CalendarService
    public let focus: FocusModel
    public let loops: LoopActions

    public init(client: CoreClient, nowPlaying: NowPlaying = NowPlaying(), calendar: CalendarService = CalendarService(),
                focus: FocusModel = FocusModel()) {
        self.nowPlaying = nowPlaying
        self.calendar = calendar
        self.focus = focus
        loops = LoopActions(client: client)
    }
}

/// Now playing, the next meeting, a running focus session and open loops.
struct TodayTab: View {
    let store: AppStore
    let today: TodayServices

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NowPlayingCard(nowPlaying: today.nowPlaying)
            MeetingCard(calendar: today.calendar)
            if today.focus.focusActive, let timer = today.focus.timer {
                FocusStrip(timer: timer)
            }
            LoopsList(loops: store.loops, memoryEnabled: store.memory.enabled, actions: today.loops)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            today.nowPlaying.start()
            today.nowPlaying.setVisible(true)
        }
        .onDisappear { today.nowPlaying.setVisible(false) }
        .task {
            // First appearance asks for calendar access; then refresh every minute while shown.
            await today.calendar.requestAccess()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                today.calendar.refresh()
            }
        }
    }
}

private struct NowPlayingCard: View {
    let nowPlaying: NowPlaying

    var body: some View {
        if let title = nowPlaying.title {
            HStack(spacing: 8) {
                artwork
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let artist = nowPlaying.artist {
                        Text(verbatim: artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    control("backward.fill", "Previous track") { nowPlaying.previous() }
                    control(nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                            nowPlaying.isPlaying ? "Pause" : "Play") { nowPlaying.playPause() }
                    control("forward.fill", "Next track") { nowPlaying.next() }
                }
            }
            .padding(6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder private var artwork: some View {
        Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct MeetingCard: View {
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

private struct FocusStrip: View {
    let timer: FocusTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Label("Focusing · \(TodayFormat.clock(timer.remaining(at: ctx.date))) left · notices held",
                  systemImage: "moon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
