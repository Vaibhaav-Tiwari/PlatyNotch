import SwiftUI

/// Content that depends on the time: ticks each second only while the panel is really shown
/// (`\.panelTicking`), so a hidden panel costs nothing. `fixed` pins the time (renders, tests).
struct TickingNow<Content: View>: View {
    var fixed: Date?
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.panelTicking) private var ticking

    var body: some View {
        if let fixed {
            content(fixed)
        } else if ticking {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
        } else {
            content(Date())
        }
    }
}
