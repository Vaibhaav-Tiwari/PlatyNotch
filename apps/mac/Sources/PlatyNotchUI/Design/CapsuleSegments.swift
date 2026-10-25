import PlatyNotchKit
import SwiftUI

/// A segmented choice in the panel's own style (the nav's capsules): the selected segment
/// on a card capsule, the rest secondary. One accent across the panel; never system blue.
struct CapsuleSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// What VoiceOver calls the whole control.
    let label: String
    var size: CGFloat = TypeScale.body.size

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected: Bool = option.value == selection
                Button { selection = option.value } label: {
                    Text(verbatim: option.title)
                        .font(.system(size: size, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(selected ? Theme.card : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
