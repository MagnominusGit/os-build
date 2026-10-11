// qforge-gptk-interpose — LD_PRELOAD library for PortMaster's gptokeyb2, in place of its own
// libinterpose.
//
// gptokeyb2 grabs the pad (EVIOCGRAB, a .gptk's `exclusive = true`) so the game sees only the keys
// and mouse it emulates. To find the pad's file descriptor it asks the preloaded library for
// interpose_get_fd() right after SDL_GameControllerOpen(); PortMaster's libinterpose answers with
// the last descriptor ANY open() returned. The image's SDL2 is sdl2-compat over SDL3, which opens
// more files after the pad's event node, so gptokeyb2 grabbed the wrong descriptor and the game
// kept reading the pad too: Shattered Pixel Dungeon's own right-stick pointer moved on top of
// gptokeyb2's mouse ("way too sensitive"), HW Pocket ACE 2026-10-11 (fd 16 reported, event9 on 13).
//
// Here only /dev/input/event* opens are recorded, and interpose_get_fd() answers with the newest
// one still open on an event node (a probe that opened and closed a node does not count).

#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef EVENT_PREFIX  // tests/test-portmaster.sh builds a host copy on a temp folder's files
#define EVENT_PREFIX "/dev/input/event"
#endif
#define RECENT 16

static int recent[RECENT];
static int recent_count;
static pthread_mutex_t recent_lock = PTHREAD_MUTEX_INITIALIZER;

static int is_event_path(const char *path)
{
    return path && strncmp(path, EVENT_PREFIX, sizeof(EVENT_PREFIX) - 1) == 0;
}

static void record(const char *path, int fd)
{
    if (fd < 0 || !is_event_path(path))
        return;
    pthread_mutex_lock(&recent_lock);
    if (recent_count == RECENT) {
        memmove(recent, recent + 1, (RECENT - 1) * sizeof(int));
        recent_count--;
    }
    recent[recent_count++] = fd;
    pthread_mutex_unlock(&recent_lock);
}

// Is fd still open on an event node (not closed, not reused for something else)?
static int still_event(int fd)
{
    char link[64], target[PATH_MAX];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(link, target, sizeof(target) - 1);
    if (n <= 0)
        return 0;
    target[n] = '\0';
    return is_event_path(target);
}

int interpose_get_fd(void)
{
    int fd = -1;
    pthread_mutex_lock(&recent_lock);
    for (int i = recent_count - 1; i >= 0 && fd < 0; i--)
        if (still_event(recent[i]))
            fd = recent[i];
    pthread_mutex_unlock(&recent_lock);
    return fd;
}

static mode_t mode_arg(int flags, va_list args)
{
    return (flags & (O_CREAT | O_TMPFILE)) ? (mode_t)va_arg(args, int) : 0;
}

#define NEXT(name) static __typeof__(name) *next; if (!next) next = (__typeof__(name) *)dlsym(RTLD_NEXT, #name)

int open(const char *path, int flags, ...)
{
    NEXT(open);
    va_list args; va_start(args, flags); mode_t mode = mode_arg(flags, args); va_end(args);
    int fd = next(path, flags, mode);
    record(path, fd);
    return fd;
}

int open64(const char *path, int flags, ...)
{
    NEXT(open64);
    va_list args; va_start(args, flags); mode_t mode = mode_arg(flags, args); va_end(args);
    int fd = next(path, flags, mode);
    record(path, fd);
    return fd;
}

int openat(int dirfd, const char *path, int flags, ...)
{
    NEXT(openat);
    va_list args; va_start(args, flags); mode_t mode = mode_arg(flags, args); va_end(args);
    int fd = next(dirfd, path, flags, mode);
    record(path, fd);
    return fd;
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    NEXT(openat64);
    va_list args; va_start(args, flags); mode_t mode = mode_arg(flags, args); va_end(args);
    int fd = next(dirfd, path, flags, mode);
    record(path, fd);
    return fd;
}
