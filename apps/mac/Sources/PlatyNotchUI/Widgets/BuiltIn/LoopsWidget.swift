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

    var kind: WidgetKind { [.glance, .tool] }

    /// Open loops from memory, less those just marked done or dismissed.
    var openCount: Int { LoopsFormat.open(store.loops).filter { !actions.hidden.contains($0.id) }.count }

    var hasContent: Bool { openCount > 0 }

    func glanceView() -> AnyView? {
        AnyView(GlanceChip(systemImage: systemImage, value: "\(openCount)", label: "Open loops"))
    }

    func tileView() -> AnyView {
        AnyView(LoopsTile(store: store, actions: actions))
    }

    /// The Library tool: how many are open, large, above the list; a calm empty state at none.
    func toolView() -> AnyView {
        let store = self.store
        let actions = self.actions
        return AnyView(LoopsTool(store: store, actions: actions, open: { [weak self] in self?.openCount ?? 0 }))
    }
}

/// Open loops full-panel.
private struct LoopsTool: View {
    let store: AppStore
    let actions: LoopActions
    let open: () -> Int

    var body: some View {
        let n: Int = open()
        if n == 0 {
            ToolEmptyState(systemImage: "checklist", title: "No open loops",
                           detail: "Promises and follow-ups from what you write show here, to tick off or dismiss.")
        } else {
            ToolPage(value: "\(n)", label: n == 1 ? "open loop" : "open loops") {
                LoopsList(loops: store.loops, memoryEnabled: store.memory.enabled, actions: actions)
            }
        }
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
    /// "In a meeting" for the wellbeing nudges: the meeting widget's state, only while it
    /// runs (`MeetingWidget.inMeeting` holds only with calendar access). Never asks for access.
    static func meetingSignal(registry: WidgetRegistry, meeting: MeetingWidget) -> () -> Bool {
        { [weak registry, weak meeting] in
            guard let registry, let meeting, registry.running.contains(MeetingWidget.widgetID) else { return false }
            return meeting.inMeeting
        }
    }

    /// `clipboard`: the app keeps its instance for the menu bar's pause item (C23).
    static func register(in registry: WidgetRegistry, store: AppStore, today: TodayServices, persist: Bool = true,
                         clipboard: ClipboardWidget? = nil) {
        registry.register(MusicWidget(nowPlaying: today.nowPlaying, visualiser: today.visualiser))
        let meeting = MeetingWidget(calendar: today.calendar)
        registry.register(meeting)
        registry.register(FocusWidget(focus: today.focus))
        registry.register(LoopsWidget(store: store, actions: today.loops))
        let time: any NotchWidget = TimeWidget(persist: persist)
        registry.register(time)
        registry.register(persist ? HUDWidget() : HUDWidget.inert())
        let shelf = persist ? ShelfWidget() : ShelfWidget.inert()
        // Shelf items get "Actions ›" only while the File actions power feature runs.
        shelf.fileActionsOn = { [weak registry] in registry?.running.contains(FileActionsWidget.widgetID) ?? false }
        registry.register(shelf)
        registry.register(clipboard ?? (persist ? ClipboardWidget() : ClipboardWidget.inert()))
        registry.register(persist ? RemindersWidget(reminders: today.reminders, calendar: today.calendar) : RemindersWidget.inert())
        registry.register(persist ? WeatherWidget() : WeatherWidget.inert())
        // Off by default. "In a meeting" only from the meeting widget while it runs with
        // calendar access; wellbeing never asks for calendar access itself.
        registry.register(persist ? WellbeingWidget(inMeeting: meetingSignal(registry: registry, meeting: meeting))
                                  : WellbeingWidget.inert())
        // On by default with battery and keep-awake only (no permission); headphones and
        // downloads stay off until turned on in its settings. Smoke: no IOKit at all.
        // "Add to Shelf" only while the shelf runs.
        let toShelf: @MainActor () -> (@MainActor (URL) -> Bool)? = { [weak registry, weak shelf] in
            guard let registry, let shelf, registry.running.contains(ShelfWidget.widgetID) else { return nil }
            return { shelf.addFile($0) }
        }
        registry.register(persist ? SystemWidget(downloads: .system(shelf: toShelf)) : SystemWidget.inert())
        // On by default; does nothing until a game is played. Smoke: scores never saved.
        let games = persist ? GamesWidget() : GamesWidget.inert()
        // A new best: Platy celebrates for a few seconds (Task 13 ruling).
        let platy = today.platy
        games.onNewBest = { [weak platy] _ in platy?.celebrate() }
        registry.register(games)
        // On by default; no network, process or script until something is pinned or
        // clicked. Smoke: no icons fetched, no Shortcuts, no Apple Events, nothing saved.
        registry.register(persist ? LaunchWidget() : LaunchWidget.inert())
        // v0.2 power features (Settings › Widgets › Power features), after the everyday ones.
        for w in powerWidgets(persist: persist) { registry.register(w) }
        // Baskets: Move to Shelf only while the shelf runs; Actions only while File actions runs.
        (registry.widget(BasketsWidget.widgetID) as? BasketsWidget)?.connect(
            shelf: { [weak registry, weak shelf] in
                guard let registry, let shelf, registry.running.contains(ShelfWidget.widgetID) else { return nil }
                return shelf
            },
            fileActionsOn: { [weak registry] in registry?.running.contains(FileActionsWidget.widgetID) ?? false })
    }

    /// Every power feature (`WidgetCategory.power`); `persist: false` gives inert ones
    /// (no monitors, permissions, files or network), as `--smoke-power` checks.
    static func powerWidgets(persist: Bool) -> [any NotchWidget] {
        var list: [any NotchWidget] = []
        // File actions has no state of its own: the same instance is inert.
        list.append(FileActionsWidget())
        // Window snapping: shortcuts only while on and Accessibility is allowed.
        list.append(persist ? WindowSnapWidget() : WindowSnapWidget.inert())
        // Camera only after a click in its tile; never in smoke runs.
        list.append(persist ? MirrorWidget() : MirrorWidget.inert())
        // Mail only while it is running; never in smoke runs (no process, no Apple Event).
        list.append(persist ? MailWidget() : MailWidget.inert())
        // Quick notes and Obsidian tasks: no vault, watch or file until set up in its settings.
        list.append(persist ? NotesWidget() : NotesWidget.inert())
        // Baskets: drag monitor, shortcut and windows only while on; never in smoke runs.
        list.append(persist ? BasketsWidget() : BasketsWidget.inert())
        return list
    }
}
