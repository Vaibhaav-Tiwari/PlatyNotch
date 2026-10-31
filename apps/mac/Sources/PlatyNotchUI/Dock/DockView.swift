import PlatyNotchKit
import SwiftUI

/// Home's dock (Island spec 3.3): every tool one click away, eight 66 pt slots spread
/// across the panel. Folded (Minimal): one Search slot, "All tools".
struct DockView: View {
    let items: [DockItemState]
    var folded = false
    let onOpen: (DockSlot) -> Void

    static let allTools = "All tools"

    /// The labels under the circles, in order (tests).
    static func labels(_ items: [DockItemState], folded: Bool = false) -> [String] {
        folded ? [allTools] : items.map(\.label)
    }

    /// "Remind, 3 due", "Timer, 18:42 left", "Note, off", "Search, ⌥⌘K".
    static func accessibilityLabel(_ i: DockItemState) -> String {
        if !i.available { return "\(i.title), off" }
        if i.live { return "\(i.title), \(i.label) left" }
        if let badge = i.badge {
            return i.slot == .core(.remind) ? "\(i.title), \(badge) due" : "\(i.title), \(badge)"
        }
        if i.slot == .core(.search), i.label != i.title { return "\(i.title), \(i.label)" }
        return i.title
    }

    var body: some View {
        HStack(spacing: 0) {
            if folded {
                Spacer(minLength: 0)
                DockButton(item: DockItemState(slot: .core(.search), label: Self.allTools, badge: nil, live: false,
                                               available: true)) { onOpen(.core(.search)) }
                Spacer(minLength: 0)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    if i > 0 { Spacer(minLength: 0) }
                    DockButton(item: item) { onOpen(item.slot) }
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock")
    }
}
