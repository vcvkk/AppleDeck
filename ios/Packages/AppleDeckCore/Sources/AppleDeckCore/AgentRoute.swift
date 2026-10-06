// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The agent bridge's routing: a method name and a body in, a response out.
///
/// Split out of the server on purpose. The transport is `NWListener` on iOS and
/// nothing else, which means it cannot be tested on the runner that tests the
/// rest of this package in seconds. What *can* be tested is everything that
/// decides what a request means and what comes back, and that is where the
/// mistakes live: a verb that answers the wrong field, an error code that does
/// not match the CLI's exit codes, a body that is valid JSON in the wrong shape.
///
/// The verbs and their JSON are DroidDeck's (`app/src/debug/.../AgentBridgeProvider.kt`
/// and `docs/agent-control.md`), because a harness written against `droiddeckctl`
/// has to drive AppleDeck with the same expressions.
public struct AgentRoute: Sendable {
    /// What the app has to answer a request. Implemented by the session
    /// controller on iOS; a fake in the tests.
    public protocol Backend: AnyObject, Sendable {
        /// The schema-1 payload, as JSON bytes.
        func statePayload() -> Data
        /// Starts a session. Returns the phase it entered, or an error.
        func start(_ start: AgentRoute.SessionStart) throws -> SessionPhase
        /// Stops the running session. Throws when there is nothing to stop.
        func stop() throws
        /// Resumes a suspended session. Throws when it is not suspended.
        func resume() throws
        /// The session folders on the device, newest last, with their file lists.
        func artifactFolders() throws -> [String: [String]]
        /// One file's bytes.
        func artifact(folder: String, name: String) throws -> Data
        /// Whether anything can start a session at all, and why not if not.
        func runtimeStatus() -> (available: Bool, detail: String)
    }

    public struct SessionStart: Equatable, Sendable {
        public var mode: SessionMode
        public var ui: SessionRequest.SteamUI
        public var url: String?
        public var wait: Bool
        public var timeout: TimeInterval?

        public init(mode: SessionMode,
                    ui: SessionRequest.SteamUI = .bigPicture,
                    url: String? = nil,
                    wait: Bool = false,
                    timeout: TimeInterval? = nil) {
            self.mode = mode
            self.ui = ui
            self.url = url
            self.wait = wait
            self.timeout = timeout
        }
    }

    public struct Response: Equatable, Sendable {
        public var status: Int
        public var body: Data

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }

        public var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    /// The bridge's error codes. DroidDeck's provider answers `UNKNOWN_COMMAND`
    /// and `COMMAND_FAILED`; `USAGE` and `NO_SESSION` are Apple's additions for
    /// the two cases adb could not produce - a malformed request from a Mac, and
    /// a command that needs a session which is not there.
    public enum BridgeError: String, Sendable {
        case unknownCommand = "UNKNOWN_COMMAND"
        case commandFailed = "COMMAND_FAILED"
        case usage = "USAGE"
        case noSession = "NO_SESSION"
        case artifactsUnavailable = "ARTIFACTS_UNAVAILABLE"
    }

    public let backend: Backend

    public init(backend: Backend) {
        self.backend = backend
    }

    /// Handles one request. `path` is the method name: the CLI posts to
    /// `http://127.0.0.1:8765/<method>`, which is the shape a Mac's curl, a
    /// shell function or `appledeckctl` all speak without an SDK.
    public func handle(method: String, body: Data?) -> Response {
        switch method {
        case "state":
            return ok(backend.statePayload())

        case "health":
            // Not DroidDeck's: the one thing a person setting this up needs is to
            // know whether the bridge is even listening, without parsing a
            // session payload.
            let status = backend.runtimeStatus()
            return json(200, ["ok": true,
                              "runtime": status.available,
                              "detail": status.detail,
                              "schema": 1])

        case "start":
            return handleStart(body)

        case "stop":
            do {
                try backend.stop()
                return json(200, ["ok": true, "command": "stop"])
            } catch {
                return failure(error, fallback: .noSession)
            }

        case "resume":
            do {
                try backend.resume()
                return json(200, ["ok": true, "command": "resume"])
            } catch {
                return failure(error, fallback: .noSession)
            }

        case "artifacts":
            do {
                let folders = try backend.artifactFolders()
                return json(200, ["ok": true, "folders": folders.keys.sorted(), "files": folders])
            } catch {
                return failure(error, fallback: .artifactsUnavailable)
            }

        case "artifact":
            return handleArtifact(body)

        default:
            return error(404, .unknownCommand, "Unknown agent command '\(method)'")
        }
    }

    private func handleStart(_ body: Data?) -> Response {
        let request = (try? JSONDecoder().decode(StartRequest.self, from: body ?? Data("{}".utf8)))
        guard let request, request.mode != .run else {
            return error(400, .usage,
                         "start needs a mode: {\"mode\":\"steam\"|\"desktop\"}")
        }
        let start = SessionStart(mode: request.mode,
                                 ui: request.ui ?? .bigPicture,
                                 url: request.url,
                                 wait: request.wait ?? false,
                                 timeout: request.timeout)
        do {
            let phase = try backend.start(start)
            return json(200, ["ok": true,
                              "command": "start",
                              "session": ["phase": phase.rawValue, "mode": request.mode.rawValue]])
        } catch {
            return failure(error, fallback: .commandFailed)
        }
    }

    private func handleArtifact(_ body: Data?) -> Response {
        struct Ask: Decodable {
            var folder: String
            var name: String
        }
        guard let ask = try? JSONDecoder().decode(Ask.self, from: body ?? Data()),
              !ask.folder.isEmpty, !ask.name.isEmpty else {
            return error(400, .usage, "artifact needs {\"folder\":...,\"name\":...}")
        }
        // The name is a path traversal waiting to happen if it is not checked
        // here: this is an HTTP endpoint, and the only thing between it and the
        // app's container is this comparison.
        if ask.name.contains("/") || ask.name.contains("..") {
            return error(400, .usage, "artifact name must be a plain file name")
        }
        do {
            let data = try backend.artifact(folder: ask.folder, name: ask.name)
            return json(200, ["ok": true, "name": ask.name, "base64": data.base64EncodedString()])
        } catch {
            return failure(error, fallback: .artifactsUnavailable)
        }
    }

    // MARK: - Responses

    private func ok(_ payload: Data) -> Response {
        // The state payload already carries every field; `ok` is added here
        // rather than in the payload so the state object stays byte-compatible
        // with what the provider puts beside it.
        guard var object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return json(500, ["ok": false, "error": BridgeError.commandFailed.rawValue,
                              "message": "the state payload is not a JSON object"])
        }
        object["ok"] = true
        return json(200, object)
    }

    private func json(_ status: Int, _ object: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                               options: [.sortedKeys])) ?? Data("{}".utf8)
        return Response(status: status, body: data)
    }

    private func error(_ status: Int, _ code: BridgeError, _ message: String) -> Response {
        json(status, ["ok": false, "error": code.rawValue, "message": message])
    }

    private func failure(_ error: Error, fallback: BridgeError) -> Response {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let code = (error as? BridgeFailure)?.code ?? fallback
        return error(200, code, message)
    }

    /// A backend that wants a different error code than the fallback.
    public struct BridgeFailure: Error {
        public var code: BridgeError
        public var message: String

        public init(code: BridgeError, message: String) {
            self.code = code
            self.message = message
        }
    }

    /// The body `start` takes. `run` is refused here for the reason upstream
    /// gives: on Android a background provider cannot open a session screen, so
    /// `run` goes through the same path as `start` rather than being refused.
    struct StartRequest: Decodable {
        var mode: SessionMode
        var ui: SessionRequest.SteamUI?
        var url: String?
        var wait: Bool?
        var timeout: Double?
    }
}