# The iOS port

How DroidDeck becomes AppleDeck, what is decided and why, and what is left.

The short version: **the guest stays, the host changes.** DroidDeck's Linux
runtime - Steam, gamescope, MangoApp, labwc, the fake-input shims, the PulseAudio
bundle - runs unchanged inside an arm64 Linux guest under QEMU's TCG. What is
replaced is everything that was Android: the launcher, the compositor's host
half, the input pipeline, audio, the file manager, and the agent bridge.

That choice is what makes "everything that works on Android works here"
achievable rather than aspirational. A session on iOS is the same session, with
the same Steam client, the same games, the same Proton, the same settings - it
runs somewhere else.

---

## 1. Why a full-system guest, and not a userspace emulator

Three ways to get DroidDeck's Linux runtime running on iOS, and why two of them
do not work:

| Approach | Verdict |
|---|---|
| **Run the guest binaries natively** (arm64 Linux ELF, no emulation) | Impossible. iOS will not execute a foreign binary, and there is no Linux kernel to give them syscalls. "Same ISA" does not mean "same platform". |
| **Userspace emulation** (iSH-AOK: x86 guest + syscall translation) | Works, and is the right answer for a *shell*. It is the wrong answer for Steam: the client is a large multi-threaded glibc program (32-bit x86 on Linux), and iSH's interpreter is a gadget-threaded design with no JIT. Booting a Steam client under it is not a performance question, it is a "does it get to the login screen" question. |
| **Full-system QEMU under TCG** | Slow, but complete. The guest has a real kernel, real `/dev`, real futexes, real `/dev/dri`, and the whole DroidDeck runtime runs as written. |

The full-system guest also gets the display right: QEMU's virtio-gpu has a
scanout, so the guest's Wayland clients render into it and QEMU hands changed
rectangles to the host, which blits them into Metal. No EGL, no ANGLE, no
vulkan-on-Metal shim, and - importantly - no change to any of the guest's own
rendering code.

The cost, stated plainly: TCG has no hypervisor available to third-party iOS
apps (Hypervisor.framework needs a private entitlement), so every guest
instruction is translated. Steam Big Picture is a 2D UI and is expected to be
usable. Games are expected to be slow. Nothing in this port pretends otherwise,
and `docs/ios-port.md`'s performance table is the honest version.

### The second backend, and why it is GPL-compatible

Valve's **Windows** Steam client does not need a Linux kernel at all. Madeira
(github.com/willfaust/Madeira, GPL-3.0-or-later) runs it on iOS today with FEX
translating x86 to arm64, Wine providing Windows, and DXMT plus a D3D12
implementation drawing through Metal - no CPU emulation of a whole system, so
games are playable.

Because Madeira is GPL-3.0-or-later, its code can live in AppleDeck's GPL-3.0
binary without a licence argument (see §5). `GuestRuntime` in
`ios/AppleDeck/Runtime/GuestRuntime.swift` is the seam: `QemuRuntime` is in the
tree, `MadeiraRuntime` is the next one. The launcher does not know or care which
it has.

---

## 2. What maps to what

| DroidDeck (Android) | AppleDeck (iOS) | State |
|---|---|---|
| `MainActivity` launcher, Compose rail | `LauncherScreen` + `LauncherModel` | ported |
| `FrontEndScreen`, `Library`, `SteamHome`, cover art | `FrontEndView`, `LibraryView` | ported |
| `StorePage` / Flathub | `StoreView`, `FlathubClient` in AppleDeckCore | ported |
| `FileManagerScreen` and friends | `FilesView`, `FileSort`, `FileRules`, `FileOperation` | ported |
| `ModeSettingsDialog`, `SettingsWidgets`, `SessionPrefs` | `SettingsView`, `Prefs` (same keys) | ported |
| `ComponentsPage`, `DriverPage`, `GameEnvironmentEditor` | `ComponentsView`, `DriverView` | partial (see §4) |
| `SessionActivity` + immersive sticky mode | `SessionScreen`, full-screen `ZStack` | ported |
| `SessionService`, `SessionState`, `SessionPhase` | `SessionController` + `SessionStateMachine` | ported |
| `SessionPaths`, `SessionArtifacts`, `events.jsonl` | `SessionArtifacts`, `SessionEvent` | ported |
| `WaylandCompositor` (C, Vulkan swapchain) | `MetalPresenter` (blit only) | replaced - the guest composites |
| `adrenotools`, Turnip, `LinuxVulkanDriverManager` | guest's own Mesa/Vulkan on virtio-gpu | moved into the guest |
| `FakeInputWriter`, `OnScreenControls`, `TouchpadGestures`, `SteamDeckPad` | `InputRouter`, `DeckPad`, `FaceButtons` | ported |
| `PulseAudioComponent`, AAudio sink, DirectAudio relay | host relay over a Unix socket into CoreAudio | not written (§4) |
| `TurnipDriver` fingerprint checks, GPU chooser | gone: the guest has one GPU | n/a |
| `BwrapSpawner` (Flatpak sandboxes) | guest-side `bannerlator-bwrap`, started by the guest's init | moved into the guest |
| `GuestCommand`, `LinuxRuntime.prootPrefix/binds` | `GuestCommandBuilder` (pure, tested) | ported |
| agent `ContentProvider` + `tools/droiddeckctl` | loopback HTTP + `ios/scripts/appledeckctl` | server not written (§4); verbs and JSON ported and tested |
| `WirelessAdbFix`, `PhantomProcessGate` | not needed: no adb, and the guest is our own process | dropped, with reasons |

### What the guest gets for free

Because the guest is DroidDeck's runtime with a real kernel in front of it:

- **proot is no longer load-bearing.** On Android it exists because an app cannot
  get mount namespaces. In the guest there is a kernel and a real uid 0, so the
  runtime's scripts run as themselves. `GuestCommandBuilder` still emits the same
  proot command line, because `LinuxRuntime`'s overlay scripts, its preload list
  and the shims in `tools/linuxfs/preload` are written against it, and because a
  runtime that works two ways is a runtime that can be debugged both ways.
- **The desktop, Flatpak, the store's installs, and imported AppImages** work the
  way they work on Android, because they are the same scripts.
- **Proton and Windows games** are unchanged from the Android side: guest-side
  Wine plus gamescope. Their speed is the TCG speed, which is where Madeira's
  backend (§1) earns its place.

---

## 3. Licensing: why `ios/` is GPL-2.0-or-later while the repo is GPL-3.0

DroidDeck is GPL-3.0. QEMU, including the UTM fork AppleDeck builds, is
GPL-2.0. iOS apps cannot spawn processes, so the emulator has to be linked into
the app - and GPL-2.0 code inside a GPL-3.0 binary is a licence violation, not a
style question.

Resolution, which is the same one Husk reached for the same reason:

- Everything AppleDeck authors under `ios/` is **GPL-2.0-or-later** (SPDX header
  on every file, licence text in `ios/LICENSE`). GPL-2.0-or-later code may be
  reused in a GPL-3.0 work, so nothing is lost.
- The repo's other contents stay exactly as upstream licensed them. The Android
  app is untouched, and remains GPL-3.0.
- Any code from a GPL-3.0 source (a Madeira backend, later) lives in its own
  module with its own SPDX header and is excluded from a build variant that links
  QEMU. That variant split is a build-time concern in `ios/project.yml`.
- The IPA is distributed with the public source of the app, which satisfies
  GPLv2 §3. Guest images are fetched at build time and never committed, the same
  as Husk's.

Not on the App Store, for the two reasons that have always applied: GPLv2's terms
against the store's distribution restrictions, and `get-task-allow` plus an
attached debugger at runtime, which App Review does not permit. Sideloading via
AltStore, SideStore or TrollStore.

---

## 4. What is left, in the order it should be built

Each item names what it unblocks. Nothing here is speculative scaffolding.

1. **`ios/patches/0001-appledeck-input-clock.patch`.** The single blocking item.
   QEMU has no public way to reach the `QemuClock` its input subsystem was
   registered with, and the key event path takes a QAPI-generated struct from a
   private header. The patch adds five functions to QEMU (`appledeck_input_clock`,
   `appledeck_send_abs/btn/key`, `appledeck_set_frame_callback`,
   `appledeck_set_event_callback`) and registers a `DisplayChangeListener` that
   calls the frame callback with the scanout's pixman image. Until it exists
   there is no emulator the app can drive; `ios/scripts/build_guest.sh` stops and
   says exactly this rather than building something inert.
2. **The bootable guest image.** DroidDeck's rootfs is an asset directory the
   Android app unpacks; the guest needs a disk image, a kernel and an initramfs.
   The rootfs contents are already right (`tools/linuxfs`), so this is packaging
   plus a `guest/rootfs.img` build step, and the image itself stays upstream.
3. **Audio.** There is no QEMU audio backend that reaches CoreAudio, and no AAudio
   to sink into. DroidDeck's DirectAudio relay already speaks a file-descriptor
   protocol between a guest `.so` and a host relay; only the host half is
   rewritten, as an `AudioUnit`/`AVAudioEngine` sink behind the same wire format.
4. **The agent bridge server.** `AgentCommand`, `AgentError`'s exit codes and the
   schema-1 state payload are written and tested; the loopback HTTP server that
   serves them is not. `droiddeckctl`'s verbs, flags and exit codes are the
   contract, and `ios/scripts/appledeckctl` is the client.
5. **Game environment editor, components manager, saves, cover art.** Ported as
   models; the screens still to write.
6. **A second backend** (Madeira, §1) behind `GuestRuntime`.

### The letterbox, and why the build pins its Xcode

An IPA installed on iOS 26 came out with black bars above and below and
everything drawn too large. That is not a layout bug: iOS runs an app with no
launch screen in the old 320x480 compatibility mode, which letterboxes it and
caps it out of the full screen a session needs. The two fixes are a real
`LaunchScreen.storyboard` and building against the newest Xcode on the runner
rather than the default one - an app built against an older SDK gets letterboxed
by the newer iOS it lands on. Both are in place, and the CI prints the Xcode it
chose so a regression is visible in the log rather than on somebody's phone.

### Performance, honestly

| What | Expectation |
|---|---|
| Guest boot to a login prompt | minutes |
| Steam Big Picture navigation | usable, with TCG-scale input latency |
| The desktop, Flatpak apps | usable |
| Games, native Linux | slow; a slideshow is a plausible outcome |
| Windows games through Proton | not viable on this backend - which is what the Madeira backend is for |

Nothing above has been measured on hardware yet. Every one of these rows is a
prediction until it is, and the port's own docs are written so that a
measurement can replace a prediction without rewriting the argument.

---

## 5. What is tested, and how

`ios/Packages/AppleDeckCore` is Foundation-only and has no UI, so it is tested
on the Linux runner (`.github/workflows/ios-ipa.yml`, job `AppleDeckCore`) in
seconds rather than in a macOS queue. It holds the parts that are decisions
rather than widgets:

- the session state machine, including that every transition is legal and that a
  repeated phase is not a transition (it would double-count in `events.jsonl`);
- the schema-1 state payload, field by field, against DroidDeck's `state`;
- the preference schema: every key and default, matched against
  `session/SessionPrefs.kt`;
- the proot command line and bind list a session runs;
- the agent bridge's verb parsing and exit codes;
- the Steam library reader and its KeyValues parser, including a truncated file
  parsing as absent rather than as an empty library;
- the file manager's ordering, name validation and protected paths.

The iOS target itself (SwiftUI, Metal, GameController, the C bridge) is compiled
by the `Unsigned IPA` job on a macOS runner on every push, and the IPA's bundle
is validated before it is packaged - the CFBundle keys, the executable the plist
names, and the platform of the guest dylib - because a bundle missing those
installs nowhere and says nothing useful about why.