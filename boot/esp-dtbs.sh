#!/usr/bin/env bash
# retroforge: the DTBs OpenABL lists for its Device model menu, for the shared ESP's \dtbs\qcom.
#
#   boot/esp-dtbs.sh <outdir> <dtb>...
#
# OpenABL builds its Device model list from the root `model` of the .dtb files on the boot drive,
# and installs the chosen one before it starts the ESP GRUB, which reads that model back
# (retroforge_dt_model) and boots the slot's OWN DTB for it. So these copies are never booted:
# what they carry is the name. They are the real DTBs, so OpenABL also finds everything else it
# reads from one (the panel rotation its menu follows, the compatible), plus one addition where a
# tree lacks it:
#
# A SPLASH REGION. OpenABL 1.2 keeps the display on at ExitBootServices only when the tree it
# installed has /reserved-memory/splash_region (or cont_splash_region), and powers the display
# down otherwise (Efi/DisplayHandover.c). The tree it installs is this copy, so without the node the
# panel would go dark at the hand-over on every board whose own tree has none. reg is all zeros,
# the <0 addr 0 size> placeholder OpenABL points at its framebuffer.
#
# Runs in the build image (device-tree-compiler provides fdtget/fdtput).
set -euo pipefail

OUTDIR="${1:-}"
[ -n "$OUTDIR" ] && [ $# -gt 1 ] || { echo "usage: boot/esp-dtbs.sh <outdir> <dtb>..." >&2; exit 2; }
shift
for t in fdtget fdtput; do
  command -v "$t" >/dev/null || { echo "esp-dtbs: $t is missing (device-tree-compiler)" >&2; exit 1; }
done

mkdir -p "$OUTDIR"
for src in "$@"; do
  name="$(basename "$src")"
  dst="$OUTDIR/$name"
  cp -f "$src" "$dst"
  fdtget -t s "$dst" / model >/dev/null 2>&1 \
    || { echo "esp-dtbs: $name has no root model, so OpenABL could not list it" >&2; exit 1; }
  if ! fdtget -l "$dst" /reserved-memory >/dev/null 2>&1; then
    fdtput -c "$dst" /reserved-memory
    fdtput -t i "$dst" /reserved-memory '#address-cells' 2
    fdtput -t i "$dst" /reserved-memory '#size-cells' 2
  fi
  if ! fdtget -l "$dst" /reserved-memory | grep -Eq '^(cont_)?splash_region(@|$)'; then
    ac="$(fdtget -t i "$dst" /reserved-memory '#address-cells' 2>/dev/null || echo 2)"
    sc="$(fdtget -t i "$dst" /reserved-memory '#size-cells' 2>/dev/null || echo 2)"
    fdtput -c "$dst" /reserved-memory/splash_region
    # shellcheck disable=SC2046  # one zero per cell is the point
    fdtput -t i "$dst" /reserved-memory/splash_region reg $(printf '0 %.0s' $(seq 1 $((ac + sc))))
  fi
done
echo "  ok   $# ESP DTBs -> $OUTDIR"
