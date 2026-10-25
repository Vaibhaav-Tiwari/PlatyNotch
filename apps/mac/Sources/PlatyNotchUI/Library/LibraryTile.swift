import PlatyNotchKit
import SwiftUI

/// SwiftUI imports DeveloperToolsSupport, which has its own `LibraryItem` (Xcode's
/// library): inside this module the name means the Library's tile.
typealias LibraryItem = PlatyNotchKit.LibraryItem

/// One Library tile (spec 6.6): the tool's icon, its name and one live line, at one fixed
/// size (`LibraryView.tileWidth` × `tileHeight`), so the grid stays even whatever the text.
/// A tool without content (`isSetUp == false`) is dimmed and its one action is "Set up".
struct LibraryTile: View {
    enum Action: Equatable { case open, setUp }

    let item: LibraryItem
    /// A plugin's own tile content (`NotchWidget.libraryTile()`), in place of the live line.
    let custom: AnyView?
    let onTap: () -> Void
    @State private var hovering = false

    static func action(for item: LibraryItem) -> Action { item.isSetUp ? .open : .setUp }

    /// What VoiceOver says the tile does.
    static func accessibilityHint(for item: LibraryItem) -> String {
        action(for: item) == .setUp ? "\(item.setupTitle ?? "Set up") \(item.title)" : "Open \(item.title)"
    }

    var body: some View {
        let dimmed: Bool = !item.isSetUp
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                iconWell(dimmed: dimmed)
                Spacer(minLength: 3)
                Text(verbatim: item.title)
                    .font(DS.font(TypeStyle(size: TypeScale.body.size, weight: .semibold)))
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                footer(dimmed: dimmed)
                    .frame(height: 14, alignment: .leading)
                    .padding(.top, 1)
            }
            .padding(EdgeInsets(top: 10, leading: Space.m, bottom: 9, trailing: Space.m))
            .frame(width: LibraryView.tileWidth, height: LibraryView.tileHeight, alignment: .topLeading)
            .background { LibraryTileCard(hovering: hovering) }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Self.accessibilityHint(for: item))
        .accessibilityAddTraits(.isButton)
        .help(Self.accessibilityHint(for: item))
    }

    /// The tool's symbol in a 28 pt well: monochrome teal on a 12% teal tint, the same
    /// weight for every tool; secondary on a neutral well while it needs setup.
    private func iconWell(dimmed: Bool) -> some View {
        let teal: Color = DS.dynamicColor(.working)
        let tint: Color = dimmed ? Color.primary.opacity(0.07) : DS.dynamicColor(.working, alpha: 0.12)
        return Image(systemName: item.systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(teal))
            .frame(width: LibraryView.iconWell, height: LibraryView.iconWell)
            .background(tint, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }

    @ViewBuilder private func footer(dimmed: Bool) -> some View {
        if dimmed {
            Text(verbatim: (item.setupTitle ?? "Set up") + " \u{203A}")
                .font(DS.font(TypeStyle(size: TypeScale.caption.size, weight: .semibold)))
                .foregroundStyle(DS.dynamicColor(.working))
                .lineLimit(1)
        } else if let custom {
            custom
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else {
            HStack(spacing: 5) {
                if item.isLive {
                    Circle()
                        .fill(DS.dynamicColor(.working))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(verbatim: item.liveLine ?? "")
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(item.isLive ? AnyShapeStyle(DS.dynamicColor(.working)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var accessibilityLabel: String {
        if !item.isSetUp { return "\(item.title), not set up" }
        if let line = item.liveLine, !line.isEmpty { return "\(item.title), \(line)" }
        return item.title
    }
}

/// A tile's one edge treatment: a subtle fill with no keyline on the dark surface; a
/// near-white card with a very soft shadow on the light one. A little brighter under the
/// pointer.
struct LibraryTileCard: View {
    let hovering: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        if scheme == .light {
            shape
                .fill(Color.white.opacity(hovering ? 1 : 0.86))
                .shadow(color: .black.opacity(0.07), radius: 3, x: 0, y: 1)
        } else {
            shape.fill(Color.white.opacity(hovering ? 0.085 : 0.055))
        }
    }
}
