#!/usr/bin/env bash
# retroforge read-only root assembler — stages `sigdefer-shim`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed.
#
# Runs on EVERY build, release included.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs).

# STAGE sigdefer-shim — /usr/lib/retroforge/libretroforge-sigdefer.so, the LD_PRELOAD shim Snes9x's
# emulator.json names: it moves Snes9x's SIGTERM handler (its whole exit) onto the GLib main loop,
# where OpenGamepadUI's Exit no longer crashes it (apps/retroforge-sigdefer).
#
# Built by `make sigdefer` (a $(ROOTFS) prerequisite). Missing means a stale invocation bypassed
# make; fail rather than assemble an image whose Snes9x crashes on every Exit.
sigdefer_lib="$ROOT/apps/retroforge-sigdefer/build/libretroforge-sigdefer.so"
[ -s "$sigdefer_lib" ] || {
  echo "sigdefer shim missing: ${sigdefer_lib#"$ROOT"/} (run: make sigdefer)" >&2
  exit 1
}
echo "  injecting sigdefer shim -> /usr/lib/retroforge/libretroforge-sigdefer.so"
install -D -m 0644 "$sigdefer_lib" "$stage/usr/lib/retroforge/libretroforge-sigdefer.so"
unset sigdefer_lib
