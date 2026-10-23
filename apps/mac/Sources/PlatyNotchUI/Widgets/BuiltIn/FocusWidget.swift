import PlatyNotchKit
import SwiftUI

/// The focus session: a tile with presets (or the running session), and a countdown in
/// the pill while focusing. The session itself lives in `FocusModel` (persisted, shared
/// with the Focus tab). While this widget is off, the Focus tab is hidden and a session
/// left running no longer holds notices.
@MainActor
final class FocusWidget: NotchWidget {
    static let widgetID = "focus"

    let id = FocusWidget.widgetID
    let title = "Focus"
    let systemImage = "moon.fill"
    let defaultEnabled = true
    let focus: FocusModel

    init(focus: FocusModel) {
        self.focus = focus
    }

    var liveActivities: [LiveActivity] {
        guard focus.focusActive, let end = focus.timer?.endsAt else { return [] }
        return [LiveActivity(id: "focus:session", widgetID: id, priority: LivePriority.focusSession,
                             glyph: .symbol("moon.fill"), tint: .accent, expiresAt: end, countdownTo: end,
                             accessibilityLabel: "Focus session running")]
    }

    func tileView() -> AnyView { AnyView(FocusTile(focus: focus)) }
}

private struct FocusTile: View {
    let focus: FocusModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            if let timer = focus.timer {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let done = timer.isDone(at: ctx.date)
                    Text(done ? "Focus done"
                              : timer.phase == .paused ? "Paused · \(TodayFormat.clock(timer.remaining(at: ctx.date))) left"
                              : "Focusing · \(TodayFormat.clock(timer.remaining(at: ctx.date))) left · notices held")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(focus.focusActive || timer.phase == .paused ? "Stop" : "Close") { focus.stop() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            } else {
                Text("Focus").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(FocusTimer.presets, id: \.self) { minutes in
                    Button("\(minutes)m") { focus.start(minutes: minutes) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .accessibilityLabel("Focus for \(minutes) minutes")
                }
            }
        }
        .padding(6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
