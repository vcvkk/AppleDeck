#!/bin/bash
# Build the guest runtime for arm64-apple-ios and stage it into the app bundle.
#
# This is the slow half of AppleDeck, and it is the half that cannot be written
# from scratch: the emulator is QEMU, built as a library for iOS, and the recipe
# that works is already proven by Husk (github.com/Leviidev/Husk) on real
# hardware. So this script does the AppleDeck-specific parts and borrows the
# rest deliberately:
#
#   * QEMU is utmapp/qemu's fork at the pinned tag. Upstream QEMU cannot build
#     itself as a library, and iOS cannot spawn processes, so the emulator has to
#     live in the app's own process.
#   * The dependency builds (libffi, glib, pixman, libucontext, libslirp, ANGLE,
#     libepoxy, virglrenderer) and the meson cross-file come from Husk's
#     scripts, fetched below at a pinned commit.
#   * The iOS JIT substrate (split-W^X, the brk handshake with StikDebug or the
#     built-in StikJIT helper) also comes from there. AppleDeck needs exactly the
#     same thing: TCG on iOS needs executable memory, and iOS only grants it to
#     an attached debugger.
#
# What is AppleDeck's own:
#
#   ios/patches/0001-appledeck-host-bridge.patch
#       Adds ui/appledeck-host.c to QEMU: appledeck_send_abs/btn/key() for input,
#       appledeck_set_frame_callback() for frames, and a DisplayChangeListener
#       that hands the app the scanout. The app's bridge knows five function
#       names and no QEMU types at all, which is what makes it survive QEMU
#       updates - the first version of this patch was going to reach into the
#       input subsystem's clock, and QEMU 10 does not have one to reach for.
#
# If the patch is not there yet this script stops and says so, rather than
# building an emulator the app cannot talk to.
set -euo pipefail

APPLEDECK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$APPLEDECK_ROOT/build"
QEMU_TAG="${QEMU_TAG:-v10.2.4}"
HUSK_COMMIT="${HUSK_COMMIT:-main}"
HUSK_REPO="https://github.com/Leviidev/Husk"

step() { printf '\n\033[1;34m##### %s\033[0m\n' "$*"; }

step "sources"
mkdir -p "$BUILD"
QEMU_SRC="$BUILD/qemu-utl"
if [ ! -d "$QEMU_SRC" ]; then
    git clone --depth 1 --branch "$QEMU_TAG" https://github.com/utmapp/qemu.git "$QEMU_SRC"
fi
HUSK_SRC="$BUILD/husk"
if [ ! -d "$HUSK_SRC" ]; then
    git clone --depth 1 "$HUSK_REPO" "$HUSK_SRC"
fi

step "AppleDeck's QEMU patch"
# ios/patches/0001-appledeck-host-bridge.patch adds ui/appledeck-host.c: input in
# (abs, buttons, evdev key codes), frames out (one DisplayChangeListener handing
# over the scanout's pixman image), and no QEMU types in any of the signatures.
PATCH="$APPLEDECK_ROOT/patches/0001-appledeck-host-bridge.patch"
if [ ! -f "$PATCH" ]; then
    echo "no $PATCH - see docs/ios-port.md" >&2
    exit 1
fi

step "apply"
for p in "$APPLEDECK_ROOT"/patches/*.patch; do
    echo "  $p"
    (cd "$QEMU_SRC" && git apply --check "$p" && git apply "$p")
done

step "dependencies"
# The sources first. Husk's build script builds out of third_party/build, and
# nothing else fetches them - so without this step every autotools package fails
# with a configure error about a directory that was never downloaded, which reads
# like a broken build rather than a missing download.
"$HUSK_SRC/scripts/fetch_sources.sh"

step "build libffi glib pixman libucontext libslirp"
# On failure the dependency's own log is printed: Husk writes one per package,
# and "[FAIL] libffi" on its own says nothing about why.
if ! "$HUSK_SRC/scripts/build_ios.sh" libffi glib pixman libucontext libslirp; then
    for log in "$HUSK_SRC"/build/logs/*.log; do
        [ -e "$log" ] || continue
        echo "=== $(basename "$log") ===" >&2
        tail -40 "$log" >&2
    done
    exit 1
fi

step "build QEMU"
if ! "$HUSK_SRC/scripts/build_ios.sh" qemu; then
    for log in "$HUSK_SRC"/build/logs/*.log; do
        [ -e "$log" ] || continue
        echo "=== $(basename "$log") ===" >&2
        tail -40 "$log" >&2
    done
    exit 1
fi

step "stage"
# Husk stages into build/ios-arm64/lib; the app expects the dylib in its
# Frameworks directory, and the guest images beside it.
mkdir -p "$BUILD/guest"
QEMU_LIB=$(find "$BUILD" -name 'libqemu-aarch64-softmmu.dylib' | head -1)
[ -n "$QEMU_LIB" ] || { echo "no QEMU dylib was built" >&2; exit 1; }
# Straight into the guest directory: package_ipa.sh stages whatever is there, and
# keeping one place means the two scripts cannot disagree about what shipped.
cp "$QEMU_LIB" "$BUILD/guest/"

echo
echo "==> staged in $BUILD/guest:"
ls -lh "$BUILD/guest" || true
echo "==> pass --guest to package_ipa.sh, or re-run the workflow with guest: true"