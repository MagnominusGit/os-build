#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/install-steamcmd: how the session puts the image's arm64
# steamcmd where the OpenGamepadUI Steam plugin runs it from.
#
#   tests/test-steamcmd-install.sh
#
# WHY THIS EXISTS. The plugin runs ~/.steam/steamcmd/steamcmd.sh, and when that is missing it fetches
# Valve's x86 build, which cannot run here. The rules, each of which goes wrong silently:
#   - install when there is no working arm64 copy: none, an x86 one, or a half-written one;
#   - never touch a working arm64 copy (steamcmd has updated itself past the image's);
#   - steamcmd.sh is written LAST, so a failed copy never leaves a steamcmd.sh that makes the plugin
#     skip its download and run a binary that is not there;
#   - nothing else in the folder is touched (the plugin's game installs, an x86 linux32/);
#   - a missing image copy is an error, not an install.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/rootfs/overlay/usr/lib/retroforge/install-steamcmd"
[ -f "$TOOL" ] || { echo "no install-steamcmd: $TOOL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

mode()  { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
mtime() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1"; }

SRC="$T/image/usr/lib/retroforge/steamcmd"
DST="$T/home/.steam/steamcmd"
mkdir -p "$SRC/linuxarm64"
# The image's copy as packages/steamcmd/prebuilt.pin lays it out (Valve's tarball, strip 0).
printf '#!/usr/bin/env bash\n: "${STEAM_PLATFORM:=linuxarm64}"\n' >"$SRC/steamcmd.sh"
printf 'ELF arm64 steamcmd\n' >"$SRC/linuxarm64/steamcmd"
printf 'ELF arm64 crashhandler\n' >"$SRC/linuxarm64/crashhandler.so"
printf 'ELF arm64 steamerrorreporter\n' >"$SRC/linuxarm64/steamerrorreporter"
chmod 755 "$SRC/steamcmd.sh" "$SRC/linuxarm64/steamcmd" "$SRC/linuxarm64/steamerrorreporter"
chmod 644 "$SRC/linuxarm64/crashhandler.so"

run() {
  OUT="$(RETROFORGE_STEAMCMD_SRC="$SRC" RETROFORGE_STEAMCMD_DIR="$DST" python3 "$TOOL" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
same_tree() {  # every image file is in DST, byte-identical, same mode
  local f
  for f in steamcmd.sh linuxarm64/steamcmd linuxarm64/crashhandler.so linuxarm64/steamerrorreporter; do
    cmp -s "$SRC/$f" "$DST/$f" && [ "$(mode "$SRC/$f")" = "$(mode "$DST/$f")" ] || return 1
  done
}

# =================================================================================================
CASE="fresh card"
run
[ "$RC" = 0 ] && same_tree && ok "installs the image's copy when none is there (exit 0)" || bad "rc=$RC err=$ERR"
[ "$(mode "$DST/linuxarm64/steamcmd")" = 755 ] && [ "$(mode "$DST/linuxarm64/crashhandler.so")" = 644 ] \
  && ok "modes kept: binaries 755, the library 644" || bad "modes $(mode "$DST/linuxarm64/steamcmd") $(mode "$DST/linuxarm64/crashhandler.so")"
left="$(find "$DST" -name '.*' -type f)"
[ -z "$left" ] && ok "no temporary file left beside them" || bad "left: $left"
[ -z "$OUT" ] && ok "prints nothing on stdout (the session's log gets stderr)" || bad "stdout: $OUT"

CASE="working arm64 copy"
printf 'ELF arm64 steamcmd, self-updated\n' >"$DST/linuxarm64/steamcmd"
before="$(mtime "$DST/linuxarm64/steamcmd") $(mtime "$DST/steamcmd.sh")"
run
[ "$RC" = 0 ] && [ "$(mtime "$DST/linuxarm64/steamcmd") $(mtime "$DST/steamcmd.sh")" = "$before" ] \
  && grep -q self-updated "$DST/linuxarm64/steamcmd" \
  && ok "left alone: a copy steamcmd updated is never put back to the image's" || bad "rewritten (rc=$RC)"
[ -z "$ERR" ] && ok "and says nothing" || bad "stderr: $ERR"

CASE="x86 copy from the plugin"
rm -rf "$DST"; mkdir -p "$DST/linux32" "$DST/steamapps/common/Game"
printf '#!/bin/bash\nPLATFORM=linux32\nSTEAMEXE=linux32/steamcmd\n' >"$DST/steamcmd.sh"
printf 'ELF i386 steamcmd\n' >"$DST/linux32/steamcmd"
printf 'game data\n' >"$DST/steamapps/common/Game/data"
run
[ "$RC" = 0 ] && same_tree && ok "the x86 steamcmd.sh is replaced and the arm64 binaries installed" || bad "rc=$RC err=$ERR"
[ -f "$DST/linux32/steamcmd" ] && [ -f "$DST/steamapps/common/Game/data" ] \
  && ok "nothing else in the folder is touched (linux32/, game installs)" || bad "lost: $(cd "$DST" && find . -type f)"
grep -q "over an x86 one" <<<"$ERR" && ok "the session log says it replaced an x86 one" || bad "stderr: $ERR"

CASE="half-written copy"
rm "$DST/steamcmd.sh"
run
[ "$RC" = 0 ] && same_tree && ok "binary there, no steamcmd.sh: installed" || bad "rc=$RC err=$ERR"
rm "$DST/linuxarm64/steamcmd"
run
[ "$RC" = 0 ] && same_tree && ok "steamcmd.sh there, no binary: installed" || bad "rc=$RC err=$ERR"

CASE="copy fails"
rm -rf "$DST"; mkdir -p "$DST"
touch "$DST/linuxarm64"   # a file where the folder has to go: every linuxarm64/ copy fails
run
[ "$RC" != 0 ] && ok "a failed copy is an error (exit $RC)" || bad "exit 0"
[ ! -e "$DST/steamcmd.sh" ] && ok "and no steamcmd.sh was written: the plugin is not told it is there" \
  || bad "steamcmd.sh written before the binaries"
rm -f "$DST/linuxarm64"

CASE="broken image copy"
run
cp -R "$DST" "$T/good"
rm "$SRC/linuxarm64/steamcmd"; rm "$DST/linuxarm64/steamcmd"
run
[ "$RC" != 0 ] && ok "no binary in the image: an error (exit $RC)" || bad "exit 0 on a broken image copy"
[ ! -e "$DST/linuxarm64/steamcmd" ] && cmp -s "$T/good/steamcmd.sh" "$DST/steamcmd.sh" \
  && ok "... and the player's copy is untouched" || bad "the player's copy changed"
rm -rf "$SRC"
run
[ "$RC" != 0 ] && grep -q "no arm64 steamcmd in the image" <<<"$ERR" && ok "no image copy at all: an error that names it" || bad "rc=$RC err=$ERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
