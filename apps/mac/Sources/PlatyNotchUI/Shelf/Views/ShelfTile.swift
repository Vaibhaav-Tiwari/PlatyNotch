import AppKit
import PlatyNotchKit
import QuickLookThumbnailing
import SwiftUI

/// The shelf's Today tile: a row of cards, newest first. Click selects (⌘-click adds),
/// double-click opens, drag takes the selection out, right-click has the menu. A missing
/// file shows a badge with Locate… and Remove. Works on any `ItemListHost` (the shelf).
struct ShelfTile: View {
    let host: any ItemListHost
    @Environment(\.inPanelTool) private var inTool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            items
            if let status = host.fileActions?.status { statusLine(status) }
        }
        .onAppear { host.refreshMissing() }
    }

    /// The last file action's outcome (a few seconds).
    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: text)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button { host.fileActions?.dismissStatus() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .font(DS.font(TypeScale.caption))
                .accessibilityLabel("Dismiss")
        }
    }

    // Split out of `body`: one expression was slow for the type checker (25 ms probe).
    private var header: some View {
        HStack {
            if inTool {
                Text(host.items.isEmpty ? "" : "Double-click to open · drag out to use")
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.secondary)
            } else {
                Label("Shelf", systemImage: "tray.full").font(.system(size: 12, weight: .semibold))
            }
            Spacer()
            if host.items.contains(where: { !$0.pinned }) {
                Button("Clear") { host.clearUnpinned() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("Remove every unpinned item")
            }
        }
    }

    @ViewBuilder private var items: some View {
        if host.items.isEmpty, inTool {
            ToolEmptyState(systemImage: "tray", title: "The shelf is empty",
                           detail: "Drag files, images, links or text to the notch to keep them here.")
        } else if inTool {
            // The tool has the room for every card: rows that wrap, not one row that scrolls.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(ShelfCard.toolSize.width), spacing: ShelfCard.toolSpacing),
                                     count: 5),
                      alignment: .leading, spacing: ShelfCard.toolSpacing) {
                ForEach(host.items) { item in
                    ShelfCard(host: host, item: item, missing: host.missing.contains(item.id),
                              selected: host.selection.contains(item.id),
                              run: host.fileActions?.running[item.id])
                }
            }
        } else if host.items.isEmpty {
            Text("Drag files, images, links or text to the notch to keep them here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(host.items) { item in
                        ShelfCard(host: host, item: item, missing: host.missing.contains(item.id),
                                  selected: host.selection.contains(item.id),
                                  run: host.fileActions?.running[item.id])
                    }
                }
            }
        }
    }
}

/// One item: thumbnail, name, pin and missing badges.
struct ShelfCard: View {
    static let size = CGSize(width: 72, height: 78)
    /// The Library tool's cards: five to a row of the panel's width.
    static let toolSize = CGSize(width: 96, height: 100)
    static let toolSpacing: CGFloat = (PanelLayout.expandedSize.width - 2 * Space.panelSide - 5 * 96) / 4
    let host: any ItemListHost
    let item: ShelfItem
    let missing: Bool
    let selected: Bool
    /// A file action working on this item (progress and Cancel on the card).
    var run: FileActionCenter.Run?
    @Environment(\.inPanelTool) private var inTool

    private var cardSize: CGSize { inTool ? Self.toolSize : Self.size }
    private var thumbnail: CGFloat { inTool ? 56 : 40 }

    var body: some View {
        content
            .overlay {
                if let run { progress(run) }
            }
    }

    private func progress(_ run: FileActionCenter.Run) -> some View {
        VStack(spacing: 4) {
            ProgressView().controlSize(.small)
            Text(verbatim: run.title).font(DS.font(TypeScale.caption)).lineLimit(1)
            Button("Cancel") { host.fileActions?.cancel(item.id) }
                .buttonStyle(.borderless)
                .font(DS.font(TypeScale.caption))
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.background.opacity(0.85)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(run.title) \(item.title)")
    }

    /// In the Shelf tool, the card's soft fill, outlined in secondary ink while selected; on
    /// the tile, the quiet wash.
    @ViewBuilder private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        if inTool {
            ToolCardFill(hovering: selected)
                .overlay { if selected { shape.strokeBorder(DS.secondary, lineWidth: 1.5) } }
        } else {
            shape.fill(.primary.opacity(selected ? 0.18 : 0.06))
        }
    }

    private var content: some View {
        // Spacing 1: two 11 pt title lines fit under the thumbnail in the fixed card.
        VStack(spacing: 1) {
            ZStack(alignment: .topTrailing) {
                ShelfThumbnail(item: item, missing: missing).frame(width: thumbnail, height: thumbnail)
                if missing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.color(.attention))
                        .accessibilityLabel("Missing")
                }
            }
            .overlay(alignment: .topTrailing) {
                if !missing, item.pinned {
                    // Beside the thumbnail's top-right corner, not over it; an overlay, so
                    // the thumbnail stays centred.
                    Image(systemName: "pin.fill").font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: TypeScale.caption.size + 1)
                }
            }
            if missing {
                HStack(spacing: 6) {
                    Button { ShelfActions.locate(item, in: host) } label: { Image(systemName: "magnifyingglass") }
                        .help("Locate “\(item.title)”…")
                        .accessibilityLabel("Locate \(item.title)")
                    Button { host.remove([item.id]) } label: { Image(systemName: "xmark") }
                        .help("Remove from the shelf")
                        .accessibilityLabel("Remove \(item.title)")
                }
                .buttonStyle(.borderless)
                .font(DS.font(TypeScale.caption))
            } else {
                // A one-word name ("example.com") takes one line in regular weight, tightened
                // if need be, and truncates in the middle rather than breaking mid-word;
                // names with spaces wrap to two lines.
                let oneLine = !item.title.contains(" ")
                Text(verbatim: item.title)
                    .font(DS.font(TypeScale.caption).weight(oneLine ? .regular : .medium))
                    .allowsTightening(true)
                    .lineLimit(oneLine ? 1 : 2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .frame(width: cardSize.width, height: cardSize.height)
        .background { cardBackground }
        .overlay {
            if !missing {
                // Clicks, drags out and the menu (AppKit: a real NSDraggingSource with file URLs).
                ShelfItemHandle(host: host, item: item)
            }
        }
        .contextMenu {
            if missing {
                Button("Locate…") { ShelfActions.locate(item, in: host) }
                Button("Remove") { host.remove([item.id]) }
            }
        }
        .accessibilityElement(children: missing ? .contain : .combine)
        .accessibilityLabel(missing ? "\(item.title), missing" : item.title)
    }
}

/// A file's Quick Look thumbnail (made on demand, kept in memory); an icon otherwise.
struct ShelfThumbnail: View {
    let item: ShelfItem
    let missing: Bool
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbol).font(.system(size: IconSize.header)).foregroundStyle(.secondary)
            }
        }
        .task(id: missing ? nil : item.fileRef?.path) { await load() }
    }

    private var symbol: String {
        switch item.kind {
        case .file: missing ? "questionmark.folder" : "doc"
        case .text: "text.alignleft"
        case .url: "link"
        }
    }

    private func load() async {
        guard !missing, let ref = item.fileRef else { image = nil; return }
        if let cached = ShelfThumbnails.cache.object(forKey: ref.path as NSString) {
            image = cached
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: ref.url, size: CGSize(width: 40, height: 40),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .all)
        if let thumbnail = await ShelfThumbnails.best(request) {
            ShelfThumbnails.cache.setObject(thumbnail, forKey: ref.path as NSString)
            image = thumbnail
        } else {
            image = NSWorkspace.shared.icon(forFile: ref.path)
        }
    }
}

@MainActor
enum ShelfThumbnails {
    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 100
        return c
    }()

    /// Quick Look's best thumbnail, or nil. An explicit continuation, not the compiler's
    /// async form of this completion-handler API: the generated form of
    /// AVAssetWriter.finishWriting crashed on resume on macOS 15.7 (CI), and this call is
    /// not proven safe there. CI greps for the generated form.
    static func best(_ request: QLThumbnailGenerator.Request) async -> NSImage? {
        await withCheckedContinuation { (done: CheckedContinuation<NSImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                done.resume(returning: rep?.nsImage)
            }
        }
    }

    /// The image a drag shows for `item`.
    static func dragImage(_ item: ShelfItem, url: URL?) -> NSImage {
        if let url, let cached = cache.object(forKey: url.path as NSString) { return cached }
        if let url { return NSWorkspace.shared.icon(forFile: url.path) }
        let name = if case .url = item.kind { "link" } else { "text.alignleft" }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }
}

/// The transparent AppKit layer over a card: click / ⌘-click select, double-click opens,
/// a drag starts an `NSDraggingSession` of the selection, right-click shows the menu.
struct ShelfItemHandle: NSViewRepresentable {
    let host: any ItemListHost
    let item: ShelfItem

    func makeNSView(context: Context) -> ShelfItemView {
        ShelfItemView(host: host, item: item)
    }

    func updateNSView(_ view: ShelfItemView, context: Context) {
        view.item = item
    }
}

final class ShelfItemView: NSView {
    private weak var host: (any ItemListHost)?
    var item: ShelfItem
    private var mouseDownEvent: NSEvent?

    init(host: any ItemListHost, item: ShelfItem) {
        self.host = host
        self.item = item
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2, let host, let url = urlIfFile(host) {
            ShelfActions.open([url])
            mouseDownEvent = nil
        } else if event.clickCount == 2, case .url(let u) = item.kind {
            NSWorkspace.shared.open(u)
            mouseDownEvent = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, let host else { return }
        host.select(item, extend: event.modifierFlags.contains(.command))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let host else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        mouseDownEvent = nil
        let writers = host.pasteboardWriters(for: host.dragSet(startingAt: item))
        guard !writers.isEmpty else {
            NSSound.beep()   // only missing files: refused, the card shows the badge
            return
        }
        let items = writers.enumerated().map { index, pair -> NSDraggingItem in
            let (shelfItem, writer) = pair
            let dragItem = NSDraggingItem(pasteboardWriter: writer)
            let url = (writer as? NSURL).flatMap { $0.isFileURL ? $0 as URL : nil }
            let offset = CGFloat(min(index, 4)) * 4
            dragItem.setDraggingFrame(CGRect(x: bounds.midX - 20 + offset, y: bounds.midY - 20 - offset, width: 40, height: 40),
                                      contents: ShelfThumbnails.dragImage(shelfItem, url: url))
            return dragItem
        }
        host.outgoingDragChanged(true)   // before the drag pasteboard changes
        beginDraggingSession(with: items, event: event, source: host.dragSource)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let host else { return nil }
        let targets = host.dragSet(startingAt: item)
        let writers = host.pasteboardWriters(for: targets)
        let fileURLs = writers.compactMap { ($0.1 as? NSURL).flatMap { $0.isFileURL ? $0 as URL : nil } }
        let shareable: [Any] = writers.map { pair -> Any in
            if let u = pair.1 as? NSURL { return u as URL }
            return (pair.1 as? NSString).map { $0 as String } ?? ""
        }
        let ids = targets.map(\.id)
        let item = self.item
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let mi = ClosureMenuItem(title: title, action: action)
            mi.isEnabled = enabled
            menu.addItem(mi)
        }
        let webURLs = targets.compactMap { if case .url(let u) = $0.kind { u } else { nil } }
        add("Open", enabled: !fileURLs.isEmpty || !webURLs.isEmpty) { ShelfActions.open(fileURLs + webURLs) }
        add("Quick Look", enabled: !fileURLs.isEmpty) { [weak self] in ShelfActions.quickLook(fileURLs, from: self?.window) }
        add("Reveal in Finder", enabled: !fileURLs.isEmpty) { ShelfActions.reveal(fileURLs) }
        menu.addItem(.separator())
        add("AirDrop", enabled: ShelfActions.canAirDrop && !shareable.isEmpty) { ShelfActions.airDrop(shareable) }
        add("Share…", enabled: !shareable.isEmpty) { [weak self] in
            if let self { ShelfActions.share(shareable, from: self) }
        }
        menu.addItem(.separator())
        add("Copy", enabled: !writers.isEmpty) { ShelfActions.copy(writers.map(\.1)) }
        add("Copy Path", enabled: !fileURLs.isEmpty) { ShelfActions.copyPaths(fileURLs) }
        // An owned copy or action result lives in the shelf's folder: Save As… puts a copy
        // where the user chooses (R11).
        if targets.count == 1, item.ownsFile, let url = fileURLs.first {
            add("Save As…") { ShelfActions.saveAs(url) }
        }
        menu.addItem(.separator())
        if let center = host.fileActions {
            let pairs: [(item: ShelfItem, url: URL?)] = writers.map { pair in
                (pair.0, (pair.1 as? NSURL).flatMap { $0.isFileURL ? $0 as URL : nil })
            }
            let entries = center.entries(for: pairs)
            if !entries.isEmpty {
                let actions = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
                actions.submenu = Self.actionsMenu(entries, center: center, host: host, pairs: pairs)
                menu.addItem(actions)
                menu.addItem(.separator())
            }
        }
        add(item.pinned ? "Unpin" : "Pin") { host.togglePin(item) }
        add(ids.count > 1 ? "Remove \(ids.count) Items" : "Remove") { host.remove(ids) }
        return menu
    }

    /// "Actions ›": the entries the center offers for this selection.
    static func actionsMenu(_ entries: [FileActionCenter.Entry], center: FileActionCenter, host: any ItemListHost,
                            pairs: [(item: ShelfItem, url: URL?)]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let files: [(item: ShelfItem, url: URL)] = pairs.compactMap { p in p.url.map { (p.item, $0) } }
        for entry in entries {
            switch entry {
            case .action(let title, let action):
                menu.addItem(ClosureMenuItem(title: title) { center.run(action, on: files) })
            case .submenu(let title, let children):
                let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                mi.submenu = actionsMenu(children, center: center, host: host, pairs: pairs)
                menu.addItem(mi)
            case .rename:
                let title = files.count > 1 ? "Batch Rename…" : "Rename…"
                menu.addItem(ClosureMenuItem(title: title) { BatchRenameDialog.run(files, center: center) })
            case .undoRename:
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Undo Rename") { center.undoRename() })
            }
        }
        return menu
    }

    private func urlIfFile(_ host: any ItemListHost) -> URL? {
        guard item.fileRef != nil else { return nil }
        guard let url = host.url(for: item) else {
            NSSound.beep()
            return nil
        }
        return url
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// The drop zone while a drag is near the notch.
struct ShelfDropZone: View {
    let shelf: ShelfWidget

    var body: some View {
        let on = shelf.dropTargeted
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: on ? 2 : 1.5, dash: on ? [] : [6, 4]))
            .foregroundStyle(on ? DS.primary : DS.secondary)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(on ? DS.ink(0.14) : Color.clear))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: on ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: IconSize.header, weight: .medium))
                    Text("Drop to keep on the Shelf").font(.system(size: 13, weight: .medium))
                    if !shelf.items.isEmpty {
                        Text(shelf.items.count == 1 ? "1 item on the shelf" : "\(shelf.items.count) items on the shelf")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Drop to keep on the Shelf")
    }
}

/// Settings › Widgets › Shelf.
struct ShelfSettings: View {
    let shelf: ShelfWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsNote("Drag anything to the notch to keep it on the shelf. Files stay where they are; the shelf remembers them, even if you rename or move them, and never deletes them.")
                .fixedSize(horizontal: false, vertical: true)
            SettingsNote("Images and files from apps like Photos or Mail are copied into PlatyNotch's private folder, and dropped text is kept there too. Unless pinned, they are deleted 7 days after you added them: while the shelf is on, at that time; while it is off, the next time PlatyNotch starts.")
                .fixedSize(horizontal: false, vertical: true)
            SettingsNote("The shelf can't tell which app a drag comes from, so Memory's excluded apps don't apply to it. Items marked as passwords or transient by the app that copied them are never kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsNote("Items from Downloads, Desktop or Documents may ask macOS for access when shown.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsNote("Turning the shelf off keeps its items. Clear Shelf deletes every unpinned item and its copy now.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear Shelf") { shelf.clearUnpinned() }
                    .disabled(!shelf.items.contains { !$0.pinned })
                    .help("Removes every unpinned item and deletes the shelf's own copies")
                Button("Show Shelf Folder") { NSWorkspace.shared.open(shelf.directory) }
                    .disabled(!FileManager.default.fileExists(atPath: shelf.directory.path))
            }
            if let kept = shelf.keptCopies {
                Text("A damaged shelf index was set aside, with the copies it may have listed, so nothing was deleted. Kept copies are not removed after 7 days.")
                    .foregroundStyle(Theme.color(.attention))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(kept == 1 ? "1 kept" : "\(kept) kept").foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.open(shelf.directory) }
                    Button("Delete Kept Copies") { shelf.deleteKeptFiles() }
                        .help("Deletes the set-aside index and every copy no shelf item lists")
                }
            }
        }
        .font(.system(size: 12))
    }
}
