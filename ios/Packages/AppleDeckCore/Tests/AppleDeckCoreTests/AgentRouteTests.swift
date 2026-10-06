// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import AppleDeckCore

/// A backend that answers from a script, so each test says what the bridge is
/// supposed to do rather than how it is wired.
final class AgentRouteTests: XCTestCase {
    final class FakeBackend: AgentRoute.Backend, @unchecked Sendable {
        var state = Data(#"{"schema":1,"session":{"phase":"IDLE"}}"#.utf8)
        var startResult: Result<SessionPhase, Error> = .success(.preparing)
        var stopResult: Result<Void, Error> = .success(())
        var resumeResult: Result<Void, Error> = .success(())
        var folders: Result<[String: [String]], Error> = .success(["session-1": ["session.log"]])
        var artifacts: [String: Data] = ["session-1/session.log": Data("hello".utf8)]
        var runtime: (available: Bool, detail: String) = (true, "QEMU (TCG)")
        var startedWith: [AgentRoute.SessionStart] = []

        func statePayload() -> Data { state }
        func start(_ start: AgentRoute.SessionStart) throws -> SessionPhase {
            startedWith.append(start)
            return try startResult.get()
        }
        func stop() throws { try stopResult.get() }
        func resume() throws { try resumeResult.get() }
        func artifactFolders() throws -> [String: [String]] { try folders.get() }
        func artifact(folder: String, name: String) throws -> Data {
            guard let data = artifacts["\(folder)/\(name)"] else {
                throw AgentRoute.BridgeFailure(code: .artifactsUnavailable, message: "no such file")
            }
            return data
        }
        func runtimeStatus() -> (available: Bool, detail: String) { runtime }
    }

    private var backend = FakeBackend()
    private var route: AgentRoute { AgentRoute(backend: backend) }

    override func setUp() {
        super.setUp()
        backend = FakeBackend()
    }

    func testStateAddsOkToThePayload() throws {
        let response = route.handle(method: "state", body: nil)
        XCTAssertEqual(response.status, 200)
        let json = try XCTUnwrap(response.json)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["schema"] as? Int, 1)
    }

    func testUnknownMethodIsFourOhFour() throws {
        let response = route.handle(method: "frobnicate", body: nil)
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(response.json?["error"] as? String, "UNKNOWN_COMMAND")
        XCTAssertEqual(response.json?["ok"] as? Bool, false)
    }

    func testStartSteamDefaultsToBigPicture() throws {
        let response = route.handle(method: "start", body: Data(#"{"mode":"steam"}"#.utf8))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(backend.startedWith.count, 1)
        XCTAssertEqual(backend.startedWith.first?.ui, .bigPicture)
        XCTAssertEqual(response.json?["session"] as? [String: Any] != nil, true)
    }

    func testStartPassesUiUrlAndWait() throws {
        let body = #"{"mode":"steam","ui":"desktop","url":"steam://friends","wait":true,"timeout":90}"#
        _ = route.handle(method: "start", body: Data(body.utf8))
        let start = try XCTUnwrap(backend.startedWith.first)
        XCTAssertEqual(start.ui, .desktop)
        XCTAssertEqual(start.url, "steam://friends")
        XCTAssertTrue(start.wait)
        XCTAssertEqual(start.timeout, 90)
    }

    func testStartWithoutAModeIsAUsageError() {
        let response = route.handle(method: "start", body: Data(#"{"ui":"desktop"}"#.utf8))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(response.json?["error"] as? String, "USAGE")
    }

    func testStartWithAMalformedBodyIsAUsageError() {
        let response = route.handle(method: "start", body: Data("not json".utf8))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(response.json?["error"] as? String, "USAGE")
    }

    func testStopAndResumeEchoTheirCommand() throws {
        for verb in ["stop", "resume"] {
            let response = route.handle(method: verb, body: nil)
            XCTAssertEqual(response.status, 200, verb)
            XCTAssertEqual(response.json?["ok"] as? Bool, true, verb)
            XCTAssertEqual(response.json?["command"] as? String, verb)
        }
    }

    func testStopWithNoSessionIsReportedNotCrashed() throws {
        backend.stopResult = .failure(AgentRoute.BridgeFailure(code: .noSession,
                                                             message: "no session is running"))
        let response = route.handle(method: "stop", body: nil)
        XCTAssertEqual(response.status, 200, "a rejected command is a 200 with ok:false, like the provider")
        XCTAssertEqual(response.json?["ok"] as? Bool, false)
        XCTAssertEqual(response.json?["error"] as? String, "NO_SESSION")
    }

    func testHealthSaysWhyASessionCannotStart() throws {
        backend.runtime = (false, "libqemu-aarch64-softmmu.dylib is not in the bundle")
        let response = route.handle(method: "health", body: nil)
        let json = try XCTUnwrap(response.json)
        XCTAssertEqual(json["runtime"] as? Bool, false)
        XCTAssertEqual(json["detail"] as? String, "libqemu-aarch64-softmmu.dylib is not in the bundle")
    }

    func testArtifactsListsFoldersAndFiles() throws {
        let response = route.handle(method: "artifacts", body: nil)
        let json = try XCTUnwrap(response.json)
        XCTAssertEqual(json["folders"] as? [String], ["session-1"])
        let files = try XCTUnwrap(json["files"] as? [String: [String]])
        XCTAssertEqual(files["session-1"], ["session.log"])
    }

    func testArtifactReturnsBase64() throws {
        let response = route.handle(method: "artifact",
                                    body: Data(#"{"folder":"session-1","name":"session.log"}"#.utf8))
        let json = try XCTUnwrap(response.json)
        XCTAssertEqual(json["base64"] as? String, Data("hello".utf8).base64EncodedString())
    }

    func testArtifactRefusesAPathTraversal() {
        for name in ["../secret", "sub/dir", ".."] {
            let body = Data("{\"folder\":\"session-1\",\"name\":\"\(name)\"}".utf8)
            let response = route.handle(method: "artifact", body: body)
            XCTAssertEqual(response.status, 400, name)
            XCTAssertEqual(response.json?["error"] as? String, "USAGE", name)
        }
    }

    func testEveryRejectedCommandStillCarriesOkFalseAndACode() {
        let responses = [
            route.handle(method: "nope", body: nil),
            route.handle(method: "start", body: nil),
            route.handle(method: "artifact", body: Data(#"{"folder":"x"}"#.utf8))
        ]
        for response in responses {
            let json = response.json ?? [:]
            XCTAssertEqual(json["ok"] as? Bool, false)
            XCTAssertNotNil(json["error"] as? String)
            XCTAssertNotNil(json["message"] as? String)
        }
    }
}