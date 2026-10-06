// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import AppleDeckCore

final class SessionStateTests: XCTestCase {
    private func machine() -> SessionStateMachine {
        SessionStateMachine(now: { 1_700_000_000_000 })
    }

    func testPhaseNamesMatchDroidDeck() {
        // The agent bridge's vocabulary. If this fails, every script written
        // against `droiddeckctl state` is broken by this port.
        XCTAssertEqual(SessionPhase.allCases.map(\.rawValue),
                       ["IDLE", "PREPARING", "INSTALLING_RUNTIME", "STARTING_COMPOSITOR",
                        "STARTING_GUEST", "STARTING_STEAM", "READY", "SUSPENDED",
                        "STOPPING", "FAILED"])
    }

    func testWalkToReady() {
        let m = machine()
        var seen: [SessionPhase] = []
        m.onTransition = { _, to, _ in seen.append(to) }
        XCTAssertTrue(m.begin(id: "s1", request: .steam(ui: .bigPicture, url: nil)))
        XCTAssertTrue(m.transition(to: .startingCompositor))
        XCTAssertTrue(m.transition(to: .startingGuest))
        XCTAssertTrue(m.transition(to: .startingSteam))
        XCTAssertTrue(m.transition(to: .ready))
        XCTAssertEqual(seen, [.preparing, .startingCompositor, .startingGuest, .startingSteam, .ready])
        XCTAssertEqual(m.phase, .ready)
        XCTAssertTrue(m.phase.isLive)
    }

    func testIllegalTransitionIsRejectedAndChangesNothing() {
        let m = machine()
        _ = m.begin(id: "s1", request: .desktop)
        XCTAssertFalse(m.transition(to: .ready), "preparing -> ready is not a walk any session takes")
        XCTAssertEqual(m.phase, .preparing)
    }

    func testReenteringTheSamePhaseIsNotATransition() {
        let m = machine()
        _ = m.begin(id: "s1", request: .desktop)
        XCTAssertTrue(m.transition(to: .startingCompositor))
        XCTAssertFalse(m.transition(to: .startingCompositor),
                       "a repeated phase would double-count in events.jsonl")
    }

    func testSuspendAndResumeArePhasesOfALiveSession() {
        let m = machine()
        _ = m.begin(id: "s1", request: .steam(ui: .bigPicture, url: nil))
        _ = m.transition(to: .startingCompositor)
        _ = m.transition(to: .startingGuest)
        _ = m.transition(to: .ready)
        XCTAssertTrue(m.setSuspended(true))
        XCTAssertEqual(m.phase, .suspended)
        XCTAssertTrue(m.suspended)
        XCTAssertTrue(m.setSuspended(false))
        XCTAssertEqual(m.phase, .ready)
    }

    func testSuspendIsRejectedBeforeTheGuestIsUp() {
        let m = machine()
        _ = m.begin(id: "s1", request: .desktop)
        XCTAssertFalse(m.setSuspended(true))
        XCTAssertFalse(m.suspended)
    }

    func testFailureFromAnyLivePhase() {
        for start: SessionPhase in [.preparing, .installingRuntime, .startingCompositor,
                                    .startingGuest, .startingSteam] {
            let m = machine()
            _ = m.begin(id: "s", request: .desktop)
            if start != .preparing {
                _ = m.transition(to: .startingCompositor)
                _ = m.transition(to: .startingGuest)
                if start == .startingSteam { _ = m.transition(to: .startingSteam) }
            }
            XCTAssertTrue(m.fail(code: "runtime.missing", message: "no guest image", status: 1))
            XCTAssertEqual(m.phase, .failed)
            XCTAssertEqual(m.failure?.code, "runtime.missing")
        }
    }

    func testBeginResetsThePreviousSession() {
        let m = machine()
        _ = m.begin(id: "s1", request: .steam(ui: .bigPicture, url: nil))
        _ = m.transition(to: .startingCompositor)
        _ = m.transition(to: .startingGuest)
        _ = m.transition(to: .ready)
        m.guestPID = 4242
        m.firstFrameSeen = true
        _ = m.fail(code: "gone", message: nil, status: 1)
        _ = m.finish()

        XCTAssertTrue(m.begin(id: "s2", request: .desktop))
        XCTAssertEqual(m.phase, .preparing)
        XCTAssertNil(m.failure)
        XCTAssertNil(m.guestPID)
        XCTAssertFalse(m.firstFrameSeen)
    }

    func testPayloadIsSchemaOneWithDroidDeckKeys() throws {
        let m = machine()
        _ = m.begin(id: "session-20260921-161256", request: .steam(ui: .bigPicture, url: "steam://store"))
        _ = m.transition(to: .startingCompositor)
        _ = m.transition(to: .startingGuest)
        _ = m.transition(to: .ready)
        m.guestPID = 777
        m.outputSize = .init(width: 2560, height: 1440)

        let data = m.payload(build: "main at abc1234",
                             appVersion: "0.2.0",
                             runtime: .init(installed: true, version: "r10",
                                            backend: "qemu-tcg", guestImage: "alpine-3.20-arm64"))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["build"] as? String, "main at abc1234")
        let runtime = object["runtime"] as! [String: Any]
        XCTAssertEqual(runtime["installed"] as? Bool, true)
        XCTAssertEqual(runtime["version"] as? String, "r10")
        let session = object["session"] as! [String: Any]
        for key in ["id", "phase", "running", "mode", "program", "steamUi", "steamUrl", "suspended",
                    "firstFrame", "output", "refreshHz", "lastTransitionAt", "guestPid",
                    "installing", "logDir", "eventsFile", "artifactsAvailable",
                    "artifactsComplete", "failure"] {
            XCTAssertNotNil(session[key], "state.\(key) is part of the published schema")
        }
        XCTAssertEqual(session["phase"] as? String, "READY")
        XCTAssertEqual(session["mode"] as? String, "steam")
        XCTAssertEqual(session["program"] as? String, "steam")
        XCTAssertEqual(session["steamUi"] as? String, "bigpicture")
        XCTAssertEqual(session["steamUrl"] as? String, "steam://store")
        XCTAssertEqual(session["guestPid"] as? Int, 777)
        XCTAssertEqual(session["output"] as? [Int], [2560, 1440])
        XCTAssertTrue(session["failure"] is NSNull, "no failure is null, never absent")
    }

    func testGuestPidOfOneIsNull() {
        let m = machine()
        _ = m.begin(id: "s", request: .desktop)
        m.guestPID = 1
        let data = m.payload(build: "b", appVersion: "1", runtime: .init(installed: false, version: nil, backend: nil, guestImage: nil))
        let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue((session?["session"] as? [String: Any])?["guestPid"] is NSNull)
    }

    func testArtifactFolderName() {
        // The stamp is UTC and US-formatted, exactly as upstream, so a bundle
        // from either platform sorts the same way.
        let name = SessionArtifacts.folderName(Date(timeIntervalSince1970: 1_695_934_376))
        XCTAssertEqual(name, "session-20230928-205256")
    }

    func testEventLineIsOneJSONObject() throws {
        let event = SessionEvent(at: 5, from: .preparing, to: .startingGuest)
        let line = try JSONEncoder().encode(event)
        let object = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        XCTAssertEqual(object["to"] as? String, "STARTING_GUEST")
        XCTAssertEqual(object["from"] as? String, "PREPARING")
    }
}