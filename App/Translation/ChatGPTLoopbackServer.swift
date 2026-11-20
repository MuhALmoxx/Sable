import Foundation
import Network
import TranslationKit

// OWNER: ChatGPT app layer (translation).
//
// Loopback receiver for the "Sign in with ChatGPT" redirect. OpenAI's flow for locally hosted
// apps redirects the browser to http://127.0.0.1:<port>/auth/callback?code=…&state=…; Sable runs
// that receiver on the iPhone itself:
// - binds to 127.0.0.1 only (loopback interface), port 1455 when free, else one the OS assigns;
// - reads one HTTP request head per connection (at most `maxRequestBytes`), answers only
//   `GET /auth/callback` (other paths 404, other methods 405, a `state` that is not this attempt's
//   400), replies with a tiny black page and `Connection: close`;
// - delivers the callback's query items exactly once, then stops listening; it also stops when
//   cancelled or after `timeout` (10 minutes by default).
// Loopback traffic does not trigger iOS local-network privacy, so no Info.plist key is needed.
// Query values (the authorization code) are never logged.
final class ChatGPTLoopbackServer: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        /// The redirect arrived: its decoded query items (code, state, scope, client_id or error).
        case callback([URLQueryItem])
        case timedOut
        /// The listener stopped working before the redirect arrived.
        case failed(String)
    }

    enum StartError: LocalizedError, Equatable {
        case couldNotListen(String)

        var errorDescription: String? {
            switch self {
            case let .couldNotListen(detail): return "Sable couldn't open its sign-in receiver on this iPhone (\(detail))."
            }
        }
    }

    static let maxRequestBytes = 16 * 1024
    static let defaultTimeout: TimeInterval = 10 * 60
    /// How long a listener may take to become ready.
    static let startTimeout: TimeInterval = 5

    let path: String
    let timeout: TimeInterval

    private let queue = DispatchQueue(label: "com.murisixz.sable.chatgpt-loopback")

    // Everything below is only touched on `queue`.
    private var listener: NWListener?
    private var pendingStart: CheckedContinuation<UInt16, Error>?
    private var startWatchdog: DispatchWorkItem?
    private var timeoutItem: DispatchWorkItem?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var expectedState: String?
    private var onEvent: (@Sendable (Event) -> Void)?
    private var listening = false
    /// Set once the callback was accepted, the attempt timed out or `stop()` was called.
    private var finished = false

    init(path: String = ChatGPTPlan.callbackPath, timeout: TimeInterval = ChatGPTLoopbackServer.defaultTimeout) {
        self.path = path
        self.timeout = timeout
    }

    deinit {
        listener?.cancel()
    }

    /// True while the listener accepts connections.
    var isListening: Bool { queue.sync { listening } }

    /// Starts listening on 127.0.0.1 and returns the bound port: `preferredPort` when it is free
    /// (pass 0 to let the OS choose), else an OS-assigned one. `onEvent` is called once, on a
    /// private queue.
    func start(preferredPort: UInt16, onEvent: @escaping @Sendable (Event) -> Void) async throws -> UInt16 {
        queue.sync {
            self.onEvent = onEvent
            self.finished = false
        }
        var port: UInt16? = nil
        if preferredPort != 0 {
            port = try? await listen(on: preferredPort)
        }
        let bound: UInt16
        if let port {
            bound = port
        } else {
            bound = try await listen(on: 0)
        }
        queue.sync { self.armTimeout() }
        return bound
    }

    /// Only a callback whose `state` equals this value is accepted (others get 400 and are ignored).
    func expectState(_ state: String) {
        queue.sync { self.expectedState = state }
    }

    /// Stops listening and drops connections that are still being read. A reply already being
    /// written is allowed to finish. No event is delivered after this.
    func stop() {
        queue.async { self.shutDown(dropConnections: true) }
    }

    // MARK: Listening (on `queue`)

    private func listen(on port: UInt16) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async { self.startListener(port: port, continuation: continuation) }
        }
    }

    private func startListener(port: UInt16, continuation: CheckedContinuation<UInt16, Error>) {
        guard !finished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        // No local-endpoint reuse: nothing else may share this port while the attempt runs.
        parameters.allowLocalEndpointReuse = false
        let localPort = NWEndpoint.Port(rawValue: port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address.loopback), port: localPort)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            continuation.resume(throwing: StartError.couldNotListen(error.localizedDescription))
            return
        }
        listener = newListener
        pendingStart = continuation
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener else { return }
            self.listenerStateChanged(state, listener: newListener)
        }
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        let watchdog = DispatchWorkItem { [weak self] in
            self?.failPendingStart(StartError.couldNotListen("the receiver did not start"))
        }
        startWatchdog = watchdog
        queue.asyncAfter(deadline: .now() + Self.startTimeout, execute: watchdog)
        newListener.start(queue: queue)
    }

    private func listenerStateChanged(_ state: NWListener.State, listener changed: NWListener) {
        guard changed === listener else { return }
        switch state {
        case .ready:
            guard let continuation = pendingStart else { return }
            pendingStart = nil
            startWatchdog?.cancel()
            startWatchdog = nil
            if let port = changed.port?.rawValue, port != 0 {
                listening = true
                continuation.resume(returning: port)
            } else {
                changed.cancel()
                listener = nil
                continuation.resume(throwing: StartError.couldNotListen("no port was assigned"))
            }
        case let .waiting(error), let .failed(error):
            if pendingStart != nil {
                failPendingStart(StartError.couldNotListen(error.localizedDescription))
            } else if !finished {
                // The receiver broke while the browser was open (e.g. iOS reclaimed it).
                let handler = onEvent
                shutDown(dropConnections: true)
                handler?(.failed("The sign-in receiver stopped (\(error.localizedDescription)). Try again."))
            }
        case .cancelled:
            listening = false
            if pendingStart != nil { failPendingStart(CancellationError()) }
        default:
            break
        }
    }

    private func failPendingStart(_ error: Error) {
        startWatchdog?.cancel()
        startWatchdog = nil
        listener?.cancel()
        listener = nil
        listening = false
        guard let continuation = pendingStart else { return }
        pendingStart = nil
        continuation.resume(throwing: error)
    }

    private func armTimeout() {
        timeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            let handler = self.onEvent
            self.shutDown(dropConnections: true)
            handler?(.timedOut)
        }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Stops the listener (and optionally open connections); later events are suppressed.
    private func shutDown(dropConnections: Bool) {
        finished = true
        onEvent = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        if pendingStart != nil { failPendingStart(CancellationError()) }
        listener?.cancel()
        listener = nil
        listening = false
        if dropConnections {
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    // MARK: Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        guard !finished else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var received = buffer
            if let content { received.append(content) }
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                self.handleRequest(head: received.subdata(in: received.startIndex..<end.lowerBound), on: connection)
            } else if received.count > Self.maxRequestBytes {
                self.respond(on: connection, status: 431, reason: "Request Header Fields Too Large",
                             message: "This request is too large.")
            } else if error != nil || isComplete {
                self.connections[ObjectIdentifier(connection)] = nil
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: received)
            }
        }
    }

    private func handleRequest(head: Data, on connection: NWConnection) {
        switch Self.parse(head: head, path: path) {
        case let .reject(status, reason, message):
            respond(on: connection, status: status, reason: reason, message: message)
        case let .callback(items):
            guard !finished else {
                respond(on: connection, status: 410, reason: "Gone", message: "This sign-in attempt has already finished.")
                return
            }
            if let expectedState, items.first(where: { $0.name == "state" })?.value != expectedState {
                respond(on: connection, status: 400, reason: "Bad Request",
                        message: "This sign-in response does not belong to the current attempt.")
                return
            }
            let declined = items.contains { $0.name == "error" }
            let handler = onEvent
            respond(on: connection, status: 200, reason: "OK",
                    message: declined ? "Sign-in did not complete. You can return to Sable." : "Signed in. You can return to Sable.")
            shutDown(dropConnections: false)
            handler?(.callback(items))
        }
    }

    private func respond(on connection: NWConnection, status: Int, reason: String, message: String) {
        // Not tracked any more: `stop()` must not cut a reply short.
        connections[ObjectIdentifier(connection)] = nil
        let body = Data(Self.page(message).utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Parsing (pure)

    enum ParsedRequest: Equatable {
        case callback([URLQueryItem])
        case reject(status: Int, reason: String, message: String)
    }

    /// Parses an HTTP/1.x request head ("GET /auth/callback?… HTTP/1.1" plus headers).
    static func parse(head: Data, path: String) -> ParsedRequest {
        guard let text = String(data: head, encoding: .utf8) else {
            return .reject(status: 400, reason: "Bad Request", message: "This request could not be read.")
        }
        let requestLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else {
            return .reject(status: 400, reason: "Bad Request", message: "This request could not be read.")
        }
        guard parts[0] == "GET" else {
            return .reject(status: 405, reason: "Method Not Allowed", message: "Only the sign-in redirect is answered here.")
        }
        // Query strings in the redirect are form-encoded, where "+" is a space.
        let target = parts[1].replacingOccurrences(of: "+", with: "%20")
        guard let components = URLComponents(string: "http://127.0.0.1" + target) else {
            return .reject(status: 400, reason: "Bad Request", message: "This request could not be read.")
        }
        guard components.path == path else {
            return .reject(status: 404, reason: "Not Found", message: "Nothing here. You can return to Sable.")
        }
        return .callback(components.queryItems ?? [])
    }

    /// Minimal black page in Sable's palette (background #000000, text #F2F1EC).
    static func page(_ message: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Sable</title></head>\
        <body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;\
        background:#000000;color:#F2F1EC;font:17px -apple-system,system-ui,sans-serif;text-align:center">\
        <p style="padding:24px">\(message)</p></body></html>
        """
    }
}
