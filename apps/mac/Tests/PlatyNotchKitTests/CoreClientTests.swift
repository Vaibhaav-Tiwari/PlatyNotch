import Foundation
import XCTest
@testable import PlatyNotchKit

/// Minimal AF_UNIX server using socket(2); accepts one client at a time.
final class TestServer: @unchecked Sendable {
    let path: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var clientFD: Int32 = -1

    init() {
        path = "/tmp/pn\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    func listen() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, Foundation.listen(fd, 4) == 0 else { throw NSError(domain: "bind", code: Int(errno)) }
        listenFD = fd
    }

    /// Blocks until a client connects.
    func accept() -> Bool {
        let fd = Foundation.accept(listenFD, nil, nil)
        guard fd >= 0 else { return false }
        lock.lock(); clientFD = fd; lock.unlock()
        return true
    }

    /// Reads until `count` newline-terminated lines have arrived.
    func readLines(_ count: Int) -> [String] {
        var codec = LineCodec()
        var lines: [Data] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while lines.count < count {
            let n = read(clientFD, &buf, buf.count)
            if n <= 0 { break }
            lines += codec.feed(Data(buf[0..<n]))
        }
        return lines.map { String(decoding: $0, as: UTF8.self) }
    }

    func write(_ s: String) {
        let bytes = Array(s.utf8)
        _ = Foundation.write(clientFD, bytes, bytes.count)
    }

    func dropClient() {
        lock.lock(); defer { lock.unlock() }
        if clientFD >= 0 { close(clientFD); clientFD = -1 }
    }

    func shutdown() {
        dropClient()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }
}

final class CoreClientTests: XCTestCase {
    func testLineCodecPartialLines() {
        var c = LineCodec()
        XCTAssertEqual(c.feed(Data("{\"a\":1}\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}"])
        XCTAssertEqual(c.feed(Data(":2}".utf8)), [])
        XCTAssertEqual(c.feed(Data("\n\n{\"c\":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"b\":2}", "{\"c\":3}"])
    }

    func testLineCodecDropsOversizedLine() {
        var c = LineCodec()
        let big = Data(repeating: 0x61, count: LineCodec.maxLineBytes + 10)
        XCTAssertEqual(c.feed(big), [])
        XCTAssertTrue(c.overflowed)
        XCTAssertEqual(c.feed(Data("xx\nok\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["ok"])
    }

    func nextMessage(_ it: inout AsyncStream<CoreEvent>.Iterator) async -> CoreEvent? { await it.next() }

    func testSubscribeSendsHelloThenSubscribe() async throws {
        let server = TestServer()
        try server.listen()
        defer { server.shutdown() }
        let client = CoreClient(socketPath: server.path)
        await client.start()
        let lines: [String] = await Task.detached {
            XCTAssertTrue(server.accept())
            return server.readLines(2)
        }.value
        XCTAssertEqual(lines.count, 2)
        let hello = try JSONCoding.decoder.decode(Envelope.self, from: Data(lines[0].utf8))
        XCTAssertEqual(hello.type, "hello")
        let h: Hello = try hello.decode()
        XCTAssertEqual(h.role, "ui")
        XCTAssertEqual(h.version, 1)
        XCTAssertTrue(h.client?.hasPrefix("PlatyNotch/") ?? false)
        let sub = try JSONCoding.decoder.decode(Envelope.self, from: Data(lines[1].utf8))
        XCTAssertEqual(sub.type, "subscribe")
        var it = client.events.makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first, .connected)
        await client.stop()
    }

    func testReconnectsAfterServerRestart() async throws {
        let server = TestServer()
        try server.listen()
        defer { server.shutdown() }
        let client = CoreClient(socketPath: server.path)
        var it = client.events.makeAsyncIterator()
        await client.start()

        func serveOnce(_ snapshotID: String) async {
            await Task.detached {
                XCTAssertTrue(server.accept())
                _ = server.readLines(2)
                server.write("{\"v\":1,\"type\":\"notice\",\"data\":{\"kind\":\"k\",\"title\":\"\(snapshotID)\"}}\n")
            }.value
        }
        await serveOnce("one")
        var e = await it.next()
        XCTAssertEqual(e, .connected)
        e = await it.next()
        guard case .message(let m1)? = e else { return XCTFail("expected message, got \(String(describing: e))") }
        XCTAssertEqual(m1.type, "notice")

        server.dropClient()
        e = await it.next()
        XCTAssertEqual(e, .disconnected)

        await serveOnce("two")
        e = await it.next()
        XCTAssertEqual(e, .connected)
        e = await it.next()
        guard case .message(let m2)? = e else { return XCTFail("expected message after reconnect") }
        XCTAssertEqual(m2.type, "notice")
        await client.stop()
    }

    func testRequestMatchesReplyByID() async throws {
        let server = TestServer()
        try server.listen()
        defer { server.shutdown() }
        let client = CoreClient(socketPath: server.path)
        await client.start()
        let responder = Task.detached {
            XCTAssertTrue(server.accept())
            // The handshake is complete on the wire before `.connected` is reported, so a
            // request made on `.connected` always comes third.
            let lines = server.readLines(3)
            let types = try lines.map { try JSONCoding.decoder.decode(Envelope.self, from: Data($0.utf8)).type }
            XCTAssertEqual(types, ["hello", "subscribe", "memory.search"])
            let env = try JSONCoding.decoder.decode(Envelope.self, from: Data(lines[2].utf8))
            // Unrelated message with a different id first, then the real reply.
            server.write("{\"v\":1,\"type\":\"pong\",\"id\":\"other\"}\n")
            server.write("{\"v\":1,\"type\":\"memory.results\",\"id\":\"\(env.id ?? "")\",\"data\":{\"hits\":[]}}\n")
        }
        // Wait until connected.
        var it = client.events.makeAsyncIterator()
        _ = await it.next()
        let reply = try await client.request(
            Envelope.make(.memorySearch, MemorySearch(query: "q")), timeout: .seconds(5))
        XCTAssertEqual(reply.type, "memory.results")
        try await responder.value
        await client.stop()
    }

    func testRequestTimesOut() async throws {
        let server = TestServer()
        try server.listen()
        defer { server.shutdown() }
        let client = CoreClient(socketPath: server.path)
        await client.start()
        Task.detached { _ = server.accept(); _ = server.readLines(3) }
        var it = client.events.makeAsyncIterator()
        _ = await it.next()
        do {
            _ = try await client.request(Envelope.make(.ping), timeout: .milliseconds(200))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? CoreClientError, .timeout)
        }
        await client.stop()
    }

    /// stop() then start() (a quick restart): a connect() still in flight when stop()
    /// ran must not report `.connected` for the cancelled loop, whose `.disconnected`
    /// could then land after the new loop's `.connected` and leave the store
    /// "reconnecting" while connected. The last event is the new loop's `.connected`.
    func testStopThenStartEndsConnected() async throws {
        // Stop at staggered points so some land while connect() is still in flight.
        for i in 0..<20 {
            let server = TestServer()
            try server.listen()
            defer { server.shutdown() }
            let client = CoreClient(socketPath: server.path)
            let events = client.events
            let collector = Task { () -> [CoreEvent] in
                var seen: [CoreEvent] = []
                for await e in events { seen.append(e) }
                return seen
            }
            await client.start()
            try await Task.sleep(for: .microseconds(i * 100))
            await client.stop()
            await client.start()
            try await Task.sleep(for: .milliseconds(200))
            collector.cancel()
            let seen = await collector.value
            XCTAssertEqual(seen.last, .connected, "iteration \(i): \(seen)")
            XCTAssertEqual(seen.filter { $0 == .connected }.count - seen.filter { $0 == .disconnected }.count, 1,
                           "iteration \(i): exactly one live connection: \(seen)")
            await client.stop()
        }
    }

    func testRestartBackoffSequenceAndReset() {
        var b = RestartBackoff()
        XCTAssertEqual([b.nextDelay(), b.nextDelay(), b.nextDelay(), b.nextDelay(), b.nextDelay()], [1, 2, 5, 10, 10])
        b.recordExit(uptime: 30)
        XCTAssertEqual(b.nextDelay(), 10)
        b.recordExit(uptime: 60)
        XCTAssertEqual(b.nextDelay(), 1)
    }
}
