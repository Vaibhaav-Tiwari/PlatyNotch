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
        .background(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous).fill(.regularMaterial))
    }

    private func chip(_ e: BasketSwitcherModel.Entry) -> some View {
        let on = e.id == model.selected
        return VStack(spacing: 4) {
            Image(systemName: "basket.fill").font(.system(size: 18)).foregroundStyle(BasketPalette.color(e.color))
            Text(verbatim: e.name).font(DS.font(TypeScale.caption).weight(on ? .semibold : .regular)).lineLimit(1)
        }
        .frame(width: 88, height: 48)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color.primary.opacity(on ? 0.15 : 0)))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The real system: NSScreen and the notch layout, the display-change notification, the
/// rename field and real windows. Never a modal session, and the app is never activated.
@MainActor
final class SystemBasketSystem: BasketSystem {
    /// Appearance (pill width) for the notch layout on each display.
    private let appearance: @MainActor () -> AppearanceSettings

    init(appearance: @escaping @MainActor () -> AppearanceSettings) {
        self.appearance = appearance
    }

    func screens() -> [BasketScreen] { Self.screens(pillWidth: appearance().pillWidth) }

    /// Every display with its notch panel's region, for any floating window that must stay
    /// clear of it (baskets, Batch rename).
    static func screens(pillWidth width: AppearanceSettings.PillWidth) -> [BasketScreen] {
        NSScreen.screens.map { s in
            let layout = PanelLayout(screenFrame: s.frame, visibleFrame: s.visibleFrame,
                                     auxLeft: s.auxiliaryTopLeftArea, auxRight: s.auxiliaryTopRightArea, pillWidth: width)
            return BasketScreen(visibleFrame: s.visibleFrame, layout: layout, displayID: s.displayID)
        }
    }

    var pointer: CGPoint { NSEvent.mouseLocation }

    func observe(_ changed: @escaping @MainActor () -> Void) -> () -> Void {
        let token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changed() }
        }
        return { NotificationCenter.default.removeObserver(token) }
    }

    func beep() { NSSound.beep() }

    /// One rename field at a time.
    private var rename: BasketRenamePanel?

    func askName(current: String, near: CGRect, done: @escaping @MainActor (String?) -> Void) {
        rename?.finish(nil)
        let size = BasketRenamePanel.size
        let wanted = CGRect(x: near.minX, y: near.minY - size.height - BasketPlacement.margin,
                            width: size.width, height: size.height)
        guard let frame = BasketPlacement.clamp(wanted, screens: screens()) else { return done(nil) }
        let panel = BasketRenamePanel(name: current, frame: frame) { [weak self] name in
            self?.rename = nil
            done(name)
        }
        rename = panel
        panel.present()
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
    func askName(current: String, near: CGRect, done: @escaping @MainActor (String?) -> Void) { done(nil) }
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

/// Rename…: a small field beside its basket. Not modal and it does not activate the app:
/// a non-activating panel that becomes key only to take the typing, placed by
/// `BasketPlacement` (never over the notch panel or the approval card, which stays
/// clickable). Return renames; Escape, Cancel or clicking elsewhere cancels.
@MainActor
final class BasketRenamePanel: NSPanel {
    static let size = CGSize(width: 260, height: 64)
    private var done: (@MainActor (String?) -> Void)?
    private let field: NSTextField

    init(name: String, frame: CGRect, done: @escaping @MainActor (String?) -> Void) {
        self.done = done
        field = NSTextField(string: name)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        let box = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        box.material = .popover
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        field.frame = CGRect(x: 10, y: 32, width: frame.width - 20, height: 22)
        field.target = self
        field.action = #selector(commit)
        field.setAccessibilityLabel("Basket name")
        let rename = NSButton(title: "Rename", target: self, action: #selector(commit))
        rename.keyEquivalent = "\r"
        rename.frame = CGRect(x: frame.width - 90, y: 4, width: 80, height: 24)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRename))
        cancel.frame = CGRect(x: frame.width - 172, y: 4, width: 80, height: 24)
        for v in [field, rename, cancel] as [NSView] { box.addSubview(v) }
        contentView = box
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        makeKeyAndOrderFront(nil)   // a non-activating panel: the app stays in the background
        makeFirstResponder(field)
    }

    @objc private func commit() { finish(field.stringValue) }
    @objc private func cancelRename() { finish(nil) }
    override func cancelOperation(_ sender: Any?) { finish(nil) }

    override func resignKey() {
        super.resignKey()
        finish(nil)
    }

    func finish(_ name: String?) {
        guard let done else { return }
        self.done = nil
        orderOut(nil)
        done(name)
    }
}
