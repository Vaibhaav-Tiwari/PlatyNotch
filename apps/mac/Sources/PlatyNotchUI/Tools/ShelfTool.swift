import AppKit
import PlatyNotchKit
import SwiftUI

/// The Shelf tool (Island spec 4): the shelf's files as rows (the file's icon, name and
/// size; text and links say so), drag a row out to use it, double-click opens; "AirDrop all"
/// in the header. Empty: the dashed drop box with Platy.
struct ShelfTool: View {
    let shelf: ShelfWidget

    /// The rows never sit in a grid (Island lint: no tile grids).
    static let usesGrid = false
    static let empty = "Drop files here to keep them"
    static let showsPlatyWhenEmpty = true

    /// Name and detail for each item: a file's size, "Text", or a link's host.
    static func rows(_ items: [ShelfItem]) -> [(title: String, detail: String)] {
        items.map { item in
            switch item.kind {
            case .file(let ref):
                let size = (try? FileManager.default.attributesOfItem(atPath: ref.path)[.size] as? NSNumber)?.int64Value
                return (ref.name, size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Missing")
            case .text(let t):
                return (t.components(separatedBy: .newlines).first ?? t, "Text")
            case .url(let u):
                return (u.absoluteString, u.host ?? "Link")
            }
        }
    }

    /// Everything it prints (tests).
    static func texts(_ items: [ShelfItem]) -> [String] {
        items.isEmpty ? [empty] : rows(items).flatMap { [$0.title, $0.detail] }
    }

    /// The header's "AirDrop all": only with AirDrop available and something on the shelf.
    static func accessoryTitle(canAirDrop: Bool, items: [ShelfItem]) -> String? {
        canAirDrop && !items.isEmpty ? "AirDrop all" : nil
    }

    static func symbol(_ item: ShelfItem) -> String {
        switch item.kind {
        case .file: "doc"
        case .text: "text.alignleft"
        case .url: "link"
        }
    }

    var body: some View {
        if shelf.items.isEmpty {
            emptyBox
        } else {
            let rows = Self.rows(shelf.items)
            ToolList(items: Array(zip(shelf.items, rows))) { pair in
                let (item, row) = pair
                ToolRow(symbol: Self.symbol(item), icon: icon(item), title: row.title, detail: row.detail,
                        selected: shelf.selection.contains(item.id), dimmed: shelf.missing.contains(item.id)) {
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(DS.tertiary)
                    }
                }
                .onTapGesture(count: 2) { if let url = shelf.url(for: item) { ShelfActions.open([url]) } }
                .onTapGesture { shelf.select(item, extend: false) }
                .onDrag { provider(item) }
                .contextMenu {
                    Button(item.pinned ? "Unpin" : "Pin") { shelf.togglePin(item) }
                    Button("Remove") { shelf.remove([item.id]) }
                }
            }
            .onAppear { shelf.refreshMissing() }
        }
    }

    private func icon(_ item: ShelfItem) -> NSImage? {
        guard case .file = item.kind, let url = shelf.url(for: item) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func provider(_ item: ShelfItem) -> NSItemProvider {
        switch item.kind {
        case .file: shelf.url(for: item).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
        case .url(let u): NSItemProvider(object: u as NSURL)
        case .text(let t): NSItemProvider(object: t as NSString)
        }
    }

    private var emptyBox: some View {
        VStack(spacing: Space.s) {
            PlatyView(mood: .idle, size: 36)
            Text(verbatim: Self.empty)
                .font(DS.font(TypeScale.body))
                .foregroundStyle(DS.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(DS.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// "AirDrop all" in the Shelf tool's header.
struct ShelfAirDropButton: View {
    let shelf: ShelfWidget

    var body: some View {
        if let title = ShelfTool.accessoryTitle(canAirDrop: ShelfActions.canAirDrop, items: shelf.items) {
            ModeChip(title: title, selected: false, compact: true) {
                let urls: [Any] = shelf.items.compactMap { shelf.url(for: $0) }
                ShelfActions.airDrop(urls)
            }
            .help("Send everything on the shelf with AirDrop")
        }
    }
}
