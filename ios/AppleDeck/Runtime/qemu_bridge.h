/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The host side of the guest runtime.
 *
 * QEMU is not linked into the app: it is built as libqemu-aarch64-softmmu.dylib
 * by ios/scripts/build_guest.sh and dlopened here at launch. iOS cannot spawn a
 * process, so the emulator has to live in ours, and dlopen is what lets one IPA
 * run with or without it - an app whose guest half was never built still
 * launches and says why, instead of not launching.
 */
#ifndef APPLEDECK_QEMU_BRIDGE_H
#define APPLEDECK_QEMU_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AppleDeckQemuConfig {
    /* Every path is inside the app container; NULL means "not staged". */
    const char *kernel;
    const char *initrd;
    const char *disk;
    const char *bios;
    const char *cmdline;
    int memory_mb;
    int vcpus;
    int width;
    int height;
    /* MMTTCG, one guest vCPU per host thread. On a phone this is the single
       largest performance decision after TCG itself. */
    int smp;
} AppleDeckQemuConfig;

/* A frame the emulator produced, as BGRA, row-major, `stride` bytes per row.
   `const void *` rather than `uint8_t *` so Swift imports it as a plain
   UnsafeRawPointer and does not have to convert. */
typedef void (*AppleDeckFrameFn)(const void *pixels, int width, int height, int stride);

/* type: 1 key down, 2 key up, 3 pointer move, 4 button down, 5 button up,
 * 6 wheel, 7 pointer enter, 8 pointer leave. Codes are QEMU's qemu_input
 * protocol numbers so the mapping lives in one table in Swift. */
typedef void (*AppleDeckEventFn)(int type, int code, int a, int b, int c);

/* Registers the frame and event callbacks. Frames arrive on QEMU's display
   thread; the presenter hops them to the main thread. Called once, at launch,
   before the first AppleDeckQemuStart. */
void AppleDeckQemuSetCallbacks(AppleDeckFrameFn frame, AppleDeckEventFn event);

/* What QEMU's patched display listener calls. Declared here because the patch
   compiles against this header, not the other way round. */
void AppleDeckQemuEmitFrame(const void *pixels, int width, int height, int stride);

/* False when the dylib is not in the bundle; `reason` says which symbol was
   missing, which is the difference between "build the guest" and "rebuild the
   guest". */
bool AppleDeckQemuAvailable(char *reason, size_t reason_len);

/* Returns 0 when the machine is running. Non-zero is a QEMU exit status. */
int AppleDeckQemuStart(const AppleDeckQemuConfig *config);
void AppleDeckQemuStop(void);
bool AppleDeckQemuRunning(void);

/* Input, straight through to the patched QEMU's appledeck_send_* functions.
   `type` values are the ones named in AppleDeckEventFn above. Events sent
   while nothing is running are counted, not queued: a queue would deliver a
   burst of stale touches to a session that has already ended. */
void AppleDeckQemuSendEvent(int type, int code, int a, int b, int c);

/* Events dropped because no session was running. Shown by the session overlay
   so "my taps do nothing" has an answer. */
unsigned long AppleDeckQemuDroppedEvents(void);

#ifdef __cplusplus
}
#endif

#endif /* APPLEDECK_QEMU_BRIDGE_H */