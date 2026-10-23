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

/// The four Plan 3 Today features as widgets, in their old order.
@MainActor
enum BuiltInWidgets {
    static func register(in registry: WidgetRegistry, store: AppStore, today: TodayServices) {
        registry.register(MusicWidget(nowPlaying: today.nowPlaying))
        registry.register(MeetingWidget(calendar: today.calendar))
        registry.register(FocusWidget(focus: today.focus))
        registry.register(LoopsWidget(store: store, actions: today.loops))
    }
}
