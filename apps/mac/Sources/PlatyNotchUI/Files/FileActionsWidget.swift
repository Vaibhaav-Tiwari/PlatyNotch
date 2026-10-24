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
}

struct FileActionsSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Right-click a shelf item › Actions to convert images, video and audio, compress a video, combine images into a PDF, zip or unzip, copy the text in an image or PDF, remove a photo's background, or rename files.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Everything runs on this Mac. Results are new shelf items, kept 7 days unless pinned; Save As… puts a copy where you want it. Nothing is written next to your files. Rename changes your files' names (never replacing one) and can be undone once.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
}
