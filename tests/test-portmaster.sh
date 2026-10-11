#!/usr/bin/env bash
# Offline test for QForge's PortMaster glue: the `mount` / `umount` stand-ins ports find first on
# their PATH (/usr/lib/qforge/portmaster/bin) and the hook files every port sources
# (mod_QForge.txt, libgl_QForge.txt).
#
#   tests/test-portmaster.sh
#
# WHY THIS EXISTS. Ports run as the player, with no sudo (plan Phase 4b, PortMaster, user decision
# 2026-10-11), yet ~300 of them mount a squashfs runtime (Godot, Weston, mono ...) with
# `$ESUDO mount <file> <dir>` and unmount it by either path. Without the stand-ins those ports die
# at their first line of setup; with a careless one, `mount --bind` over a player's folder would
# replace their data with a symlink. Each rule below is one of those cases:
#
#   - mount <file> <dir> runs squashfuse and records the mount; a mount left on <dir> (a crashed
#     port) is released first;
#   - umount takes the mount point OR the squashfs file, and says "not mounted" (exit 32) like the
#     real one when there is nothing;
#   - mount --bind becomes a symlink, and only over nothing / a symlink / an empty folder or file;
#   - anything else goes to the real mount / umount;
#   - mod_QForge.txt puts the stand-ins first on PATH (once), and Godot runs full screen at the
#     panel size; libgl_QForge.txt never selects gl4es's KMS output (LIBGL_FB=4).
#
# HOW: the shipped scripts run with their seams (QFORGE_MOUNTS, QFORGE_SQUASHFUSE,
# QFORGE_FUSERMOUNT, QFORGE_REAL_MOUNT, QFORGE_REAL_UMOUNT, XDG_RUNTIME_DIR) pointing into a
# sandbox; squashfuse and fusermount are stubs that edit a fake mount table. No FUSE, no root.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/rootfs/overlay/usr/lib/qforge/portmaster/bin"
PM_DATA="$ROOT/rootfs/overlay/usr/share/qforge/emulators/portmaster"
for f in "$BIN/mount" "$BIN/umount" "$PM_DATA/mod_QForge.txt" "$PM_DATA/libgl_QForge.txt"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/run" "$T/libs"
# squashfuse <file> <dir>: "mounts" by adding a row to the fake table; fails for a file named bad.*.
cat > "$T/stub/squashfuse" <<EOF
#!/bin/bash
echo "squashfuse \$*" >> "$T/calls"
case \$(basename "\$1") in bad.*) exit 1 ;; esac
echo "squashfuse \$(printf '%s' "\$2" | sed 's/ /\\\\040/g') fuse.squashfuse ro,nosuid,nodev 0 0" >> "$T/mounts"
EOF
# fusermount -u [-z] <dir>: drops the row.
cat > "$T/stub/fusermount" <<EOF
#!/bin/bash
echo "fusermount \$*" >> "$T/calls"
m="\${!#}"; m="\$(printf '%s' "\$m" | sed 's/ /\\\\040/g')"
awk -v m="\$m" '\$2 != m' "$T/mounts" > "$T/mounts.new" && mv "$T/mounts.new" "$T/mounts"
EOF
printf '#!/bin/bash\necho "real-mount $*" >> "%s/calls"\n' "$T" > "$T/stub/real-mount"
printf '#!/bin/bash\necho "real-umount $*" >> "%s/calls"\n' "$T" > "$T/stub/real-umount"
chmod +x "$T/stub/"*
export QFORGE_MOUNTS="$T/mounts" QFORGE_SQUASHFUSE="$T/stub/squashfuse" QFORGE_FUSERMOUNT="$T/stub/fusermount"
export QFORGE_REAL_MOUNT="$T/stub/real-mount" QFORGE_REAL_UMOUNT="$T/stub/real-umount" XDG_RUNTIME_DIR="$T/run"
REG="$T/run/qforge-portmaster-mounts"
reset() { : > "$T/mounts"; : > "$T/calls"; rm -f "$REG"; }
is_mounted() { awk -v p="$1" '{ gsub(/\\040/, " ", $2) } $2 == p {f=1} END {exit !f}' "$T/mounts"; }
GODOT="$T/libs/frt_3.5.2.squashfs"; : > "$GODOT"
WESTON="$T/libs/weston_pkg_0.2.squashfs"; : > "$WESTON"

# =================================================================================================
CASE="mount a runtime"
reset
"$BIN/mount" "$GODOT" "$T/home/godot"; rc=$?
[ "$rc" = 0 ] && is_mounted "$T/home/godot" && ok "mount <file> <dir>: squashfuse mounts it, exit 0" || bad "rc=$rc calls: $(cat "$T/calls")"
[ -d "$T/home/godot" ] && ok "creates the mount point" || bad "no mount point"
grep -qxF "$T/home/godot	$GODOT" "$REG" && ok "recorded in the registry (mount point TAB file)" || bad "registry: $(cat "$REG" 2>/dev/null)"
"$BIN/mount" "$GODOT" "$T/home/godot"
grep -qx "fusermount -u -z $T/home/godot" "$T/calls" && [ "$(grep -c "^squashfuse $T/home/godot " "$T/mounts")" = 1 ] \
  && ok "mounting again over a left mount releases it first (a port that crashed)" || bad "calls: $(cat "$T/calls" | tr '\n' '|')"
"$BIN/mount" "$WESTON" "$T/tmp dir/weston"
is_mounted "$T/tmp dir/weston" && ok "a mount point with a space" || bad "space path not mounted: $(cat "$T/mounts")"
bad_sq="$T/libs/bad.squashfs"; : > "$bad_sq"
"$BIN/mount" "$bad_sq" "$T/home/bad" 2>/dev/null; rc=$?
[ "$rc" = 32 ] && ! grep -q "home/bad" "$REG" && ok "squashfuse fails: exit 32, nothing recorded" || bad "rc=$rc"

CASE="umount"
"$BIN/umount" "$T/home/godot"; rc=$?
[ "$rc" = 0 ] && ! is_mounted "$T/home/godot" && grep -qx "fusermount -u $T/home/godot" "$T/calls" \
  && ok "umount <dir>: fusermount -u, exit 0" || bad "rc=$rc calls: $(tail -2 "$T/calls" | tr '\n' '|')"
! grep -q "home/godot" "$REG" && ok "... and forgotten in the registry" || bad "registry: $(cat "$REG")"
"$BIN/umount" "$T/home/godot" 2>"$T/err"; rc=$?
[ "$rc" = 32 ] && grep -q "not mounted" "$T/err" && ok "umount of what is not mounted: exit 32, 'not mounted' (ports add || true)" || bad "rc=$rc"
reset; "$BIN/mount" "$GODOT" "$T/home/godot"
"$BIN/umount" "$GODOT"; rc=$?
[ "$rc" = 0 ] && ! is_mounted "$T/home/godot" && ok "umount <file.squashfs> releases what that file is mounted on" || bad "umount by file: rc=$rc"
[ ! -s "$REG" ] && [ -z "$(ls "$T/run" | grep -v '^qforge-portmaster-mounts$')" ] \
  && ok "... the registry forgets its last row too, no temp file left" || bad "registry: $(cat "$REG") run: $(ls "$T/run")"
"$BIN/mount" "$WESTON" "$T/tmp dir/weston"
"$BIN/umount" -l "$T/tmp dir/weston"; rc=$?
[ "$rc" = 0 ] && grep -qx "fusermount -u -z $T/tmp dir/weston" "$T/calls" && ok "umount -l: lazy (fusermount -z)" || bad "calls: $(tail -1 "$T/calls")"

CASE="mount --bind (no root: a symlink, never over data)"
reset; mkdir -p "$T/game/savedata"; echo save > "$T/game/savedata/s1"
mkdir -p "$T/home/.config/Game"
"$BIN/mount" --bind "$T/game/savedata" "$T/home/.config/Game"; rc=$?
[ "$rc" = 0 ] && [ "$(readlink "$T/home/.config/Game")" = "$T/game/savedata" ] && [ -f "$T/home/.config/Game/s1" ] \
  && ok "over an empty folder: a symlink to the source" || bad "rc=$rc link=$(readlink "$T/home/.config/Game")"
"$BIN/mount" --bind "$T/game/savedata" "$T/home/.config/Game"; rc=$?
[ "$rc" = 0 ] && [ "$(readlink "$T/home/.config/Game")" = "$T/game/savedata" ] && ok "again over its own symlink" || bad "rc=$rc"
"$BIN/umount" "$T/home/.config/Game"; rc=$?
[ "$rc" = 0 ] && [ -L "$T/home/.config/Game" ] && ok "umount of the symlink: success, nothing to do" || bad "rc=$rc"
mkdir -p "$T/home/.local/share/Real"; echo keep > "$T/home/.local/share/Real/data"
"$BIN/mount" --bind "$T/game/savedata" "$T/home/.local/share/Real" 2>/dev/null; rc=$?
[ "$rc" = 32 ] && [ "$(cat "$T/home/.local/share/Real/data")" = keep ] && [ ! -L "$T/home/.local/share/Real" ] \
  && ok "over a folder holding data: refused (exit 32), the data is untouched" || bad "rc=$rc"
echo conf > "$T/home/game.cfg"; echo src > "$T/game/game.cfg"
"$BIN/mount" --bind "$T/game/game.cfg" "$T/home/game.cfg" 2>/dev/null; rc=$?
[ "$rc" = 32 ] && [ "$(cat "$T/home/game.cfg")" = conf ] && ok "over a file holding data: refused" || bad "rc=$rc"
: > "$T/home/empty.cfg"
"$BIN/mount" --bind "$T/game/game.cfg" "$T/home/empty.cfg"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/home/empty.cfg")" = src ] && ok "over an empty file (bind_files touches it first): a symlink" || bad "rc=$rc"
"$BIN/mount" --bind "$T/game/missing" "$T/home/x" 2>/dev/null; rc=$?
[ "$rc" = 32 ] && [ ! -e "$T/home/x" ] && ok "a missing source: exit 32, nothing created" || bad "rc=$rc"

CASE="everything else goes to the real tools"
reset
"$BIN/mount"; "$BIN/mount" -t tmpfs none "$T/x"; "$BIN/umount" -a
grep -qx "real-mount " "$T/calls" && grep -qx "real-mount -t tmpfs none $T/x" "$T/calls" && grep -qx "real-umount -a" "$T/calls" \
  && ok "bare mount, other options and umount -a pass through unchanged" || bad "calls: $(cat "$T/calls" | tr '\n' '|')"
"$BIN/mount" "$T/nonexistent.squashfs" "$T/home/n"
grep -qx "real-mount $T/nonexistent.squashfs $T/home/n" "$T/calls" && ! grep -q "^squashfuse" "$T/calls" \
  && ok "a source that is not a file is not ours: the real mount" || bad "calls: $(cat "$T/calls" | tr '\n' '|')"

# =================================================================================================
CASE="mod_QForge.txt"
out="$(env -i PATH=/usr/bin:/bin DISPLAY_WIDTH=1920 DISPLAY_HEIGHT=1080 bash -c '
  source "$1"; source "$1"
  echo "path=$PATH"; echo "godot=$GODOT_OPTS"; echo "godot2=$GODOT2_OPTS"
  echo "can_mount=${PM_CAN_MOUNT-unset}"; echo "helper=$(type -t pm_platform_helper)"' _ "$PM_DATA/mod_QForge.txt")"
grep -qx "path=/usr/lib/qforge/portmaster/bin:/usr/bin:/bin" <<<"$out" \
  && ok "puts the stand-ins first on PATH, once (sourced twice)" || bad "$(grep path= <<<"$out")"
grep -qx "godot=--resolution 1920x1080 -f" <<<"$out" && grep -qx "godot2=-r 1920x1080 -f" <<<"$out" \
  && ok "Godot 2 and 3+: full screen at the panel size" || bad "$(grep godot <<<"$out")"
grep -qx "can_mount=unset" <<<"$out" && ok "leaves PM_CAN_MOUNT to PortMaster (Y: ports unmount their runtimes)" || bad "$(grep can_mount <<<"$out")"
grep -qx "helper=function" <<<"$out" && ok "defines pm_platform_helper" || bad "no pm_platform_helper"
ctl() { env -i PATH=/usr/bin:/bin bash -c '
  get_controls() { sdl_controllerconfig="$(head -c "$1" /dev/zero | tr "\0" x)"; DEVICE=$2; }
  source "$1"; source "$1"; get_controls "$2" "$3"; echo "${#sdl_controllerconfig} $DEVICE"' _ "$PM_DATA/mod_QForge.txt" "$@"; }
[ "$(ctl 472286 "")" = "0 " ] \
  && ok "get_controls with no device GUID: the whole db is not exported (E2BIG on every exec), SDL reads the file" || bad "big: $(ctl 472286 "")"
[ "$(ctl 300 03000000)" = "300 03000000" ] && ok "a device's own mapping is kept, and get_controls' other results" || bad "small: $(ctl 300 03000000)"
QLIB=/usr/lib/qforge/portmaster/lib
ld() { env -i PATH=/usr/bin:/bin ${1+LD_LIBRARY_PATH="$1"} bash -c 'source "$1"; source "$1"; echo "$LD_LIBRARY_PATH"' _ "$PM_DATA/mod_QForge.txt"; }
[ "$(ld)" = "$QLIB" ] && [ "$(ld "")" = "$QLIB" ] && [ "$(ld /port/libs)" = "/port/libs:$QLIB" ] \
  && ok "appends QForge's compat libs to LD_LIBRARY_PATH, once, last (a port's own libs win)" || bad "unset=$(ld) empty=$(ld "") set=$(ld /port/libs)"
link="$ROOT/rootfs/overlay$QLIB/libtheoradec.so.1"
[ -L "$link" ] && [ "$(readlink "$link")" = /usr/lib/libtheoradec.so.2 ] \
  && ok "libtheoradec.so.1 (PortMaster's LÖVE runtime) -> the image's libtheoradec.so.2" || bad "link: $(readlink "$link")"

CASE="libgl_QForge.txt"
mkdir -p "$T/port/gl4es.aarch64" "$T/port/libs.aarch64" "$T/glx-yes" "$T/glx-no"
printf '#!/bin/sh\necho "OpenGL version string: 4.6 (Compatibility Profile) Mesa"\n' > "$T/glx-yes/glxinfo"
printf '#!/bin/sh\nexit 1\n' > "$T/glx-no/glxinfo"
chmod +x "$T/glx-yes/glxinfo" "$T/glx-no/glxinfo"
gl() { (cd "$T/port" && env -i PATH="$1:/usr/bin:/bin" DEVICE_ARCH=aarch64 LD_LIBRARY_PATH= bash -c '
  source "$1"; echo "es=${LIBGL_ES-} fb=${LIBGL_FB-unset} ld=$LD_LIBRARY_PATH"' _ "$PM_DATA/libgl_QForge.txt"); }
o="$(gl "$T/glx-yes")"
[[ $o == "es= fb=unset ld=$T/port/libs.aarch64:" ]] && ok "desktop GL found: no gl4es, the port's libs only" || bad "with GL: $o"
o="$(gl "$T/glx-no")"
[[ $o == "es=2 fb=unset ld=$T/port/libs.aarch64:$T/port/gl4es.aarch64:" ]] \
  && ok "no desktop GL: gl4es on X11, never LIBGL_FB=4 (KMS belongs to gamescope)" || bad "without GL: $o"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
