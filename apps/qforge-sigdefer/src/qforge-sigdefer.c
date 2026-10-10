// qforge-sigdefer — an LD_PRELOAD shim that runs a program's SIGTERM / SIGINT handler from its
// GLib main loop instead of inside the signal.
//
// WHY. Snes9x 1.63's GTK frontend (master too) installs S9xTerm for SIGTERM, SIGINT and SIGQUIT,
// and S9xTerm runs S9xExit: the config save, the sound and display teardown, the deletes and
// exit(0), all inside the signal handler while its other threads keep running. It crashes there
// on every OpenGamepadUI Exit (SIGSEGV / SIGABRT, HW 2026-10-06, Pocket ACE). Closing its window
// runs the same S9xExit from the main loop, and that is clean.
//
// HOW. sigaction() is interposed. When the program installs a plain handler for SIGTERM or SIGINT,
// the handler is handed to g_unix_signal_add() instead, so GLib's own (async-signal-safe) handler
// takes the signal and the program's handler runs on the next main-loop iteration, like a window
// close. Everything else goes to the real sigaction(): other signals, SIG_DFL / SIG_IGN, SA_SIGINFO
// handlers, and GLib's own calls made while we register (it installs its handler through the same
// function). SIGQUIT stays as it is: g_unix_signal_add() does not accept it, and nothing sends it.
//
// If the program has no GLib loaded when it installs the handler, nothing changes.
//
// Built for the image with the build container's cross toolchain (see the Makefile): it only
// references sigaction and dlsym, which every glibc the image or an AppImage bundles has.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdint.h>

typedef int (*sigaction_fn)(int, const struct sigaction *, struct sigaction *);
typedef unsigned int (*unix_signal_add_fn)(int, int (*)(void *), void *);

static void (*handlers[NSIG])(int);
static __thread int registering;

// A GSourceFunc: the program's handler, now on the main loop. It returns TRUE (keep the source)
// because a handler that does not exit may well be called again.
static int run_handler(void *data)
{
    int sig = (int)(intptr_t)data;
    handlers[sig](sig);
    return 1;
}

static int deferrable(int sig, const struct sigaction *act)
{
    return act && (sig == SIGTERM || sig == SIGINT) && !(act->sa_flags & SA_SIGINFO)
        && act->sa_handler != SIG_DFL && act->sa_handler != SIG_IGN;
}

int sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
    static sigaction_fn real;
    if (!real)
        real = (sigaction_fn)dlsym(RTLD_NEXT, "sigaction");

    unix_signal_add_fn add = NULL;
    if (!registering && deferrable(sig, act))
        add = (unix_signal_add_fn)dlsym(RTLD_DEFAULT, "g_unix_signal_add");
    if (!add)
        return real(sig, act, old);

    if (old && real(sig, NULL, old) != 0)
        return -1;
    int first = handlers[sig] == NULL;
    handlers[sig] = act->sa_handler;
    if (first) {
        registering = 1;
        add(sig, run_handler, (void *)(intptr_t)sig);
        registering = 0;
    }
    return 0;
}
