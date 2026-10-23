import PlatyNotchKit
import SwiftUI

/// Focus timer: 25 / 50 / 90 minute presets. While running, notices are held (approvals still show).
struct FocusTab: View {
    let focus: FocusModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 10) {
                if let timer = focus.timer {
                    running(timer, now: ctx.date)
                } else {
                    idle
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var idle: some View {
        VStack(spacing: 8) {
            Text("Start a focus session")
                .font(.system(size: 13, weight: .semibold))
            Text("Notices wait until it ends. Approvals still show.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(FocusTimer.presets, id: \.self) { minutes in
                    Button { focus.start(minutes: minutes) } label: {
                        Text("\(minutes) min").font(.system(size: 12, weight: .medium)).frame(minWidth: 56)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Focus for \(minutes) minutes")
                }
            }
        }
    }

    @ViewBuilder private func running(_ timer: FocusTimer, now: Date) -> some View {
        let done = timer.isDone(at: now)
        Text(done ? "Done" : TodayFormat.clock(timer.remaining(at: now)))
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .accessibilityLabel(done ? "Focus session done" : "\(TodayFormat.clock(timer.remaining(at: now))) left")
        Text(done ? "\(timer.minutes) minute session finished"
                  : timer.phase == .paused ? "Paused · notices are showing" : "Focusing · notices are held")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        HStack(spacing: 8) {
            if !done {
                if timer.phase == .paused {
                    Button("Resume") { focus.resume() }
                } else {
                    Button("Pause") { focus.pause() }
                }
            }
            Button(done ? "Close" : "Stop") { focus.stop() }
        }
        .buttonStyle(.bordered)
        .font(.system(size: 12))
    }
}
