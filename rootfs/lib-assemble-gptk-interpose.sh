#!/usr/bin/env bash
# qforge read-only root assembler — stages `gptk-interpose`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed (tests/test-mkroot.sh reads the
# `# STAGE <name>` banners out of this file set, and asserts the roster it was audited against).
#
# Runs on EVERY build, release included.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs).

# STAGE gptk-interpose — /usr/lib/qforge/portmaster/libqforge-gptk-interpose.so, preloaded into
# PortMaster's gptokeyb2 in place of its own libinterpose (mod_QForge.txt): it reports the pad's
# event node, so `exclusive = true` really hides the pad from the game (apps/qforge-gptk-interpose).
#
# Built by `make gptk-interpose` (a $(ROOTFS) prerequisite). Missing means a stale invocation
# bypassed make; fail rather than assemble an image where gptokeyb2 ports read the pad twice.
gptk_lib="$ROOT/apps/qforge-gptk-interpose/build/libqforge-gptk-interpose.so"
[ -s "$gptk_lib" ] || {
  echo "gptk interposer missing: ${gptk_lib#"$ROOT"/} (run: make gptk-interpose)" >&2
  exit 1
}
echo "  injecting gptk interposer -> /usr/lib/qforge/portmaster/libqforge-gptk-interpose.so"
install -D -m 0644 "$gptk_lib" "$stage/usr/lib/qforge/portmaster/libqforge-gptk-interpose.so"
unset gptk_lib
