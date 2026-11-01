import PlatyNotchKit
import SwiftUI

/// Settings › Dock's state (Island spec 6): the saved slots, every tool that can sit in the
/// dock, and the fold switch. Every change saves at once; the panel reads it when it next draws.
@MainActor @Observable
final class DockSettingsModel {
    /// One tool that can sit in the dock.
    struct Choice: Equatable {
        let slot: DockSlot
        let title: String
        let symbol: String
        /// The widgets that make it available; empty: always available.
        let widgetIDs: [String]
    }

    static let full = "The dock holds \(DockLayout.maxSlots)."

    private(set) var layout: DockLayout
    private(set) var folded: Bool
    /// The refusal under the list ("The dock holds 8."); nil otherwise.
    private(set) var message: String?
    @ObservationIgnored private let widgets: WidgetRegistry
    @ObservationIgnored private let defaults: UserDefaults

    init(widgets: WidgetRegistry, defaults: UserDefaults) {
        self.widgets = widgets
        self.defaults = defaults
        layout = DockLayout.load(from: defaults)
        folded = IslandPrefs.load(from: defaults).dockFolded
    }

    /// The core tools in their order, then every other tool widget (Baskets, Mail, a plug-in's).
    var choices: [Choice] {
        let core: [Choice] = DockTool.allCases.map { t in
            Choice(slot: .core(t), title: t.title, symbol: t.symbol, widgetIDs: t.widgetIDs)
        }
        let taken: Set<String> = Set(DockTool.allCases.flatMap(\.widgetIDs))
        let others: [Choice] = widgets.widgets
            .filter { $0.kind.contains(.tool) && !taken.contains($0.id) }
            .map { Choice(slot: .tool($0.id), title: $0.title, symbol: $0.systemImage, widgetIDs: [$0.id]) }
        return core + others
    }

    func choice(_ slot: DockSlot) -> Choice? { choices.first { $0.slot == slot } }

    /// Drag to reorder.
    func move(from: IndexSet, to: Int) {
        layout.move(fromOffsets: from, toOffset: to)
        save()
    }

    /// A checkbox: adds before Search (refused past 8), or removes (never Search). Picking a
    /// tool whose widget is off turns the widget on.
    func set(_ slot: DockSlot, on: Bool) {
        if on {
            guard !layout.slots.contains(slot) else { return }
            guard layout.add(slot) else {
                message = Self.full
                return
            }
            if let ids = choice(slot)?.widgetIDs, !ids.isEmpty, !ids.contains(where: { widgets.isEnabled($0) }),
               let id = ids.first(where: { widgets.widget($0) != nil }) {
                widgets.setEnabled(id, true)
            }
        } else {
            guard layout.remove(slot) else { return }
        }
        message = nil
        save()
    }

    /// "Fold the dock into Search" (Minimal's switch).
    func setFolded(_ on: Bool) {
        folded = on
        var prefs = IslandPrefs.load(from: defaults)
        prefs.dockFolded = on
        prefs.save(to: defaults)
    }

    private func save() { layout.save(to: defaults) }
}

/// Settings › Dock (Island spec 6): the slots in order (drag to reorder), a checkbox per
/// tool, "N of 8", and the fold switch. Search moves but cannot be removed.
struct DockSection: View {
    @State private var model: DockSettingsModel

    init(widgets: WidgetRegistry, defaults: UserDefaults = .standard) {
        _model = State(initialValue: DockSettingsModel(widgets: widgets, defaults: defaults))
    }

    /// A list row's height (the list is as tall as its rows; the form scrolls).
    static let rowHeight: CGFloat = 24

    /// "6 of 8".
    static func counter(_ l: DockLayout) -> String { "\(l.slots.count) of \(DockLayout.maxSlots)" }

    /// Search's checkbox is disabled; every other one toggles.
    static func canToggle(_ slot: DockSlot, in _: DockLayout) -> Bool { slot != .core(.search) }

    var body: some View {
        SettingsPage("Dock", subtitle: "The round tools under Now Playing and Today.") {
            Form {
                Section {
                    List {
                        ForEach(model.layout.slots, id: \.self) { slot in
                            slotRow(slot)
                        }
                        .onMove { model.move(from: $0, to: $1) }
                    }
                    .frame(height: CGFloat(model.layout.slots.count) * Self.rowHeight + 4)
                    .scrollDisabled(true)
                } header: {
                    HStack {
                        SettingLabel("In the dock", info: "Drag to change the order. Search can move but stays in the dock.")
                        Spacer()
                        Text(verbatim: Self.counter(model.layout))
                            .font(DS.font(TypeScale.caption)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(model.choices, id: \.slot) { c in
                        Toggle(isOn: Binding(get: { model.layout.slots.contains(c.slot) },
                                             set: { model.set(c.slot, on: $0) })) {
                            ToolLabel(title: c.title, symbol: c.symbol)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!Self.canToggle(c.slot, in: model.layout))
                    }
                    if let message = model.message {
                        Text(verbatim: message).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                    }
                } header: {
                    SettingLabel("Tools", info: "Up to 8, Search included. Picking a tool whose widget is off turns the widget on.")
                }
                Section {
                    Toggle(isOn: Binding(get: { model.folded }, set: { model.setFolded($0) })) {
                        SettingLabel("Fold the dock into Search",
                                     info: "Home shows one Search button, All tools, instead of the row of tools.")
                    }
                    .toggleStyle(.switch)
                }
            }
            .settingsForm()
        }
    }

    private func slotRow(_ slot: DockSlot) -> some View {
        let c = model.choice(slot)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            ToolLabel(title: c?.title ?? slot.toolID, symbol: c?.symbol ?? "square.dashed")
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A tool's symbol in a fixed column, then its name, so the names line up.
private struct ToolLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 20)
            Text(verbatim: title)
        }
    }
}
