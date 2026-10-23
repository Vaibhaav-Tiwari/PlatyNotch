import Foundation

/// Fans `CoreClient.events` (a single-consumer stream) out to any number of
/// subscribers on the main actor: the store, plugins, settings.
/// Plugins get this hub but may only listen (`subscribe`, `stream`, `cancel`): feeding
/// it (`start`, `publish`) and `stop` are package access, so no plugin can inject a
/// fake approval or cut the store off from the core.
@MainActor
public final class CoreEventHub {
    public typealias Token = UUID

    private var handlers: [(Token, @MainActor (CoreEvent) -> Void)] = []
    private var streams: [Token: AsyncStream<CoreEvent>.Continuation] = [:]
    private var pump: Task<Void, Never>?

    public init() {}

    /// Starts reading `source`. Call once.
    package func start(_ source: AsyncStream<CoreEvent>) {
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            for await event in source { self?.publish(event) }
            self?.finishStreams()
        }
    }

    package func stop() {
        pump?.cancel()
        pump = nil
        finishStreams()
    }

    /// Calls `handler` for every event, in subscription order.
    @discardableResult
    public func subscribe(_ handler: @escaping @MainActor (CoreEvent) -> Void) -> Token {
        let t = Token()
        handlers.append((t, handler))
        return t
    }

    /// A stream of every event from now on (ends on `cancel` or `stop`).
    public func stream() -> (Token, AsyncStream<CoreEvent>) {
        let t = Token()
        let (s, c) = AsyncStream.makeStream(of: CoreEvent.self, bufferingPolicy: .bufferingNewest(1024))
        streams[t] = c
        c.onTermination = { [weak self] _ in
            Task { @MainActor in self?.streams[t] = nil }
        }
        return (t, s)
    }

    public func cancel(_ token: Token) {
        handlers.removeAll { $0.0 == token }
        streams.removeValue(forKey: token)?.finish()
    }

    /// Delivers one event (also used by tests).
    package func publish(_ event: CoreEvent) {
        for (_, h) in handlers { h(event) }
        for c in streams.values { c.yield(event) }
    }

    private func finishStreams() {
        for c in streams.values { c.finish() }
        streams = [:]
    }
}

extension CoreEvent {
    /// The payload of an `ext.event` envelope.
    public var extMessage: ExtMessage? {
        guard case .message(let env) = self, env.type == MessageType.extEvent.rawValue else { return nil }
        return try? env.decode(ExtMessage.self)
    }
}
