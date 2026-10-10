#!/usr/bin/env bash
# Offline check for the LD_PRELOAD shim apps/qforge-sigdefer (Snes9x's Exit crash).
#
#   tests/test-sigdefer.sh
#
# Builds the shim for the host and runs small GLib programs that install a SIGTERM / SIGINT handler
# the way Snes9x does (sigaction, plain sa_handler); the test then signals them from outside while
# their main loop sits idle in poll, as OpenGamepadUI's Exit does. The handler records g_main_depth(): 0 when it runs inside the signal (what crashes Snes9x),
# 1 or more when the main loop dispatched it. The same program without the shim is the control.
#
# What it cannot tell you: that Snes9x's own S9xExit is clean from the main loop (HW), or that the
# AppImage's bundled loader honours LD_PRELOAD (HW). The aarch64 build's glibc floor is checked by
# the shim's Makefile.
#
# Runs on the host, no root. Needs a C compiler and the glib-2.0 development files.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/apps/qforge-sigdefer/build/libqforge-sigdefer.host.so"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

if ! pkg-config --exists glib-2.0; then
  echo "test-sigdefer.sh: SKIP (no glib-2.0 development files)"
  exit 0
fi
make -s -C "$ROOT/apps/qforge-sigdefer" host >/dev/null || { echo "test-sigdefer.sh: shim does not build"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

cat > "$T/prog.c" <<'EOF'
#define _GNU_SOURCE
#include <glib.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static void handler(int sig)
{
    // Not async-signal-safe on purpose: it is what Snes9x does, and the test only reads the result.
    printf("handled sig=%d depth=%d\n", sig, g_main_depth());
    fflush(stdout);
    _exit(0);
}

static void other(int sig) { (void)sig; }

int main(void)
{
    struct sigaction sa = {0};
    sa.sa_handler = handler;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    // Left alone by the shim: SIGQUIT (GLib cannot watch it) and SIG_IGN.
    struct sigaction q = {0}, got = {0};
    q.sa_handler = other;
    sigaction(SIGQUIT, &q, NULL);
    sigaction(SIGQUIT, NULL, &got);
    printf("sigquit %s\n", got.sa_handler == other ? "kept" : "replaced");
    struct sigaction ign = {0};
    ign.sa_handler = SIG_IGN;
    sigaction(SIGUSR1, &ign, NULL);
    sigaction(SIGUSR1, NULL, &got);
    printf("sigusr1 %s\n", got.sa_handler == SIG_IGN ? "ignored" : "changed");
    fflush(stdout);
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(3000, (GSourceFunc)g_main_loop_quit, loop);
    g_main_loop_run(loop);
    printf("not handled\n");
    return 1;
}
EOF
# shellcheck disable=SC2046
cc -O1 -o "$T/prog" "$T/prog.c" $(pkg-config --cflags --libs glib-2.0) || { echo "test program does not build"; exit 1; }

depth() { sed -n 's/^handled sig=[0-9]* depth=\([0-9]*\)$/\1/p' "$1"; }

# Start the program, let it reach its idle main loop, then signal it.
signal_run() { # <signal> <out> [env...]
  local sig="$1" out="$2"; shift 2
  env "$@" "$T/prog" > "$out" 2>&1 & local pid=$!
  for _ in $(seq 50); do grep -q '^sigusr1' "$out" 2>/dev/null && break; sleep 0.02; done
  sleep 0.2; kill -s "$sig" "$pid"; wait "$pid"
}

for sig in term int; do
  signal_run "${sig^^}" "$T/plain.$sig"
  [ "$(depth "$T/plain.$sig")" = 0 ] && ok "control: without the shim the SIG${sig^^} handler runs inside the signal (depth 0)" \
    || bad "control ($sig): $(cat "$T/plain.$sig")"
  signal_run "${sig^^}" "$T/shim.$sig" LD_PRELOAD="$SHIM"
  d="$(depth "$T/shim.$sig")"
  [ -n "$d" ] && [ "$d" -ge 1 ] && ok "with the shim the SIG${sig^^} handler runs from the main loop (depth $d)" \
    || bad "shim ($sig): $(cat "$T/shim.$sig")"
done
grep -qx "sigquit kept" "$T/shim.term" && ok "SIGQUIT's handler is installed as asked (GLib cannot watch it)" \
  || bad "SIGQUIT: $(cat "$T/shim.term")"
grep -qx "sigusr1 ignored" "$T/shim.term" && ok "SIG_IGN still reaches the real sigaction" \
  || bad "SIG_IGN: $(cat "$T/shim.term")"

# A program that never loads GLib keeps its handler as it is (nothing to defer to).
cat > "$T/noglib.c" <<'EOF'
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
static void handler(int sig) { printf("handled sig=%d\n", sig); fflush(stdout); _exit(0); }
int main(void)
{
    struct sigaction sa = {0};
    sa.sa_handler = handler;
    sigaction(SIGTERM, &sa, NULL);
    kill(getpid(), SIGTERM);
    sleep(3);
    printf("not handled\n");
    return 1;
}
EOF
cc -O1 -o "$T/noglib" "$T/noglib.c" || { echo "test program does not build"; exit 1; }
LD_PRELOAD="$SHIM" "$T/noglib" > "$T/noglib.out" 2>&1
grep -qx "handled sig=15" "$T/noglib.out" && ok "without GLib loaded the handler is installed as asked" \
  || bad "no GLib: $(cat "$T/noglib.out")"

echo "test-sigdefer.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
