import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// The picker's search, rows and selection, and what each key does (no window: tests use
/// it directly).
@MainActor @Observable
final class ClipPickerModel {
    enum Effect: Equatable {
        case close
        case choose(ClipItem)
    }

    private(set) var picker = ClipPicker()
    private(set) var results: [ClipItem] = []
    /// False after a link opened the picker (`platynotch://clipboard/open`): ↩ and ⌘1–9 do
    /// nothing until the user presses an arrow key or moves the mouse over it, so a page
    /// cannot open the picker and have a stray ↩ paste into the app behind it.
    private(set) var pasteArmed = true
    /// A hover counts only this long after opening (AppKit reports a stationary cursor as
    /// a hover about 100 ms after the window appears under it).
    static let hoverArmDelay: TimeInterval = 0.3
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var openedAt = Date.distantPast
    /// Where the pointer was when the picker opened (screen coordinates).
    @ObservationIgnored private var openPointer: CGPoint?
    @ObservationIgnored private unowned let widget: ClipboardWidget

    init(widget: ClipboardWidget) {
        self.widget = widget
    }

    var query: String {
        get { picker.query }
        set { picker.query = newValue; refresh() }
    }

    var selection: Int { picker.selection }

    func refresh() {
        let next = picker.results(in: widget.history)
        if next != results { results = next }
        picker.clamp(count: results.count)
    }

    /// `pointer`: where the mouse is now (a hover only arms once it has moved from there).
    func reset(armed: Bool = true, pointer: CGPoint? = nil) {
        picker = ClipPicker()
        pasteArmed = armed
        openedAt = now()
        openPointer = pointer
        refresh()
    }

    /// An arrow key: the user is here.
    func arm() {
        if !pasteArmed { pasteArmed = true }
    }

    /// The mouse over the picker, at `location` (screen coordinates). Arms only when it has
    /// moved from where it was at opening, and not before `hoverArmDelay`.
    func pointerMoved(to location: CGPoint) {
        guard !pasteArmed, now().timeIntervalSince(openedAt) >= Self.hoverArmDelay, location != openPointer else { return }
        pasteArmed = true
    }

    func select(_ index: Int) { picker.select(index, count: results.count) }

    /// Applies a key's action; returns what the window should do.
    func perform(_ action: ClipPickerAction) -> Effect? {
        switch action {
        case .up: arm(); picker.move(-1, count: results.count)
        case .down: arm(); picker.move(1, count: results.count)
        case .close: return .close
        case .paste:
            guard pasteArmed else { return nil }
            return picker.selected(in: results).map(Effect.choose)
        case .quickPick(let n):
            guard pasteArmed else { return nil }
            return ClipPicker.quickPick(n, in: results).map(Effect.choose)
        case .togglePin:
            if let item = picker.selected(in: results) { widget.togglePin(item) }
        case .delete:
            if let item = picker.selected(in: results) { widget.remove(item.id) }
        case .edit, .swallow:
            break
        }
        return nil
    }
}

/// The picker's window: a floating, non-activating panel. Non-activating, so the app the
/// user was typing in stays the active app and gets the keyboard back when it closes.
/// Its level is `.floating`, below the notch panel's `.statusBar`, so it can never cover
/// an approval card even where they overlap; it never changes the notch panel's mode.
final class ClipPickerWindow: NSPanel {
    static let size = CGSize(width: 420, height: 380)
    static let pickerLevel = NSWindow.Level.floating

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true   // sets .floating: the level is set after it
        level = Self.pickerLevel
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    /// Key only while open (it is ordered out otherwise).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Opens and closes the picker near the cursor. While it is open it takes the keyboard
/// (a local key monitor sees every key first, `ClipPickerKey`): nothing typed there, and
/// no ⌘ shortcut, reaches another window, so approval cards' ⌘↩ / ⌘⌫ can never fire from
/// the picker. Closing hands the keyboard back: to the notch panel if it had it (an
/// approval peek), otherwise to the app that was frontmost.
@MainActor
final class ClipPickerPanel {
    let model: ClipPickerModel
    private unowned let widget: ClipboardWidget
    private var window: ClipPickerWindow?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?

    init(widget: ClipboardWidget) {
        self.widget = widget
        model = ClipPickerModel(widget: widget)
    }

    var isOpen: Bool { window?.isVisible == true }

    func toggle() {
        if isOpen { close(restoreFocus: true) } else { open() }
    }

    func historyChanged() {
        if isOpen { model.refresh() }
    }

    /// `armed: false` when a link opened it (see `ClipPickerModel.pasteArmed`).
    func open(armed: Bool = true) {
        guard !isOpen else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        previousKeyWindow = NSApp.keyWindow
        model.reset(armed: armed, pointer: NSEvent.mouseLocation)
        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(Self.frame(near: NSEvent.mouseLocation, size: ClipPickerWindow.size), display: false)
        window.makeKeyAndOrderFront(nil)
        installMonitors(window)
    }

    /// `restoreFocus`: hand the keyboard back (Escape, the shortcut again). A click
    /// elsewhere already moved it, so it is not taken back.
    func close(restoreFocus: Bool) {
        removeMonitors()
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        if restoreFocus { giveBackFocus() }
    }

    private func giveBackFocus() {
        if let ours = previousKeyWindow, ours.isVisible, ours.canBecomeKey {
            ours.makeKey()
        } else if let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate()
        }
    }

    private func choose(_ item: ClipItem) {
        let ourWindowWasKey = previousKeyWindow != nil
        let target = previousApp.map { RunningAppTarget(app: $0, ourWindowWasKey: ourWindowWasKey) }
        close(restoreFocus: ourWindowWasKey)   // our own window: give it back; the app: the paster activates it
        widget.paste(item, to: target)
    }

    private func makeWindow() -> ClipPickerWindow {
        let w = ClipPickerWindow()
        let host = NSHostingView(rootView: ClipPickerView(model: model,
                                                          onChoose: { [weak self] in self?.choose($0) },
                                                          trusted: { [weak self] in self?.widget.trust.isTrusted() ?? false },
                                                          imageURL: { [weak self] in self?.widget.imageURL(for: $0) }))
        host.frame = CGRect(origin: .zero, size: ClipPickerWindow.size)
        w.contentView = host
        return w
    }

    private func installMonitors(_ window: NSWindow) {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let key = event
            let eaten = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, key.window === window || window.isKeyWindow else { return false }
                return self.handleKey(key)
            }
            return eaten ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoreFocus: false) }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// True when the key was the picker's (eaten).
    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        guard let action = ClipPickerKey.action(keyCode: event.keyCode, command: command,
                                                queryEmpty: model.query.isEmpty, isRepeat: event.isARepeat) else {
            return false
        }
        if case .edit(let selector) = action {
            NSApp.sendAction(Selector(selector), to: nil, from: nil)
            return true
        }
        switch model.perform(action) {
        case .close: close(restoreFocus: true)
        case .choose(let item): choose(item)
        case nil: break
        }
        return true
    }

    /// Below and to the right of the cursor, kept on the cursor's screen.
    static func frame(near point: CGPoint, size: CGSize, screens: [CGRect] = NSScreen.screens.map(\.visibleFrame)) -> CGRect {
        let screen = screens.first { $0.insetBy(dx: -1, dy: -1).contains(point) } ?? screens.first
            ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: point.x - 24, y: point.y - size.height - 12)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        return CGRect(origin: origin, size: size)
    }
}

/// Search field, rows, and the key hints.
struct ClipPickerView: View {
    @Bindable var model: ClipPickerModel
    let onChoose: (ClipItem) -> Void
    let trusted: () -> Bool
    let imageURL: (ClipItem) -> URL?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
            }
            .padding(10)
            Divider()
            if model.results.isEmpty {
                Text(model.query.isEmpty ? "Nothing copied yet." : "No matches.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index)
                                    .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selection) { _, i in
                        if model.results.indices.contains(i) { proxy.scrollTo(model.results[i].id) }
                    }
                }
            }
            Divider()
            Text(trusted() ? "↩ paste   ⌘1–9 pick   ⌘P pin   ⌫ delete   esc close"
                           : "↩ copy (paste needs Accessibility, see Settings)   ⌘P pin   ⌫ delete   esc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: ClipPickerWindow.size.width, height: ClipPickerWindow.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .onAppear { searchFocused = true }
        .onContinuousHover { phase in
            // Screen coordinates, compared with where the pointer was at opening.
            if case .active = phase { model.pointerMoved(to: NSEvent.mouseLocation) }
        }
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        HStack(spacing: 6) {
            ClipRow(item: item, imageURL: imageURL(item))
            if index < ClipPicker.quickPickCount {
                Text("⌘\(index + 1)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(index == model.selection ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onChoose(item) }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onChoose(item) }
    }
}
