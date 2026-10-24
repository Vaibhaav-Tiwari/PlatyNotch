import Foundation
import Network

public enum CoreEvent: Sendable, Equatable {
    case connected
    case disconnected
    case message(Envelope)
}

public enum CoreClientError: Error, Equatable {
    case notConnected
    case timeout
    case cancelled
}

/// Newline-delimited JSON client for the `notch serve` Unix socket, with reconnect and request/reply matching.
public actor CoreClient {
    /// `PLATYNOTCH_SOCKET`, else `$PLATYNOTCH_HOME/notch.sock`, as the Go core resolves it.
    public static var defaultSocketPath: String { CorePaths.socketPath() }

    public static let reconnectDelays: [Double] = [0.25, 0.5, 1, 2]

    /// SINGLE CONSUMER. The app's `CoreEventHub` is its only reader; a second reader
    /// would steal events from the store. Package access, so plugins cannot reach it:
    /// they subscribe through `PluginContext.events`.
    package nonisolated let events: AsyncStream<CoreEvent>
    private let continuation: AsyncStream<CoreEvent>.Continuation
    private let socketPath: String
    private let clientName: String

    private var transport: Transport?
    private var runTask: Task<Void, Never>?
    /// The loop `stop()` cancelled, until it has wound down (`start()` waits for it).
    private var stoppedRun: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Envelope, Error>] = [:]

    public init(socketPath: String, clientName: String = "PlatyNotch/0.1.0") {
        self.socketPath = socketPath
        self.clientName = clientName
        (events, continuation) = AsyncStream.makeStream(of: CoreEvent.self, bufferingPolicy: .unbounded)
    }

    /// Connects (and keeps reconnecting) until `stop()`. After a `stop()`, the new loop
    /// starts only once the old one has finished, so its last `.disconnected` never
    /// lands after the new `.connected`.
    public func start() {
        guard runTask == nil else { return }
        let previous = stoppedRun
        runTask = Task {
            await previous?.value
            await self.run()
        }
    }

    public func stop() {
        runTask?.cancel()
        stoppedRun = runTask ?? stoppedRun
        runTask = nil
        transport?.close()
        transport = nil
        failPending(CoreClientError.cancelled)
    }

    public func send(_ env: Envelope) async throws {
        guard let transport else { throw CoreClientError.notConnected }
        var data = try JSONCoding.encoder.encode(env)
        data.append(0x0A)
        try await transport.send(data)
    }

    public func request(_ env: Envelope, timeout: Duration) async throws -> Envelope {
        var env = env
        let id = env.id ?? UUID().uuidString
        env.id = id
        let request = env
        let timer = Task {
            try await Task.sleep(for: timeout)
            self.resolve(id: id, with: .failure(CoreClientError.timeout))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Envelope, Error>) in
                pending[id] = cont
                Task {
                    do { try await self.send(request) }
                    catch { self.resolve(id: id, with: .failure(error)) }
                }
            }
        } onCancel: {
            Task { await self.resolve(id: id, with: .failure(CoreClientError.cancelled)) }
        }
    }

    // MARK: - Connection loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let t = Transport(path: socketPath)
            var wasConnected = false
            do {
                try await t.connect()
                // stop() may have run while connect() was suspended. Reporting this
                // connection would race the next start()'s loop (its late .disconnected
                // could follow the new .connected), so drop it without any event.
                if Task.isCancelled { t.close(); break }
                // hello and subscribe go out first. Only then is the connection usable and
                // reported: the actor is reentrant at each send, so a request issued on an
                // early `.connected` could otherwise land between hello and subscribe.
                try await handshake(t)
                if Task.isCancelled { t.close(); break }
                transport = t
                wasConnected = true
                attempt = 0
                continuation.yield(.connected)
                var codec = LineCodec()
                for await chunk in t.incoming {
                    for line in codec.feed(chunk) { dispatch(line) }
                }
            } catch {
                // fall through to disconnect handling
            }
            t.close()
            if transport === t { transport = nil }
            failPending(CoreClientError.notConnected)
            if wasConnected { continuation.yield(.disconnected) }
            if Task.isCancelled { break }
            let delays = Self.reconnectDelays
            let delay = delays[min(attempt, delays.count - 1)]
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func handshake(_ t: Transport) async throws {
        let hello = try Envelope.make(.hello, Hello(role: ClientRole.ui.rawValue, client: clientName))
        for env in [hello, Envelope.make(.subscribe)] {
            var data = try JSONCoding.encoder.encode(env)
            data.append(0x0A)
            try await t.send(data)
        }
    }

    private func dispatch(_ line: Data) {
        guard let env = try? JSONCoding.decoder.decode(Envelope.self, from: line) else { return }
        if let id = env.id, pending[id] != nil {
            resolve(id: id, with: .success(env))
            return
        }
        continuation.yield(.message(env))
    }

    private func resolve(id: String, with result: Result<Envelope, Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let all = pending
        pending = [:]
        for (_, c) in all { c.resume(throwing: error) }
    }
}

/// One Unix-socket connection (Network.framework).
final class Transport: @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let incomingCont: AsyncStream<Data>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "platynotch.core-transport")

    init(path: String) {
        (incoming, incomingCont) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    func connect() async throws {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if !once.done { once.done = true; cont.resume() }
                    self.receiveLoop()
                case .failed(let e), .waiting(let e):
                    if !once.done { once.done = true; cont.resume(throwing: e) }
                    else { self.incomingCont.finish() }
                    self.connection.cancel()
                case .cancelled:
                    if !once.done { once.done = true; cont.resume(throwing: CoreClientError.cancelled) }
                    self.incomingCont.finish()
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.incomingCont.yield(data) }
            if error != nil || isComplete {
                self.incomingCont.finish()
                self.connection.cancel()
                return
            }
            self.receiveLoop()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func close() {
        connection.cancel()
        incomingCont.finish()
    }
}
