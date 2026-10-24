import PlatyNotchKit
import SwiftUI

/// Open loops from memory with Done / Dismiss. No live activity; the store is fed by the core.
@MainActor
final class LoopsWidget: NotchWidget {
    static let widgetID = "loops"

    let id = LoopsWidget.widgetID
    let title = "Open loops"
    let systemImage = "checklist"
    let defaultEnabled = true
    let store: AppStore
    let actions: LoopActions

    init(store: AppStore, actions: LoopActions) {
        self.store = store
        self.actions = actions
    }

    func tileView() -> AnyView {
        AnyView(LoopsTile(store: store, actions: actions))
    }
}

private struct LoopsTile: View {
    let store: AppStore
    let actions: LoopActions

    var body: some View {
        LoopsList(loops: store.loops, memoryEnabled: store.memory.enabled, actions: actions)
    }
}

/// The Plan 3 Today features as widgets, in their old order, then Plan 3b's.
/// `persist: false` (smoke runs) reads saved widget state but never writes it, and the
/// HUD never creates an event tap, prompts, or touches volume or brightness; Reminders never
/// touches EventKit and Weather never touches the network.
@MainActor
enum BuiltInWidgets {
    /// `clipboard`: the app keeps its instance for the menu bar's pause item (C23).
    static func register(in registry: WidgetRegistry, store: AppStore, today: TodayServices, persist: Bool = true,
                         clipboard: ClipboardWidget? = nil) {
        registry.register(MusicWidget(nowPlaying: today.nowPlaying, visualiser: today.visualiser))
        registry.register(MeetingWidget(calendar: today.calendar))
        registry.register(FocusWidget(focus: today.focus))
        registry.register(LoopsWidget(store: store, actions: today.loops))
        registry.register(TimeWidget(persist: persist))
        registry.register(persist ? HUDWidget() : HUDWidget.inert())
        registry.register(persist ? ShelfWidget() : ShelfWidget.inert())
        registry.register(clipboard ?? (persist ? ClipboardWidget() : ClipboardWidget.inert()))
        registry.register(persist ? RemindersWidget(reminders: today.reminders, calendar: today.calendar) : RemindersWidget.inert())
        registry.register(persist ? WeatherWidget() : WeatherWidget.inert())
    }
}
