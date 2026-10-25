import PlatyNotchKit
import SwiftUI

/// Now's hero card (spec 6.4): 160 pt tall, the hero radius and padding, a keyline in the
/// live item's tint, and ‹ "2 of 3" › on the trailing side when there is more than one
/// live item (a horizontal swipe steps too). The content gets the rest and truncates; the
/// controls never leave the frame.
struct HeroFrame<Content: View>: View {
    /// Room the ‹ › column takes beside the content.
    static var controlsWidth: CGFloat { 64 }

    let keyline: Color?
    let position: String?
    let onStep: ((Int) -> Void)?
    let content: Content

    init(keyline: Color?, position: String?, onStep: ((Int) -> Void)?, @ViewBuilder content: () -> Content) {
        self.keyline = keyline
        self.position = position
        self.onStep = onStep
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if let position, let onStep {
                HeroControls(position: position, onStep: onStep)
                    .frame(width: Self.controlsWidth)
                    .layoutPriority(1)
            }
        }
        .environment(\.heroPosition, position)
        .padding(Space.heroPadding)
        .frame(maxWidth: .infinity)
        .frame(height: NowMetrics.hero)
        .dsCard(radius: Radius.hero, keyline: keyline)
        .contentShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .gesture(swipe)
    }

    /// A horizontal drag of 40 pt steps the deck (left: next).
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard let onStep else { return }
                let dx: CGFloat = value.translation.width
                guard abs(dx) >= 40, abs(dx) > abs(value.translation.height) else { return }
                onStep(dx < 0 ? 1 : -1)
            }
    }
}

/// "2 of 3" above ‹ ›.
struct HeroControls: View {
    let position: String
    let onStep: (Int) -> Void

    var body: some View {
        VStack(spacing: Space.xs) {
            Text(verbatim: position)
                .font(DS.font(TypeScale.caption))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            HStack(spacing: Space.xs) {
                step("chevron.left", label: "Previous live item", delta: -1)
                step("chevron.right", label: "Next live item", delta: 1)
            }
        }
        .fixedSize()
    }

    private func step(_ symbol: String, label: String, delta: Int) -> some View {
        Button { onStep(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: IconSize.row, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

extension LiveTint {
    /// The hero keyline for this tint; nil for neutral (the default keyline).
    var keyline: Color? {
        self == .neutral ? nil : Theme.tint(self).opacity(0.7)
    }
}
