#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/install-steamcmd: how the session puts RetroForge's steamcmd
# stub where the OpenGamepadUI Steam plugin runs steamcmd from.
#
#   tests/test-steamcmd-install.sh
#
# WHY THIS EXISTS. The plugin runs ~/.steam/steamcmd/steamcmd.sh, and when that is missing it fetches
# Valve's x86 build, which cannot run here. The image ships no steamcmd, only a stub that downloads
# Valve's arm64 one the first time it runs, from the channel steamcmd.pin names, through
# steamcmd-fetch (tests/test-steamcmd-stub.sh tests that part). The rules here, each of which goes
# wrong silently:
#   - place the stub when there is no working arm64 copy: none, an x86 one, or a half-written one;
#   - the image's stub already in place is fine: nothing is rewritten on every boot;
#   - a stub from an older image is replaced with this image's;
#   - a stub with Valve's binaries beside it (its download was cut off before steamcmd.sh) is
#     still a stub, not a working copy;
#   - never touch a working arm64 copy (steamcmd has updated itself past anything we could put back),
#     including the bare one the stub leaves (steamcmd.sh + linuxarm64/steamcmd) before steamcmd's
#     first start downloads the rest;
#   - steamcmd.sh goes in through a temporary file and a rename, and a failed write leaves no
#     steamcmd.sh that would make the plugin skip its download;
#   - nothing else in the folder is touched (the plugin's game installs, an x86 linux32/);
#   - while a stub holds the folder's lock (it is downloading), nothing is touched;
#   - a missing image stub is an error, not an install.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/rootfs/overlay/usr/lib/retroforge/install-steamcmd"
STUB_REAL="$ROOT/rootfs/overlay/usr/lib/retroforge/steamcmd-stub"
FETCH_REAL="$ROOT/rootfs/overlay/usr/lib/retroforge/steamcmd-fetch"
for f in "$TOOL" "$STUB_REAL" "$FETCH_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

mode()  { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
stamp() { python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino, s.st_mtime_ns)' "$1"; }

STUB="$T/image/usr/lib/retroforge/steamcmd-stub"
DST="$T/home/.steam/steamcmd"
mkdir -p "$(dirname "$STUB")"
cp "$STUB_REAL" "$STUB"

run() {
  OUT="$(RETROFORGE_STEAMCMD_STUB="$STUB" RETROFORGE_STEAMCMD_DIR="$DST" python3 "$TOOL" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
is_stub()   { cmp -s "$STUB" "$DST/steamcmd.sh"; }
tempfiles() { find "$DST" -name '.steamcmd.sh.*' 2>/dev/null; }
valve_arm64() {  # Valve's arm64 copy as the stub leaves it: the launcher and the bootstrapper binary
  mkdir -p "$DST/linuxarm64"
  printf '#!/usr/bin/env bash\n: "${STEAM_PLATFORM:=linuxarm64}"\n' >"$DST/steamcmd.sh"
  printf 'ELF arm64 steamcmd\n' >"$DST/linuxarm64/steamcmd"
  chmod 755 "$DST/steamcmd.sh" "$DST/linuxarm64/steamcmd"
}
self_updated() {  # ... and as steamcmd's first start leaves it: the rest of the manifest's packages
  mkdir -p "$DST/package" "$DST/public"
  printf 'ELF arm64 steamclient\n' >"$DST/linuxarm64/steamclient.so"
  printf '"linuxarm64" { "version" "1791918946" }\n' >"$DST/package/steam_cmd_linuxarm64.manifest"
  : >"$DST/package/steam_cmd_linuxarm64.installed"
  printf '"Language" "English"\n' >"$DST/public/steambootstrapper_english.txt"
}

# =================================================================================================
CASE="the image's stub"
head -n 2 "$STUB_REAL" | grep -qx '# RETROFORGE_STEAMCMD_STUB' \
  && ok "carries the marker line install-steamcmd tells it apart by" || bad "no marker line on line 2"
[ -x "$STUB_REAL" ] && ok "is executable in the overlay (the image copies the tree as-is)" || bad "mode $(mode "$STUB_REAL")"
[ -x "$FETCH_REAL" ] && grep -q 'RETROFORGE_STEAMCMD_FETCH:-/usr/lib/retroforge/steamcmd-fetch}' "$STUB_REAL" \
  && ok "its download helper is executable in the overlay, where the stub looks for it" || bad "steamcmd-fetch: mode $(mode "$FETCH_REAL")"

CASE="fresh card"
run
[ "$RC" = 0 ] && is_stub && ok "the stub is put at steamcmd.sh when nothing is there (exit 0)" || bad "rc=$RC err=$ERR"
[ "$(mode "$DST/steamcmd.sh")" = 755 ] && ok "0755: the plugin execs it directly" || bad "mode $(mode "$DST/steamcmd.sh")"
[ "$(find "$DST" -mindepth 1 | wc -l)" = 1 ] && ok "and nothing else: no steamcmd in the image to copy" \
  || bad "also: $(cd "$DST" && find . -mindepth 1)"
[ -z "$(tempfiles)" ] && ok "no temporary file left beside it" || bad "left: $(tempfiles)"
[ -z "$OUT" ] && ok "prints nothing on stdout (the session's log gets stderr)" || bad "stdout: $OUT"
grep -q "placed the steamcmd stub" <<<"$ERR" && ok "the session log says so" || bad "stderr: $ERR"

CASE="stub in place"
before="$(stamp "$DST/steamcmd.sh")"
run; run
[ "$RC" = 0 ] && [ "$(stamp "$DST/steamcmd.sh")" = "$before" ] \
  && ok "the image's stub is fine as it is: not rewritten on every boot" || bad "rewritten (rc=$RC)"
[ -z "$ERR" ] && ok "and says nothing" || bad "stderr: $ERR"

CASE="older stub"
{ head -n 2 "$STUB"; echo 'echo "an older image'"'"'s stub"'; } >"$DST/steamcmd.sh"
run
[ "$RC" = 0 ] && is_stub && ok "a stub from an older image is replaced with this one" || bad "rc=$RC err=$ERR"
grep -q "updated the steamcmd stub" <<<"$ERR" && ok "the session log says it was updated" || bad "stderr: $ERR"

CASE="stub, download cut off"
mkdir -p "$DST/linuxarm64"; printf 'ELF arm64 steamcmd\n' >"$DST/linuxarm64/steamcmd"
before="$(stamp "$DST/steamcmd.sh")"
run
[ "$RC" = 0 ] && [ "$(stamp "$DST/steamcmd.sh")" = "$before" ] && is_stub \
  && ok "the stub with Valve's binary beside it stays the stub (its next run finishes the job)" || bad "rc=$RC err=$ERR"
{ head -n 2 "$STUB"; echo 'linuxarm64 older stub'; } >"$DST/steamcmd.sh"
run
[ "$RC" = 0 ] && is_stub && ok "... and an older stub beside it is still updated, not taken for Valve's" || bad "rc=$RC err=$ERR"

CASE="working arm64 copy"
rm -rf "$DST"; valve_arm64
before="$(stamp "$DST/linuxarm64/steamcmd") $(stamp "$DST/steamcmd.sh")"
run
[ "$RC" = 0 ] && [ "$(stamp "$DST/linuxarm64/steamcmd") $(stamp "$DST/steamcmd.sh")" = "$before" ] && [ -z "$ERR" ] \
  && ok "as the stub leaves it (launcher + bootstrapper binary, nothing else yet): left alone, silently" || bad "rewritten (rc=$RC err=$ERR)"
self_updated
printf 'ELF arm64 steamcmd, self-updated\n' >"$DST/linuxarm64/steamcmd"
before="$(stamp "$DST/linuxarm64/steamcmd") $(stamp "$DST/steamcmd.sh")"
run
[ "$RC" = 0 ] && [ "$(stamp "$DST/linuxarm64/steamcmd") $(stamp "$DST/steamcmd.sh")" = "$before" ] \
  && grep -q self-updated "$DST/linuxarm64/steamcmd" \
  && ok "left alone: Valve's copy, which steamcmd updates, is never replaced by the stub" || bad "rewritten (rc=$RC)"
[ -z "$ERR" ] && ok "and says nothing" || bad "stderr: $ERR"

CASE="x86 copy from the plugin"
rm -rf "$DST"; mkdir -p "$DST/linux32" "$DST/steamapps/common/Game"
printf '#!/bin/bash\nPLATFORM=linux32\nSTEAMEXE=linux32/steamcmd\n' >"$DST/steamcmd.sh"
printf 'ELF i386 steamcmd\n' >"$DST/linux32/steamcmd"
printf 'game data\n' >"$DST/steamapps/common/Game/data"
run
[ "$RC" = 0 ] && is_stub && ok "the x86 steamcmd.sh is replaced by the stub" || bad "rc=$RC err=$ERR"
[ -f "$DST/linux32/steamcmd" ] && [ -f "$DST/steamapps/common/Game/data" ] \
  && ok "nothing else in the folder is touched (linux32/, game installs)" || bad "lost: $(cd "$DST" && find . -type f)"
grep -q "over an x86 steamcmd" <<<"$ERR" && ok "the session log says it replaced an x86 one" || bad "stderr: $ERR"

CASE="x86 copy, Valve's shared steamcmd.sh"
# Valve may ship one steamcmd.sh in both tarballs: it knows linuxarm64, but there is no arm64 binary.
rm -rf "$DST"; mkdir -p "$DST/linux32"
printf '#!/bin/bash\n[ "$(uname -m)" = aarch64 ] && P=linuxarm64 || P=linux32\n' >"$DST/steamcmd.sh"
printf 'ELF i386 steamcmd\n' >"$DST/linux32/steamcmd"
run
[ "$RC" = 0 ] && is_stub && ok "a steamcmd.sh that knows linuxarm64 without the binary is replaced" || bad "rc=$RC err=$ERR"

CASE="half-written copy"
rm -rf "$DST"; valve_arm64; rm "$DST/steamcmd.sh"
printf 'self-updated library\n' >"$DST/linuxarm64/steamclient.so"
run
[ "$RC" = 0 ] && is_stub && ok "binary there, no steamcmd.sh: the stub goes in" || bad "rc=$RC err=$ERR"
[ -f "$DST/linuxarm64/steamcmd" ] && [ -f "$DST/linuxarm64/steamclient.so" ] \
  && ok "... and linuxarm64/ is left as it was" || bad "linuxarm64: $(ls "$DST/linuxarm64")"
rm -rf "$DST"; valve_arm64; rm "$DST/linuxarm64/steamcmd"
run
[ "$RC" = 0 ] && is_stub && ok "steamcmd.sh there, no binary: the stub replaces it" || bad "rc=$RC err=$ERR"
grep -q "over an incomplete steamcmd" <<<"$ERR" && ok "the session log says what it replaced" || bad "stderr: $ERR"

CASE="a stub is downloading"
rm -rf "$DST"; mkdir -p "$DST/linux32"
printf '#!/bin/bash\nPLATFORM=linux32\n' >"$DST/steamcmd.sh"
before="$(stamp "$DST/steamcmd.sh")"
# The stub holds a flock on the folder itself while it downloads; hold it the same way. -o keeps the
# lock in flock(1) alone, so stopping its child (the sleep, whose pid it wrote) releases it.
flock -o "$DST" sh -c 'echo $$ >"$1/.held.tmp" && mv "$1/.held.tmp" "$1/.held" && exec sleep 30' sh "$T" & holder=$!
for _ in $(seq 50); do [ -s "$T/.held" ] && break; sleep 0.1; done
run
kill "$(cat "$T/.held")" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$RC" = 0 ] && [ "$(stamp "$DST/steamcmd.sh")" = "$before" ] \
  && ok "the folder is left alone while its lock is held (exit 0)" || bad "rc=$RC, steamcmd.sh changed: $(head -c 80 "$DST/steamcmd.sh")"
grep -q "download is running" <<<"$ERR" && ok "and the session log says why" || bad "stderr: $ERR"
run
[ "$RC" = 0 ] && is_stub && ok "once the lock is free, the next start places the stub" || bad "rc=$RC err=$ERR"

CASE="write fails"
rm -rf "$DST"; mkdir -p "$(dirname "$DST")"
touch "$DST"   # a file where the folder has to go (works as root too, unlike a read-only folder)
run
[ "$RC" != 0 ] && grep -q "could not set up" <<<"$ERR" && ok "an error that names the folder (exit $RC)" || bad "rc=$RC err=$ERR"
rm -f "$DST"; mkdir -p "$DST/steamcmd.sh"   # a folder where steamcmd.sh has to go
run
[ "$RC" != 0 ] && ok "a failed rename is an error (exit $RC)" || bad "exit 0"
[ -d "$DST/steamcmd.sh" ] && [ -z "$(tempfiles)" ] \
  && ok "and nothing is left behind: no steamcmd.sh, no temporary file" || bad "left: $(tempfiles)"
rm -rf "$DST"

CASE="broken image"
valve_arm64; rm "$DST/linuxarm64/steamcmd"
cp "$DST/steamcmd.sh" "$T/before"
printf '#!/bin/bash\necho no marker\n' >"$STUB"
run
[ "$RC" != 0 ] && grep -q "no steamcmd stub in the image" <<<"$ERR" \
  && ok "an image file without the marker is not installed (exit $RC)" || bad "rc=$RC err=$ERR"
cmp -s "$T/before" "$DST/steamcmd.sh" && ok "... and the player's folder is untouched" || bad "the player's copy changed"
rm -f "$STUB"
run
[ "$RC" != 0 ] && grep -q "no steamcmd stub in the image" <<<"$ERR" && ok "no image stub at all: an error that names it" || bad "rc=$RC err=$ERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
