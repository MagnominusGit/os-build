#!/usr/bin/env bash
# retroforge read-only root assembler — stages `gptk-interpose`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed.
#
# Runs on EVERY build, release included.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs).

# STAGE gptk-interpose — /usr/lib/retroforge/portmaster/libretroforge-gptk-interpose.so, preloaded into
# PortMaster's gptokeyb2 in place of its own libinterpose (mod_RetroForge.txt): it reports the pad's
# event node, so `exclusive = true` really hides the pad from the game (apps/retroforge-gptk-interpose).
#
# Built by `make gptk-interpose` (a $(ROOTFS) prerequisite). Missing means a stale invocation
# bypassed make; fail rather than assemble an image where gptokeyb2 ports read the pad twice.
gptk_lib="$ROOT/apps/retroforge-gptk-interpose/build/libretroforge-gptk-interpose.so"
[ -s "$gptk_lib" ] || {
  echo "gptk interposer missing: ${gptk_lib#"$ROOT"/} (run: make gptk-interpose)" >&2
  exit 1
}
echo "  injecting gptk interposer -> /usr/lib/retroforge/portmaster/libretroforge-gptk-interpose.so"
install -D -m 0644 "$gptk_lib" "$stage/usr/lib/retroforge/portmaster/libretroforge-gptk-interpose.so"
unset gptk_lib
