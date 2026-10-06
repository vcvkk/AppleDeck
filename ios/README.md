# AppleDeck, the iOS port

DroidDeck on iOS. The guest is DroidDeck's; the launcher is Apple's.

The design, the reasoning behind it, what is built and what is left are in
[`../docs/ios-port.md`](../docs/ios-port.md). This file is how to build it and
what is where.

## Status

| Piece | State |
|---|---|
| Full fork of DroidDeck, history and tags | done |
| Android build in the fork (APK, unsigned CI) | green on every push |
| `AppleDeckCore` - state machine, preferences, guest command line, agent verbs, library, file rules | done, tested on the Linux runner |
| SwiftUI launcher: home, library, store, files, components, driver, settings | done |
| Session screen: Metal presenter, HUD, on-screen controls, game controllers | done |
| QEMU-TCG guest bridge (`qemu_bridge.c`) | done except for the QEMU patch it needs |
| The QEMU patch that exposes input and frames | **not written** - blocking |
| Bootable guest image | not built |
| Audio relay to CoreAudio | not written |
| Agent bridge HTTP server | not written (the protocol is done and tested) |
| Unsigned IPA from Actions | builds on every push |

Nothing in this table has been run on a device. It has been compiled, and its
parts have been tested where they can be tested without an iPhone.

Verified on every push, since the letterbox fix:

- `AppleDeckCore`: `swift test` on ubuntu, all tests green.
- `Unsigned IPA`: builds on a macOS runner against the newest Xcode on the image,
  passes the bundle validation in `scripts/package_ipa.sh`, and is attached to the
  run as `AppleDeck-ipa`.
- The Android APK still builds from this fork, unmodified except for the two
  fork adjustments noted in the workflow (release assets come from upstream, and
  signing is off unless `DROIDDECK_SIGNING` is set).

## Building

The only supported build is the one in CI, which is also the only one that can
produce an installable artifact:

```sh
gh workflow run ios-ipa.yml            # or push to main
```

That gives an unsigned `AppleDeck.ipa` as a run artifact, ready for AltStore,
SideStore, TrollStore or Sideloadly. Locally, with Xcode and XcodeGen:

```sh
brew install xcodegen
cd ios
xcodegen generate
./scripts/package_ipa.sh ~/Desktop/AppleDeck.ipa
```

The guest runtime is a separate, slow step, and it is not finished:

```sh
./scripts/build_guest.sh               # stops and explains what is missing
```

### Why unsigned, and why not the App Store

Two independent reasons, both of which have to be true and neither of which can
be worked around:

1. The binary links QEMU, which is GPLv2, and the app's own code is
   GPL-2.0-or-later so the combination is. GPLv2's terms conflict with the App
   Store's distribution restrictions - the long-settled VLC question.
2. TCG needs executable memory, and iOS only grants it while a debugger is
   attached (StikDebug, or the built-in StikJIT helper). That needs
   `get-task-allow`, which App Review does not permit.

Distribution is a public source repository plus sideloaded builds. That satisfies
GPLv2 §3: the corresponding source of everything in the IPA is here.

## Layout

```
ios/
  project.yml                 XcodeGen; the checked-in .xcodeproj is generated from it
  AppleDeck/
    App/                      the entry point and the launcher's shape
    Launcher/                 the pages, and the model they share
    Session/                  the session screen, the presenter, the controller
    Input/                    touch, keyboard, game controllers
    Runtime/                  the guest bridge: qemu_bridge.c and GuestRuntime.swift
    include/                  the bridging header
  Packages/AppleDeckCore/     the decisions, without the widgets. Foundation only
  scripts/
    package_ipa.sh            build, validate the bundle, package
    build_guest.sh            fetch, patch and build QEMU for iOS
  LICENSE                     GPL-2.0, for everything above
```

`AppleDeckCore` is a separate SwiftPM package on purpose. It holds the parts
that are decisions rather than pixels - the session state machine, the
preference schema (DroidDeck's key names), the proot command line a session
runs, the agent bridge's verbs and schema-1 payload, the Steam library reader,
the file manager's rules - and it has no UIKit in it, so all of it is tested on
a Linux runner in seconds rather than only in a macOS queue.

## The agent bridge

DroidDeck reaches its agent bridge over `adb shell content call`. iOS has no adb
and no way for a shell to reach an app, so AppleDeck's is a loopback HTTP
endpoint. The verbs, the flags, the JSON and the exit codes are DroidDeck's, so
a harness that drives DroidDeck over `droiddeckctl` drives AppleDeck over
`appledeckctl` with the same expressions:

```sh
appledeckctl state --json
appledeckctl start steam --wait
appledeckctl start desktop
appledeckctl run /usr/bin/foo -- arg1 arg2
appledeckctl stop
appledeckctl resume
```

Exit codes are upstream's: 0 success, 2 invalid or rejected, 3 transport, 4
session failure, 5 timeout. The server is not written yet; the protocol is in
`AppleDeckCore` and its tests are the contract it will be built against.

## Licence

GPL-2.0-or-later for everything in `ios/` (`ios/LICENSE`). The rest of the
repository keeps upstream's GPL-3.0. The reasoning, including why a GPL-3.0
backend such as Madeira can be added later without a licence argument, is in
[`../docs/ios-port.md`](../docs/ios-port.md#3-licensing-why-ios-is-gpl-2-0-or-later-while-the-repo-is-gpl-3-0).