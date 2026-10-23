import Foundation
import Observation
import PlatyNotchKit

/// Something ringing: the widget's id for it and the title for "Stop <title>".
public struct RingingItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// What `PanelSurfaces` sends each display's panel.
public enum PanelSurfaceSignal: Equatable, Sendable {
    case peek(id: String, until: Date)
    case endPeek(id: String)
    case ring(id: String)
    case stopRinging(id: String)
    case hud(HUDKind, level: Double, until: Date)
    /// A drag with something on the drag pasteboard is in progress (Task 5's detector).
    case dragSession(active: Bool)
}

/// A display's panel listening to `PanelSurfaces` (`NotchController`).
@MainActor
public protocol PanelSurfaceSink: AnyObject {
    func receive(_ signal: PanelSurfaceSignal)
    /// Whether this panel currently shows the HUD (as a surface or an indicator).
    var showsHUD: Bool { get }
}

/// The transient surfaces widgets ask for (peeks, ringing, HUDs, the drag session),
/// fanned out to every display's panel. One instance, shared like the registry. It holds
/// what is current so a panel rebuilt for a display change gets it replayed.
/// Precedence against approvals and the open panel is `PanelPrecedence` (PlatyNotchKit).
@MainActor @Observable
public final class PanelSurfaces {
    /// How long a HUD stays after the last change.
    public static let hudDuration: TimeInterval = 1.5

    /// What is ringing, oldest first (the menu bar's "Stop <title>" items, the chip).
    public private(set) var rings: [RingingItem] = []
    /// Ringing ids, oldest first. Games pause while this is non-empty (Task 10).
    public var ringing: [String] { rings.map(\.id) }
    /// True while a drag session is in progress.
    public private(set) var dragActive = false

    @ObservationIgnored private weak var registry: WidgetRegistry?
    @ObservationIgnored private var sinks: [WeakSink] = []
    @ObservationIgnored private var currentPeek: WidgetPeek?
    @ObservationIgnored private var currentHUD: HUDState?
    @ObservationIgnored var now: () -> Date = Date.init

    /// `registry` supplies the views; peeks and rings without a view are refused.
    public init(registry: WidgetRegistry? = nil) {
        self.registry = registry
        observeRegistry()
    }

    /// A widget turned off mid-peek or mid-ring takes its surface with it (no blank card).
    private func observeRegistry() {
        guard let registry else { return }
        withObservationTracking {
            _ = registry.running
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.dropSurfacesWithoutViews()
                self?.observeRegistry()
            }
        }
    }

    func dropSurfacesWithoutViews() {
        if let p = currentPeek, !hasView(p.id) { endPeek(id: p.id) }
        for r in rings where !hasView(r.id) { stopRinging(id: r.id) }
    }

    // MARK: - Panels

    /// Adds a panel and replays what is current (rings, an unexpired peek / HUD, the drag session).
    public func attach(_ sink: PanelSurfaceSink) {
        guard !sinks.contains(where: { $0.sink === sink }) else { return }
        sinks.append(WeakSink(sink: sink))
        let t = now()
        for r in rings { sink.receive(.ring(id: r.id)) }
        if let p = currentPeek, p.until > t { sink.receive(.peek(id: p.id, until: p.until)) }
        if let h = currentHUD, h.until > t { sink.receive(.hud(h.kind, level: h.level, until: h.until)) }
        if dragActive { sink.receive(.dragSession(active: true)) }
    }

    public func detach(_ sink: PanelSurfaceSink) {
        sinks.removeAll { $0.sink == nil || $0.sink === sink }
    }

    // MARK: - Widget API (through WidgetContext)

    /// Peeks `id` (a widget's own id, conventionally "<widget>.<what>") until `until`.
    /// False, and nothing shown, when no running widget supplies `peekView(id:)`.
    @discardableResult
    public func peek(id: String, until: Date) -> Bool {
        guard hasView(id) else { return false }
        currentPeek = WidgetPeek(id: id, until: until)
        send(.peek(id: id, until: until))
        return true
    }

    public func endPeek(id: String) {
        if currentPeek?.id == id { currentPeek = nil }
        send(.endPeek(id: id))
    }

    /// Starts a sticky ringing surface (alarm, timer) shown until `stopRinging(id:)`. The
    /// view is the widget's `peekView(id:)`; `title` names it in "Stop <title>" (menu bar,
    /// chip). False when no running widget supplies a view.
    @discardableResult
    public func ring(id: String, title: String) -> Bool {
        guard hasView(id) else { return false }
        if !rings.contains(where: { $0.id == id }) { rings.append(RingingItem(id: id, title: title)) }
        send(.ring(id: id))
        return true
    }

    public func stopRinging(id: String) {
        rings.removeAll { $0.id == id }
        send(.stopRinging(id: id))
    }

    /// Shows a level HUD for `hudDuration`. Returns whether any panel shows it (false over
    /// full screen or under a ringing card), so the caller can let the system HUD show instead.
    @discardableResult
    public func showHUD(kind: HUDKind, level: Double) -> Bool {
        let h = HUDState(kind: kind, level: level, until: now().addingTimeInterval(Self.hudDuration))
        currentHUD = h
        send(.hud(kind, level: h.level, until: h.until))
        return sinks.contains { $0.sink?.showsHUD == true }
    }

    /// A drag began / ended anywhere (Task 5's detector). Each panel opens its drop zone
    /// only while the dragging cursor is near its notch.
    public func setDragSession(active: Bool) {
        guard active != dragActive else { return }
        dragActive = active
        send(.dragSession(active: active))
    }

    private func hasView(_ id: String) -> Bool {
        guard let registry else { return true }   // no registry (tests of the controller alone)
        return registry.peekView(id: id) != nil
    }

    private func send(_ s: PanelSurfaceSignal) {
        sinks.removeAll { $0.sink == nil }
        for w in sinks { w.sink?.receive(s) }
    }

    private struct WeakSink {
        weak var sink: PanelSurfaceSink?
    }
}
