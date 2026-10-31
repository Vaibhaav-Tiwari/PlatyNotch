import AppKit
import PlatyNotchKit
import SwiftUI

/// The Shelf tool (Island spec 4): the shelf's items as rows (the file's thumbnail, name and
/// size; text and links say so). Each row carries the shelf's own AppKit handle
/// (`ShelfItemHandle`): click / ⌘-click select, double-click opens, drag takes the
/// selection out, right-click has the full menu (Open, Quick Look, Reveal, AirDrop, Share,
/// Copy, Save As…, Actions ›, Pin, Remove). A file action shows its progress and Cancel on
/// the row, and its outcome under the list. A missing file offers Locate… and Remove.
/// "Clear" and "AirDrop all" sit in the header. Empty: the dashed drop box with Platy.
struct ShelfTool: View {
    let shelf: ShelfWidget

    static let empty = "Drop files here to keep them"

    /// Name and detail for each item: a file's size, "Text", or a link's host. Reads only the
    /// file's attributes (never a bookmark refresh, which would redraw the list).
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if shelf.items.isEmpty {
                emptyBox
            } else {
                let rows = Self.rows(shelf.items)
                ToolList(items: Array(zip(shelf.items, rows))) { pair in
                    ShelfToolRow(shelf: shelf, item: pair.0, title: pair.1.title, detail: pair.1.detail)
                }
            }
            if let status = shelf.fileActions?.status {
                HStack(spacing: 6) {
                    Text(verbatim: status).font(DS.font(TypeScale.caption)).foregroundStyle(DS.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button { shelf.fileActions?.dismissStatus() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .font(DS.font(TypeScale.caption))
                        .foregroundStyle(DS.tertiary)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { shelf.refreshMissing() }
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

/// One shelf row: the thumbnail well, name, detail and badges, with the shelf's AppKit
/// handle over it (select, drag, double-click, the menu) and a file action's progress.
struct ShelfToolRow: View {
    let shelf: ShelfWidget
    let item: ShelfItem
    let title: String
    let detail: String

    var body: some View {
        let missing = shelf.missing.contains(item.id)
        let selected = shelf.selection.contains(item.id)
        HStack(spacing: 10) {
            ShelfThumbnail(item: item, missing: missing)
                .frame(width: 22, height: 22)
                .frame(width: 28, height: 28)
                .background(DS.raised, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            Text(verbatim: title)
                .font(DS.font(TypeScale.body))
                .foregroundStyle(missing ? DS.secondary : DS.primary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if missing {
                Text("Missing").font(DS.font(TypeScale.caption)).foregroundStyle(DS.color(.needsYou))
                Button("Locate…") { ShelfActions.locate(item, in: shelf) }
                    .buttonStyle(.plain).font(DS.font(TypeScale.caption)).foregroundStyle(DS.secondary)
                Button { shelf.remove([item.id]) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(DS.font(TypeScale.caption)).foregroundStyle(DS.tertiary)
                    .accessibilityLabel("Remove \(item.title)")
            } else {
                Text(verbatim: detail).font(DS.font(TypeScale.caption)).foregroundStyle(DS.tertiary).lineLimit(1).fixedSize()
                if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(DS.tertiary)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(selected ? DS.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay {
            if !missing { ShelfItemHandle(host: shelf, item: item) }
        }
        .overlay {
            if let run = shelf.fileActions?.running[item.id] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: run.title).font(DS.font(TypeScale.caption)).foregroundStyle(DS.secondary)
                    Spacer(minLength: 0)
                    Button("Cancel") { shelf.fileActions?.cancel(item.id) }
                        .buttonStyle(.plain).font(DS.font(TypeScale.caption)).foregroundStyle(DS.primary)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.card.opacity(0.92), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(run.title) \(item.title)")
            }
        }
        .contextMenu {
            if missing {
                Button("Locate…") { ShelfActions.locate(item, in: shelf) }
                Button("Remove") { shelf.remove([item.id]) }
            }
        }
        .accessibilityElement(children: missing ? .contain : .combine)
        .accessibilityLabel(missing ? "\(item.title), missing" : item.title)
    }
}

/// The Shelf tool's header: "Clear" (unpinned items) and "AirDrop all".
struct ShelfHeaderButtons: View {
    let shelf: ShelfWidget

    var body: some View {
        HStack(spacing: 6) {
            if shelf.items.contains(where: { !$0.pinned }) {
                ModeChip(title: "Clear", selected: false, compact: true) { shelf.clearUnpinned() }
                    .help("Remove every unpinned item")
            }
            if let title = ShelfTool.accessoryTitle(canAirDrop: ShelfActions.canAirDrop, items: shelf.items) {
                ModeChip(title: title, selected: false, compact: true) {
                    ShelfActions.airDrop(shelf.items.compactMap { shelf.url(for: $0) })
                }
                .help("Send everything on the shelf with AirDrop")
            }
        }
    }
}
