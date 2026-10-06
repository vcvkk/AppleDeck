// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import AppleDeckCore

/// What the launcher needs from a guest runtime, so the session coordinator does
/// not care which one it has.
///
/// Two implement this today:
///
/// * `QemuRuntime` - an aarch64 Linux guest under QEMU's TCG, running
///   DroidDeck's runtime verbatim (Steam, gamescope, MangoApp, the desktop).
///   Complete, and slow: TCG is the whole performance story.
/// * `MadeiraRuntime` - Valve's Windows client through FEX and Wine with Metal
///   underneath, which is what makes Windows games fast enough to play. It
///   covers the Steam half of DroidDeck, not the Linux half.
///
/// A runtime that cannot run reports why in `unavailableReason`, and the
/// launcher shows it on the press of Play rather than starting a session that
/// cannot start.
protocol GuestRuntime: AnyObject {
    var identifier: String { get }
    /// What the user sees: "QEMU (TCG)", "Wine + FEX", ...
    var displayName: String { get }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    /// What the session needs from the runtime to run, so the install page can
    /// say "install the guest" rather than "something went wrong".
    var missingArtifacts: [String] { get }

    /// Called on the main thread for every frame. Not guaranteed to be
    /// main-thread-affine after the first call, because QEMU's display callback
    /// runs on its own thread: implementations hop.
    var onFrame: ((GuestFrame) -> Void)? { get set }
    /// Called when the machine ends on its own, with the guest's exit reason.
    var onExit: ((String) -> Void)? { get set }

    func start(_ request: SessionRequest, guest: GuestConfiguration) throws
    func stop()
    func suspend()
    func resume()
    func send(_ input: GuestInput)
}

/// One frame out of the runtime.
public struct GuestFrame {
    public var width: Int
    public var height: Int
    public var stride: Int
    /// BGRA, row-major. Borrowed: valid only for the duration of the callback.
    public var pixels: UnsafeRawBufferPointer

    public init(width: Int, height: Int, stride: Int, pixels: UnsafeRawBufferPointer) {
        self.width = width
        self.height = height
        self.stride = stride
        self.pixels = pixels
    }
}

/// Everything a runtime needs before it can boot: paths to the pieces it
/// fetched, and the output size the launcher chose.
public struct GuestConfiguration {
    public var kernel: URL?
    public var initrd: URL?
    public var disk: URL?
    public var bios: URL?
    public var cmdline: String
    public var memoryMB: Int
    public var vcpus: Int
    public var outputWidth: Int
    public var outputHeight: Int

    public init(kernel: URL?, initrd: URL?, disk: URL?, bios: URL?,
                cmdline: String = "", memoryMB: Int = 4096, vcpus: Int = 4,
                outputWidth: Int = 1280, outputHeight: Int = 720) {
        self.kernel = kernel
        self.initrd = initrd
        self.disk = disk
        self.bios = bios
        self.cmdline = cmdline
        self.memoryMB = memoryMB
        self.vcpus = vcpus
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }
}

/// An input event on its way to the guest, in QEMU's numbers. Mapping touch,
/// keys and game controllers onto this is `InputRouter`'s whole job.
public enum GuestInput {
    case key(code: Int, down: Bool)
    case pointer(x: Int, y: Int)
    case button(linuxButton: Int, down: Bool)
    case wheel(axis: Int, delta: Int)

    var eventType: Int32 {
        switch self {
        case .key(_, let down): return down ? 1 : 2
        case .pointer: return 3
        case .button(_, let down): return down ? 4 : 5
        case .wheel: return 6
        }
    }

    var arguments: (Int32, Int32, Int32, Int32) {
        switch self {
        case .key(let code, _): return (Int32(code), 0, 0, 0)
        case .pointer(let x, let y): return (0, Int32(x), Int32(y), 0)
        case .button(let button, _): return (Int32(button), 0, 0, 0)
        case .wheel(let axis, let delta): return (Int32(axis), Int32(delta), 0, 0)
        }
    }
}

/// The TCG guest.
///
/// Deliberately thin: everything interesting is in QEMU and in the guest image,
/// which are the same artefacts DroidDeck already builds. What this class owns
/// is the translation of DroidDeck's *session* concepts (a mode, a program, a
/// suspend) into guest boot parameters and guest commands, and the frame and
/// input plumbing.
final class QemuRuntime: GuestRuntime {
    let identifier = "qemu-tcg"
    let displayName = "QEMU (TCG)"

    var onFrame: ((GuestFrame) -> Void)?
    var onExit: ((String) -> Void)?

    private(set) var isAvailable = false
    private(set) var unavailableReason: String?
    private(set) var missingArtifacts: [String] = []
    private var started = false
    /// Held for as long as the machine is up: QEMU reads its argv inside
    /// qemu_init on the thread AppleDeckQemuStart created, so freeing these
    /// when start() returns would be a use-after-free that happens to work
    /// until it does not.
    private var argvKeepAlive: CStrings?

    init() {
        var reason = [CChar](repeating: 0, count: 256)
        isAvailable = AppleDeckQemuAvailable(&reason, 256)
        if !isAvailable {
            unavailableReason = String(cString: reason)
        }
        AppleDeckQemuSetCallbacks({ pixels, width, height, stride in
            AppleDeckFrameBridge.dispatch(pixels, width, height, stride)
        }, { type, code, a, b, c in
            AppleDeckInputBridge.dispatch(type, code, a, b, c)
        })
    }

    func start(_ request: SessionRequest, guest: GuestConfiguration) throws {
        guard isAvailable else {
            throw AgentError.transport(unavailableReason ?? "the guest runtime is not available")
        }
        guard !started else {
            throw AgentError.sessionFailed("a session is already running")
        }
        guard guest.kernel != nil, guest.disk != nil else {
            throw AgentError.sessionFailed("no guest image; install the runtime first")
        }

        // The C strings have to outlive this function: QEMU reads its argv
        // inside qemu_init, which runs on the thread AppleDeckQemuStart creates.
        let keepAlive = CStrings()
        argvKeepAlive = keepAlive
        let commandLine = guest.cmdline.isEmpty ? SessionCommandLine.make(for: request) : guest.cmdline
        var config = AppleDeckQemuConfig()
        config.kernel = keepAlive.copy(guest.kernel?.path)
        config.initrd = keepAlive.copy(guest.initrd?.path)
        config.disk = keepAlive.copy(guest.disk?.path)
        config.bios = keepAlive.copy(guest.bios?.path)
        config.cmdline = keepAlive.copy(commandLine)
        config.memory_mb = Int32(guest.memoryMB)
        config.vcpus = Int32(guest.vcpus)
        config.smp = Int32(guest.vcpus)
        config.width = Int32(guest.outputWidth)
        config.height = Int32(guest.outputHeight)

        let status = AppleDeckQemuStart(&config)
        if status != 0 {
            // Nothing is running, so nothing can be reading these any more.
            keepAlive.release()
            argvKeepAlive = nil
        }
        guard status == 0 else {
            throw AgentError.sessionFailed(status == -2 ? "a session is already running" : "the guest refused to start (\(status))")
        }
        started = true
    }

    func stop() {
        guard started else { return }
        // Stop first: AppleDeckQemuStop joins the machine's thread, so by the
        // time it returns nothing is reading the argv any more.
        AppleDeckQemuStop()
        argvKeepAlive?.release()
        argvKeepAlive = nil
        started = false
    }

    func suspend() {
        // Suspending a TCG guest means stopping the world: the machine has to
        // be paused, not the app, or the guest's clock keeps running and Steam
        // comes back to a session that thinks minutes passed.
        AppleDeckQemuSendEvent(8, 0, 0, 0, 0)
    }

    func resume() {
        AppleDeckQemuSendEvent(7, 0, 0, 0, 0)
    }

    func send(_ input: GuestInput) {
        let (code, a, b, c) = input.arguments
        AppleDeckQemuSendEvent(input.eventType, code, a, b, c)
    }

    /// How many input events were dropped for want of a running guest.
    var droppedInputEvents: Int { Int(AppleDeckQemuDroppedEvents()) }
}

/// Frames arrive on QEMU's display thread and go straight into the Metal
/// presenter's texture cache; the hop to the main thread happens there, once,
/// rather than here for every event type that might need it.
enum AppleDeckFrameBridge {
    private static let lock = NSLock()
    private static var handler: ((UnsafeRawPointer, Int, Int, Int) -> Void)?

    static func install(_ handler: @escaping (UnsafeRawPointer, Int, Int, Int) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func dispatch(_ pixels: UnsafeRawPointer?, _ width: Int32, _ height: Int32, _ stride: Int32) {
        guard let pixels else { return }
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(pixels, Int(width), Int(height), Int(stride))
    }
}

/// `strdup`ed C strings with their lifetimes attached, because a Swift string
/// cannot be handed to C as a `const char *` that C may keep.
final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func copy(_ string: String?) -> UnsafePointer<CChar>? {
        guard let string else { return nil }
        guard let pointer = strdup(string) else { return nil }
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }

    func release() {
        for pointer in pointers { free(pointer) }
        pointers.removeAll()
    }

    deinit { release() }
}

/// Input events the guest sends back (a guest-driven reset, a device change).
/// Nothing routes them today; the hook exists so the guest's side has somewhere
/// to go once MangoApp is running in-guest.
enum AppleDeckInputBridge {
    static func dispatch(_ type: Int32, _ code: Int32, _ a: Int32, _ b: Int32, _ c: Int32) {
        _ = (type, code, a, b, c)
    }
}

/// The kernel command line that tells the guest's init which session to start.
///
/// The guest image is DroidDeck's, so the variable names are the ones
/// `tools/linuxfs/overlay/usr/local/bin/steam-startup` reads.
enum SessionCommandLine {
    static func make(for request: SessionRequest) -> String {
        switch request {
        case .steam(let ui, let url):
            var line = "appledeck.mode=steam appledeck.ui=\(ui.rawValue)"
            if let url, !url.isEmpty {
                line += " appledeck.url=\(url)"
            }
            return line
        case .desktop:
            return "appledeck.mode=desktop"
        case .run(let program, let arguments):
            let joined = arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
            return "appledeck.mode=run appledeck.program=\(program) appledeck.args=\(joined)"
        }
    }
}