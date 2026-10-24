import AppKit
import PlatyNotchKit
import SwiftUI

/// The switcher's strip (a seam: tests record what it shows).
@MainActor
protocol BasketSwitcherShowing: AnyObject {
    func show(_ baskets: [(name: String, color: BasketColor)], selected: Int, screens: [BasketScreen])
    func hide()
}

/// The strip the switcher shortcut shows for a moment, like ⌘Tab: every basket's color and
/// name, the one brought forward highlighted. Never key, never activates, at `.floating`,
/// and placed by `BasketPlacement` (never over the notch panel or the approval card).
@MainActor
final class BasketSwitcherPanel: NSPanel, BasketSwitcherShowing {
    private let model = BasketSwitcherModel()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: BasketSwitcherView(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ baskets: [(name: String, color: BasketColor)], selected: Int, screens: [BasketScreen]) {
        model.entries = baskets.enumerated().map { BasketSwitcherModel.Entry(id: $0.offset, name: $0.element.name, color: $0.element.color) }
        model.selected = selected
        let size = CGSize(width: CGFloat(max(baskets.count, 1)) * 96 + 16, height: 64)
        // The lower third of the display under the pointer, clear of the panel.
        let p = NSEvent.mouseLocation
        let screen = screens.first { $0.visibleFrame.contains(p) } ?? screens.first
        guard let screen else { return }
        let v = screen.visibleFrame
        let wanted = CGRect(x: v.midX - size.width / 2, y: v.minY + v.height / 3 - size.height / 2,
                            width: size.width, height: size.height)
        guard let f = BasketPlacement.clamp(wanted, screens: [screen]) else { return }
        setFrame(f, display: true)
        orderFrontRegardless()
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: baskets[safe: selected]?.name ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func hide() { orderOut(nil) }
}

@MainActor @Observable
final class BasketSwitcherModel {
    struct Entry: Identifiable {
        let id: Int
        let name: String
        let color: BasketColor
    }

    var entries: [Entry] = []
    var selected = 0
}

struct BasketSwitcherView: View {
    let model: BasketSwitcherModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.entries) { e in chip(e) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
    }

    private func chip(_ e: BasketSwitcherModel.Entry) -> some View {
        let on = e.id == model.selected
        return VStack(spacing: 4) {
            Image(systemName: "basket.fill").font(.system(size: 18)).foregroundStyle(BasketPalette.color(e.color))
            Text(verbatim: e.name).font(.system(size: 10, weight: on ? .semibold : .regular)).lineLimit(1)
        }
        .frame(width: 88, height: 48)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(on ? 0.15 : 0)))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The real system: NSScreen and the notch layout, NSWorkspace and screen notifications,
/// NSAlert, and real windows.
@MainActor
final class SystemBasketSystem: BasketSystem {
    /// Appearance (pill width) for the notch layout on each display.
    private let appearance: @MainActor () -> AppearanceSettings

    init(appearance: @escaping @MainActor () -> AppearanceSettings) {
        self.appearance = appearance
    }

    func screens() -> [BasketScreen] {
        let width = appearance().pillWidth
        return NSScreen.screens.map { s in
            let layout = PanelLayout(screenFrame: s.frame, visibleFrame: s.visibleFrame,
                                     auxLeft: s.auxiliaryTopLeftArea, auxRight: s.auxiliaryTopRightArea, pillWidth: width)
            return BasketScreen(visibleFrame: s.visibleFrame, layout: layout)
        }
    }

    var pointer: CGPoint { NSEvent.mouseLocation }

    func observe(_ changed: @escaping @MainActor () -> Void) -> () -> Void {
        let ws = NSWorkspace.shared.notificationCenter
        let handler: @Sendable (Notification) -> Void = { _ in MainActor.assumeIsolated { changed() } }
        let tokens: [(NotificationCenter, NSObjectProtocol)] = [
            (ws, ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: handler)),
            (ws, ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: handler)),
            (.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil, queue: .main, using: handler)),
        ]
        return { for (center, token) in tokens { center.removeObserver(token) } }
    }

    func beep() { NSSound.beep() }

    func confirmClose(name: String, count: Int, canMoveToShelf: Bool) -> BasketCloseChoice {
        let alert = NSAlert()
        alert.messageText = "Close “\(name)”?"
        let items = count == 1 ? "1 item" : "\(count) items"
        alert.informativeText = canMoveToShelf
            ? "It holds \(items). Move them to the Shelf, or discard them: copies the basket made are deleted, your own files never are."
            : "It holds \(items). Discarding deletes the copies the basket made; your own files never are. Turn on the Shelf to move them there instead."
        if canMoveToShelf { alert.addButton(withTitle: "Move to Shelf") }
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()   // user-initiated: the alert needs the keyboard
        let r = alert.runModal()
        let buttons: [BasketCloseChoice] = canMoveToShelf ? [.moveToShelf, .discard, .cancel] : [.discard, .cancel]
        let i = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return buttons.indices.contains(i) ? buttons[i] : .cancel
    }

    func askName(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Basket"
        let field = NSTextField(string: current)
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func makeWindow(host: BasketHost, frame: CGRect) -> BasketWindowing { BasketPanel(host: host, frame: frame) }

    func makeSwitcher() -> BasketSwitcherShowing { BasketSwitcherPanel() }
}

/// Smoke runs: no display, no observers, no windows, no sound.
@MainActor
final class NoBasketSystem: BasketSystem {
    func screens() -> [BasketScreen] { [] }
    var pointer: CGPoint { .zero }
    func observe(_ changed: @escaping @MainActor () -> Void) -> () -> Void { {} }
    func beep() {}
    func confirmClose(name: String, count: Int, canMoveToShelf: Bool) -> BasketCloseChoice { .cancel }
    func askName(current: String) -> String? { nil }
    func makeWindow(host: BasketHost, frame: CGRect) -> BasketWindowing { NoBasketWindow(frame: frame) }
    func makeSwitcher() -> BasketSwitcherShowing { NoBasketSwitcher() }
}

@MainActor
final class NoBasketWindow: BasketWindowing {
    private(set) var frame: CGRect
    init(frame: CGRect) { self.frame = frame }
    func place(_ frame: CGRect) { self.frame = frame }
    func show() {}
    func hide() {}
    func close() {}
}

@MainActor
final class NoBasketSwitcher: BasketSwitcherShowing {
    func show(_ baskets: [(name: String, color: BasketColor)], selected: Int, screens: [BasketScreen]) {}
    func hide() {}
}
