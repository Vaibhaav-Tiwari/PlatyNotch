import AppKit
import PlatyNotchKit
import SwiftUI

/// What the controller needs of a basket's window (a seam: tests use a fake, smoke runs
/// never make one).
@MainActor
protocol BasketWindowing: AnyObject {
    var frame: CGRect { get }
    func place(_ frame: CGRect)
    /// Ordered in without taking focus.
    func show()
    func hide()
    func close()
}

/// A basket's window (R5): a borderless, non-activating `NSPanel` that never becomes key
/// or main, at `.floating` (below the notch panel's `.statusBar`), on every Space and
/// beside full-screen apps (`fullScreenAuxiliary`; hidden over them when Appearance says
/// so, by the controller). It never touches the notch's drag session. Its frame always
/// comes from `BasketPlacement` (the controller), so it never covers the notch panel or
/// the approval card. It takes drops of files, links, images and text.
@MainActor
final class BasketPanel: NSPanel, BasketWindowing {
    init(host: BasketHost, frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false   // moved only by its header, through the controller (clamped)
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = true
        let view = BasketDropView(rootView: BasketView(host: host))
        view.host = host
        // Registered at creation: the window appears under a drag already in progress.
        view.registerForDraggedTypes(PanelDrop.types)
        view.sizingOptions = []
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
        setAccessibilityLabel(host.name)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(_ frame: CGRect) { setFrame(frame, display: true) }
    func show() { orderFrontRegardless() }
    func hide() { orderOut(nil) }
}

/// The basket's content (SwiftUI), and the destination of drags of files, links, images
/// and text onto it (never our own drags, nothing concealed or transient). The pasteboard
/// is read only in `performDragOperation`.
@MainActor
final class BasketDropView: NSHostingView<BasketView> {
    weak var host: BasketHost?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { offer(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { offer(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { host?.setDropTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { host?.setDropTargeted(false) }

    private func offer(_ info: NSDraggingInfo) -> NSDragOperation {
        // Not while the close question shows: the basket may be about to go (N1).
        guard let host, host.closeAsk == nil, host.room > 0, ShelfDropTarget.accepts(info) else {
            host?.setDropTargeted(false)
            return []
        }
        host.setDropTargeted(true)
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let host, host.closeAsk == nil, host.room > 0, ShelfDropTarget.accepts(sender) else { return false }
        host.setDropTargeted(false)
        let pb = sender.draggingPasteboard
        let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if !hasFiles, host.receivePromises(from: pb) > 0 { return true }
        return host.receive(pasteboard: pb) > 0
    }
}

/// A basket: a header (color, name, count, close) to move it by, and the shelf's cards.
struct BasketView: View {
    let host: BasketHost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(8)
        .frame(width: BasketPlacement.size.width, height: BasketPlacement.size.height, alignment: .topLeading)
        .background(background)
        .overlay {
            if let ask = host.closeAsk { BasketClosePrompt(host: host, ask: ask) }
        }
        .onAppear { host.refreshMissing() }
    }

    private var tint: Color { BasketPalette.color(host.color) }

    private var background: some View {
        let on = host.dropTargeted || host.highlighted
        return RoundedRectangle(cornerRadius: 12)
            .fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(on ? 1 : 0.6), lineWidth: on ? 3 : 1.5))
    }

    // Split out of `body` (type-check time).
    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(verbatim: host.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if host.pinned {
                Image(systemName: "pin.fill").font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            Spacer(minLength: 4)
            Text(verbatim: "\(host.items.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityLabel(host.items.count == 1 ? "1 item" : "\(host.items.count) items")
            Button { host.owner?.requestClose(host) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .help("Close basket")
                .accessibilityLabel("Close \(host.name)")
        }
        .frame(height: 18)
        .background(BasketHandle(host: host))
    }

    @ViewBuilder private var content: some View {
        if host.items.isEmpty {
            Text("Drop files, links, images or text here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BasketHandle(host: host))
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

/// The close question, inside the basket (never a modal alert, R5): Move to Shelf (only
/// while the shelf runs), Discard, Cancel.
struct BasketClosePrompt: View {
    let host: BasketHost
    let ask: BasketCloseAsk

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: ask.count == 1 ? "Close with 1 item?" : "Close with \(ask.count) items?")
                .font(.system(size: 12, weight: .semibold))
            Text("Discard deletes the copies this basket made, never your own files.")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .accessibilityElement(children: .contain)
    }

    // Split out of `body` (type-check time).
    private var buttons: some View {
        HStack(spacing: 6) {
            if ask.canMoveToShelf {
                Button("Move to Shelf") { host.owner?.resolveClose(host, .moveToShelf) }
            }
            Button("Discard") { host.owner?.resolveClose(host, .discard) }
            Button("Cancel") { host.owner?.resolveClose(host, .cancel) }
        }
        .controlSize(.small)
    }
}

enum BasketPalette {
    static func color(_ c: BasketColor) -> Color {
        switch c {
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case .purple: .purple
        case .teal: .teal
        }
    }
}

/// The header's AppKit layer: dragging it moves the basket (each step placed by the
/// controller, so it never enters the notch panel's region; dropped on another basket, it
/// merges), right-click shows the basket's menu.
struct BasketHandle: NSViewRepresentable {
    let host: BasketHost

    func makeNSView(context: Context) -> BasketHandleView { BasketHandleView(host: host) }
    func updateNSView(_ view: BasketHandleView, context: Context) {}
}

final class BasketHandleView: NSView {
    private weak var host: BasketHost?
    private var grab: (pointer: CGPoint, origin: CGPoint)?

    init(host: BasketHost) {
        self.host = host
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window, let host else { return }
        grab = (NSEvent.mouseLocation, window.frame.origin)
        host.owner?.beginMove(host)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab, let host, let window else { return }
        let p = NSEvent.mouseLocation
        var f = window.frame
        f.origin = CGPoint(x: grab.origin.x + p.x - grab.pointer.x, y: grab.origin.y + p.y - grab.pointer.y)
        host.owner?.basketMoved(host, to: f)
    }

    override func mouseUp(with event: NSEvent) {
        defer { grab = nil }
        guard grab != nil, let host else { return }
        host.owner?.basketDropped(host, pointer: NSEvent.mouseLocation)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let host, let owner = host.owner else { return nil }
        return owner.menu(for: host)
    }
}
