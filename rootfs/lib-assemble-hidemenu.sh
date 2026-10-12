#!/usr/bin/env bash
# retroforge read-only root assembler — stages `hidemenu-shim`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed (tests/test-mkroot.sh reads the
# `# STAGE <name>` banners out of this file set, and asserts the roster it was audited against).
#
# Runs on EVERY build, release included.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs).

# STAGE hidemenu-shim — /usr/lib/retroforge/libretroforge-hidemenu.so, the LD_PRELOAD shim melonDS's
# emulator.json names: every melonDS window after the first gets a zero-height menu bar, so its
# second window shows only the DS bottom screen on a dual-screen board's second panel
# (apps/retroforge-hidemenu).
#
# Built by `make hidemenu` (a $(ROOTFS) prerequisite). Missing means a stale invocation bypassed
# make; fail rather than assemble an image whose melonDS definition preloads a missing library.
hidemenu_lib="$ROOT/apps/retroforge-hidemenu/build/libretroforge-hidemenu.so"
[ -s "$hidemenu_lib" ] || {
  echo "hidemenu shim missing: ${hidemenu_lib#"$ROOT"/} (run: make hidemenu)" >&2
  exit 1
}
echo "  injecting hidemenu shim -> /usr/lib/retroforge/libretroforge-hidemenu.so"
install -D -m 0644 "$hidemenu_lib" "$stage/usr/lib/retroforge/libretroforge-hidemenu.so"
unset hidemenu_lib
