import PlatyNotchKit
import SwiftUI

/// One dock slot (Island spec 3.3, 3.4): a 38 pt `raised` circle with a 17 pt monochrome
/// symbol and a 10.5 pt label under it, in a 66 pt slot. Search is a clear circle with a
/// 1 pt `stroke` ring. Live: the circle amber at 0.18 and the symbol and label amber, the
/// label a time. A count badge sits at the circle's top right. Off: dimmed to tertiary.
/// Hover lifts the circle to `stroke`.
struct DockButton: View {
    let item: DockItemState
    let action: () -> Void
    @State private var hovering = false

    /// The state colour of a live slot (amber), else nil.
    static func tone(_ item: DockItemState) -> StateTone? { item.live ? .needsYou : nil }

    /// The label's ink: tertiary while the tool is off, secondary otherwise (live: amber).
    static func labelInk(_ item: DockItemState) -> Double { item.available ? Ink.secondary : Ink.tertiary }

    static func symbol(_ item: DockItemState) -> String {
        switch item.slot {
        case .core(let t): t.symbol
        case .tool: "square.grid.2x2"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                circle
                Text(verbatim: item.label)
                    .font(DS.font(TypeScale.dockLabel).monospacedDigit())
                    .foregroundStyle(Self.tone(item).map { DS.color($0) } ?? DS.ink(Self.labelInk(item)))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: HomeMetrics.dockSlot)
            .overlay(alignment: .topTrailing) { badge }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.title)
        .accessibilityLabel(DockView.accessibilityLabel(item))
    }

    private var isSearch: Bool { item.slot == .core(.search) }

    private var circle: some View {
        ZStack {
            if let tone = Self.tone(item) {
                Circle().fill(DS.dynamicColor(tone, alpha: HomeMetrics.liveFill))
            } else if isSearch {
                Circle().fill(hovering ? DS.stroke : Color.clear)
                Circle().strokeBorder(DS.stroke, lineWidth: 1)
            } else {
                Circle().fill(hovering ? DS.stroke : DS.raised)
            }
            Image(systemName: Self.symbol(item))
                .symbolRenderingMode(.monochrome)
                .font(.system(size: HomeMetrics.dockIcon, weight: .regular))
                .foregroundStyle(Self.tone(item).map { DS.color($0) }
                                 ?? (item.available ? DS.primary : DS.tertiary))
        }
        .frame(width: HomeMetrics.dockCircle, height: HomeMetrics.dockCircle)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var badge: some View {
        if let text = item.badge {
            Text(verbatim: text)
                .font(DS.font(TypeScale.badge).monospacedDigit())
                .foregroundStyle(Color.white)
                .padding(.horizontal, 4)
                .frame(minWidth: HomeMetrics.badgeHeight, minHeight: HomeMetrics.badgeHeight)
                .background(DS.countBlue, in: Capsule())
                .offset(x: -12, y: -2)
                .accessibilityHidden(true)
        }
    }
}
