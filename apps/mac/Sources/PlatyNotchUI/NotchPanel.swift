import AppKit
import Quartz
import SwiftUI

/// The borderless, non-activating window over the notch. It is transparent and
/// click-through except where the controller says the cursor is on the panel.
final class NotchPanel: NSPanel {
    /// Set by the controller: true only when expanded or peeking an approval.
    /// The mode may take the keyboard (expanded, approval peek). Leaving such a mode
    /// forgets the click: a later approval peek needs a click of its own.
    var allowsKey = false {
        didSet { if !allowsKey { clickedIn = false } }
    }
    var onEscape: (() -> Void)?
    /// ⌘1 / ⌘2 while the panel is key: true when it was used (Home, Agents).
    var onCommandDigit: ((Int) -> Bool)?
    /// ⌘K while the panel is key: focuses the command line (true when used).
    var onCommandK: (() -> Bool)?
    /// A printable key no text field took, while the panel is key: starts the command line
    /// with it (true when used).
    var onTyped: ((String) -> Bool)?

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

    /// Approvals win over any modal session (C1): if a modal panel is ever up (an open
    /// panel in Settings, a v0.1 picker), the approval card still takes clicks and keys,
    /// so a request never times out behind it. Fixed: a setter cannot turn it off.
    override var worksWhenModal: Bool {
        get { true }
        set {}
    }

    /// A left click; right and other buttons never hand the panel the keyboard.
    static func isPress(_ type: NSEvent.EventType) -> Bool { type == .leftMouseDown }

    /// Every event reaches the window here before AppKit decides on key status, so a
    /// click anywhere in the content (SwiftUI or a layer-backed subview) counts. A click
    /// counts only while the mode may take the keyboard: a click on the compact pill or a
    /// notice leaves nothing behind for a later approval peek (final re-review A4).
    override func sendEvent(_ event: NSEvent) {
        if Self.isPress(event.type) { noteMouseDown() }
        super.sendEvent(event)
    }

    func noteMouseDown() {
        if allowsKey { clickedIn = true }
    }

    /// An explicit request for the keyboard (the global command shortcut, a click in the
    /// command line): as a click would. Only while the mode may take the keyboard.
    func grantKey() {
        if allowsKey { clickedIn = true }
    }

    override func resignKey() {
        super.resignKey()
        clickedIn = false
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// ⌘1 and ⌘2 with no other modifier; nil for anything else (Return is never a shortcut here).
    static func commandDigit(_ event: NSEvent) -> Int? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command,
              let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let digit = Int(chars), (1...2).contains(digit) else { return nil }
        return digit
    }

    /// ⌘K with no other modifier.
    static func isCommandK(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command,
              let chars = event.charactersIgnoringModifiers else { return false }
        return chars.lowercased() == "k"
    }

    /// The text a key types into the command line: printable, with no ⌘ or ⌃ held (⌥ and
    /// ⇧ make characters). Nil for arrows, Return, Tab, Esc and the rest.
    static func typedText(_ event: NSEvent) -> String? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .function, .numericPad]),
              let chars = event.characters, !chars.isEmpty, chars.count == 1,
              let scalar = chars.unicodeScalars.first else { return nil }
        let v = scalar.value
        // Control characters, Delete, and the private-use range arrow keys come in.
        guard v >= 0x20, v != 0x7F, !(0xF700...0xF8FF).contains(v) else { return nil }
        return chars
    }

    /// ⌘⌫ and ⌘↩ with no other modifier: an approval's Deny and Allow, and also text
    /// editing (delete to the line's start, Return) in a focused field.
    static func isApprovalKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command
        else { return false }
        return event.keyCode == 51 || event.keyCode == 36 || event.keyCode == 76   // ⌫, ↩, ⌤
    }

    /// While a text field has the keyboard, ⌘⌫ and ⌘↩ edit its text and never answer an
    /// approval: the approval shortcuts apply only with no field focused.
    static func keyBelongsToText(_ event: NSEvent, textFocused: Bool) -> Bool {
        textFocused && isApprovalKey(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A focused field takes ⌘⌫ / ⌘↩ before any approval shortcut can see them.
        if Self.keyBelongsToText(event, textFocused: firstResponder is NSText), let text = firstResponder {
            text.keyDown(with: event)
            return true
        }
        // Only while this panel has the keyboard (never a shortcut another window was sent).
        if isKeyWindow, Self.isCommandK(event), onCommandK?() == true { return true }
        if isKeyWindow, let digit = Self.commandDigit(event), onCommandDigit?(digit) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else if isKeyWindow, let text = Self.typedText(event), onTyped?(text) == true {
            return   // the command line took it (no text field had focus)
        } else {
            super.keyDown(with: event)
        }
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
