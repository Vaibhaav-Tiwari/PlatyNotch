/// A plugin hosted by the notch app (Pro builds on this). Minimal for now:
/// Plan 3 Task 10 adds `start(context:)`, settings sections, panel tabs and event handling.
@MainActor
public protocol NotchPlugin: AnyObject {
    var id: String { get }
}
