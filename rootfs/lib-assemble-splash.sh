#!/usr/bin/env bash
# qforge read-only root assembler — stages `boot-splash`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed (tests/test-mkroot.sh reads the
# `# STAGE <name>` banners out of this file set, and asserts the roster it was audited against).
#
# Runs on EVERY build, release included; it only has to precede debug-capture.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs).

# STAGE boot-splash — the drawer (was 4c-4): the SAME binary and asset the initramfs carries, installed into the
# sealed root as well. Both copies are needed and neither is redundant: the initramfs one paints
# from before root is mounted until the session takes the display, and this one paints the
# shutdown and reboot screens, long after the initramfs has been freed.
#
# Built by `make splash` (a $(ROOTFS) prerequisite via $(INITRAMFS)). Missing means a stale
# invocation bypassed make; fail rather than assemble an image whose shutdown screen is black.
splash_bin="$ROOT/apps/qforge-splash/build/qforge-splash"
splash_asset="$ROOT/work/splash/logo.nds1"
splash_font="$stage/usr/share/fonts/noto/NotoSansMono-Medium.ttf"
[ -s "$splash_bin" ] && [ -s "$splash_asset" ] || {
  echo "splash payload missing: ${splash_bin#"$ROOT"/} / ${splash_asset#"$ROOT"/} (run: make splash)" >&2
  exit 1
}
[ -s "$splash_font" ] || {
  echo "splash font missing from the base: ${splash_font#"$stage"/} — the status line needs it" >&2
  exit 1
}
echo "  injecting boot splash -> /usr/lib/qforge/qforge-splash"
install -D -m 0755 "$splash_bin" "$stage/usr/lib/qforge/qforge-splash"
install -D -m 0644 "$splash_asset" "$stage/usr/share/qforge/splash/logo.nds1"
# A symlink, not a copy: the font is already in the image and it is 600 KB. The initramfs copy
# has to be a real file (there is no /usr/share/fonts there), but this one does not.
install -d -m 0755 "$stage/usr/share/qforge/splash"
ln -sfn ../../fonts/noto/NotoSansMono-Medium.ttf "$stage/usr/share/qforge/splash/font.ttf"
unset splash_bin splash_asset splash_font
