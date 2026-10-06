// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import AppleDeckCore

final class GuestLayoutTests: XCTestCase {
    private func builder(fakeRoot: Bool = false, uid: Int = 501) -> GuestCommandBuilder {
        let paths = GuestPaths.standard(container: "/var/app/Documents", documents: "/var/app/Documents")
        return GuestCommandBuilder(host: .init(
            uid: uid,
            paths: paths,
            prootBinary: "/var/app/bin/proot",
            prootLoader: "/var/app/bin/libproot.so",
            guestKernelRelease: "6.6.0-appledeck",
            guestHostname: "AppleDeck"))
    }

    func testRootfsPathIsTheOneTheOverlayScriptsUse() {
        let paths = GuestPaths.standard(container: "/var/app", documents: "/var/app/Documents")
        XCTAssertEqual(paths.rootfs, "/var/app/files/linuxfs")
        XCTAssertTrue(paths.rootfs.hasSuffix("files/linuxfs"),
                      "the runtime installer and the guest overlay both name this path")
    }

    func testProotPrefixMatchesLinuxRuntime() {
        let cmd = builder().prootPrefix()
        XCTAssertEqual(cmd.first, "/var/app/bin/proot")
        XCTAssertTrue(cmd.contains("--kill-on-exit"))
        XCTAssertTrue(cmd.contains("--kernel-release=6.6.0-appledeck"))
        XCTAssertTrue(cmd.contains("-i"))
        XCTAssertTrue(cmd.contains("501:501"))
        XCTAssertEqual(cmd.suffix(4), ["-r", "/var/app/Documents/files/linuxfs", "-w", "/root"])
    }

    func testFakeRootUsesDashZero() {
        XCTAssertTrue(builder(fakeRoot: true).prootPrefix(fakeRoot: true).contains("-0"))
        XCTAssertFalse(builder(fakeRoot: true).prootPrefix(fakeRoot: true).contains("-i"))
    }

    func testBindsCarryTheGuestsView() {
        let binds = builder().binds(sessionRoot: "/var/app/Documents/DroidDeck/s1")
        let specs = binds.map(\.spec)
        XCTAssertTrue(specs.contains("/dev"))
        XCTAssertTrue(specs.contains("/dev/urandom:/dev/random"))
        XCTAssertTrue(specs.contains("/proc/self/fd/0:/dev/stdin"))
        // SELinux: an empty directory where the host has a policy.
        XCTAssertTrue(specs.contains("/var/app/Documents/files/linuxfs/etc/bannerlator/empty:/sys/fs/selinux"))
        XCTAssertTrue(specs.contains("/var/app/Documents/DroidDeck/s1"))
    }

    func testBindSpecDropsTheGuestWhenItEqualsTheHost() {
        XCTAssertEqual(Bind.same("/dev").spec, "/dev")
        XCTAssertEqual(Bind(host: "/a", guest: "/b").spec, "/a:/b")
        XCTAssertEqual(Bind.parse("/a:/b"), Bind(host: "/a", guest: "/b"))
        XCTAssertEqual(Bind.parse("/a"), Bind.same("/a"))
    }

    func testBindCoverage() {
        let bind = Bind(host: "/h", guest: "/root/.local/share/Steam")
        XCTAssertTrue(bind.covers("/root/.local/share/Steam"))
        XCTAssertTrue(bind.covers("/root/.local/share/Steam/steamapps"))
        XCTAssertFalse(bind.covers("/root/.local"))
        XCTAssertFalse(bind.covers("/root/.local/share/SteamBackups"))
        XCTAssertTrue(Bind(host: "/", guest: "/").covers("/anything"))
    }

    func testGuestEnvironmentKeepsTheRuntimesVariables() {
        let env = builder().guestEnvironment()
        XCTAssertTrue(env.contains("HOME=/root"))
        XCTAssertTrue(env.contains("PATH=/usr/local/bin:/usr/bin:/bin"))
        XCTAssertTrue(env.contains("LANG=C.UTF-8"))
        XCTAssertTrue(env.contains { $0.hasPrefix("XDG_DATA_DIRS=") })
    }

    func testHostEnvironmentCarriesTheProotLoader() {
        let env = builder().hostEnvironment()
        XCTAssertEqual(env["PROOT_LOADER"], "/var/app/bin/libproot.so")
        XCTAssertNil(env["PROOT_NO_SECCOMP"])
    }

    func testSteamSessionRunsGamescopeWithTheRuntimesStartupScript() {
        let cmd = builder().sessionCommand(.steam(ui: .bigPicture, url: "steam://rungameid/10"))
        XCTAssertTrue(cmd.contains("/usr/local/bin/gamescope"))
        XCTAssertTrue(cmd.contains("--steamurl=steam://rungameid/10"))
        XCTAssertEqual(cmd.suffix(1), ["/usr/local/bin/steam-startup"])
    }

    func testDesktopSessionRunsTheDesktopsOwnScript() {
        let cmd = builder().sessionCommand(.desktop)
        XCTAssertEqual(cmd.last, "/usr/local/bin/droiddeck-desktop")
    }

    func testRunSessionPassesGuestArgumentsThrough() {
        let cmd = builder().sessionCommand(.run(program: "/usr/bin/foo", arguments: ["--window", "42"]))
        XCTAssertEqual(cmd.suffix(3), ["/usr/bin/foo", "--window", "42"])
    }

    func testEnvIsInvokedAfterTheBindsAndBeforeTheProgram() {
        let cmd = builder().sessionCommand(.desktop)
        guard let envIndex = cmd.firstIndex(of: "/usr/bin/env") else {
            return XCTFail("no env -i in the session command")
        }
        XCTAssertEqual(cmd[envIndex + 1], "-i")
        XCTAssertTrue(cmd[..<envIndex].contains("-b"), "binds come before env")
    }
}

final class PrefsTests: XCTestCase {
    func testDefaultsMatchDroidDeck() {
        let p = Prefs(store: MemoryPrefsStore())
        XCTAssertTrue(p.launcherFullscreen)
        XCTAssertTrue(p.hud)
        XCTAssertTrue(p.forceFullscreen)
        XCTAssertTrue(p.logsEnabled)
        XCTAssertTrue(p.addedGamesArt)
        XCTAssertTrue(p.tuSysmem)
        XCTAssertTrue(p.glThread)
        XCTAssertTrue(p.noGlError)
        XCTAssertTrue(p.zinkLazy)
        XCTAssertTrue(p.noXalia)
        XCTAssertFalse(p.storeEnabled)
        XCTAssertFalse(p.appImagesEnabled)
        XCTAssertFalse(p.backActionsInverted)
        XCTAssertFalse(p.gamescopeRealtime)
        XCTAssertFalse(p.prootNoSeccomp)
        XCTAssertEqual(p.theme, "graphite")
        XCTAssertEqual(p.steamChannel, "steam")
        XCTAssertEqual(p.desktopRenderer, "vulkan")
        XCTAssertEqual(p.touchMode, .auto)
        XCTAssertEqual(p.oscMode, .auto)
        XCTAssertEqual(p.controllerProfile, .deck)
        XCTAssertEqual(p.linuxDriver(mode: .steam), "")
    }

    func testAutoTouchModeIsATouchpadOnTheDesktopAndDirectInSteam() {
        let p = Prefs(store: MemoryPrefsStore())
        XCTAssertEqual(p.effectiveTouchMode(for: .desktop), .touchpad)
        XCTAssertEqual(p.effectiveTouchMode(for: .steam), .direct)
        p.touchMode = .direct
        XCTAssertEqual(p.effectiveTouchMode(for: .desktop), .direct)
    }

    func testAutoOnScreenControlsFollowTheSessionAndTheQAM() {
        let p = Prefs(store: MemoryPrefsStore())
        XCTAssertTrue(p.onScreenControlsVisible(for: .desktop, steamQAMOpen: false))
        XCTAssertFalse(p.onScreenControlsVisible(for: .steam, steamQAMOpen: false))
        XCTAssertTrue(p.onScreenControlsVisible(for: .steam, steamQAMOpen: true))
        p.oscMode = .never
        XCTAssertFalse(p.onScreenControlsVisible(for: .desktop, steamQAMOpen: true))
    }

    func testBackActionOrderInverts() {
        let p = Prefs(store: MemoryPrefsStore())
        XCTAssertEqual(p.backActionsOrder, ControllerProfile.backMenuThenQAM)
        p.backActionsInverted = true
        XCTAssertEqual(p.backActionsOrder, ControllerProfile.backQAMThenMenu)
    }

    func testLinuxDriverIsKeyedPerMode() {
        let store = MemoryPrefsStore()
        let p = Prefs(store: store)
        p.setLinuxDriver("turnip-glibc", mode: .desktop)
        XCTAssertEqual(store.string(forKey: "linuxDriver.desktop"), "turnip-glibc")
        XCTAssertEqual(p.linuxDriver(mode: .steam), "", "Steam keeps the driver in the runtime")
    }
}