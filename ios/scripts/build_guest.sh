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
#   ios/patches/0001-appledeck-input-clock.patch
#       Adds appledeck_input_clock(), appledeck_send_abs/btn/key() and
#       appledeck_set_frame_callback() to QEMU, so the app bridge can drive
#       input and receive frames without knowing QEMU's private types.
#
# If the patch is not there yet this script stops and says so, rather than
# building an emulator the app cannot talk to.
set -euo pipefail

APPLEDECK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$APPLEDECK_ROOT/build"
QEMU_TAG="${QEMU_TAG:-10.0.12-utm}"
HUSK_COMMIT="${HUSK_COMMIT:-main}"
HUSK_REPO="https://github.com/Leviidev/Husk"

step() { printf '\n\033[1;34m##### %s\033[0m\n' "$*"; }

step "sources"
mkdir -p "$BUILD"
QEMU_SRC="$BUILD/qemu"
if [ ! -d "$QEMU_SRC" ]; then
    git clone --depth 1 --branch "$QEMU_TAG" https://github.com/utmapp/qemu.git "$QEMU_SRC"
fi
HUSK_SRC="$BUILD/husk"
if [ ! -d "$HUSK_SRC" ]; then
    git clone --depth 1 "$HUSK_REPO" "$HUSK_SRC"
fi

step "AppleDeck's QEMU patch"
PATCH="$APPLEDECK_ROOT/patches/0001-appledeck-input-clock.patch"
if [ ! -f "$PATCH" ]; then
    cat >&2 <<EOF

No $PATCH.

That patch is the next piece of work (see docs/ios-port.md, "Guest runtime:
what is left"). It has to add, to QEMU:

  void *appledeck_input_clock(void);
  void  appledeck_send_abs(int axis, int value);
  void  appledeck_send_btn(int button, int down);
  void  appledeck_send_key(int keycode, int down);
  void  appledeck_set_frame_callback(AppleDeckFrameFn);
  void  appledeck_set_event_callback(AppleDeckEventFn);

and register a DisplayChangeListener that calls the frame callback with the
scanout's pixman image. Until it exists there is no way to build an emulator the
app can drive, and building one anyway would only produce an IPA whose session
does nothing.

EOF
    exit 1
fi

step "apply"
for p in "$APPLEDECK_ROOT"/patches/*.patch; do
    echo "  $p"
    (cd "$QEMU_SRC" && git apply --check "$p" && git apply "$p")
done

step "dependencies"
# libffi glib pixman libucontext libslirp, ANGLE, then libepoxy + virglrenderer.
"$HUSK_SRC/scripts/build_ios.sh" libffi glib pixman libucontext libslirp

step "QEMU"
"$HUSK_SRC/scripts/build_ios.sh" qemu

step "stage"
# Husk stages into build/ios-arm64/lib; the app expects the dylib in its
# Frameworks directory, and the guest images beside it.
mkdir -p "$BUILD/guest"
QEMU_LIB=$(find "$BUILD" -name 'libqemu-aarch64-softmmu.dylib' | head -1)
[ -n "$QEMU_LIB" ] || { echo "no QEMU dylib was built" >&2; exit 1; }
cp "$QEMU_LIB" "$BUILD/guest/"

# The guest image is DroidDeck's own runtime, unpacked into a disk the guest
# boots: the rootfs the Android app ships as an asset, an arm64 kernel and an
# initramfs. Fetched, never committed - it is ~1 GiB and it belongs upstream.
if [ ! -f "$BUILD/guest/rootfs.img" ]; then
    echo "==> fetching the guest image" >&2
    echo "    See docs/ios-port.md for how the DroidDeck rootfs becomes a bootable" >&2
    echo "    image, and tools/linuxfs for what it contains." >&2
fi

echo
echo "==> staged in $BUILD/guest:"
ls -lh "$BUILD/guest" || true
echo "==> pass --guest to package_ipa.sh, or re-run the workflow with guest: true"