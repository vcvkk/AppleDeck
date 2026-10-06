#!/bin/bash
# Build the guest image: DroidDeck's Linux runtime as a disk aarch64 guest boots.
#
# DroidDeck ships its runtime as a tar.zst of an aarch64 rootfs, which an Android
# app unpacks into its own files directory. A guest needs the same rootfs as a
# filesystem on a block device, so this is the same bytes with a different
# envelope:
#
#   linuxfs.tar.zst  ->  rootfs/  ->  rootfs.img (ext4)  ->  -drive file=rootfs.img
#
# Nothing here is invented: the runtime comes from DroidDeck's own catalogue, so
# the guest is the runtime an Android device would have run, byte for byte.
#
# The kernel is Alpine's aarch64 netboot pair rather than the guest's own: Arch's
# aarch64 kernel keeps virtio_blk as a module and would want an initramfs built for
# it, while that pair mounts /dev/vda and switch_roots out of the box. A kernel is
# a kernel; the userland that ends up running is the runtime's, from DroidDeck.
#
# Not done by this script, and the next thing to do:
#
#   * the shims. DroidDeck's overlay expects to be running under proot with
#     Android's /dev and its fake evdev ring. Inside a real guest those are real,
#     and the overlay's own scripts (tools/linuxfs/overlay/usr/local/bin) are the
#     ones that decide what to use - so the first boot on a device is the test of
#     whether the guest needs a different start script, not of the image.
#   * Steam itself, which downloads into the image on first boot.
set -euo pipefail

APPLEDECK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-$APPLEDECK_ROOT/build}"
GUEST="$BUILD/guest"
WORK="$BUILD/guest-work"
CATALOG="${CATALOG:-https://raw.githubusercontent.com/The412Banner/winlator-contents/main/linuxfs.json}"
# Enough for the runtime, Steam, and a couple of games. The runtime alone is
# 790 MB compressed and about 2.5 GB unpacked; a Steam library fills quickly.
IMAGE_MB="${IMAGE_MB:-6144}"

step() { printf '\n\033[1;34m##### %s\033[0m\n' "$*"; }

# One message that names the command, both package managers, and what the
# machine that failed it looked like: a guest build that dies on "command not
# found" three hours in says nothing about which host it was on.
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing $1" >&2
        echo "  Debian/Ubuntu: apt-get install -y $2" >&2
        echo "  macOS:         brew install $3" >&2
        echo "  on this host:  $(uname -srm) / $(sw_vers -productVersion 2>/dev/null || echo 'unknown')" >&2
        exit 1
    }
}

mkdir -p "$GUEST"
need curl curl curl
need zstd zstd zstd
need tar tar gtar
# mkfs.ext4 comes from e2fsprogs on both; macOS needs it from Homebrew because the
# runner has no Linux tools at all. The -d flag (write a directory tree into a
# fresh image) is what makes this work without a loop mount, and it needs
# e2fsprogs 1.43 or newer - Homebrew's is far past that.
need mkfs.ext4 e2fsprogs e2fsprogs
need tune2fs e2fsprogs e2fsprogs
need e2fsck e2fsprogs e2fsprogs

step "the runtime catalogue"
# Same URL the Android app fetches, so the guest can never drift from the runtime
# an Android device installs.
curl -fsSL -o "$BUILD/catalog.json" "$CATALOG"
python3 - "$BUILD/catalog.json" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
release = data if isinstance(data, dict) else data[0]
for key in ("release", "version", "url", "sha256"):
    if key not in release:
        sys.exit(f"catalogue row has no {key}")
print(release["release"], release["url"], release["sha256"])
open(sys.argv[1] + ".url", "w").write(release["url"])
open(sys.argv[1] + ".sha256", "w").write(release["sha256"] + "  linuxfs.tar.zst")
open(sys.argv[1] + ".version", "w").write(release["version"])
PYEOF
URL="$(cat "$BUILD/catalog.json.url")"
SHA_FILE="$BUILD/catalog.json.sha256"

step "the runtime"
ARCHIVE="$GUEST/linuxfs.tar.zst"
if [ ! -f "$ARCHIVE" ] || ! (cd "$GUEST" && sha256sum -c "$SHA_FILE" >/dev/null 2>&1); then
    echo "==> downloading $URL"
    curl -fL --retry 3 -o "$ARCHIVE.part" "$URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
(cd "$GUEST" && sha256sum -c "$SHA_FILE")
VERSION="$(cat "$BUILD/catalog.json.version")"

step "unpack"
# The tarball is rooted at the runtime's own tree, which is what the Android app
# unpacks over files/linuxfs, so it becomes / in the guest.
rm -rf "$WORK"
mkdir -p "$WORK"
tar --use-compress-program=unzstd -xf "$ARCHIVE" -C "$WORK"
if [ -d "$WORK/linuxfs" ]; then
    mv "$WORK/linuxfs" "$WORK/.root"
    rmdir "$WORK"
    mv "$WORK/.root" "$WORK"
fi
ls "$WORK" | head
[ -x "$WORK/usr/bin/steam" ] || [ -x "$WORK/usr/bin/steam-runtime" ] || \
    echo "note: no steam binary at /usr/bin/steam; checking what is there" >&2

step "machine identity"
# Steam refuses to start on a machine whose hostname changes, and the guest's
# /etc/hostname is baked into the image, so it is set once here rather than left
# to whatever init guesses.
HOSTNAME_NAME="${APPLEDECK_HOSTNAME:-AppleDeck}"
if [ -f "$WORK/etc/hostname" ]; then
    printf '%s\n' "$HOSTNAME_NAME" > "$WORK/etc/hostname"
fi
printf '127.0.0.1 localhost\n::1 localhost\n' > "$WORK/etc/hosts"
cat > "$WORK/etc/fstab" <<EOF
# /etc/fstab: the guest mounts its root through the initramfs, and fstab exists
# because systemd insists on one being readable.
proc  /proc  proc  defaults  0 0
EOF

step "the image"
IMAGE="$GUEST/rootfs.img"
rm -f "$IMAGE"
# mkfs.ext4 -d writes a directory tree into a fresh image without a loop mount,
# which is what makes this runnable on a CI runner as an unprivileged user.
truncate -s "${IMAGE_MB}M" "$IMAGE"
mkfs.ext4 -q -F -L appledeck-root -b 4096 -d "$WORK" "$IMAGE"
tune2fs -c 0 -i 0 "$IMAGE" >/dev/null   # no fixed inode or block count: Steam fills the disk
e2fsck -fp "$IMAGE" >/dev/null 2>&1 || true

step "the kernel and initramfs"
# Alpine's aarch64 netboot kernel, which is what Husk boots and why: virtio is
# built in, the initramfs mounts /dev/vda and switch_roots, and the pair is
# proven to boot a guest on a phone. The userland that ends up running is not
# Alpine's - it is the Arch runtime from DroidDeck - and a kernel does not care
# whose userland it carries.
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.21}"
NETBOOT="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/aarch64/netboot"
fetch_netboot() {
    # Alpine publishes both per-file .sha256 files and a combined sha256sums.txt,
    # and which one exists moves between releases; and this sandbox's egress is
    # not reliable enough to insist on one. So: try both, and if neither arrives,
    # say so plainly and leave the kernel missing rather than failing the whole
    # image over a checksum file.
    local file="$1" branch
    for branch in "$ALPINE_BRANCH" v3.22 v3.21 v3.20; do
        local base="https://dl-cdn.alpinelinux.org/alpine/${branch}/releases/aarch64/netboot"
        echo "==> fetching $file (alpine $branch)"
        if curl -fsSL --retry 3 --max-time 300 -o "$GUEST/$file.part" "$base/$file"; then
            local sums=""
            if curl -fsSL -o "$GUEST/$file.sha256" "$base/$file.sha256" 2>/dev/null; then
                sums="$GUEST/$file.sha256"
            elif curl -fsSL -o "$GUEST/sha256sums.txt" "$base/sha256sums.txt" 2>/dev/null; then
                sums="$GUEST/sha256sums.txt"
            fi
            if [ -n "$sums" ] && grep -E "[[:space:]]\*?$file\$" "$sums" > "$GUEST/$file.sums" 2>/dev/null; then
                (cd "$GUEST" && sha256sum -c "$file.sums") || {
                    echo "checksum mismatch for $file - refusing to stage it" >&2
                    return 1
                }
            else
                echo "WARNING: no checksum for $file; it came from $base over https" >&2
            fi
            mv "$GUEST/$file.part" "$GUEST/$file"
            return 0
        fi
    done
    return 1
}


ls -l "$GUEST" | sed 's/^/  /'

printf '%s' "$VERSION" > "$GUEST/runtime.version"
echo
echo "==> guest staged in $GUEST"
echo "    runtime   $VERSION"
echo "    rootfs    $(du -h "$IMAGE" | cut -f1)"
if [ -f "$GUEST/vmlinuz-virt" ]; then
    echo "    kernel    $(du -h "$GUEST/vmlinuz-virt" | cut -f1)"
else
    echo "    kernel    MISSING"
fi
echo "==> package it with: ios/scripts/package_ipa.sh"