import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// The pattern and a live preview for Batch rename (R10): nothing is renamed until the
/// user clicks Rename, and the preview is exactly the plan that runs.
@MainActor @Observable
final class BatchRenameModel {
    static let defaultPattern = "{name} {n}"

    var pattern: String {
        didSet { refresh() }
    }
    private(set) var plan = RenamePlan(steps: [])
    @ObservationIgnored let targets: [(item: ShelfItem, url: URL)]
    @ObservationIgnored let date: Date

    init(targets: [(item: ShelfItem, url: URL)], pattern: String = BatchRenameModel.defaultPattern, date: Date = Date()) {
        self.targets = targets
        self.pattern = pattern
        self.date = date
        refresh()
    }

    private func refresh() {
        plan = FileActionCenter.renamePlan(targets, pattern: pattern, date: date)
    }

    /// "old → new" lines, every target in order ("unchanged" when it keeps its name).
    var previewLines: [(old: String, new: String)] {
        let byIndex = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.index, $0.to.lastPathComponent) })
        return targets.enumerated().map { i, t in (t.url.lastPathComponent, byIndex[i] ?? t.url.lastPathComponent) }
    }
}

struct BatchRenameView: View {
    @Bindable var model: BatchRenameModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Pattern", text: $model.pattern)
                .textFieldStyle(.roundedBorder)
            Text("{name} the name · {n} or {n:3} the number · {date:yyyy-MM-dd} today. The extension is kept.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.previewLines.enumerated()), id: \.offset) { _, line in
                        row(line.old, line.new)
                    }
                }
            }
            .frame(height: 120)
        }
        .frame(width: 340)
    }

    private func row(_ old: String, _ new: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: old).lineLimit(1).truncationMode(.middle)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Text(verbatim: new).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(old == new ? Color.secondary : Color.primary)
        }
        .font(.system(size: 11))
    }
}

@MainActor
enum BatchRenameDialog {
    /// Asks for a pattern with a preview, then renames (user-initiated, so the app comes
    /// forward for the keyboard, like Locate…).
    static func run(_ targets: [(item: ShelfItem, url: URL)], center: FileActionCenter) {
        guard !targets.isEmpty else { return }
        let model = BatchRenameModel(targets: targets)
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Rename “\(targets[0].item.title)”" : "Rename \(targets.count) items"
        alert.informativeText = "Names already taken get “ 2”, “ 3”. Undo Rename puts them back."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let host = NSHostingView(rootView: BatchRenameView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 340, height: 190)
        alert.accessoryView = host
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        center.rename(targets, plan: model.plan)
    }
}
