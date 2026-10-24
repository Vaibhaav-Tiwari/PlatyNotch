import PlatyNotchKit
import SwiftUI

/// Every agent session (newest first) and the usage bars.
struct AgentsTab: View {
    let sessions: [Session]
    let usage: Usage
    let onOpenTerminal: (Session) -> Void
    @Environment(\.platyMood) private var platyMood

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sessions.isEmpty {
                VStack(spacing: 4) {
                    if let platyMood { PlatyView(mood: platyMood, size: 64).padding(.bottom, 2) }
                    Text("No agent sessions")
                        .font(.system(size: 12, weight: .medium))
                    Text("Start Claude Code or Codex in a terminal and it shows up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(sessions) { SessionRow(session: $0, now: ctx.date, onOpenTerminal: onOpenTerminal) }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
            UsageSection(usage: usage)
        }
    }
}
