// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The `state` payload of the agent bridge, schema 1.
///
/// The field names and shapes are DroidDeck's, not Apple's: `state` is a
/// published contract (`docs/agent-control.md` upstream) and a test harness
/// driving DroidDeck over `adb` has to drive AppleDeck over its local socket
/// with the same jq expressions. Fields AppleDeck cannot fill are `null`, never
/// omitted.
public struct SessionStatePayload: Codable, Equatable, Sendable {
    public var schema: Int
    public var build: String
    public var appVersion: String
    public var runtime: RuntimeInfo
    public var session: SessionInfo
    /// Only present on a response to a command, never inside `state`. Upstream
    /// puts `ok` and `command` beside the state object; here `state` is its own
    /// object and the envelope carries those two keys.
    public var ok: Bool?
    public var command: String?

    public struct RuntimeInfo: Codable, Equatable, Sendable {
        public var installed: Bool
        public var version: String?
        /// AppleDeck adds one key DroidDeck has no way to express: which runtime
        /// backend a session would use, and what it found. `null` when no
        /// backend is available at all (no QEMU dylib built, no guest image).
        public var backend: String?
        public var guestImage: String?

        // Written out rather than left as the memberwise initialiser: that one
        // is internal, and the app - which imports this package plainly, not
        // with @testable - has to be able to build this.
        public init(installed: Bool,
                    version: String? = nil,
                    backend: String? = nil,
                    guestImage: String? = nil) {
            self.installed = installed
            self.version = version
            self.backend = backend
            self.guestImage = guestImage
        }
    }

    public struct SessionInfo: Codable, Equatable, Sendable {
        public var id: String
        public var phase: SessionPhase
        public var running: Bool
        public var mode: String
        public var program: String?
        public var steamUi: String?
        public var steamUrl: String?
        public var suspended: Bool
        public var firstFrame: Bool
        public var output: OutputSize
        public var refreshHz: Double
        public var lastTransitionAt: Int64
        public var guestPid: Int32?
        public var installing: String?
        public var logDir: String?
        public var eventsFile: String?
        public var artifactsAvailable: Bool
        public var artifactsComplete: Bool
        public var failure: Failure?

        // Encoded by hand for one reason: a synthesized Codable encoder omits a nil
        // optional instead of writing null, and `state` is a published shape whose
        // fields are all present whether or not they have a value. A harness doing
        // `jq .session.logDir` has to get null, not nothing.
        enum CodingKeys: String, CodingKey {
            case id, phase, running, mode, program, steamUi, steamUrl, suspended
            case firstFrame, output, refreshHz, lastTransitionAt, guestPid
            case installing, logDir, eventsFile, artifactsAvailable
            case artifactsComplete, failure
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(phase, forKey: .phase)
            try c.encode(running, forKey: .running)
            try c.encode(mode, forKey: .mode)
            try c.encodeOrNull(program, forKey: .program)
            try c.encodeOrNull(steamUi, forKey: .steamUi)
            try c.encodeOrNull(steamUrl, forKey: .steamUrl)
            try c.encode(suspended, forKey: .suspended)
            try c.encode(firstFrame, forKey: .firstFrame)
            try c.encode(output, forKey: .output)
            try c.encode(refreshHz, forKey: .refreshHz)
            try c.encode(lastTransitionAt, forKey: .lastTransitionAt)
            try c.encodeOrNull(guestPid, forKey: .guestPid)
            try c.encodeOrNull(installing, forKey: .installing)
            try c.encodeOrNull(logDir, forKey: .logDir)
            try c.encodeOrNull(eventsFile, forKey: .eventsFile)
            try c.encode(artifactsAvailable, forKey: .artifactsAvailable)
            try c.encode(artifactsComplete, forKey: .artifactsComplete)
            try c.encodeOrNull(failure, forKey: .failure)
        }
    }

    public struct OutputSize: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        // A two-element array, not an object. DroidDeck writes
        // JSONArray().put(width).put(height), and a harness reading
        // `.session.output[0]` has to find a number there.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(width)
            try c.encode(height)
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            width = try c.decode(Int.self)
            height = try c.decode(Int.self)
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public var code: String
        public var message: String?
        public var status: Int?

        public init(code: String, message: String?, status: Int?) {
            self.code = code
            self.message = message
            self.status = status
        }

        enum CodingKeys: String, CodingKey { case code, message, status }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(code, forKey: .code)
            try c.encodeOrNull(message, forKey: .message)
            try c.encodeOrNull(status, forKey: .status)
        }
    }


    public init(schema: Int = 1,
                build: String,
                appVersion: String,
                runtime: RuntimeInfo,
                session: SessionInfo) {
        self.schema = schema
        self.build = build
        self.appVersion = appVersion
        self.runtime = runtime
        self.session = session
    }

    private enum CodingKeys: String, CodingKey {
        case schema, build, appVersion, runtime, session, ok, command
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(build, forKey: .build)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(runtime, forKey: .runtime)
        try c.encode(session, forKey: .session)
        try c.encodeIfPresent(ok, forKey: .ok)
        try c.encodeIfPresent(command, forKey: .command)
    }
}

/// The one place a phase changes.
///
/// Every transition goes through `transition(to:at:)`, which validates it
/// against `SessionPhase.canTransition(to:)`, stamps `lastTransitionAt` and
/// appends a line to `events.jsonl`. Upstream does this from a service and an
/// activity with two `volatile` fields between them; on iOS there is one
/// coordinator, so the invariant is enforceable and is enforced.
public final class SessionStateMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var _phase: SessionPhase = .idle
    private var _sessionID: String?
    private var _request: SessionRequest?
    private var _suspended = false
    private var _firstFrame = false
    private var _failure: SessionStatePayload.Failure?
    private var _lastTransitionAt: Int64 = 0
    private var _guestPID: Int32?
    private var _installing: String?
    private var _output = SessionStatePayload.OutputSize(width: 1920, height: 1080)
    private var _refreshHz: Double = 60

    /// Called for every accepted transition, in order, on whatever thread made
    /// it. The coordinator uses it to write `events.jsonl` and to update the UI.
    public var onTransition: ((SessionPhase, SessionPhase, Int64) -> Void)?

    public init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    private let now: () -> Int64

    public var phase: SessionPhase {
        lock.lock(); defer { lock.unlock() }
        return _phase
    }

    public var sessionID: String? {
        get { lock.lock(); defer { lock.unlock() }; return _sessionID }
    }

    public var request: SessionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
    }

    public var suspended: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _suspended }
    }

    public var firstFrameSeen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _firstFrame }
        set { lock.lock(); _firstFrame = newValue; lock.unlock() }
    }

    public var failure: SessionStatePayload.Failure? {
        get { lock.lock(); defer { lock.unlock() }; return _failure }
    }

    public var guestPID: Int32? {
        get { lock.lock(); defer { lock.unlock() }; return _guestPID }
        set { lock.lock(); _guestPID = newValue; lock.unlock() }
    }

    public var installing: String? {
        get { lock.lock(); defer { lock.unlock() }; return _installing }
        set { lock.lock(); _installing = newValue; lock.unlock() }
    }

    public var outputSize: SessionStatePayload.OutputSize {
        get { lock.lock(); defer { lock.unlock() }; return _output }
        set { lock.lock(); _output = newValue; lock.unlock() }
    }

    public var refreshHz: Double {
        get { lock.lock(); defer { lock.unlock() }; return _refreshHz }
        set { lock.lock(); _refreshHz = newValue; lock.unlock() }
    }

    /// Begins a session. Clears everything the last one left behind, which is
    /// why it is not a transition from `idle` with a stale request attached.
    @discardableResult
    public func begin(id: String, request: SessionRequest, at explicitTime: Int64? = nil) -> Bool {
        lock.lock()
        let allowed = _phase == .idle || _phase == .stopping
        if allowed {
            _sessionID = id
            _request = request
            _suspended = false
            _firstFrame = false
            _failure = nil
            _guestPID = nil
            _installing = nil
        }
        let at = explicitTime ?? now()
        if allowed {
            _phase = .preparing
            _lastTransitionAt = at
        }
        let listener = onTransition
        lock.unlock()
        if allowed { listener?(.idle, .preparing, at) }
        return allowed
    }

    /// Moves to `next`, or returns false and changes nothing if the move is not
    /// legal from here. Re-entering the same phase is not a transition and is
    /// also rejected: it would double-count in `events.jsonl`.
    @discardableResult
    public func transition(to next: SessionPhase, at explicitTime: Int64? = nil) -> Bool {
        lock.lock()
        guard _phase.canTransition(to: next) else { lock.unlock(); return false }
        let previous = _phase
        let at = explicitTime ?? now()
        _phase = next
        _lastTransitionAt = at
        if next == .stopping || next == .idle { _suspended = false }
        let listener = onTransition
        lock.unlock()
        listener?(previous, next, at)
        return true
    }

    /// Suspend/resume, which are a property of a live session rather than a
    /// phase of their own: `ready` and `suspended` are both live, and
    /// `droiddeckctl resume` has to work from either.
    @discardableResult
    public func setSuspended(_ value: Bool) -> Bool {
        lock.lock()
        guard _phase == .ready || _phase == .suspended else { lock.unlock(); return false }
        _suspended = value
        let previous = _phase
        let next: SessionPhase = value ? .suspended : .ready
        let at = now()
        _phase = next
        let listener = onTransition
        lock.unlock()
        if previous != next { listener?(previous, next, at) }
        return true
    }

    @discardableResult
    public func fail(code: String, message: String? = nil, status: Int? = nil) -> Bool {
        lock.lock()
        _failure = SessionStatePayload.Failure(code: code, message: message, status: status)
        let allowed = _phase.canTransition(to: .failed)
        let previous = _phase
        let at = now()
        if allowed { _phase = .failed; _lastTransitionAt = at }
        let listener = onTransition
        lock.unlock()
        if allowed { listener?(previous, .failed, at) }
        return allowed
    }

    /// Ends the session and returns to `idle`, ready for the next `begin`.
    public func finish() {
        lock.lock()
        let previous = _phase
        let at = now()
        _phase = .idle
        _lastTransitionAt = at
        _suspended = false
        _firstFrame = false
        _guestPID = nil
        _installing = nil
        let listener = onTransition
        lock.unlock()
        if previous != .idle { listener?(previous, .idle, at) }
    }

    /// The JSON body for `state`.
    public func payload(build: String,
                        appVersion: String,
                        runtime: SessionStatePayload.RuntimeInfo,
                        artifacts: SessionArtifacts = .none) -> Data {
        lock.lock()
        let session = SessionStatePayload.SessionInfo(
            id: _sessionID ?? artifacts.directoryName ?? "",
            phase: _phase,
            running: _phase.isLive,
            mode: _request?.mode.rawValue ?? SessionMode.steam.rawValue,
            program: _request?.programName,
            steamUi: steamUIValue(),
            steamUrl: steamURLValue(),
            suspended: _suspended,
            firstFrame: _firstFrame,
            output: _output,
            refreshHz: _refreshHz,
            lastTransitionAt: _lastTransitionAt,
            guestPid: _guestPID.flatMap { $0 > 1 ? $0 : nil },
            installing: _installing,
            logDir: artifacts.directoryPath,
            eventsFile: artifacts.directoryPath.map { ($0 as NSString).appendingPathComponent("events.jsonl") },
            artifactsAvailable: artifacts.directoryPath != nil,
            artifactsComplete: artifacts.complete,
            failure: _failure)
        lock.unlock()
        let payload = SessionStatePayload(build: build,
                                          appVersion: appVersion,
                                          runtime: runtime,
                                          session: session)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoded on every `state` call and nowhere else, so a throw here is a
        // programming error rather than a runtime condition.
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    private func steamUIValue() -> String? {
        guard case .steam(let ui, _) = _request else { return nil }
        return ui.rawValue
    }

    private func steamURLValue() -> String? {
        guard case .steam(_, let url) = _request else { return nil }
        return url
    }
}

/// Where a session's artifacts are, as the state payload reports them.
public struct SessionArtifacts: Equatable, Sendable {
    public var directoryPath: String?
    public var directoryName: String?
    public var complete: Bool

    public static let none = SessionArtifacts(directoryPath: nil, directoryName: nil, complete: false)

    public init(directoryPath: String?, directoryName: String?, complete: Bool) {
        self.directoryPath = directoryPath
        self.directoryName = directoryName
        self.complete = complete
    }

    /// `session-20260921-161256`, the folder name upstream stamps. The stamp is
    /// UTC because upstream formats it with a US locale and no time zone, and
    /// two machines in two zones have to name a session the same way for the
    /// artifacts to be comparable.
    public static func folderName(_ date: Date, calendar: Calendar? = nil) -> String {
        // The calendar is optional rather than defaulted to a stored constant
        // because a public function's default argument may not name an
        // internal static, and duplicating the UTC definition would be worse.
        var utc = calendar ?? Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)! // the identifier always resolves
        let f = DateFormatter()
        f.calendar = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "session-\(f.string(from: date))"
    }

}

/// Writes null rather than nothing, for the fields that may have no value.
///
/// KeyedEncodingContainer's `encodeNil` writes a bare null, which is what the
/// published `state` shape has always had; `encodeIfPresent` would drop the key,
/// and a harness reading `.session.logDir` would get nothing at all. At file
/// scope: an extension is not valid inside a type.
extension KeyedEncodingContainer {
    // mutating: KeyedEncodingContainer is a struct, and encodeNil and encode both
    // change it. Declaring it otherwise is the compiler's "cannot use mutating
    // member on immutable value".
    mutating func encodeOrNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        guard let value else {
            try encodeNil(forKey: key)
            return
        }
        try encode(value, forKey: key)
    }
}
