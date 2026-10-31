import PlatyNotchKit
import SwiftUI

/// The File actions power feature (Task 2): its on/off switch under Settings › Widgets ›
/// Power features. Off by default. While it runs, shelf items get an "Actions ›" menu
/// (convert, compress video, combine into PDF, zip, unzip, copy text, remove background,
/// batch rename). It has no tile and does no work of its own: actions run only when
/// picked, on this Mac, and their results are new shelf items (R11).
@MainActor
final class FileActionsWidget: NotchWidget {
    static let widgetID = "fileActions"

    let id = FileActionsWidget.widgetID
    let title = "File actions"
    let systemImage = "wand.and.stars"
    let defaultEnabled = false
    var hasTile: Bool { false }
    var category: WidgetCategory { .power }

    func tileView() -> AnyView { AnyView(EmptyView()) }
    func settingsView() -> AnyView? { AnyView(FileActionsSettings()) }
    /// The Library tool: what the actions do and where they live.
    func toolView() -> AnyView { AnyView(FileActionsTool()) }
}

/// File actions in the Library: every action with its symbol, and how to reach them.
struct FileActionsTool: View {
    static let actions: [(symbol: String, title: String)] = [
        ("arrow.triangle.2.circlepath", "Convert images, video and audio"),
        ("film", "Compress a video"),
        ("doc.richtext", "Combine images into a PDF"),
        ("doc.zipper", "Zip or unzip"),
        ("text.viewfinder", "Copy the text in an image or PDF"),
        ("person.crop.rectangle", "Remove a photo's background"),
        ("pencil.line", "Rename files in a batch"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Right-click a shelf item, then Actions.")
                .font(DS.font(TypeScale.body))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)],
                      alignment: .leading, spacing: Space.s) {
                ForEach(Self.actions, id: \.title) { action in
                    HStack(spacing: Space.s) {
                        DS.icon(action.symbol, size: IconSize.symbol)
                            .foregroundStyle(DS.secondary)
                            .frame(width: 22)
                        Text(verbatim: action.title)
                            .font(DS.font(TypeScale.body))
                            .lineLimit(1)
                            .minimumScaleFactor(TypeScale.minimum / TypeScale.body.size)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.m)
                    .frame(height: 36)
                    .panelFill()
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Everything runs on this Mac. Results are new shelf items, kept 7 days unless pinned. Nothing is written next to your files; a rename can be undone once.")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FileActionsSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsNote("Right-click a shelf item › Actions to convert images, video and audio, compress a video, combine images into a PDF, zip or unzip, copy the text in an image or PDF, remove a photo's background, or rename files.")
                .fixedSize(horizontal: false, vertical: true)
            SettingsNote("Everything runs on this Mac. Results are new shelf items, kept 7 days unless pinned; Save As… puts a copy where you want it. Nothing is written next to your files. Rename changes your files' names (never replacing one) and can be undone once.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
}
