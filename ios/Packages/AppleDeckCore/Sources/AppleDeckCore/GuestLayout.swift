// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Where everything lives, in the guest and on the device.
///
/// Two of these paths are DroidDeck's verbatim and must stay that way, because
/// the guest rootfs is DroidDeck's: `files/linuxfs` is where the runtime
/// installer unpacks, `Download/DroidDeck` is where a support bundle is
/// expected to come from, and the guest paths (`/root/.local/share/Steam`,
/// `/usr/local/bin/gamescope`) are what the overlay scripts in
/// `tools/linuxfs/overlay` write to.
///
/// iOS has no Downloads directory an app may write and no `getExternalFilesDir`,
/// so the device-side roots live in the app container and the *Documents*
/// subdirectory is what the Files screen and the share sheet expose.
public struct GuestPaths: Sendable {
    /// The container root: `Library/Application Support/AppleDeck` on device.
    public var container: String
    /// `files/linuxfs` upstream, the guest's `/`. Held here and nowhere else.
    public var rootfs: String
    /// Where session artifacts go. Upstream: `Download/DroidDeck/<session>`.
    public var artifacts: String
    /// `cacheDir` upstream. Cleared by the system whenever it is bored.
    public var cache: String
    /// `XDG_RUNTIME_DIR` for the session: `files/.flatpak-rt` upstream.
    public var runtimeDir: String
    /// The guest's writable home, a bind target.
    public var home: String
    /// Where imported games live when the user has not chosen a folder.
    public var documents: String

    public init(container: String,
                artifacts: String,
                cache: String,
                documents: String) {
        self.container = container
        self.rootfs = "\(container)/files/linuxfs"
        self.artifacts = artifacts
        self.cache = cache
        self.documents = documents
        self.runtimeDir = "\(container)/files/.flatpak-rt"
        self.home = "\(container)/files/home"
    }

    public static func standard(container: String, documents: String) -> GuestPaths {
        GuestPaths(container: container,
                  artifacts: "\(documents)/DroidDeck",
                  cache: "\(container)/cache",
                  documents: documents)
    }

    /// Guest paths, kept as constants because the overlay scripts, the fake
    /// input shim and the compositor all name them.
    public enum Guest {
        public static let root = "/root"
        public static let steamData = "/root/.local/share/Steam"
        public static let gamescope = "/usr/local/bin/gamescope"
        public static let mangoApp = "/usr/local/bin/mangoapp"
        public static let desktop = "/usr/local/bin/droiddeck-desktop"
        public static let accounts = "/etc/passwd"
        public static let shadow = "/etc/shadow"
        public static let group = "/etc/group"
        public static let preloadList = "/etc/ld.so.preload"
        public static let fakeInput = "/dev/input"
        public static let loader = "/opt/android-host/proot"
        public static let pulseaudio = "/usr/bin/pulseaudio"
    }

    /// `device.txt`: what this device is and every setting the session ran
    /// with. A support bundle is worthless without it, so the session writes it
    /// before anything else happens.
    public var deviceReport: String { "\(artifacts)/device.txt" }
    public var sessionLog: String { "\(artifacts)/session.log" }
    public var waylandLog: String { "\(artifacts)/wayland.log" }
    public var steamLog: String { "\(artifacts)/steam.log" }
    public var desktopLog: String { "\(artifacts)/desktop.log" }
    public var eventsLog: String { "\(artifacts)/events.jsonl" }

    /// The runtime version stamp the installer writes next to the rootfs, which
    /// is what `state.runtime.version` reports.
    public var runtimeVersionFile: String { "\(container)/files/linuxfs.version" }
    public var runtimeInstalledMarker: String { "\(container)/files/linuxfs/.droiddeck-runtime" }
}

/// One `host:guest` bind, matching `-b` specs proot takes.
public struct Bind: Equatable, Sendable {
    public var host: String
    public var guest: String

    public init(host: String, guest: String) {
        self.host = host
        self.guest = guest
    }

    /// proot's own spelling: `host:guest`, or just the path when they are equal.
    public var spec: String { host == guest ? host : "\(host):\(guest)" }

    public static func same(_ path: String) -> Bind { Bind(host: path, guest: path) }

    public static func parse(_ spec: String) -> Bind {
        guard let colon = spec.firstIndex(of: ":") else { return .same(spec) }
        return Bind(host: String(spec[spec.startIndex..<colon]),
                    guest: String(spec[spec.index(after: colon)...]))
    }

    /// True when `path` is `dir` or inside it, the test `binds(for:)` uses to
    /// pick the most specific bind.
    public func covers(_ path: String) -> Bool {
        guest == "/" || path == guest || path.hasPrefix(guest.hasSuffix("/") ? guest : guest + "/")
    }
}

/// Builds the command line a session runs inside the runtime.
///
/// This is `runtime/LinuxRuntime.java`'s `prootPrefix` and `binds`, plus
/// `runtime/GuestCommand.kt`'s environment, as pure functions over a
/// description of the host. Nothing here touches the file system, so the exact
/// argv a session will exec is a unit test rather than something found out on
/// a device.
public struct GuestCommandBuilder: Sendable {
    public struct Host: Sendable {
        /// The device uid proot reports to the guest. Upstream passes
        /// `-i <uid>:<uid>`; on iOS every guest process is the app's own uid,
        /// and `-0` (fake root) is what the package tools need.
        public var uid: Int
        public var paths: GuestPaths
        /// The proot binary staged in the container, and the loader it dlopens.
        public var prootBinary: String
        public var prootLoader: String
        /// Proot links against a libtalloc beside it; `LD_LIBRARY_PATH` is how
        /// Android's linker is told, and iOS does not need it.
        public var prootLibraryPath: String?
        /// Set when proot's seccomp acceleration is switched off by request.
        public var prootNoSeccomp: Bool
        /// The host kernel release proot reports, so Steam's platform checks
        /// pass. iOS has no `uname` a guest may read, so it is asserted.
        public var guestKernelRelease: String
        public var guestHostname: String
        public var externalStorage: String?

        public init(uid: Int,
                    paths: GuestPaths,
                    prootBinary: String,
                    prootLoader: String,
                    prootLibraryPath: String? = nil,
                    prootNoSeccomp: Bool = false,
                    guestKernelRelease: String = "6.6.0-appledeck",
                    guestHostname: String = "AppleDeck",
                    externalStorage: String? = nil) {
            self.uid = uid
            self.paths = paths
            self.prootBinary = prootBinary
            self.prootLoader = prootLoader
            self.prootLibraryPath = prootLibraryPath
            self.prootNoSeccomp = prootNoSeccomp
            self.guestKernelRelease = guestKernelRelease
            self.guestHostname = guestHostname
            self.externalStorage = externalStorage
        }
    }

    public let host: Host

    public init(host: Host) { self.host = host }

    /// `LinuxRuntime.prootPrefix`. `fakeRoot` is `-0` (uid 0) for the package
    /// tools, `-i uid:uid` otherwise so nothing inside sees a different user.
    public func prootPrefix(cwd: String = GuestPaths.Guest.root, fakeRoot: Bool = false) -> [String] {
        var cmd: [String] = [host.prootBinary, "--kill-on-exit"]
        // Preserve the host kernel identity while giving the guest its own name.
        cmd.append("--kernel-release=\(host.guestKernelRelease)")
        cmd.append("--hostname=\(host.guestHostname)")
        if fakeRoot {
            cmd.append("-0")
        } else {
            cmd.append("-i")
            cmd.append("\(host.uid):\(host.uid)")
        }
        cmd += ["-r", host.paths.rootfs, "-w", cwd]
        return cmd
    }

    /// `LinuxRuntime.binds`: the host paths the session sees inside the guest,
    /// in the order upstream adds them.
    public func binds(sessionRoot: String? = nil, runtimeDir: String? = nil, extra: [String] = []) -> [Bind] {
        let root = host.paths.rootfs
        var out: [Bind] = [
            .same("/dev"), .same("/proc"), .same("/sys"),
            Bind(host: "/dev/urandom", guest: "/dev/random"),
            Bind(host: "/proc/self/fd", guest: "/dev/fd"),
            Bind(host: "/proc/self/fd/0", guest: "/dev/stdin"),
            Bind(host: "/proc/self/fd/1", guest: "/dev/stdout"),
            Bind(host: "/proc/self/fd/2", guest: "/dev/stderr"),
            // SELinux: the guest sees an empty directory where the host has an
            // enforcing policy, so nothing inside tries to read a label file.
            Bind(host: "\(root)/etc/bannerlator/empty", guest: "/sys/fs/selinux"),
            .same(host.paths.container + "/files"),
            .same(host.paths.cache)
        ]
        if let runtimeDir { out.append(.same(runtimeDir)) }
        if let sessionRoot { out.append(.same(sessionRoot)) }
        if let external = host.externalStorage { out.append(.same(external)) }
        out += extra.map(Bind.parse)
        return out
    }

    /// The guest environment for a session. `PATH`, `HOME` and the Flatpak
    /// variables are upstream's, unchanged: the overlay scripts and the
    /// MangoApp binary in the runtime expect them.
    public func guestEnvironment(flatpakBwrap: String = "/usr/local/bin/bannerlator-bwrap") -> [String] {
        [
            "HOME=\(GuestPaths.Guest.root)",
            "USER=root",
            "LANG=C.UTF-8",
            "PATH=/usr/local/bin:/usr/bin:/bin",
            "XDG_RUNTIME_DIR=\(host.paths.runtimeDir)",
            "XDG_DATA_HOME=\(GuestPaths.Guest.root)/.local/share",
            "FLATPAK_BWRAP=\(flatpakBwrap)",
            "XDG_DATA_DIRS=\(GuestPaths.Guest.root)/.local/share/flatpak/exports/share:/usr/local/share:/usr/share"
        ]
    }

    /// The host environment proot itself needs. `PROOT_LOADER` and
    /// `PROOT_TMP_DIR` are read by proot before the guest exists, so they
    /// belong here rather than in the guest environment.
    public func hostEnvironment() -> [String: String] {
        var env = [
            "PROOT_LOADER": host.prootLoader,
            "PROOT_TMP_DIR": host.paths.cache
        ]
        if host.prootNoSeccomp { env["PROOT_NO_SECCOMP"] = "1" }
        if let libs = host.prootLibraryPath, !libs.isEmpty { env["LD_LIBRARY_PATH"] = libs }
        return env
    }

    /// The full argv for a session: the proot prefix, the binds, `env -i` with
    /// the guest environment, then the program.
    ///
    /// `session` decides what runs. Steam is started through the runtime's own
    /// start script so the client's environment (and the DXVK/vulkan variables
    /// that go with a mode) come from the runtime rather than from here,
    /// which is what keeps this identical to what Android runs.
    public func sessionCommand(_ session: SessionRequest,
                               sessionRoot: String? = nil,
                               fakeRoot: Bool = false) -> [String] {
        var cmd = prootPrefix(cwd: GuestPaths.Guest.root, fakeRoot: fakeRoot)
        for bind in binds(sessionRoot: sessionRoot, runtimeDir: host.paths.runtimeDir) {
            cmd += ["-b", bind.spec]
        }
        cmd += ["/usr/bin/env", "-i"] + guestEnvironment()
        switch session {
        case .steam(let ui, let url):
            cmd += [GuestPaths.Guest.gamescope]
            cmd += gamescopeArguments(ui: ui, url: url)
            cmd += ["/usr/local/bin/steam-startup"]
        case .desktop:
            cmd += ["/usr/local/bin/droiddeck-desktop"]
        case .run(let program, let arguments):
            cmd += [program] + arguments
        }
        return cmd
    }

    /// The gamescope line upstream builds, including the Steam client's own
    /// `--steam` pair. Kept in one place because the compositor's output size
    /// and this must agree.
    public func gamescopeArguments(ui: SessionRequest.SteamUI, url: String?) -> [String] {
        var args = ["--steam", "--rt", "--fullscreen", "--expose-wayland"]
        if ui == .desktop { args.append("--prefer-vulkan-layers") }
        if let url, !url.isEmpty { args += ["--steamurl=\(url)"] }
        return args
    }

    /// A command outside any session - the store's Flatpak work, an AppImage
    /// import. `GuestCommand.run` upstream.
    public func oneShotCommand(argv: [String], fakeRoot: Bool = false) -> [String] {
        var cmd = prootPrefix(cwd: GuestPaths.Guest.root, fakeRoot: fakeRoot)
        for bind in binds(runtimeDir: host.paths.runtimeDir) {
            cmd += ["-b", bind.spec]
        }
        cmd += ["/usr/bin/env", "-i"] + guestEnvironment()
        return cmd + argv
    }
}