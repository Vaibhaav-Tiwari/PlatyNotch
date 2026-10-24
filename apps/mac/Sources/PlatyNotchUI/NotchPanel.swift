import AppKit
import Quartz
import SwiftUI

/// The borderless, non-activating window over the notch. It is transparent and
/// click-through except where the controller says the cursor is on the panel.
final class NotchPanel: NSPanel {
    /// Set by the controller: true only when expanded or peeking an approval.
    var allowsKey = false
    var onEscape: (() -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // `isFloatingPanel` sets the level to `.floating`, so it must come first: set
        // after it, `.statusBar` was silently lost (the panel sat at `.floating`).
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    /// AppKit normally pushes windows below the menu bar. The notch panel must sit
    /// over the camera housing, so keep exactly the frame we ask for.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// A mouse-down landed in the panel since it last lost key status. Only then can it
    /// become key: when one of PlatyNotch's own windows (Settings, onboarding, a Locate
    /// panel) closes, AppKit hands key to another of the app's windows, and the notch panel
    /// must never take the keyboard that way, without a click (A4).
    private(set) var clickedIn = false

    override var canBecomeKey: Bool { allowsKey && clickedIn }
    override var canBecomeMain: Bool { false }

    static func isPress(_ type: NSEvent.EventType) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    /// Every event reaches the window here before AppKit decides on key status, so a
    /// click anywhere in the content (SwiftUI or a layer-backed subview) counts.
    override func sendEvent(_ event: NSEvent) {
        if Self.isPress(event.type) { noteMouseDown() }
        super.sendEvent(event)
    }

    func noteMouseDown() { clickedIn = true }

    override func resignKey() {
        super.resignKey()
        clickedIn = false
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    // Quick Look for shelf items: the open panel is the key window when the user picks
    // "Quick Look", so it is the panel's controller (QLPreviewPanel's responder-chain API).
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { ShelfQuickLook.shared.hasItems }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { ShelfQuickLook.shared.attach(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { ShelfQuickLook.shared.detach(panel) }
    }
}

/// Where the hosting view sends the drags it receives (the controller).
@MainActor
protocol PanelDropRouting: AnyObject {
    func panelDragUpdated(_ info: NSDraggingInfo) -> NSDragOperation
    func panelDragExited()
    func panelPerformDrop(_ info: NSDraggingInfo) -> Bool
    func panelDragEnded()
}

/// Hosting view that takes the first click, so a click on the compact pill acts immediately.
/// It is the panel's drag destination (registered for `PanelDrop.types` at creation, not
/// when the drop zone appears) and hands every drag to `dropRouter`; nothing in the
/// panel's SwiftUI content uses `onDrop`.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    weak var dropRouter: PanelDropRouting?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropRouter?.panelDragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropRouter?.panelDragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropRouter?.panelDragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropRouter != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropRouter?.panelPerformDrop(sender) ?? false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropRouter?.panelDragEnded()
    }
}
