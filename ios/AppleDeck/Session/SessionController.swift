// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import AppleDeckCore

/// Owns the running session: the phases, the artifacts, the guest.
///
/// DroidDeck splits this across a `SessionService` and a `SessionActivity`
/// because Android lets either outlive the other. On iOS one coordinator owns
/// both halves, which is why the state machine in `AppleDeckCore` can enforce the
/// transitions instead of trusting two writers to a `volatile` field.
@MainActor
final class SessionController: ObservableObject {
    /// Told when a session has ended, so the launcher can refresh what the guest
    /// changed: installed games, saves, artwork.
    var onFinish: (() -> Void)?

    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var request: SessionRequest?
    @Published private(set) var suspended = false
    @Published private(set) var failureMessage: String?
    @Published private(set) var logDirectory: String?
    @Published private(set) var droppedInputEvents = 0

    /// Read by the overlay (the HUD switch) and by the session view's gestures.
    let prefs: Prefs
    private let runtime: QemuRuntime
    private let paths: GuestPaths
    private let machine = SessionStateMachine()
    private var artifacts: SessionArtifacts = .none
    private var firstFrameSeen = false

    /// The page size the guest is told to render at, from `shape` and the
    /// screen. `SessionPrefs.shapeMode` is honoured the way upstream does it:
    /// `16:9` is a fixed shape, `exact` is the panel's own, `auto` is 16:9 or
    /// wider depending on which way the phone is held.
    func outputSize(for screen: CGSize) -> (width: Int, height: Int) {
        switch prefs.shapeMode {
        case .wide:
            return (1280, 720)
        case .exact:
            let long = Int(max(screen.width, screen.height))
            return (long, Int(Double(long) * 9.0 / 16.0))
        case .auto:
            let landscape = CGSize(width: max(screen.width, screen.height),
                                   height: min(screen.width, screen.height))
            if abs(landscape.width / max(landscape.height, 1) - 16.0 / 9.0) < 0.01 {
                return (1280, 720)
            }
            // Taller than 16:9: keep the height, widen the guest's output so it
            // fills the panel instead of letterboxing it.
            let height = 720
            let width = Int(Double(height) * landscape.width / max(landscape.height, 1))
            return (width - width % 8, height)
        }
    }

    var isActive: Bool { phase.isLive }

    var canStart: Bool { phase == .idle || phase == .failed }

    init(prefs: Prefs, runtime: QemuRuntime, paths: GuestPaths) {
        self.prefs = prefs
        self.runtime = runtime
        self.paths = paths
        machine.onTransition = { [weak self] from, to, at in
            // The state machine is not main-thread-affine on purpose: it is
            // called from the runtime's teardown path as well as from here.
            Task { @MainActor in self?.transition(from: from, to: to, at: at) }
        }
    }

    func start(_ request: SessionRequest) {
        guard machine.begin(id: "", request: request) else {
            failureMessage = "a session is already running"
            return
        }
        firstFrameSeen = false
        artifacts = claimArtifacts()
        publish()
        if !runtime.isAvailable {
            machine.fail(code: "runtime.unavailable",
                         message: runtime.unavailableReason ?? "no guest runtime",
                         status: nil)
            publish()
            return
        }
        machine.transition(to: .startingCompositor)
        machine.transition(to: .startingGuest)

        do {
            try runtime.start(request, guest: guestConfiguration())
            machine.transition(to: request.mode == .run ? .ready : .startingSteam)
            if request.mode == .run {
                machine.firstFrameSeen = true
                machine.transition(to: .ready)
            }
            publish()
        } catch {
            machine.fail(code: "guest.start", message: error.localizedDescription, status: nil)
            publish()
        }
    }

    func stop() {
        guard phase.isLive else { return }
        machine.transition(to: .stopping)
        publish()
        runtime.stop()
        releaseArtifacts()
        machine.finish()
        publish()
        onFinish?()
    }

    func toggleSuspend() {
        guard phase == .ready || phase == .suspended else { return }
        let next = !suspended
        machine.setSuspended(next)
        if next {
            runtime.suspend()
        } else {
            runtime.resume()
        }
        publish()
    }

    /// Suspending because the app went away, per `suspend`. `never` keeps the
    /// session running, which on iOS means the guest keeps burning battery
    /// until the user comes back - which is what the preference asks for.
    func sceneDidEnterBackground() {
        guard prefs.suspendMode != .never else { return }
        guard phase == .ready else { return }
        machine.setSuspended(true)
        runtime.suspend()
        publish()
    }

    func sceneWillEnterForeground() {
        guard prefs.suspendMode == .auto, phase == .suspended else { return }
        machine.setSuspended(false)
        runtime.resume()
        publish()
    }

    /// Input from the router, straight to the runtime. The session controller
    /// owns the runtime, so nothing else may call it.
    func send(_ input: GuestInput) {
        runtime.send(input)
    }

    /// The first frame means the loading panel is behind us, exactly as
    /// upstream's `firstFrameSeen` means.
    func noteFrame() {
        guard !firstFrameSeen else { return }
        firstFrameSeen = true
        machine.firstFrameSeen = true
        machine.transition(to: .ready)
        publish()
    }

    // MARK: - State

    private func publish() {
        phase = machine.phase
        self.request = machine.request
        suspended = machine.suspended
        failureMessage = machine.failure?.message ?? machine.failure?.code
        logDirectory = artifacts.directoryPath
        droppedInputEvents = runtime.droppedInputEvents
    }

    private func transition(from: SessionPhase, to: SessionPhase, at: Int64) {
        publish()
        guard let directory = artifacts.directoryPath else { return }
        let event = SessionEvent(at: at, from: from, to: to)
        try? event.append(to: URL(fileURLWithPath: directory + "/events.jsonl"))
    }

    /// The schema-1 body the agent bridge serves, byte-compatible with
    /// DroidDeck's.
    var statePayload: Data {
        machine.payload(
            build: Bundle.main.object(forInfoDictionaryKey: "AppleDeckBuildCommit") as? String ?? "unknown",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            runtime: .init(installed: isRuntimeInstalled,
                           version: runtimeVersion,
                           backend: runtime.isAvailable ? runtime.identifier : nil,
                           guestImage: nil),
            artifacts: artifacts)
    }

    var isRuntimeInstalled: Bool {
        FileManager.default.fileExists(atPath: paths.runtimeInstalledMarker)
    }

    var runtimeVersion: String? {
        guard let text = try? String(contentsOfFile: paths.runtimeVersionFile, encoding: .utf8) else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Artifacts

    /// One folder per session, named as upstream names it, in Documents so the
    /// Files page and the share sheet can reach it. With logs off it goes to the
    /// cache and is deleted when the session ends, which is what upstream does
    /// and for the same reason: a session nobody is debugging should not leave
    /// megabytes behind.
    private func claimArtifacts() -> SessionArtifacts {
        let parent = prefs.logsEnabled ? paths.artifacts : paths.cache + "/session-logs"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        var name = SessionArtifacts.folderName(Date())
        var suffix = 2
        while fm.fileExists(atPath: "\(parent)/\(name)") {
            name = "\(SessionArtifacts.folderName(Date()))-\(suffix)"
            suffix += 1
        }
        let directory = "\(parent)/\(name)"
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        writeDeviceReport(to: directory)
        artifacts = SessionArtifacts(directoryPath: directory, directoryName: name, complete: false)
        return artifacts
    }

    private func releaseArtifacts() {
        guard let directory = artifacts.directoryPath else { return }
        let fm = FileManager.default
        if !prefs.logsEnabled {
            try? fm.removeItem(atPath: directory)
        } else {
            // `.complete` is upstream's marker for "this folder will not grow
            // any more"; the agent bridge reports it as artifactsComplete.
            fm.createFile(atPath: directory + "/.complete", contents: nil)
        }
        artifacts = .none
    }

    /// `device.txt`: what this device is and every setting the session ran with.
    /// Written before anything else, because it is what makes the rest of the
    /// folder readable.
    private func writeDeviceReport(to directory: String) {
        var lines: [String] = []
        lines.append("# AppleDeck device report")
        lines.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("device: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("machine: \(ProcessInfo.processInfo.processorCount) cores")
        lines.append("runtime: \(runtime.identifier) available=\(runtime.isAvailable)")
        if let reason = runtime.unavailableReason { lines.append("runtime reason: \(reason)") }
        lines.append("runtime version: \(runtimeVersion ?? "none")")
        lines.append("shape: \(prefs.shapeMode.rawValue)")
        lines.append("touch: \(prefs.touchMode.rawValue)")
        lines.append("osc: \(prefs.oscMode.rawValue)")
        lines.append("controller: \(prefs.controllerProfile.rawValue)")
        lines.append("forceFullscreen: \(prefs.forceFullscreen)")
        lines.append("suspend: \(prefs.suspendMode.rawValue)")
        lines.append("guestHostname: \(prefs.guestHostname)")
        lines.append("storeEnabled: \(prefs.storeEnabled)")
        lines.append("hud: \(prefs.hud)")
        try? lines.joined(separator: "\n").write(toFile: directory + "/device.txt",
                                                 atomically: true, encoding: .utf8)
    }

    private func guestConfiguration() -> GuestConfiguration {
        let kernel = firstExisting(["\(paths.container)/guest/vmlinuz-virt",
                                    "\(paths.container)/guest/Image"])
        let initrd = firstExisting(["\(paths.container)/guest/initramfs-virt"])
        let disk = firstExisting(["\(paths.container)/guest/rootfs.img"])
        let bios = firstExisting(["\(paths.container)/guest/edk2-aarch64-code.fd"])
        return GuestConfiguration(kernel: kernel, initrd: initrd, disk: disk, bios: bios,
                                  cmdline: "", memoryMB: 4096, vcpus: 4,
                                  outputWidth: 1280, outputHeight: 720)
    }

    private func firstExisting(_ paths: [String]) -> URL? {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}