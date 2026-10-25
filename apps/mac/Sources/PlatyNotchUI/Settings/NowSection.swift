import PlatyNotchKit
import SwiftUI

/// Settings › Now's state: the four glance slots (`GlanceSlots`) and hero cycling
/// (`NowSettings`), saved on every change.
@MainActor @Observable
final class NowSettingsModel {
    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
        /// "On", "Off" (the widget is turned off: its chip waits until it is on) or "Agents".
        let status: String
    }

    static let slotCount = GlanceSlots.limit

    /// One id (or nil, empty) per slot.
    private(set) var slots: [String?]
    private(set) var heroCycling: Bool
    @ObservationIgnored private let widgets: WidgetRegistry
    @ObservationIgnored private let defaults: UserDefaults

    init(widgets: WidgetRegistry, defaults: UserDefaults) {
        self.widgets = widgets
        self.defaults = defaults
        let saved = GlanceSlots.load(from: defaults, glanceCapable: widgets.defaultGlanceOrder)
        slots = (0..<Self.slotCount).map { $0 < saved.ids.count ? saved.ids[$0] : nil }
        heroCycling = NowSettings.load(from: defaults).heroCycling
    }

    /// Every glance a slot can hold: glance-capable widgets (on or off) and the usage glance.
    var options: [Option] {
        widgets.defaultGlanceOrder.map { id in
            if id == GlanceSlots.usageID { return Option(id: id, title: "Claude/Codex usage", status: "Agents") }
            let title: String = widgets.widget(id)?.title ?? id
            return Option(id: id, title: title, status: widgets.isEnabled(id) ? "On" : "Off")
        }
    }

    /// Puts `id` in `slot` (nil empties it). An id already in another slot swaps places
    /// with what `slot` held, so a glance is never in two slots.
    func set(slot: Int, id: String?) {
        guard slots.indices.contains(slot) else { return }
        var next = slots
        if let id, let other = next.firstIndex(of: id), other != slot { next[other] = next[slot] }
        next[slot] = id
        slots = next
        save()
    }

    /// Drag to reorder: the slot at `from` moves to `to`; the others close up around it.
    func move(from: Int, to: Int) {
        guard slots.indices.contains(from), slots.indices.contains(to), from != to else { return }
        var next = slots
        let moved = next.remove(at: from)
        next.insert(moved, at: to)
        slots = next
        save()
    }

    func setHeroCycling(_ on: Bool) {
        heroCycling = on
        NowSettings(heroCycling: on).save(to: defaults)
    }

    private func save() {
        GlanceSlots(ids: slots.compactMap { $0 }).save(to: defaults)
    }
}

/// Settings › Now: the four glances under the hero, in order (drag the handle), and
/// whether the hero steps through what is live.
struct NowSection: View {
    @State private var model: NowSettingsModel
    @State private var dragging: Int?

    init(widgets: WidgetRegistry, defaults: UserDefaults = .standard) {
        _model = State(initialValue: NowSettingsModel(widgets: widgets, defaults: defaults))
    }

    var body: some View {
        SettingsPage("Now", subtitle: "What the open notch shows first.") {
            Form {
                Section {
                    ForEach(0..<NowSettingsModel.slotCount, id: \.self) { slot in slotRow(slot) }
                } header: {
                    SettingLabel("Glances", info: "Four small chips under the hero. A glance whose widget is off, or that has nothing to show, is skipped and comes back to its place. Drag the handle to reorder.")
                }
                Section("Hero") {
                    Toggle(isOn: Binding(get: { model.heroCycling }, set: { model.setHeroCycling($0) })) {
                        SettingLabel("Step through live items",
                                     info: "With this on, the hero shows one live item at a time with ‹ › to step. Off, it shows only the most important one.")
                    }
                    .toggleStyle(.switch)
                }
            }
            .settingsForm()
        }
    }

    private func slotRow(_ slot: Int) -> some View {
        let options = model.options
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
                .help("Drag to reorder")
                .accessibilityHidden(true)
            Text(verbatim: "\(slot + 1)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(SettingsTint.accent)
                .frame(width: 20, height: 20)
                .background(SettingsTint.well, in: Circle())
                .accessibilityHidden(true)
            Picker("Glance \(slot + 1)", selection: Binding(get: { model.slots[slot] },
                                                             set: { model.set(slot: slot, id: $0) })) {
                Text("None").tag(String?.none)
                Divider()
                ForEach(options) { option in
                    Text(verbatim: option.status == "Off" ? "\(option.title) (off)" : option.title)
                        .tag(Optional(option.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(dragging == slot ? SettingsTint.well : .clear, in: RoundedRectangle(cornerRadius: 6))
        .draggable(String(slot)) {
            Text(verbatim: "Glance \(slot + 1)").padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap(Int.init) else { return false }
            model.move(from: from, to: slot)
            return true
        } isTargeted: { over in dragging = over ? slot : (dragging == slot ? nil : dragging) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Glance \(slot + 1)")
        .accessibilityAction(named: "Move up") { model.move(from: slot, to: max(slot - 1, 0)) }
        .accessibilityAction(named: "Move down") {
            model.move(from: slot, to: min(slot + 1, NowSettingsModel.slotCount - 1))
        }
    }
}
