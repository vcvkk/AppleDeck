// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Network
import AppleDeckCore

/// The agent bridge's transport: a loopback HTTP listener over `AgentRoute`.
///
/// Deliberately thin. Everything that decides what a request means lives in
/// `AgentRoute`, where it is tested on a Linux runner; this file only accepts a
/// connection, reads a body, hands it over and writes the response back.
///
/// Why loopback HTTP and not a Unix socket: iOS gives an app no way for a shell
/// to reach it, and a Mac's tooling - curl, a shell function, `appledeckctl` -
/// speaks HTTP without an SDK. The port is 8765, on 127.0.0.1 only, so nothing
/// off the phone can reach it.
@MainActor
final class AgentBridgeServer {
    /// Where it listens, printed into the session log so a Mac can be pointed at
    /// it without reading the source.
    static let port: UInt16 = 8765

    private let route: AgentRoute
    private var listener: NWListener?
    private(set) var isRunning = false

    init(route: AgentRoute) {
        self.route = route
    }

    func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: Self.port) else {
            throw AgentRoute.BridgeFailure(code: .transport,
                                           message: "port \(Self.port) is out of range")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only. A listener that says "on everything" is not a knob worth
        // having on a bridge that can start and stop sessions.
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters, on: endpoint)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        listener.stateUpdateHandler = { [weak self] (state: NWListener.State) in
            Task { @MainActor in
                switch state {
                case .ready: self?.isRunning = true
                case .failed, .cancelled: self?.isRunning = false
                default: break
                }
            }
        }
        self.listener = listener
        listener.start(queue: DispatchQueue.main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, body: Data())
    }

    /// Reads until the request stops growing. The bodies here are small and the
    /// clients are single-shot requests, so a size cap and "the first request
    /// that fits" is a complete implementation - anything more would be a parser
    /// for a protocol nobody needs.
    private func receive(_ connection: NWConnection, body: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = body
            if let data { accumulated.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            if isComplete {
                let response = self.respond(to: accumulated)
                self.write(response, to: connection)
                return
            }
            self.receive(connection, body: accumulated)
        }
    }

    /// Turns one request buffer into a response.
    ///
    /// The request line is parsed by hand because the only clients are ours and
    /// their shapes are fixed: `POST /<method> HTTP/1.1`, a header block, then a
    /// body whose length is in Content-Length. A URLSession-style client with a
    /// chunked body would not parse, and would say so: an unparseable request
    /// gets 400 with an explanation rather than being treated as a method name.
    func respond(to request: Data) -> AgentRoute.Response {
        let text = String(decoding: request, as: UTF8.self)
        guard let lineEnd = text.range(of: "\r\n") else {
            return badRequest("no request line")
        }
        let requestLine = text[text.startIndex..<lineEnd.lowerBound]
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else {
            return badRequest("malformed request line '\(requestLine)'")
        }
        let method = String(parts[1].dropFirst())     // strip the leading '/'
        let headers = String(text[lineEnd.upperBound...])
        guard let separator = headers.range(of: "\r\n\r\n") else {
            return badRequest("no header terminator")
        }
        var body = Data(headers[separator.upperBound...].utf8)
        // Content-Length first, then whatever arrived: a client that sends less
        // than it promised gets the rest of what it sent read, not a hang.
        let length = headers[headers.startIndex..<separator.lowerBound]
            .split(separator: "\r\n")
            .compactMap { header -> Int? in
                let parts = header.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
            .first
        if let length, length > body.count {
            // Nothing more is coming on this connection if the client half-closed;
            // waiting would hang, so answer with what has been read.
            body = Data(body.prefix(length))
        }
        if method.isEmpty { return badRequest("no method in '\(requestLine)'") }
        return route.handle(method: method, body: body.isEmpty ? nil : body)
    }

    private func badRequest(_ message: String) -> AgentRoute.Response {
        AgentRoute.Response(status: 400,
                            body: Data(#"{"ok":false,"error":"USAGE","message":"\#(message)"}"#.utf8))
    }

    private func write(_ response: AgentRoute.Response, to connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status)
            .capitalized(with: .current)
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var buffer = Data(head.utf8)
        buffer.append(response.body)
        connection.send(content: buffer, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// The session controller, seen as the bridge's backend.
///
/// The bridge is synchronous - `appledeckctl` expects an answer to the request it
/// sent - and the session controller is main-actor bound, so every answer hops
/// back to the main actor. The listener is already delivering on the main queue,
/// so that hop is a no-op in practice and correct if it ever is not.
extension SessionController: AgentRoute.Backend {
    nonisolated func sessionStatePayload() -> Data {
        MainActor.assumeIsolated { statePayload }
    }

    nonisolated func startSession(_ request: AgentRoute.SessionStart) throws -> SessionPhase {
        // Result, not throws: assumeIsolated has no throwing overload on every
        // toolchain, and the alternative - a second copy of the guard on the main
        // actor - is a race.
        let outcome: Result<SessionPhase, Error> = MainActor.assumeIsolated {
            guard canStart else {
                return .failure(AgentRoute.BridgeFailure(
                    code: .noSession, message: "a session is already running"))
            }
            switch request.mode {
            case .steam: start(.steam(ui: request.ui, url: request.url))
            case .desktop: start(.desktop)
            case .run:
                return .failure(AgentRoute.BridgeFailure(
                    code: .usage, message: "run needs a program path"))
            }
            return .success(phase)
        }
        return try outcome.get()
    }

    nonisolated func stopSession() throws {
        let outcome: Result<Void, Error> = MainActor.assumeIsolated {
            guard phase.isLive else {
                return .failure(AgentRoute.BridgeFailure(
                    code: .noSession, message: "no session is running"))
            }
            stop()
            return .success(())
        }
        try outcome.get()
    }

    nonisolated func resumeSession() throws {
        let outcome: Result<Void, Error> = MainActor.assumeIsolated {
            guard phase == .suspended else {
                return .failure(AgentRoute.BridgeFailure(
                    code: .noSession, message: "the session is not suspended"))
            }
            toggleSuspend()
            return .success(())
        }
        try outcome.get()
    }

    nonisolated func artifactFolders() throws -> [String: [String]] {
        MainActor.assumeIsolated {
            guard let directory = logDirectory else { return [:] }
            let url = URL(fileURLWithPath: directory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return [url.lastPathComponent: names]
        }
    }

    nonisolated func artifact(folder: String, name: String) throws -> Data {
        let outcome: Result<Data, Error> = MainActor.assumeIsolated {
            guard let directory = logDirectory,
                  URL(fileURLWithPath: directory).lastPathComponent == folder else {
                return .failure(AgentRoute.BridgeFailure(
                    code: .artifactsUnavailable, message: "no session folder named \(folder)"))
            }
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else {
                return .failure(AgentRoute.BridgeFailure(
                    code: .artifactsUnavailable, message: "no such file"))
            }
            return .success(data)
        }
        return try outcome.get()
    }

    nonisolated func runtimeStatus() -> (available: Bool, detail: String) {
        MainActor.assumeIsolated { (sessionRuntimeAvailable, sessionRuntimeDetail) }
    }
}
