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
    /// Return in the pattern field.
    var submit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Pattern", text: $model.pattern)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
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

/// Batch rename's window: the title, the pattern with its preview, and Cancel / Rename.
/// Not modal and it never activates the app (C1): a non-activating panel at `.floating`
/// that becomes key only to take the typing, like `BasketRenamePanel`, placed by
/// `BasketPlacement` (never over the notch panel or the approval card, which stays
/// clickable while this is open). Return renames; Escape or Cancel cancels. Clicking
/// elsewhere (an approval, another app) leaves it open: a click on it takes the keyboard
/// back, and Rename still runs exactly the plan the preview shows.
@MainActor
final class BatchRenamePanel: NSPanel {
    static let size = CGSize(width: 372, height: 300)
    let model: BatchRenameModel
    private var done: (@MainActor (Bool) -> Void)?

    init(model: BatchRenameModel, frame: CGRect, done: @escaping @MainActor (Bool) -> Void) {
        self.model = model
        self.done = done
        super.init(contentRect: frame, styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        let count = model.targets.count
        let title = count == 1 ? "Rename “\(model.targets[0].item.title)”" : "Rename \(count) items"
        self.title = title
        contentView = NSHostingView(rootView: BatchRenameSheet(
            title: title, model: model,
            rename: { [weak self] in self?.finish(true) },
            cancel: { [weak self] in self?.finish(false) }))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        makeKeyAndOrderFront(nil)   // a non-activating panel: the app stays in the background
    }

    override func cancelOperation(_ sender: Any?) { finish(false) }

    /// The close button.
    override func close() {
        finish(false)
        super.close()
    }

    /// `rename` true runs the plan; the panel goes either way, once.
    func finish(_ rename: Bool) {
        guard let done else { return }
        self.done = nil
        orderOut(nil)
        done(rename)
    }
}

/// The panel's content: what `NSAlert` showed before, without a modal session.
struct BatchRenameSheet: View {
    let title: String
    let model: BatchRenameModel
    let rename: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.headline).lineLimit(1).truncationMode(.middle)
            Text("Names already taken get “ 2”, “ 3”. Undo Rename puts them back.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            BatchRenameView(model: model, submit: rename)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Rename", action: rename).keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 28, leading: 16, bottom: 14, trailing: 16))
        .frame(width: BatchRenamePanel.size.width, height: BatchRenamePanel.size.height, alignment: .topLeading)
    }
}

@MainActor
enum BatchRenameDialog {
    /// The one open Batch rename (a second request replaces it, cancelled).
    private(set) static var current: BatchRenamePanel?

    /// Asks for a pattern with a preview, then renames. Never a modal session and never
    /// activates the app, so an approval arriving meanwhile stays clickable (C1). The panel
    /// opens where the menu was (the pointer), moved clear of the notch panel's region.
    static func run(_ targets: [(item: ShelfItem, url: URL)], center: FileActionCenter,
                    near point: CGPoint = NSEvent.mouseLocation,
                    screens: [BasketScreen] = SystemBasketSystem.screens(pillWidth: AppearanceStore.load(from: .standard).pillWidth)) {
        guard !targets.isEmpty else { return }
        current?.finish(false)
        guard let frame = BasketPlacement.frame(centeredAt: point, size: BatchRenamePanel.size, screens: screens) else {
            NSSound.beep()
            return
        }
        let model = BatchRenameModel(targets: targets)
        let panel = BatchRenamePanel(model: model, frame: frame) { rename in
            current = nil
            if rename { center.rename(targets, plan: model.plan) }
        }
        current = panel
        panel.present()
    }
}
