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
        let panel = context.panel
        controller.hidesForFullScreen = { panel.fullScreen && AppearanceStore.load(from: d).hideInFullScreen }
        controller.start(drags: context.drags, sensitivity: sensitivity, switcher: switcherCombo)
    }

    func stop() {
        guard context != nil else { return }
        controller.stop()
        context = nil
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
}

struct BasketsSettingsView: View {
    let widget: BasketsWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("""
            While dragging a file or link, shake the pointer left and right: a basket appears \
            there to drop it into. Drag items back out of a basket whenever you need them. \
            Up to 6 baskets of 50 items each.
            """)
            .fixedSize(horizontal: false, vertical: true)
            sensitivityRow
            switcherRow
            if widget.controller.switcherTaken, let combo = widget.switcherCombo {
                Label { Text(verbatim: "\(combo.display) is taken by another app. Choose another shortcut.") }
                    icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Text("""
            Shaking while selecting text, drawing or moving a window never makes a basket. \
            A basket never covers the notch or an approval request. Drag one basket onto another \
            to merge them; right-click its title for Pin, Color, Rename, Actions, Move All to \
            Shelf and Clear.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("""
            Files you drop stay where they are. Images, text and files from apps like Photos are \
            copied into PlatyNotch's private folder. Baskets are cleared when PlatyNotch quits or \
            Baskets is turned off, deleting those copies (never your own files), unless the \
            basket or one of its items is pinned; pinned baskets come back at the next start, and \
            their copies are deleted 7 days after you added them unless pinned.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }

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
