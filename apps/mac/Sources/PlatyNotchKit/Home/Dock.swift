import Foundation

/// The dock's core tools (Island spec 3.3): eight round buttons, Search last.
public enum DockTool: String, Codable, CaseIterable, Sendable {
    case timer, note, remind, clipboard, shelf, memory, games, search

    public var title: String {
        switch self {
        case .timer: "Timer"
        case .note: "Note"
        case .remind: "Remind"
        case .clipboard: "Clipboard"
        case .shelf: "Shelf"
        case .memory: "Memory"
        case .games: "Games"
        case .search: "Search"
        }
    }

    /// A monochrome SF Symbol.
    public var symbol: String {
        switch self {
        case .timer: "timer"
        case .note: "note.text"
        case .remind: "checklist"
        case .clipboard: "doc.on.clipboard"
        case .shelf: "tray"
        case .memory: "brain"
        case .games: "gamecontroller"
        case .search: "magnifyingglass"
        }
    }

    /// The widgets that make the tool available (any one of them); none: always available.
    public var widgetIDs: [String] {
        switch self {
        case .timer: ["time", "focus"]
        case .note: ["notes"]
        case .remind: ["reminders"]
        case .clipboard: ["clipboard"]
        case .shelf: ["shelf"]
        case .memory, .search: []
        case .games: ["games"]
        }
    }

    /// The tool the slot opens inside Home (`PanelRoute.tool`).
    public var toolID: String {
        switch self {
        case .timer: PanelTools.timer
        case .note: "notes"
        case .remind: "reminders"
        case .clipboard: "clipboard"
        case .shelf: "shelf"
        case .memory: PanelTools.memory
        case .games: "games"
        case .search: PanelTools.search
        }
    }
}

/// One dock slot: a core tool, or another panel tool by its tool id (Baskets, Mail, a
/// plugin tab). Encoded as `"timer"` or `"tool:baskets"`.
public enum DockSlot: Hashable, Codable, Sendable {
    case core(DockTool)
    case tool(String)

    private static let toolPrefix = "tool:"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix(Self.toolPrefix) {
            self = .tool(String(raw.dropFirst(Self.toolPrefix.count)))
        } else if let t = DockTool(rawValue: raw) {
            self = .core(t)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "dock slot \(raw)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .core(let t): try c.encode(t.rawValue)
        case .tool(let id): try c.encode(Self.toolPrefix + id)
        }
    }

    /// The tool the slot opens.
    public var toolID: String {
        switch self {
        case .core(let t): t.toolID
        case .tool(let id): id
        }
    }
}

/// The user's dock: at most eight slots, no duplicates, Search always there (last unless
/// moved).
public struct DockLayout: Codable, Equatable, Sendable {
    public static let maxSlots = 8
    public static let key = "dock.layout"
    public static let standard = DockLayout(slots: DockTool.allCases.map(DockSlot.core))

    public private(set) var slots: [DockSlot]

    public init(slots: [DockSlot]) {
        var seen: Set<DockSlot> = []
        var out = slots.filter { seen.insert($0).inserted }
        if !out.contains(.core(.search)) { out.append(.core(.search)) }
        while out.count > Self.maxSlots {
            // Cut from the end, never Search.
            guard let i = out.lastIndex(where: { $0 != .core(.search) }) else { break }
            out.remove(at: i)
        }
        self.slots = out
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(slots: try c.decode([DockSlot].self, forKey: .slots))
    }

    /// The saved dock; the standard one when none is saved or it is damaged.
    public static func load(from defaults: UserDefaults) -> DockLayout {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(DockLayout.self, from: data) else { return .standard }
        return saved
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    public mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { slots[$0] }
        var rest = slots
        for i in fromOffsets.sorted(by: >) { rest.remove(at: i) }
        let before = fromOffsets.filter { $0 < toOffset }.count
        let at = max(0, min(rest.count, toOffset - before))
        rest.insert(contentsOf: moving, at: at)
        slots = rest
    }

    /// Adds a slot before Search; refused when full ("The dock holds 8.") or already there.
    @discardableResult
    public mutating func add(_ s: DockSlot) -> Bool {
        guard slots.count < Self.maxSlots, !slots.contains(s) else { return false }
        if let search = slots.firstIndex(of: .core(.search)), search == slots.count - 1 {
            slots.insert(s, at: search)
        } else {
            slots.append(s)
        }
        return true
    }

    /// Removes a slot; Search cannot be removed.
    @discardableResult
    public mutating func remove(_ s: DockSlot) -> Bool {
        guard s != .core(.search), let i = slots.firstIndex(of: s) else { return false }
        slots.remove(at: i)
        return true
    }
}

/// What one dock button shows now.
public struct DockItemState: Equatable, Sendable {
    public let slot: DockSlot
    /// The label under the circle: the title, a live time, or the search shortcut.
    public let label: String
    /// A count badge ("3", "99+"); nil hides it.
    public let badge: String?
    /// Amber: something runs (Timer only).
    public let live: Bool
    /// The tool's widget is on (an off slot is dimmed and opens "Turn on").
    public let available: Bool

    public init(slot: DockSlot, label: String, badge: String?, live: Bool, available: Bool) {
        self.slot = slot
        self.label = label
        self.badge = badge
        self.live = live
        self.available = available
    }

    /// The tool's title (the label unless live or Search).
    public var title: String {
        switch slot {
        case .core(let t): t.title
        case .tool: label
        }
    }
}

/// The dock's state from the models (pure: every query takes the time).
public enum DockState {
    public static func items(layout: DockLayout, toolTitles: [String: String], enabledWidgets: Set<String>,
                             focus: FocusTimer?, timers: [CountdownTimer], stopwatch: Stopwatch?, remindersDue: Int,
                             shelfCount: Int, searchKey: String?, now: Date) -> [DockItemState] {
        layout.slots.compactMap { slot in
            switch slot {
            case .tool(let id):
                guard let title = toolTitles[id] else { return nil }
                return DockItemState(slot: slot, label: title, badge: nil, live: false, available: true)
            case .core(let t):
                let available = t.widgetIDs.isEmpty || t.widgetIDs.contains { enabledWidgets.contains($0) }
                switch t {
                case .timer:
                    let live = available ? timerLive(focus: focus, timers: timers, stopwatch: stopwatch, now: now) : nil
                    return DockItemState(slot: slot, label: live ?? t.title, badge: nil, live: live != nil,
                                         available: available)
                case .remind:
                    return DockItemState(slot: slot, label: t.title, badge: available ? badge(remindersDue) : nil,
                                         live: false, available: available)
                case .shelf:
                    return DockItemState(slot: slot, label: t.title, badge: available ? badge(shelfCount) : nil,
                                         live: false, available: available)
                case .search:
                    return DockItemState(slot: slot, label: searchKey ?? t.title, badge: nil, live: false, available: true)
                default:
                    return DockItemState(slot: slot, label: t.title, badge: nil, live: false, available: available)
                }
            }
        }
    }

    /// Focus left first, else the soonest running timer, else the running stopwatch's
    /// elapsed time; nil when nothing runs.
    static func timerLive(focus: FocusTimer?, timers: [CountdownTimer], stopwatch: Stopwatch?, now: Date) -> String? {
        if let focus, focus.isRunning(at: now) { return clock(focus.remaining(at: now)) }
        let soonest = timers.filter { $0.isRunning(at: now) }
            .min { ($0.endsAt ?? .distantFuture) < ($1.endsAt ?? .distantFuture) }
        if let soonest { return clock(soonest.remaining(at: now)) }
        if let stopwatch, stopwatch.isRunning { return clock(stopwatch.elapsed(at: now)) }
        return nil
    }

    /// nil for 0, the count, or "99+".
    public static func badge(_ n: Int) -> String? {
        guard n > 0 else { return nil }
        return n > 99 ? "99+" : "\(n)"
    }

    /// `m:ss`, or `h:mm:ss` from an hour; a part-second counts as a whole one.
    public static func clock(_ t: TimeInterval) -> String {
        let total: Int = max(0, Int(t.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let ss: String = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 { return "\(h):\(m < 10 ? "0\(m)" : "\(m)"):\(ss)" }
        return "\(m):\(ss)"
    }
}
