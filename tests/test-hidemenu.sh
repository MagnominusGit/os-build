#!/usr/bin/env bash
# Offline check for the LD_PRELOAD shim apps/retroforge-hidemenu (melonDS's second-window menu bar).
#
#   tests/test-hidemenu.sh
#
# Builds the shim for the host, a stand-in "Qt" library exporting the two methods it touches
# (QMainWindow::setMenuBar, QWidget::setFixedHeight) under their real mangled names, and a program
# that, like melonDS, hands three windows their menu bars through setMenuBar(). The stand-in records
# every call. With the shim, the real setMenuBar runs for all three and only the second and third
# bars are set to height 0; without it, no height is set (the control).
#
# What it cannot tell you: that melonDS's AppImage loads the shim (sharun needs
# SHARUN_ALLOW_LD_PRELOAD, see melonDS's emulator.json) or that a zero-height bar looks right (HW).
#
# Runs on the host, no root. Needs a C compiler.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/apps/retroforge-hidemenu/build/libretroforge-hidemenu.host.so"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

make -s -C "$ROOT/apps/retroforge-hidemenu" host >/dev/null || { echo "test-hidemenu.sh: shim does not build"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

cat > "$T/fakeqt.c" <<'EOF'
#include <stdio.h>
void _ZN11QMainWindow10setMenuBarEP8QMenuBar(void *win, void *bar) { printf("setMenuBar %p %p\n", win, bar); }
void _ZN7QWidget14setFixedHeightEi(void *w, int h) { printf("setFixedHeight %p %d\n", w, h); }
EOF
cat > "$T/prog.c" <<'EOF'
void _ZN11QMainWindow10setMenuBarEP8QMenuBar(void *win, void *bar);
int main(void)
{
    static char win[3], bar[3];
    for (int i = 0; i < 3; i++)
        _ZN11QMainWindow10setMenuBarEP8QMenuBar(&win[i], &bar[i]);
    return 0;
}
EOF
cc -shared -fPIC -o "$T/libfakeqt.so" "$T/fakeqt.c" || { echo "test-hidemenu.sh: stand-in does not build"; exit 1; }
cc -o "$T/prog" "$T/prog.c" -L"$T" -lfakeqt -Wl,-rpath,"$T" || { echo "test-hidemenu.sh: program does not build"; exit 1; }

with="$(LD_PRELOAD="$SHIM" "$T/prog")"
without="$("$T/prog")"

[ "$(grep -c '^setMenuBar ' <<<"$with")" = 3 ] \
  && ok "the real setMenuBar still runs for every window" \
  || bad "setMenuBar reached Qt $(grep -c '^setMenuBar ' <<<"$with") times, want 3"
bars=( $(awk '/^setMenuBar /{print $3}' <<<"$with") )
fixed=( $(awk '/^setFixedHeight /{print $2 ":" $3}' <<<"$with") )
[ "${fixed[*]}" = "${bars[1]}:0 ${bars[2]}:0" ] \
  && ok "the second and third menu bars get height 0, the first keeps its menu" \
  || bad "setFixedHeight calls were '${fixed[*]}', want '${bars[1]}:0 ${bars[2]}:0'"
grep -q '^setFixedHeight ' <<<"$without" \
  && bad "control: setFixedHeight was called without the shim" \
  || ok "control: without the shim no bar height is touched"

echo
echo "test-hidemenu.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
