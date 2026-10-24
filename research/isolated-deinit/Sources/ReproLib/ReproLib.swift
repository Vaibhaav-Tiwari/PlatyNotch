import Foundation

public enum Counters {
    nonisolated(unsafe) public static var deinits = 0
}

public enum ReproLocal {
    @TaskLocal public static var marker: Int = 0
}

/// The class under test: `@MainActor` with an `isolated deinit`.
@MainActor
public final class MainFoo {
    public init() {}
    isolated deinit {
        Counters.deinits += 1
        print("  MainFoo isolated deinit ran (main thread: \(Thread.isMainThread), marker: \(ReproLocal.marker))")
    }
}

/// Control: `@MainActor` class with a plain (nonisolated) deinit.
@MainActor
public final class MainPlain {
    public init() {}
    deinit {
        Counters.deinits += 1
        print("  MainPlain deinit ran")
    }
}

@globalActor
public actor CustomActor {
    public static let shared = CustomActor()
}

/// Variant e: a custom global actor instead of the main actor. Only the main actor's
/// isolated deinit back-deploys; others need macOS 15.4 (a compile error otherwise).
@available(macOS 15.4, *)
@CustomActor
public final class CustomFoo {
    /// Nonisolated so the main thread can create (and then release) one.
    nonisolated public init() {}
    isolated deinit {
        Counters.deinits += 1
        print("  CustomFoo isolated deinit ran (marker: \(ReproLocal.marker))")
    }
}

/// Like PlatyNotch's DragSubscription: also referenced weakly (forces a side table).
@MainActor
public final class Holder {
    public weak var foo: MainFoo?
    public init() {}
}
