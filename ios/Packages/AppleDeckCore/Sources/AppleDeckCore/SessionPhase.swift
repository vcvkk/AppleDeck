// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The lifecycle values the agent bridge reports, kept byte-identical to
/// `SessionPhase` in `session/SessionPhase.kt` so a script written against
/// DroidDeck's `droiddeckctl state --json` parses AppleDeck's output without
/// being taught a second vocabulary.
///
/// Anything that adds a phase here has to add it there too, and the ordering
/// below is the order a session walks them in.
public enum SessionPhase: String, Codable, CaseIterable, Sendable {
    case idle = "IDLE"
    case preparing = "PREPARING"
    case installingRuntime = "INSTALLING_RUNTIME"
    case startingCompositor = "STARTING_COMPOSITOR"
    case startingGuest = "STARTING_GUEST"
    case startingSteam = "STARTING_STEAM"
    case ready = "READY"
    case suspended = "SUSPENDED"
    case stopping = "STOPPING"
    case failed = "FAILED"

    /// `ready` is the only phase a caller waits on: `wait ready` resolves here,
    /// or in `failed`, or on the timeout.
    public var isLive: Bool {
        switch self {
        case .preparing, .installingRuntime, .startingCompositor,
             .startingGuest, .startingSteam, .ready, .suspended:
            return true
        case .idle, .stopping, .failed:
            return false
        }
    }

    /// Phases that come before the guest is up. The launcher shows its progress
    /// panel for these and nothing else, which is why the runtime installer gets
    /// its own phase: on iOS it is the slowest step by an order of magnitude.
    public var isPreparing: Bool {
        switch self {
        case .preparing, .installingRuntime, .startingCompositor,
             .startingGuest, .startingSteam:
            return true
        default:
            return false
        }
    }

    /// The phases a session can legally move to next. A coordinator that
    /// proposes anything else has a bug, and `SessionStateMachine` says so
    /// instead of quietly accepting a transition that leaves the state
    /// unrepresentable (for example `ready` straight back to `preparing`).
    public func canTransition(to next: SessionPhase) -> Bool {
        switch (self, next) {
        case (.idle, .preparing),
             (.preparing, .installingRuntime), (.preparing, .startingCompositor),
             (.installingRuntime, .startingCompositor),
             (.startingCompositor, .startingGuest),
             (.startingGuest, .startingSteam),
             (.startingGuest, .ready),
             (.startingSteam, .ready),
             (.ready, .suspended), (.ready, .stopping), (.ready, .failed),
             (.suspended, .ready), (.suspended, .stopping),
             (.stopping, .idle),
             (.preparing, .failed), (.installingRuntime, .failed),
             (.startingCompositor, .failed), (.startingGuest, .failed),
             (.startingSteam, .failed):
            return true
        default:
            return false
        }
    }
}

/// The two session modes, named as `SessionService.MODE_STEAM` and
/// `MODE_DESKTOP` are upstream so a `droiddeckctl start <mode>` script ports
/// over unchanged.
public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case steam
    case desktop
    /// The third mode upstream has: a bare program in the runtime, started by
    /// `droiddeckctl run /usr/bin/foo -- arg1 arg2`.
    case run

    public var acceptsProgram: Bool { self == .run }
}

/// What a session was asked to play. Mirrors the fields `SessionState` carries
/// across the activity/service split; on iOS there is no split (one process,
/// one coordinator) but the agent bridge still reports them, because that is
/// the contract `state` publishes.
public enum SessionRequest: Codable, Equatable, Sendable {
    /// Steam Big Picture, or Steam's own desktop UI, optionally with a URL.
    case steam(ui: SteamUI, url: String?)
    /// The labwc desktop and the programs on it.
    case desktop
    /// A program path inside the runtime, with guest arguments.
    case run(program: String, arguments: [String])

    public enum SteamUI: String, Codable, Sendable {
        case bigPicture
        case desktop

        public var rawValue: String {
            switch self {
            case .bigPicture: return "bigpicture"
            case .desktop: return "desktop"
            }
        }
    }

    public var mode: SessionMode {
        switch self {
        case .steam: return .steam
        case .desktop: return .desktop
        case .run: return .run
        }
    }

    /// The `program` field of the state payload: the path for a bare program,
    /// `steam` or `desktop` otherwise.
    public var programName: String? {
        switch self {
        case .steam: return "steam"
        case .desktop: return "desktop"
        case .run(let program, _): return program
        }
    }
}