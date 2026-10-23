import SwiftUI

/// The ringing card below the notch (`PanelLayout.ringingHeight`): a pulsing ring around a
/// bell, what rings, Snooze (alarms, 9 min) and Stop. Buttons work on the first click;
/// nothing here is focusable or has a key equivalent (the panel never takes the keyboard
/// for a ringing card). Reduce Motion stills the pulse.
struct RingingOverlay: View {
    let title: String
    let subtitle: String
    let isAlarm: Bool
    var onSnooze: (() -> Void)?
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Theme.color(.attention).opacity(pulse ? 0 : 0.8), lineWidth: 3)
                    .scaleEffect(pulse ? 1.35 : 0.9)
                Circle().fill(Theme.color(.attention).opacity(0.2))
                Image(systemName: isAlarm ? "alarm.fill" : "timer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.color(.attention))
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let onSnooze {
                Button("Snooze", action: onSnooze)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .focusable(false)
                    .help("Ring again in 9 minutes")
            }
            Button("Stop", action: onStop)
                .buttonStyle(.borderedProminent)
                .tint(Theme.color(.attention))
                .controlSize(.regular)
                .focusable(false)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) ringing")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
