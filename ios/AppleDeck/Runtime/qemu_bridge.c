/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * See qemu_bridge.h for what this is. The load is deliberately lazy and
 * fault-tolerant: a missing symbol is reported by name, because the ways this
 * goes wrong (never staged, staged from an older build, staged from an
 * unpatched QEMU) need three different fixes and "QEMU is missing" does not
 * tell them apart.
 *
 * Input is not driven through QEMU's qemu_input_* API here. Those take a
 * QemuClock pointer that upstream QEMU has no public accessor for, and the
 * key event path takes a QAPI-generated struct whose layout is a private
 * header's business. ios/patches/0001-appledeck-input-clock.patch adds three
 * functions to QEMU that own all of that:
 *
 *   appledeck_input_clock()            the clock input was registered with
 *   appledeck_send_abs(axis, value)    virtio-tablet absolute coordinates
 *   appledeck_send_btn(button, down)   buttons and keys
 *   appledeck_send_key(keycode, down)
 *
 * so this file stays free of QEMU internals and the patch stays small enough
 * to review.
 */
#include "qemu_bridge.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define QEMU_LIBRARY "libqemu-aarch64-softmmu.dylib"

typedef int (*qemu_init_fn)(int argc, char **argv);
typedef int (*qemu_main_loop_fn)(void);
typedef void (*qemu_cleanup_fn)(void);
typedef void *(*appledeck_clock_fn)(void);
typedef void (*appledeck_send_abs_fn)(int axis, int value);
typedef void (*appledeck_send_btn_fn)(int button, int down);
typedef void (*appledeck_send_key_fn)(int keycode, int down);
/* Added by the same patch: QEMU's display listener needs QEMU's own types to
   register, so the callback is handed over from inside QEMU instead. */
typedef void (*appledeck_set_frame_callback_fn)(AppleDeckFrameFn);
typedef void (*appledeck_set_event_callback_fn)(AppleDeckEventFn);

static struct {
    void *handle;
    qemu_init_fn init;
    qemu_main_loop_fn main_loop;
    qemu_cleanup_fn cleanup;
    appledeck_clock_fn clock;
    appledeck_send_abs_fn send_abs;
    appledeck_send_btn_fn send_btn;
    appledeck_send_key_fn send_key;
    appledeck_set_frame_callback_fn set_frame_callback;
    appledeck_set_event_callback_fn set_event_callback;
    bool running;
    pthread_t loop;
    bool have_loop;
    pthread_mutex_t lock;
    AppleDeckFrameFn frame;
    AppleDeckEventFn event;
} qemu;

static pthread_once_t once = PTHREAD_ONCE_INIT;
static char unavailable[256];

/* How many input events were dropped because the guest was not up. The session
   overlay shows the count: a session whose input silently does nothing looks
   exactly like a hung game. */
static unsigned long dropped_events;

static void note(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(unavailable, sizeof(unavailable), format, args);
    va_end(args);
}

static void *symbol(const char *name, bool required) {
    void *address = dlsym(qemu.handle, name);
    if (address == NULL && required) {
        note("libqemu is in the bundle but does not export %s; rebuild the guest with "
             "ios/patches/0001-appledeck-input-clock.patch applied "
             "(an unpatched or older QEMU dylib was staged)", name);
    }
    return address;
}

static void load(void) {
    pthread_mutex_init(&qemu.lock, NULL);
    qemu.handle = dlopen(QEMU_LIBRARY, RTLD_NOW | RTLD_GLOBAL);
    if (qemu.handle == NULL) {
        note("%s is not in the bundle; build it with ios/scripts/build_guest.sh", QEMU_LIBRARY);
        return;
    }
    qemu.init = (qemu_init_fn)symbol("qemu_init", true);
    qemu.main_loop = (qemu_main_loop_fn)symbol("qemu_main_loop", true);
    qemu.cleanup = (qemu_cleanup_fn)symbol("qemu_cleanup", false);
    qemu.clock = (appledeck_clock_fn)symbol("appledeck_input_clock", true);
    qemu.send_abs = (appledeck_send_abs_fn)symbol("appledeck_send_abs", true);
    qemu.send_btn = (appledeck_send_btn_fn)symbol("appledeck_send_btn", true);
    qemu.send_key = (appledeck_send_key_fn)symbol("appledeck_send_key", true);
    qemu.set_frame_callback = (appledeck_set_frame_callback_fn)symbol("appledeck_set_frame_callback", true);
    qemu.set_event_callback = (appledeck_set_event_callback_fn)symbol("appledeck_set_event_callback", false);
    if (qemu.init == NULL || qemu.main_loop == NULL) {
        return;
    }
    unavailable[0] = '\0';
}

void AppleDeckQemuSetCallbacks(AppleDeckFrameFn frame, AppleDeckEventFn event) {
    pthread_once(&once, load);
    pthread_mutex_lock(&qemu.lock);
    qemu.frame = frame;
    qemu.event = event;
    AppleDeckFrameFn frameCopy = frame;
    AppleDeckEventFn eventCopy = event;
    appledeck_set_frame_callback_fn setFrame = qemu.set_frame_callback;
    appledeck_set_event_callback_fn setEvent = qemu.set_event_callback;
    pthread_mutex_unlock(&qemu.lock);
    /* The frame callback has to be registered from inside QEMU: its display
       listener is built from types that only exist there. The copy handed over
       is a small C trampoline that forwards to the Swift closure, so the Swift
       side never has to be a C function pointer itself. */
    if (setFrame != NULL) {
        setFrame(frameCopy);
    }
    if (setEvent != NULL) {
        setEvent(eventCopy);
    }
}

/* QEMU's display listener calls this from its own thread for every scanout
   update. It is a C trampoline on purpose: a Swift closure cannot be stored and
   called later across the language boundary without a C function to land on. */
void AppleDeckQemuEmitFrame(const void *pixels, int width, int height, int stride) {
    pthread_once(&once, load);
    AppleDeckFrameFn frame;
    pthread_mutex_lock(&qemu.lock);
    frame = qemu.frame;
    pthread_mutex_unlock(&qemu.lock);
    if (frame != NULL && pixels != NULL) {
        frame(pixels, width, height, stride);
    }
}

bool AppleDeckQemuAvailable(char *reason, size_t reason_len) {
    pthread_once(&once, load);
    if (reason != NULL && reason_len > 0) {
        snprintf(reason, reason_len, "%s", unavailable);
    }
    return qemu.init != NULL && qemu.main_loop != NULL && qemu.send_abs != NULL
        && qemu.set_frame_callback != NULL;
}

/* The QEMU argv for the guest, kept here rather than in Swift because it is the
   same list on every platform the guest is booted from, and a typo in an
   option is a guest that never boots rather than an error worth reading. */
static char **build_argv(const AppleDeckQemuConfig *config, int *out_argc) {
    static char memory[32], kernel[1024], initrd[1024], bios[1024], cmdline[2048];
    static char drive[4352], display[64];
    static char *argv[64];
    int n = 0;

    snprintf(memory, sizeof(memory), "%dM", config->memory_mb > 0 ? config->memory_mb : 4096);
    snprintf(cmdline, sizeof(cmdline), "console=ttyAMA0 root=/dev/vda rw rootfstype=ext4 %s",
             config->cmdline == NULL ? "" : config->cmdline);
    snprintf(drive, sizeof(drive), "file=%s,if=none,id=hd0,format=raw,snapshot=on",
             config->disk == NULL ? "" : config->disk);
    snprintf(display, sizeof(display), "%dx%d", config->width, config->height);

    argv[n++] = (char *)"qemu-system-aarch64";
    argv[n++] = (char *)"-machine";
    argv[n++] = (char *)"virt";
    argv[n++] = (char *)"-cpu";
    argv[n++] = (char *)"max";
    argv[n++] = (char *)"-accel";
    argv[n++] = (char *)"tcg";
    /* MMTTCG: one guest vCPU per host thread. On a phone this is the second
       largest decision after TCG itself. */
    if (config->smp > 1) {
        argv[n++] = (char *)"-smp";
        argv[n++] = config->smp >= 4 ? (char *)"4" : (char *)"2";
    }
    argv[n++] = (char *)"-m";
    argv[n++] = memory;
    if (config->bios != NULL) {
        snprintf(bios, sizeof(bios), "%s", config->bios);
        argv[n++] = (char *)"-bios";
        argv[n++] = bios;
    }
    if (config->kernel != NULL) {
        snprintf(kernel, sizeof(kernel), "%s", config->kernel);
        argv[n++] = (char *)"-kernel";
        argv[n++] = kernel;
    }
    if (config->initrd != NULL) {
        snprintf(initrd, sizeof(initrd), "%s", config->initrd);
        argv[n++] = (char *)"-initrd";
        argv[n++] = initrd;
    }
    if (config->disk != NULL) {
        argv[n++] = (char *)"-drive";
        argv[n++] = drive;
        argv[n++] = (char *)"-device";
        argv[n++] = (char *)"virtio-blk-device,drive=hd0";
    }
    argv[n++] = (char *)"-append";
    argv[n++] = cmdline;

    /* One virtio-gpu with a scanout: the guest's Wayland clients (MangoApp, the
       desktop, and whatever Steam draws into) render into it, and QEMU hands
       each changed rectangle to the display listener the presenter installed.
       virtio-tablet is the absolute pointer, which is what makes touch land
       where the finger is with no pointer capture to solve. */
argv[n++] = (char *)"-device";
    argv[n++] = (char *)"virtio-gpu-pci";
    argv[n++] = (char *)"-device";
    argv[n++] = (char *)"virtio-tablet-pci";
    argv[n++] = (char *)"-device";
    argv[n++] = (char *)"virtio-keyboard-pci";
    /* Audio is not a QEMU audio backend: iOS has no backend for one, so the
       guest's PulseAudio talks to the relay in ios/AppleDeck/Audio over the
       socket the runtime already ships, and this device stays silent on
       purpose. */
    argv[n++] = (char *)"-audiodev";
    argv[n++] = (char *)"none,id=snd0";
    argv[n++] = (char *)"-display";
    argv[n++] = display;
    argv[n] = NULL;

    *out_argc = n;
    return argv;
}

struct start_args {
    AppleDeckQemuConfig config;
};

static void *loop_thread(void *pointer) {
    struct start_args *args = pointer;
    int argc = 0;
    char **argv = build_argv(&args->config, &argc);
    qemu.init(argc, argv);
    pthread_mutex_lock(&qemu.lock);
    qemu.running = true;
    qemu.have_loop = true;
    pthread_mutex_unlock(&qemu.lock);
    qemu.main_loop();
    pthread_mutex_lock(&qemu.lock);
    qemu.running = false;
    qemu.have_loop = false;
    pthread_mutex_unlock(&qemu.lock);
    free(args);
    return NULL;
}

int AppleDeckQemuStart(const AppleDeckQemuConfig *config) {
    pthread_once(&once, load);
    if (qemu.init == NULL || qemu.main_loop == NULL) {
        return -1;
    }
    pthread_mutex_lock(&qemu.lock);
    if (qemu.running) {
        pthread_mutex_unlock(&qemu.lock);
        return -2;
    }
    pthread_mutex_unlock(&qemu.lock);

    struct start_args *args = calloc(1, sizeof(*args));
    if (args == NULL) {
        return -3;
    }
    args->config = *config;
    if (pthread_create(&qemu.loop, NULL, loop_thread, args) != 0) {
        free(args);
        return -3;
    }
    pthread_mutex_lock(&qemu.lock);
    qemu.have_loop = true;
    pthread_mutex_unlock(&qemu.lock);
    return 0;
}

void AppleDeckQemuStop(void) {
    pthread_once(&once, load);
    pthread_mutex_lock(&qemu.lock);
    qemu.running = false;
    pthread_mutex_unlock(&qemu.lock);
    if (qemu.cleanup != NULL) {
        qemu.cleanup();
    }
    /* The machine's main loop returns on its own once the guest is gone.
       Joining it here is what keeps a stopped session from leaving a thread
       writing into a presenter that has been torn down. */
    if (qemu.have_loop) {
        pthread_join(qemu.loop, NULL);
        qemu.have_loop = false;
    }
}

bool AppleDeckQemuRunning(void) {
    pthread_once(&once, load);
    pthread_mutex_lock(&qemu.lock);
    bool running = qemu.running;
    pthread_mutex_unlock(&qemu.lock);
    return running;
}

void AppleDeckQemuSendEvent(int type, int code, int a, int b, int c) {
    pthread_once(&once, load);
    pthread_mutex_lock(&qemu.lock);
    bool ready = qemu.running;
    pthread_mutex_unlock(&qemu.lock);

    if (!ready) {
        pthread_mutex_lock(&qemu.lock);
        dropped_events++;
        pthread_mutex_unlock(&qemu.lock);
        return;
    }
    /* axis codes are QEMU's: 0 x, 1 y. Buttons are virtio's: 0 left, 1 right,
       2 middle, 3 side, 4 extra. Keycodes are Linux evdev codes, which is what
       the guest's input stack expects from a virtio-keyboard. */
    switch (type) {
    case 1: if (qemu.send_key != NULL) qemu.send_key(code, 1); break;
    case 2: if (qemu.send_key != NULL) qemu.send_key(code, 0); break;
    case 3: if (qemu.send_abs != NULL) qemu.send_abs(a, b); break;
    case 4: if (qemu.send_btn != NULL) qemu.send_btn(a, 1); break;
    case 5: if (qemu.send_btn != NULL) qemu.send_btn(a, 0); break;
    case 6: if (qemu.send_abs != NULL) qemu.send_abs(a, b); break;
    case 7: if (qemu.send_abs != NULL) qemu.send_abs(a, b); break;
    case 8: if (qemu.send_abs != NULL) qemu.send_abs(0, 0); break;
    default: break;
    }
    (void)c;
}

unsigned long AppleDeckQemuDroppedEvents(void) {
    pthread_once(&once, load);
    pthread_mutex_lock(&qemu.lock);
    unsigned long count = dropped_events;
    pthread_mutex_unlock(&qemu.lock);
    return count;
}