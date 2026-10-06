#!/bin/bash
# Build AppleDeck and package an unsigned IPA.
#
# Unsigned on purpose: AltStore, SideStore and TrollStore all re-sign at install,
# so no signing team is needed and one artifact works for everyone. This mirrors
# ios/scripts/package_ipa.sh in Husk, which is where the approach comes from.
#
# The validation step is not optional decoration. A bundle missing
# CFBundleIdentifier builds and zips perfectly happily and then fails to install
# with no useful message - Xcode does not inject those keys when a custom
# INFOPLIST_FILE is supplied without GENERATE_INFOPLIST_FILE, which is exactly
# how this project is set up.
set -euo pipefail

APPLEDECK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="${DD:-/tmp/appledeck_ipa}"
OUT="${1:-$APPLEDECK_ROOT/build/AppleDeck.ipa}"
mkdir -p "$DD"

if command -v xcodegen >/dev/null 2>&1; then
    echo "==> regenerating the project from project.yml"
    (cd "$APPLEDECK_ROOT" && xcodegen generate --quiet)
else
    echo "==> xcodegen not installed; using the checked-in project as-is" >&2
fi

echo "==> building"

# One build reports every error in the module, because the limit the compiler
# applies is per file: a build with three problems in three files shows all
# three, and only a single file with twenty of them is cut short. Xcode 26 has no
# -error-limit frontend flag to raise even that, so this is as close as the
# toolchain gets.
build_app() {
    xcodebuild -project "$APPLEDECK_ROOT/AppleDeck.xcodeproj" -scheme AppleDeck \
        -sdk iphoneos -configuration Release -derivedDataPath "$DD" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        build 2>&1 | tee "$DD/build.log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
}

build_app

# A failed build used to sail straight past this: the previous .app is still in
# DerivedData, so validation and packaging both succeed and produce an IPA of the
# LAST build. Shipping a stale binary silently is the worst outcome here.
if ! grep -q "BUILD SUCCEEDED" "$DD/build.log"; then
    echo "build failed; refusing to package a stale app" >&2
    grep -E "error:" "$DD/build.log" | head -20 >&2
    exit 1
fi

APP="$DD/Build/Products/Release-iphoneos/AppleDeck.app"
[ -d "$APP" ] || { echo "no app bundle at $APP" >&2; exit 1; }

# Stamp the build's identity into the bundle so a log from a stale install is
# distinguishable from a log proving a fix did not work.
APP_PLIST="$DD/Build/Products/Release-iphoneos/AppleDeck.app/Info.plist"
if [ -f "$APP_PLIST" ]; then
    COMMIT="$(git -C "$APPLEDECK_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    git -C "$APPLEDECK_ROOT" diff --quiet 2>/dev/null || COMMIT="$COMMIT-dirty"
    plutil -replace AppleDeckBuildCommit -string "$COMMIT" "$APP_PLIST"
    plutil -replace AppleDeckBuildDate -string "$(date -u '+%Y-%m-%d %H:%M UTC')" "$APP_PLIST"
    # The SDK version travels inside the bundle, because "it still looks wrong"
    # is unanswerable without knowing what the IPA was built against: an app built
    # against an older SDK is letterboxed by the newer iOS it is installed on, and
    # the person reporting it is looking at a phone, not at a build log.
    SDK=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo unknown)
    XCODE=$(xcodebuild -version | head -1)
    plutil -replace AppleDeckSDKVersion -string "$SDK ($XCODE)" "$APP_PLIST"
    echo "==> stamped build $COMMIT, sdk $SDK, $XCODE"
fi

echo "==> validating bundle"
PLIST="$APP/Info.plist"
rc=0
for key in CFBundleIdentifier CFBundleExecutable CFBundleName \
           CFBundlePackageType CFBundleVersion CFBundleShortVersionString \
           MinimumOSVersion UIDeviceFamily; do
    val="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)"
    if [ -z "$val" ]; then
        echo "  MISSING  $key   <-- the app will not install" >&2
        rc=1
    else
        printf "  ok       %-28s %s\n" "$key" "$(echo "$val" | head -1)"
    fi
done

EXE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null || true)"
if [ -n "$EXE" ] && [ ! -f "$APP/$EXE" ]; then
    echo "  MISSING  executable '$EXE' named by CFBundleExecutable" >&2
    rc=1
elif [ -n "$EXE" ]; then
    printf "  ok       %-28s %s\n" "executable present" "$EXE"
fi

# The compiled launch screen, checked for rather than assumed. An app that ships
# without one is run by iOS in the old 320x480 compatibility mode: black bars
# above and below and everything scaled up, which is the first thing an
# installer sees and looks like a layout bug. Two mistakes produce it - the key
# is missing from Info.plist, or the storyboard is not in the bundle - and only
# the second is visible from here.
LAUNCH_NAME=$(/usr/libexec/PlistBuddy -c "Print :UILaunchStoryboardName" "$PLIST" 2>/dev/null || true)
if [ -n "$LAUNCH_NAME" ]; then
    if [ -d "$APP/${LAUNCH_NAME}.storyboardc" ]; then
        printf "  ok       %-28s %s\n" "launch screen" "${LAUNCH_NAME}.storyboardc"
    else
        echo "  MISSING  ${LAUNCH_NAME}.storyboardc   <-- iOS will letterbox this app" >&2
        rc=1
    fi
else
    echo "  MISSING  UILaunchStoryboardName   <-- iOS will letterbox this app" >&2
    rc=1
fi

# The same check for the key form, and for the two that make iPadOS run an app
# in compatibility mode: no UIRequiresFullScreen, and every orientation declared
# for both idioms.
if [ -z "$(/usr/libexec/PlistBuddy -c "Print :UIRequiresFullScreen" "$PLIST" 2>/dev/null || true)" ]; then
    printf "  ok       %-28s %s\n" "UIRequiresFullScreen" "absent (good)"
else
    echo "  NOTE     UIRequiresFullScreen is set; iPadOS ignores it and letterboxes anyway"
fi
for key in UISupportedInterfaceOrientations 'UISupportedInterfaceOrientations~iphone' 'UISupportedInterfaceOrientations~ipad'; do
    # plutil, not PlistBuddy: PlistBuddy's key path parser treats '~' as
    # something other than part of a key name, and the idiomatic keys are exactly
    # the ones with a '~' in them.
    count=$(plutil -extract "$key" xml1 -o - "$PLIST" 2>/dev/null | grep -c "UIInterfaceOrientation" || true)
    if [ "${count:-0}" -ge 4 ]; then
        printf "  ok       %-28s %s orientations\n" "$key" "$count"
    else
        echo "  MISSING  $key lists ${count:-0} orientations; iPadOS letterboxes an app that does not support all four" >&2
        rc=1
    fi
done

# The guest runtime is optional at build time and mandatory at run time, so the
# bundle is checked either way: present when the guest was staged, and absent
# with a clear log line when it was not (the app then says why on launch).
QEMU="$APP/Frameworks/libqemu-aarch64-softmmu.dylib"
if [ -f "$QEMU" ]; then
    printf "  ok       %-28s %s\n" "guest runtime staged" "$(du -h "$QEMU" | cut -f1)"
    for guest in vmlinuz-virt initramfs-virt rootfs.img edk2-aarch64-code.fd; do
        if [ -f "$APP/guest/$guest" ]; then
            printf "  ok       guest/%s\n" "$guest"
        else
            echo "  MISSING  guest/$guest   <-- a session will not boot" >&2
            rc=1
        fi
    done
else
    echo "  note     no guest runtime in this build; the app will say why at launch"
fi

# The library build must be for iOS and for arm64. A Linux or x86_64 dylib loads
# and then crashes on the first frame, which is a miserable way to find out.
if [ -f "$QEMU" ]; then
    if ! file "$QEMU" | grep -qE 'arm64.*(platform 2|Platform/IO)?'; then
        echo "  ERROR    $QEMU is not arm64" >&2
        rc=1
    fi
    if otool -l "$QEMU" 2>/dev/null | grep -qA3 LC_BUILD_VERSION; then
        platform="$(otool -l "$QEMU" | awk '/LC_BUILD_VERSION/{found=1} found && /platform/{print $2; exit}')"
        if [ "$platform" != "2" ] && [ "$platform" != "ios" ]; then
            echo "  ERROR    $QEMU targets platform '$platform', not iOS (2)" >&2
            rc=1
        fi
    fi
fi

[ $rc -eq 0 ] || { echo "==> bundle is not installable; refusing to package" >&2; exit 1; }

echo "==> packaging"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
TMP_IPA="$STAGE/AppleDeck.ipa"
( cd "$STAGE" && zip -qry "$TMP_IPA" Payload )

# Atomic replace so a half-written IPA never sits where the good one was.
mkdir -p "$(dirname "$OUT")"
mv -f "$TMP_IPA" "$OUT"
rm -rf "$STAGE"
echo "==> $OUT  ($(du -h "$OUT" | cut -f1))"