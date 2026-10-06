// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The agent bridge, ported.
///
/// Upstream reaches it over `adb shell content call` against a `ContentProvider`
/// guarded by the shell-only `DUMP` permission, and ships `tools/droiddeckctl`
/// to wrap that. iOS has no adb and no way for a shell to reach an app, so the
/// bridge is an HTTP endpoint on the loopback interface and the CLI is the same
/// verb/flag/exit-code surface pointed at it. Everything else - the verbs, the
/// flags, the JSON, the exit codes - is DroidDeck's, because the point of the
/// agent bridge is that a test harness does not have to know which platform it
/// is driving.
public enum AgentCommand: Equatable, Sendable {
    case state
    case start(SessionStart)
    case run(program: String, arguments: [String])
    case stop
    case resume

    public struct SessionStart: Equatable, Sendable {
        public var mode: SessionMode
        public var ui: SessionRequest.SteamUI?
        public var url: String?
        public var wait: Bool
        public var timeout: TimeInterval?

        public init(mode: SessionMode,
                    ui: SessionRequest.SteamUI? = nil,
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

    /// Parses an argument vector the way `tools/droiddeckctl` builds it.
    ///
    /// Upstream's device resolution (`ADB_SERIAL`, then deduplicating transports
    /// that report one serial, then asking) has no iOS analogue: there is one
    /// device, it is the phone the app is on, and the serial flag is accepted
    /// and ignored so a script that sets it for Android still runs.
    public static func parse(_ arguments: [String]) throws -> AgentCommand {
        var args = arguments
        var serial: String?
        // --serial is accepted before the verb, as upstream's CLI accepts it.
        while let first = args.first, first == "--serial" {
            args.removeFirst()
            guard !args.isEmpty else { throw AgentError.usage("missing value for --serial") }
            serial = args.removeFirst()
        }
        _ = serial
        guard let verb = args.first else { throw AgentError.usage("no command") }
        args.removeFirst()

        switch verb {
        case "state":
            return .state
        case "stop":
            return .stop
        case "resume":
            return .resume
        case "start":
            let (rest, flags) = split(args)
            guard let first = rest.first else { throw AgentError.usage("start needs steam or desktop") }
            let mode: SessionMode
            switch first {
            case "steam": mode = .steam
            case "desktop": mode = .desktop
            case "run": mode = .run
            default: throw AgentError.usage("unknown start target '\(first)'")
            }
            let ui = flags["ui"].flatMap { SessionRequest.SteamUI(rawValue: $0) }
            let url = flags["url"]
            let wait = flags["wait"] != nil
            let timeout = flags["timeout"].flatMap(Double.init)
            if mode == .steam {
                return .start(SessionStart(mode: mode, ui: ui ?? .bigPicture, url: url, wait: wait, timeout: timeout))
            }
            return .start(SessionStart(mode: mode, ui: nil, url: nil, wait: wait, timeout: timeout))
        case "run":
            guard let program = args.first, program.hasPrefix("/") else {
                throw AgentError.usage("run needs an absolute program path")
            }
            args.removeFirst()
            // A literal `--` separates the program from its arguments, so a
            // guest argument that looks like a flag still arrives.
            if args.first == "--" { args.removeFirst() }
            return .run(program: program, arguments: args)
        default:
            throw AgentError.usage("unknown command '\(verb)'")
        }
    }

    /// The first bare word is the verb's target; everything after it that
    /// starts with `--` is a flag. `value` flags take the next argument.
    private static func split(_ args: [String]) -> ([String], [String: String]) {
        var positional: [String] = []
        var flags: [String: String] = [:]
        var index = 0
        let valueFlags: Set<String> = ["ui", "url", "timeout"]
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    flags[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
                } else if valueFlags.contains(name), index + 1 < args.count {
                    flags[name] = args[index + 1]
                    index += 1
                } else {
                    flags[name] = ""
                }
            } else {
                positional.append(arg)
            }
            index += 1
        }
        return (positional, flags)
    }

    /// The verb name a response echoes back.
    public var verb: String {
        switch self {
        case .state: return "state"
        case .start: return "start"
        case .run: return "run"
        case .stop: return "stop"
        case .resume: return "resume"
        }
    }
}

public enum AgentError: Error, Equatable, Sendable {
    /// Exit 2 upstream: invalid or rejected command.
    case usage(String)
    /// Exit 4: the session failed.
    case sessionFailed(String)
    /// Exit 5: a wait timed out.
    case timeout(String)
    /// Exit 3, 6 or 7: no bridge, artifact trouble, bad request.
    case transport(String)

    public var exitCode: Int32 {
        switch self {
        case .usage: return 2
        case .transport: return 3
        case .sessionFailed: return 4
        case .timeout: return 5
        }
    }

    public var message: String {
        switch self {
        case .usage(let text), .sessionFailed(let text),
             .timeout(let text), .transport(let text):
            return text
        }
    }
}

/// One line of `events.jsonl`: the session's transitions, in order, with the
/// phase names DroidDeck uses.
public struct SessionEvent: Codable, Equatable, Sendable {
    public var at: Int64
    public var from: SessionPhase?
    public var to: SessionPhase
    public var detail: String?

    public init(at: Int64, from: SessionPhase?, to: SessionPhase, detail: String? = nil) {
        self.at = at
        self.from = from
        self.to = to
        self.detail = detail
    }

    /// Appends itself to a file, one JSON object per line.
    public func append(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(self)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }
}