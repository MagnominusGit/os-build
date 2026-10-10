#!/usr/bin/env bash
# qforge read-only root assembler — stages `sigdefer-shim`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed (tests/test-mkroot.sh reads the
# `# STAGE <name>` banners out of this file set, and asserts the roster it was audited against).
#
# Runs on EVERY build, release included.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs).

# STAGE sigdefer-shim — /usr/lib/qforge/libqforge-sigdefer.so, the LD_PRELOAD shim Snes9x's
# emulator.json names: it moves Snes9x's SIGTERM handler (its whole exit) onto the GLib main loop,
# where OpenGamepadUI's Exit no longer crashes it (apps/qforge-sigdefer).
#
# Built by `make sigdefer` (a $(ROOTFS) prerequisite). Missing means a stale invocation bypassed
# make; fail rather than assemble an image whose Snes9x crashes on every Exit.
sigdefer_lib="$ROOT/apps/qforge-sigdefer/build/libqforge-sigdefer.so"
[ -s "$sigdefer_lib" ] || {
  echo "sigdefer shim missing: ${sigdefer_lib#"$ROOT"/} (run: make sigdefer)" >&2
  exit 1
}
echo "  injecting sigdefer shim -> /usr/lib/qforge/libqforge-sigdefer.so"
install -D -m 0644 "$sigdefer_lib" "$stage/usr/lib/qforge/libqforge-sigdefer.so"
unset sigdefer_lib
