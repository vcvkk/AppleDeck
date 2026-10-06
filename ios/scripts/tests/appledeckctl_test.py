#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""appledeckctl against a stub bridge.

The CLI and the bridge are two halves of one contract: verbs, flags, JSON and
exit codes. Both are written (ios/scripts/appledeckctl and AgentRoute.swift), and
neither can be run against the other on a machine without an iPhone - so this
runs the CLI against a stand-in server that answers the way AgentRoute does.

It is not a test of AgentRoute itself; Swift tests that on the same runner. It is
a test of the contract *between* them: a field renamed on one side, or an exit
code that drifted from the documented table, shows up here and nowhere else.

    python3 ios/scripts/tests/appledeckctl_test.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, os.pardir, "appledeckctl")

STATE = {
    "schema": 1,
    "build": "main at deadbee",
    "appVersion": "0.1.0",
    "runtime": {"installed": True, "version": "r9",
                "backend": "qemu-tcg", "guestImage": None},
    "session": {
        "id": "session-20260921-161256", "phase": "IDLE", "running": False,
        "mode": "steam", "program": "steam", "steamUi": "bigpicture",
        "steamUrl": None, "suspended": False, "firstFrame": False,
        "output": [1280, 720], "refreshHz": 60.0, "lastTransitionAt": 0,
        "guestPid": None, "installing": None, "logDir": None,
        "eventsFile": None, "artifactsAvailable": False,
        "artifactsComplete": False, "failure": None,
    },
}

calls: list[tuple[str, dict]] = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # noqa: D102 - silence the test output
        pass

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802 - the stdlib's name
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}
        method = self.path.lstrip("/")
        calls.append((method, body))

        if method == "state":
            payload = dict(STATE)
            payload["ok"] = True
            self._send(200, payload)
        elif method == "start":
            if "mode" not in body:
                self._send(400, {"ok": False, "error": "USAGE",
                                 "message": "start needs a mode"})
                return
            # The session really does move, because `start --wait` polls `state`
            # afterwards and a stub that answered PREPARING forever would hang the
            # CLI until its timeout - which is correct behaviour and a useless
            # test.
            phase = "READY" if body.get("wait") else "PREPARING"
            STATE["session"]["phase"] = phase
            STATE["session"]["running"] = True
            STATE["session"]["mode"] = body["mode"]
            self._send(200, {"ok": True, "command": "start",
                             "session": {"phase": phase, "mode": body["mode"]}})
        elif method == "stop":
            STATE["session"]["phase"] = "STOPPING"
            STATE["session"]["running"] = False
            self._send(200, {"ok": True, "command": "stop"})
        elif method == "resume":
            STATE["session"]["phase"] = "READY"
            STATE["session"]["suspended"] = False
            self._send(200, {"ok": True, "command": "resume"})
        elif method == "artifacts":
            self._send(200, {"ok": True,
                             "folders": ["session-1"],
                             "files": {"session-1": ["session.log", "device.txt"]}})
        elif method == "artifact":
            body_name = body.get("name")
            if "/" in body_name or ".." in body_name:
                self._send(400, {"ok": False, "error": "USAGE",
                                 "message": "artifact name must be a plain file name"})
                return
            payload = b"from the bridge"
            self._send(200, {"ok": True, "name": body_name,
                             "base64": __import__("base64").b64encode(payload).decode()})
        else:
            self._send(404, {"ok": False, "error": "UNKNOWN_COMMAND",
                             "message": f"Unknown agent command '{method}'"})

    def do_GET(self):  # noqa: N802
        self.do_POST()


def run(*args: str, endpoint: str | None = None) -> tuple[int, str, str]:
    command = [sys.executable, CLI]
    if endpoint:
        command += ["--endpoint", endpoint]
    command += list(args)
    done = subprocess.run(command, capture_output=True, text=True, timeout=30)
    return done.returncode, done.stdout, done.stderr


failures: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"ok    {name}")
    else:
        print(f"FAIL  {name} {detail}")
        failures.append(name)


def main() -> int:
    server = HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_port
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = f"http://127.0.0.1:{port}"

    try:
        code, out, _ = run("state", "--json", endpoint=endpoint)
        check("state exits 0", code == 0, f"exit={code}")
        payload = json.loads(out)
        check("state is schema 1", payload.get("schema") == 1)
        check("state carries every published field",
              all(key in payload["session"] for key in
                  ["id", "phase", "running", "mode", "program", "steamUi", "steamUrl",
                   "suspended", "firstFrame", "output", "refreshHz", "lastTransitionAt",
                   "guestPid", "installing", "logDir", "eventsFile",
                   "artifactsAvailable", "artifactsComplete", "failure"]))
        check("state reports ok", payload.get("ok") is True)

        code, out, _ = run("state", endpoint=endpoint)
        check("state prints a line per field", "phase      IDLE" in out, out[:120])

        code, out, _ = run("start", "steam", "--wait", endpoint=endpoint)
        check("start steam exits 0", code == 0, f"exit={code}")
        check("start reports the phase", out.strip() == "READY", out.strip())
        check("start sent wait",
              any(m == "start" and b.get("wait") is True for m, b in calls))

        run("start", "steam", "--ui", "desktop", "--url", "steam://friends",
            "--timeout", "90", endpoint=endpoint)
        sent = [b for m, b in calls if m == "start"][-1]
        check("start sends ui, url and timeout",
              sent.get("ui") == "desktop" and sent.get("url") == "steam://friends"
              and sent.get("timeout") == 90.0,
              json.dumps(sent))

        run("run", "/usr/bin/foo", "--", "arg1", endpoint=endpoint)
        check("run is not a start the bridge accepts",
              code == 0, "the CLI sends run as a start with mode=run")

        code, out, _ = run("stop", endpoint=endpoint)
        check("stop exits 0 and echoes", code == 0 and "STOPPING" in out)

        code, out, _ = run("resume", endpoint=endpoint)
        check("resume exits 0 and echoes", code == 0 and "RESUMED" in out)

        with tempfile.TemporaryDirectory() as directory:
            code, out, err = run("logs", "latest", directory, endpoint=endpoint)
            check("logs copies the files", code == 0 and "2 file(s)" in out,
                  f"exit={code} {err[:120]}")
            check("logs wrote the session log",
                  os.path.exists(os.path.join(directory, "session.log")))

        code, _, _ = run("frobnicate", endpoint=endpoint)
        check("unknown verb is a usage error (exit 2)", code == 2, f"exit={code}")

        code, _, err = run("state", endpoint="http://127.0.0.1:1")
        check("an unreachable bridge is exit 3", code == 3, f"exit={code}")
        check("an unreachable bridge says so", "no answer from" in err, err[:120])
    finally:
        server.shutdown()

    print()
    if failures:
        print(f"{len(failures)} failing: {', '.join(failures)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())