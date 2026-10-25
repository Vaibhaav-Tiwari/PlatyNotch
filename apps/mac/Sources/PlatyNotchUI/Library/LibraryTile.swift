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
    @Environment(\.colorScheme) private var scheme

    static func action(for item: LibraryItem) -> Action { item.isSetUp ? .open : .setUp }

    /// What VoiceOver says the tile does.
    static func accessibilityHint(for item: LibraryItem) -> String {
        action(for: item) == .setUp ? "\(item.setupTitle ?? "Set up") \(item.title)" : "Open \(item.title)"
    }

    var body: some View {
        let dimmed: Bool = !item.isSetUp
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                DS.icon(item.systemImage, size: IconSize.tile)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.dynamicColor(.working)))
                    .frame(width: IconSize.tile + 4, height: IconSize.tile + 4, alignment: .leading)
                Spacer(minLength: 0)
                Text(verbatim: item.title)
                    .font(DS.font(TypeStyle(size: TypeScale.body.size, weight: .semibold)))
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                footer(dimmed: dimmed)
                    .frame(height: 16, alignment: .leading)
                    .padding(.top, 2)
            }
            .padding(Space.m)
            .frame(width: LibraryView.tileWidth, height: LibraryView.tileHeight, alignment: .topLeading)
            .background(hoverWash, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .dsCard()
            .opacity(dimmed ? 0.78 : 1)
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

    @ViewBuilder private func footer(dimmed: Bool) -> some View {
        if dimmed {
            Text(verbatim: item.setupTitle ?? "Set up")
                .font(DS.font(TypeStyle(size: TypeScale.caption.size, weight: .semibold)))
                .foregroundStyle(DS.dynamicColor(.working))
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(DS.dynamicColor(.working, alpha: 0.14), in: Capsule())
        } else if let custom {
            custom
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else if let line = item.liveLine, !line.isEmpty {
            Text(verbatim: line)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Color.clear
        }
    }

    /// A faint lift under the pointer (the card keeps its keyline).
    private var hoverWash: Color {
        guard hovering else { return .clear }
        return (scheme == .light ? Color.black : Color.white).opacity(0.05)
    }

    private var accessibilityLabel: String {
        if !item.isSetUp { return "\(item.title), not set up" }
        if let line = item.liveLine, !line.isEmpty { return "\(item.title), \(line)" }
        return item.title
    }
}
