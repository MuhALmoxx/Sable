import Network
import XCTest
import TranslationKit
@testable import Sable

/// The loopback receiver for the ChatGPT sign-in redirect, exercised over real TCP on 127.0.0.1.
final class ChatGPTLoopbackServerTests: XCTestCase {
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ChatGPTLoopbackServer.Event] = []

        func append(_ event: ChatGPTLoopbackServer.Event) {
            lock.lock(); defer { lock.unlock() }
            stored.append(event)
        }

        var events: [ChatGPTLoopbackServer.Event] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    struct Reply {
        let status: Int
        let body: String
    }

    // MARK: Server over TCP

    func testCallbackIsDeliveredOnceWithA200PageAndTheReceiverStops() async throws {
        let server = ChatGPTLoopbackServer(timeout: 120)
        let log = EventLog()
        let delivered = expectation(description: "the callback is delivered")
        let port = try await server.start(preferredPort: 0) { event in
            log.append(event)
            delivered.fulfill()
        }
        defer { server.stop() }
        XCTAssertNotEqual(port, 0)
        XCTAssertTrue(server.isListening)

        let reply = try await Self.get("/auth/callback?code=abc&state=xyz", port: port)
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(reply.body.contains("Signed in. You can return to Sable."), reply.body)
        await fulfillment(of: [delivered], timeout: 5)

        guard case let .callback(items)? = log.events.first else {
            return XCTFail("Expected a callback event, got \(log.events)")
        }
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "abc")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "xyz")

        let stopped = await Self.waitUntil(timeout: 5) { !server.isListening }
        XCTAssertTrue(stopped, "The receiver must stop listening after the callback")
        do {
            let late = try await Self.get("/auth/callback?code=again&state=xyz", port: port)
            XCTFail("The receiver answered \(late.status) after it should have stopped")
        } catch {
            // Expected: nothing listens on the port any more.
        }
        XCTAssertEqual(log.events.count, 1, "The callback is delivered exactly once")
    }

    func testOtherPathsGet404AndDoNotEndTheAttempt() async throws {
        let server = ChatGPTLoopbackServer(timeout: 120)
        let log = EventLog()
        let delivered = expectation(description: "the callback is delivered")
        let port = try await server.start(preferredPort: 0) { event in
            log.append(event)
            delivered.fulfill()
        }
        defer { server.stop() }

        for target in ["/favicon.ico", "/", "/auth/callback/extra?code=abc&state=xyz", "/auth?code=abc&state=xyz"] {
            let reply = try await Self.get(target, port: port)
            XCTAssertEqual(reply.status, 404, "\(target) must get 404")
        }
        XCTAssertTrue(server.isListening, "Wrong paths must not end the attempt")
        XCTAssertTrue(log.events.isEmpty)

        let reply = try await Self.get("/auth/callback?code=abc&state=xyz", port: port)
        XCTAssertEqual(reply.status, 200)
        await fulfillment(of: [delivered], timeout: 5)
    }

    func testCallbackForAnotherAttemptIsRejected() async throws {
        let server = ChatGPTLoopbackServer(timeout: 120)
        let log = EventLog()
        let delivered = expectation(description: "the matching callback is delivered")
        let port = try await server.start(preferredPort: 0) { event in
            log.append(event)
            delivered.fulfill()
        }
        defer { server.stop() }
        server.expectState("expected-state")

        let wrong = try await Self.get("/auth/callback?code=abc&state=other", port: port)
        XCTAssertEqual(wrong.status, 400)
        XCTAssertTrue(server.isListening)
        XCTAssertTrue(log.events.isEmpty, "A foreign state must not be delivered")

        let right = try await Self.get("/auth/callback?code=abc&state=expected-state", port: port)
        XCTAssertEqual(right.status, 200)
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(log.events.count, 1)
    }

    func testDeclinedConsentIsDeliveredWithItsOwnPage() async throws {
        let server = ChatGPTLoopbackServer(timeout: 120)
        let log = EventLog()
        let delivered = expectation(description: "the error callback is delivered")
        let port = try await server.start(preferredPort: 0) { event in
            log.append(event)
            delivered.fulfill()
        }
        defer { server.stop() }

        let reply = try await Self.get("/auth/callback?error=access_denied&state=xyz", port: port)
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(reply.body.contains("Sign-in did not complete"), reply.body)
        await fulfillment(of: [delivered], timeout: 5)
        guard case let .callback(items)? = log.events.first else { return XCTFail("No callback event") }
        XCTAssertEqual(items.first { $0.name == "error" }?.value, "access_denied")
    }

    func testOnlyGETIsAnswered() async throws {
        let server = ChatGPTLoopbackServer(timeout: 120)
        let port = try await server.start(preferredPort: 0) { _ in }
        defer { server.stop() }
        let reply = try await Self.get("/auth/callback?code=abc&state=xyz", port: port, method: "POST")
        XCTAssertEqual(reply.status, 405)
        XCTAssertTrue(server.isListening)
    }

    func testBusyPreferredPortFallsBackToAnotherPort() async throws {
        let first = ChatGPTLoopbackServer(timeout: 120)
        let taken = try await first.start(preferredPort: 0) { _ in }
        defer { first.stop() }
        let second = ChatGPTLoopbackServer(timeout: 120)
        let port = try await second.start(preferredPort: taken) { _ in }
        defer { second.stop() }
        XCTAssertNotEqual(port, taken, "A port in use must not be shared")
        XCTAssertNotEqual(port, 0)
    }

    func testStopEndsListeningWithoutAnEvent() async throws {
        let server = ChatGPTLoopbackServer(timeout: 120)
        let log = EventLog()
        _ = try await server.start(preferredPort: 0) { log.append($0) }
        server.stop()
        let stopped = await Self.waitUntil(timeout: 5) { !server.isListening }
        XCTAssertTrue(stopped)
        XCTAssertTrue(log.events.isEmpty)
    }

    func testTimeoutStopsTheReceiver() async throws {
        let server = ChatGPTLoopbackServer(timeout: 0.3)
        let log = EventLog()
        let timedOut = expectation(description: "the attempt times out")
        _ = try await server.start(preferredPort: 0) { event in
            log.append(event)
            timedOut.fulfill()
        }
        await fulfillment(of: [timedOut], timeout: 10)
        XCTAssertEqual(log.events, [.timedOut])
        XCTAssertFalse(server.isListening)
    }

    // MARK: Request parsing (pure)

    func testParsingDecodesFormEncodedQueries() {
        let head = Data("GET /auth/callback?code=a%2Bb&state=s1&scope=openid+profile%20email HTTP/1.1\r\nHost: 127.0.0.1:1455".utf8)
        guard case let .callback(items) = ChatGPTLoopbackServer.parse(head: head, path: "/auth/callback") else {
            return XCTFail("Expected a callback")
        }
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "a+b")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "s1")
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "openid profile email")
    }

    func testParsingRejectsEverythingElse() {
        func status(_ line: String) -> Int? {
            if case let .reject(status, _, _) = ChatGPTLoopbackServer.parse(head: Data(line.utf8), path: "/auth/callback") {
                return status
            }
            return nil
        }
        XCTAssertEqual(status("POST /auth/callback?code=a HTTP/1.1"), 405)
        XCTAssertEqual(status("GET /other HTTP/1.1"), 404)
        XCTAssertEqual(status("GET /auth/callback/ HTTP/1.1"), 404)
        XCTAssertEqual(status("GET http://example.com/auth/callback?code=a HTTP/1.1"), 400)
        XCTAssertEqual(status("GET /auth/callback?code=a"), 400)
        XCTAssertEqual(status("garbage"), 400)
        XCTAssertNil(status("GET /auth/callback?code=a&state=b HTTP/1.1"))
    }

    // MARK: Helpers

    static func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// An HTTP request with URLSession, the way a client reaches the receiver. If App Transport
    /// Security refuses plain HTTP to the loopback address in the test host, the same request is
    /// written over TCP instead (the real redirect comes from the browser, which ATS does not govern).
    static func get(_ target: String, port: UInt16, method: String = "GET") async throws -> Reply {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(target)"))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = method
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return Reply(status: status, body: String(decoding: data, as: UTF8.self))
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            return try await RawExchange(port: port).send("\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n")
        }
    }

    /// Minimal HTTP/1.1 client over NWConnection (ATS fallback).
    final class RawExchange: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.murisixz.sable.tests.raw-http")
        private let port: UInt16
        private var connection: NWConnection?
        private var continuation: CheckedContinuation<Reply, Error>?
        private var received = Data()

        init(port: UInt16) { self.port = port }

        func send(_ request: String) async throws -> Reply {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, Error>) in
                queue.async {
                    self.continuation = continuation
                    let connection = NWConnection(host: .ipv4(IPv4Address.loopback), port: nwPort, using: .tcp)
                    self.connection = connection
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                            self.receive()
                        case let .failed(error), let .waiting(error):
                            self.finish(.failure(error))
                        default:
                            break
                        }
                    }
                    connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 10) { self.finish(.failure(URLError(.timedOut))) }
                }
            }
        }

        private func receive() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data { self.received.append(data) }
                if isComplete || error != nil {
                    self.finish(Self.parse(self.received))
                } else {
                    self.receive()
                }
            }
        }

        private func finish(_ result: Result<Reply, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            connection?.cancel()
            continuation.resume(with: result)
        }

        static func parse(_ data: Data) -> Result<Reply, Error> {
            let text = String(decoding: data, as: UTF8.self)
            let statusLine = text.components(separatedBy: "\r\n").first ?? ""
            guard let code = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
                return .failure(URLError(.badServerResponse))
            }
            let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            return .success(Reply(status: code, body: body))
        }
    }
}
