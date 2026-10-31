import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Baskets (v0.2 Task 1): a power feature with no tile, off by default. While a file is
/// being dragged, shake the pointer and a basket appears there to drop it into
/// (`BasketController`). No permission (mouse-button monitors and a Carbon shortcut need
/// none), no network. Items live in `baskets.noindex/<basket id>/` (0700); unpinned baskets
/// are cleared at quit or when turned off.
@MainActor @Observable
final class BasketsWidget: NotchWidget {
    static let widgetID = "baskets"

    let id = BasketsWidget.widgetID
    let title = "Baskets"
    let systemImage = "basket"
    let defaultEnabled = false
    let hasTile = false
    let category: WidgetCategory = .power

    private(set) var sensitivity = ShakeDetector.defaultSensitivity
    private(set) var switcherCombo: KeyCombo? = BasketSettings.switcherPresets[0]

    @ObservationIgnored let controller: BasketController
    @ObservationIgnored private var context: WidgetContext?
    /// The shelf while it runs (Move to Shelf).
    @ObservationIgnored private var shelf: @MainActor () -> ShelfWidget? = { nil }

    init(directory: URL = CorePaths.baskets(), persist: Bool = true, system: BasketSystem? = nil,
         makeHotKey: @escaping HotKeyMaker = HotKey.make) {
        let store = BasketStore(directory: directory, persist: persist)
        let sys = system ?? SystemBasketSystem(appearance: { AppearanceStore.load(from: .standard) })
        controller = BasketController(store: store, system: sys, makeHotKey: makeHotKey)
    }

    /// Smoke runs: nothing read or written, no windows, observers or shortcut.
    static func inert() -> BasketsWidget {
        BasketsWidget(persist: false, system: NoBasketSystem(), makeHotKey: { _, _, _ in nil })
    }

    /// The shelf (Move to Shelf, its own drags never summon) and File actions (every
    /// basket's "Actions ›"), wired by `BuiltInWidgets`.
    func connect(shelf: @escaping @MainActor () -> ShelfWidget?, fileActionsOn: @escaping @MainActor () -> Bool) {
        self.shelf = shelf
        let store = controller.store
        store.shelf = { [weak self] in self?.shelf()?.transferTarget }
        store.shelfChanged = { [weak self] in self?.shelf()?.itemsArrived() }
        controller.fileActionsOn = fileActionsOn
        controller.shelfOutgoing = { [weak self] in self?.shelf()?.outgoingDrag ?? false }
    }

    var isRunning: Bool { context != nil }

    func start(context: WidgetContext) {
        guard self.context == nil else { return }
        self.context = context
        let d = context.defaults
        sensitivity = BasketSettings.sensitivity(d)
        switcherCombo = BasketSettings.switcherCombo(d)
        controller.store.defaults = d
        controller.hotKeyCatalog = context.hotKeys
        let surfaces = context.surfaces
        controller.coveredDisplays = {
            AppearanceStore.load(from: d).hideInFullScreen ? surfaces.fullScreenDisplays : []
        }
        // Pushed by the panels when a display's full-screen state changes (no polling).
        surfaces.onFullScreenChange(owner: self) { [weak self] _ in self?.controller.fullScreenChanged() }
        controller.start(drags: context.drags, sensitivity: sensitivity, switcher: switcherCombo)
        damagedCount = controller.store.damagedCount
    }

    func stop() {
        guard let context else { return }
        context.surfaces.onFullScreenChange(owner: self, nil)
        controller.stop()
        self.context = nil
    }

    /// Basket folders with a damaged index (kept, nothing deleted): Settings shows them.
    private(set) var damagedCount = 0

    /// Settings › "Delete Kept Copies", after its confirming click.
    func deleteDamaged() {
        controller.store.deleteDamaged()
        damagedCount = controller.store.damagedCount
    }

    func setSensitivity(_ value: Int) {
        guard let d = context?.defaults else { return }
        BasketSettings.setSensitivity(value, d)
        sensitivity = BasketSettings.sensitivity(d)
        controller.setSensitivity(sensitivity)
    }

    func setSwitcherCombo(_ combo: KeyCombo?) {
        guard let d = context?.defaults else { return }
        BasketSettings.setSwitcherCombo(combo, d)
        switcherCombo = BasketSettings.switcherCombo(d)
        controller.setSwitcher(switcherCombo)
    }

    func tileView() -> AnyView { AnyView(EmptyView()) }

    func settingsView() -> AnyView? { AnyView(BasketsSettingsView(widget: self)) }

    /// Full-panel in the Library: a composed page, not the settings text.
    func toolView() -> AnyView { AnyView(BasketsToolPage(widget: self)) }
}

/// Baskets as a Library tool: what it does in one line, its two controls on one card,
/// and the rules a tooltip away. No accent colour; a taken shortcut is a plain note.
struct BasketsToolPage: View {
    let widget: BasketsWidget

    static let detail = "Drag a file or link and shake the pointer: a basket appears there to drop it into."

    var body: some View {
        ToolIconPage(systemImage: "basket", title: "Shake while dragging", detail: Self.detail) {
            VStack(spacing: Space.s) {
                ToolControlCard {
                    row("Shake sensitivity") {
                        Picker("Shake sensitivity",
                               selection: Binding(get: { widget.sensitivity }, set: { widget.setSensitivity($0) })) {
                            ForEach(Array(ShakeDetector.sensitivityRange), id: \.self) { v in
                                Text(verbatim: BasketsSettingsView.sensitivityName(v)).tag(v)
                            }
                        }
                    }
                    Divider().opacity(0.5)
                    row("Switch baskets") {
                        Picker("Switch baskets",
                               selection: Binding(get: { widget.switcherCombo }, set: { widget.setSwitcherCombo($0) })) {
                            ForEach(BasketSettings.switcherPresets, id: \.self) { c in
                                Text(verbatim: c.display).tag(Optional(c))
                            }
                            Text("Off").tag(KeyCombo?.none)
                        }
                    }
                }
                if widget.controller.switcherTaken, let combo = widget.switcherCombo {
                    Label {
                        Text(verbatim: BasketsSettingsView.takenNote(combo, usedBy: widget.controller.switcherUsedBy))
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360, alignment: .leading)
                }
                Text("Up to 6 baskets of 50 items. Cleared at quit unless pinned.")
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.secondary)
                    .help("""
                    Files you drop stay where they are; images and text are copied into PlatyNotch's \
                    private folder and deleted with the basket. Pinned baskets come back at the next start.
                    """)
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(verbatim: title).font(DS.font(TypeScale.body))
            Spacer(minLength: Space.s)
            control()
                .labelsHidden()
                .fixedSize()
        }
        .frame(height: 24)
    }
}

struct BasketsSettingsView: View {
    let widget: BasketsWidget

    /// Why the switcher's shortcut is not held: another app, or a named PlatyNotch feature.
    static func takenNote(_ combo: KeyCombo, usedBy owner: String?) -> String {
        if let owner { return "\(combo.display) is used by \(owner) in PlatyNotch. Choose another shortcut." }
        return "\(combo.display) is taken by another app. Choose another shortcut."
    }

    /// What Baskets does and promises, behind the ⓘ (controls first).
    static let about = """
    While dragging a file or link, shake the pointer left and right: a basket appears there to drop it into. \
    Drag items back out whenever you need them. Up to 6 baskets of 50 items each. Shaking while selecting text, \
    drawing or moving a window never makes a basket, and a basket never covers the notch or an approval. Drag \
    one basket onto another to merge them; right-click its title for Pin, Color, Rename, Actions, Move All to \
    Shelf and Clear.
    """

    static let privacy = """
    Files you drop stay where they are. Images, text and files from apps like Photos are copied into \
    PlatyNotch's private folder. Baskets are cleared when PlatyNotch quits or Baskets is turned off, deleting \
    those copies (never your own files), unless the basket or one of its items is pinned; pinned baskets come \
    back at the next start, and their copies are deleted 7 days after you added them unless pinned.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sensitivityRow
            switcherRow
            if widget.controller.switcherTaken, let combo = widget.switcherCombo {
                Label { Text(verbatim: Self.takenNote(combo, usedBy: widget.controller.switcherUsedBy)) }
                    icon: { Image(systemName: "info.circle") }
                    .foregroundStyle(.secondary)
            }
            damagedRow
        }
        .font(.system(size: 12))
        // Behind the page's one ⓘ (Settings › Widgets › Baskets), taking no row of their own.
        .background {
            SettingsNote(Self.about)
            SettingsNote(Self.privacy)
        }
    }

    /// Damaged basket indexes: the count, then Delete Kept Copies, then a confirming click.
    @ViewBuilder private var damagedRow: some View {
        if widget.damagedCount > 0 {
            let n = widget.damagedCount
            Text("""
            \(n == 1 ? "A basket's list was" : "\(n) baskets' lists were") damaged and set aside with the \
            copies they may have listed, so nothing was deleted.
            """)
            .foregroundStyle(Theme.color(.attention))
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(verbatim: n == 1 ? "1 kept" : "\(n) kept").foregroundStyle(.secondary)
                Button("Show in Finder") { NSWorkspace.shared.open(widget.controller.store.directory) }
                if confirmingDelete {
                    Button("Delete \(n == 1 ? "It" : "Them")", role: .destructive) {
                        widget.deleteDamaged()
                        confirmingDelete = false
                    }
                    Button("Cancel") { confirmingDelete = false }
                } else {
                    Button("Delete Kept Copies…") { confirmingDelete = true }
                        .help("Deletes the set-aside lists and the copies no basket item lists")
                }
            }
        }
    }

    @State private var confirmingDelete = false

    // Split out of `body` (type-check time).
    private var sensitivityRow: some View {
        HStack {
            Text("Shake sensitivity")
            Picker("Shake sensitivity", selection: Binding(get: { widget.sensitivity }, set: { widget.setSensitivity($0) })) {
                ForEach(Array(ShakeDetector.sensitivityRange), id: \.self) { v in
                    Text(verbatim: Self.sensitivityName(v)).tag(v)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
        }
    }

    private var switcherRow: some View {
        HStack {
            Text("Switch baskets")
            Picker("Switch baskets", selection: Binding(get: { widget.switcherCombo }, set: { widget.setSwitcherCombo($0) })) {
                ForEach(BasketSettings.switcherPresets, id: \.self) { c in
                    Text(verbatim: c.display).tag(Optional(c))
                }
                Text("Off").tag(KeyCombo?.none)
            }
            .labelsHidden()
            .frame(maxWidth: 120)
        }
    }

    static func sensitivityName(_ v: Int) -> String {
        let reversals = ShakeDetector.threshold(sensitivity: v)
        let word = switch v {
        case 1: "Lowest"
        case 2: "Low"
        case 3: "Standard"
        case 4: "High"
        default: "Highest"
        }
        return "\(word) (\(reversals) shakes)"
    }
}
