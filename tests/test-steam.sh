#!/usr/bin/env bash
# Offline test for /usr/bin/steam and /usr/lib/retroforge/steam-bootstrap: how the image provides the
# `steam` the OpenGamepadUI Steam plugin launches games with.
#
#   tests/test-steam.sh
#
# WHY THIS EXISTS. Neither is exercised before a player picks a Steam game, and each rule below fails
# as a game that never starts, a black screen, or a half-set-up client that looks ready:
#   bootstrap:
#   - downloads the pinned runtime and Valve's arm64 client binaries, and refuses either unless
#     the sha256 matches (the runtime's from the pin, the client's from Valve's manifest);
#   - unpacks Valve's zips correctly: '\' separators, no execute bits in the zip, Unix symlinks;
#   - once set up, touches the network for nothing;
#   - a failed download leaves no half-set-up client and no temp files, and never touches the
#     player's other files in the Steam folder;
#   - a runtime bump replaces the old version, but a failed one keeps it;
#   - refuses a zip path or symlink that leaves its folder.
#   wrapper:
#   - runs steamrtarm64/steam inside the runtime's `run` with the plugin's arguments, from the
#     Steam folder, and starts it again on exit 42 (after an update);
#   - points ~/.steam/steam and ~/.steam/root at the client;
#   - drops a D-Bus address that is not ours, and the STEAM_RUNTIME variables;
#   - a failed bootstrap is exit 1 without running anything.
# Valve's servers are replaced by file:// URLs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-bootstrap"
WRAP="$ROOT/rootfs/overlay/usr/bin/steam"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/runtime.pin"
for f in "$BOOT" "$WRAP" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

mode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
sha()  { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

CDN="$T/cdn"; mkdir -p "$CDN"
DATA="$T/home/.local/share"
STEAM_ROOT="$DATA/Steam"
RT_DIR="$DATA/retroforge/steam-runtime"
PIN="$T/runtime.pin"

mkruntime() {  # mkruntime <tar.xz> <marker>: a runtime tarball laid out like Valve's
  python3 - "$1" "$2" <<'PY'
import io, sys, tarfile
path, marker = sys.argv[1:3]
def add(t, name, data=b"", mode=0o644, kind=tarfile.REGTYPE, link=""):
    i = tarfile.TarInfo(name); i.type = kind; i.mode = mode; i.linkname = link; i.size = len(data)
    t.addfile(i, io.BytesIO(data) if data else None)
with tarfile.open(path, "w:xz") as t:
    add(t, "steam-runtime-steamrt-arm64", kind=tarfile.DIRTYPE, mode=0o755)
    add(t, "steam-runtime-steamrt-arm64/run", f"#!/bin/sh\n# {marker}\n".encode(), 0o755)
    add(t, "steam-runtime-steamrt-arm64/files", kind=tarfile.DIRTYPE, mode=0o755)
    add(t, "steam-runtime-steamrt-arm64/files/lib", kind=tarfile.SYMTYPE, link="usr/lib")
PY
}
mkpin() {  # mkpin <version> <tar.xz> [sha256]
  printf 'name: steam-runtime-steamrt-arm64\nversion: %s\nurl: file://%s\nsha256: %s\n' "$1" "$2" "${3:-$(sha "$2")}" >"$PIN"
}
mkclient() {  # mkclient <zip> [extra member] : the client binaries as Valve zips them
  python3 - "$1" "${2:-}" <<'PY'
import stat, sys, zipfile
path, extra = sys.argv[1:3]
def add(z, name, data=b"", mode=stat.S_IFREG | 0o666, system=0):
    i = zipfile.ZipInfo(name); i.create_system = system; i.external_attr = mode << 16
    z.writestr(i, data)
with zipfile.ZipFile(path, "w") as z:
    add(z, "steamrtarm64\\libs/", mode=stat.S_IFDIR)
    add(z, "steamrtarm64/builddate.txt", b"Oct 13 2026\n")
    add(z, "steamrtarm64/steam", b"\x7fELF arm64 steam\n")
    add(z, "steamrtarm64/steamwebhelper.sh", b"#!/bin/bash\nexec ./steamwebhelper\n")
    add(z, "steamrtarm64\\libs\\libcurl.so", b"libcurl.so.4.8.0", stat.S_IFLNK | 0o755, 3)
    add(z, "steamrtarm64/libs/libcurl.so.4.8.0", b"\x7fELF arm64 libcurl\n")
    if extra:
        add(z, extra, b"evil\n")
PY
}
mkmanifest() {  # mkmanifest <client zip> [sha2] : Valve's client manifest, with a decoy package first
  local file="bins_linuxarm64_linuxarm64.zip.$(basename "$1")"
  cp "$1" "$CDN/$file"
  cat >"$CDN/steam_client_linuxarm64" <<EOF
"linuxarm64"
{
	"version"		"1791918634"
	"bins_sdk_linuxarm64_linuxarm64"
	{
		"file"		"bins_sdk_linuxarm64_linuxarm64.zip.decoy"
		"size"		"1"
		"sha2"		"0000000000000000000000000000000000000000000000000000000000000000"
	}
	"bins_linuxarm64_linuxarm64"
	{
		"file"		"$file"
		"size"		"$(wc -c <"$1" | tr -d ' ')"
		"sha2"		"${2:-$(sha "$1")}"
	}
}
EOF
}
boot() {
  OUT="$(HOME="$T/home" XDG_DATA_HOME="$DATA" RETROFORGE_STEAM_RUNTIME_PIN="$PIN" \
         RETROFORGE_STEAM_CDN="file://$CDN" python3 "$BOOT" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
leftovers() { find "$DATA" -name '.tmp-*' -o -name '.retroforge-bootstrap-*' | head -3; }

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "version, a versioned repo.steampowered.com url naming it, and a sha256" || bad "the image's runtime.pin is malformed"
import re, sys
t = open(sys.argv[1]).read()
f = {k: re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) for k in ("version", "url", "sha256")}
assert all(f.values())
v, u, s = (m.group(1) for m in f.values())
assert re.fullmatch(r"[0-9a-f]{64}", s)
assert u == f"https://repo.steampowered.com/steamrt3c/images/{v}/steam-runtime-steamrt-arm64.tar.xz", u
PY

CASE="fresh card"
mkruntime "$T/rt1.tar.xz" v1; mkpin 3c.0.1 "$T/rt1.tar.xz"
mkclient "$T/client.zip"; mkmanifest "$T/client.zip"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/3c.0.1/steam-runtime-steamrt-arm64/run" ] \
  && ok "exit 0, prints the runtime's run" || bad "rc=$RC out=$OUT err=$ERR"
[ -x "$OUT" ] && [ -L "$RT_DIR/3c.0.1/steam-runtime-steamrt-arm64/files/lib" ] \
  && ok "the runtime is unpacked with its symlinks" || bad "runtime: $(ls -laR "$RT_DIR" 2>&1 | head -20)"
[ -f "$STEAM_ROOT/steamrtarm64/steam" ] && [ "$(mode "$STEAM_ROOT/steamrtarm64/steam")" = 755 ] \
  && ok "the client binary is in place, 0755 although the zip says 0666" || bad "steam: $(ls -la "$STEAM_ROOT/steamrtarm64" 2>&1)"
[ "$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh")" = 755 ] && [ "$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")" = 644 ] \
  && ok "#! scripts 0755, data 0644" || bad "modes: sh=$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh") txt=$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")"
[ -d "$STEAM_ROOT/steamrtarm64/libs" ] && [ "$(readlink "$STEAM_ROOT/steamrtarm64/libs/libcurl.so")" = libcurl.so.4.8.0 ] \
  && ok "'\\' separators become folders, and link entries become symlinks" || bad "libs: $(ls -la "$STEAM_ROOT/steamrtarm64/libs" 2>&1)"
[ -z "$(find "$STEAM_ROOT" -name '*\\*')" ] && ok "no file has a '\\' in its name" || bad "$(find "$STEAM_ROOT" -name '*\\*')"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"
grep -q "downloading Valve's arm64 Steam client" <<<"$ERR" && ok "says on stderr what it downloads" || bad "stderr: $ERR"

CASE="already set up"
rm -rf "$CDN"; mkdir -p "$CDN"   # Valve unreachable, and the pin's tarball gone too
rm -f "$T/rt1.tar.xz"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/3c.0.1/steam-runtime-steamrt-arm64/run" ] && [ -z "$ERR" ] \
  && ok "no download at all once both are there (works offline, says nothing)" || bad "rc=$RC err=$ERR"

CASE="runtime bump, bad checksum"
mkruntime "$T/rt2.tar.xz" v2; mkpin 3c.0.2 "$T/rt2.tar.xz" "$(printf '0%.0s' {1..64})"
boot
[ "$RC" = 1 ] && grep -q "sha256 mismatch" <<<"$ERR" && [ -z "$OUT" ] && ok "refused (exit 1, nothing on stdout)" || bad "rc=$RC out=$OUT err=$ERR"
[ -x "$RT_DIR/3c.0.1/steam-runtime-steamrt-arm64/run" ] && [ ! -e "$RT_DIR/3c.0.2" ] \
  && ok "the old runtime is kept, nothing half-unpacked" || bad "runtimes: $(ls -A "$RT_DIR")"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="runtime bump"
mkpin 3c.0.2 "$T/rt2.tar.xz"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/3c.0.2/steam-runtime-steamrt-arm64/run" ] && grep -q v2 "$OUT" \
  && ok "the new version is installed" || bad "rc=$RC out=$OUT err=$ERR"
[ "$(ls -A "$RT_DIR")" = 3c.0.2 ] && ok "and the old one removed" || bad "runtimes: $(ls -A "$RT_DIR")"

CASE="client download, bad checksum"
rm -rf "$STEAM_ROOT/steamrtarm64"
mkdir -p "$STEAM_ROOT/steamapps/common/Game"; echo data >"$STEAM_ROOT/steamapps/common/Game/data"
mkclient "$T/client.zip"; mkmanifest "$T/client.zip" "$(printf 'f%.0s' {1..64})"
boot
[ "$RC" = 1 ] && grep -q "sha256 mismatch" <<<"$ERR" && ok "refused (exit 1)" || bad "rc=$RC err=$ERR"
[ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "no half-set-up client left" || bad "steamrtarm64 exists"
[ -f "$STEAM_ROOT/steamapps/common/Game/data" ] && ok "the player's games are untouched" || bad "games gone"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="leftover from a failed attempt"
mkdir -p "$STEAM_ROOT/steamrtarm64"; echo stale >"$STEAM_ROOT/steamrtarm64/builddate.txt"
mkmanifest "$T/client.zip"
boot
[ "$RC" = 0 ] && [ -x "$STEAM_ROOT/steamrtarm64/steam" ] && ! grep -q stale "$STEAM_ROOT/steamrtarm64/builddate.txt" \
  && ok "a steamrtarm64/ without the client is replaced" || bad "rc=$RC err=$ERR"
[ -f "$STEAM_ROOT/steamapps/common/Game/data" ] && ok "the player's games are untouched" || bad "games gone"

CASE="manifest without the package"
rm -rf "$STEAM_ROOT/steamrtarm64"
printf '"linuxarm64"\n{\n\t"version"\t\t"1"\n}\n' >"$CDN/steam_client_linuxarm64"
boot
[ "$RC" = 1 ] && grep -q "lists no bins_linuxarm64_linuxarm64" <<<"$ERR" && ok "an error that names the package" || bad "rc=$RC err=$ERR"

CASE="unsafe zip"
mkclient "$T/evil.zip" "../../escaped"; mkmanifest "$T/evil.zip"
boot
[ "$RC" = 1 ] && grep -q "unsafe path" <<<"$ERR" && ok "a path leaving the folder is refused" || bad "rc=$RC err=$ERR"
[ -z "$(find "$T" -name escaped)" ] && [ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "and nothing was written" || bad "$(find "$T" -name escaped)"

CASE="offline on a fresh card"
rm -rf "$CDN" "$DATA"
mkpin 3c.0.2 "$T/missing.tar.xz" "$(printf 'a%.0s' {1..64})"
boot
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "could not download" <<<"$ERR" && ok "exit 1, says what it could not fetch" || bad "rc=$RC out=$OUT err=$ERR"

# ================================================================================================
# The wrapper, with the bootstrap stubbed: a fake runtime `run` records how it was called.
W="$T/w"; mkdir -p "$W/rt"
cat >"$W/rt/run" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$W/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$W/count"
{ echo "args: \$*"; echo "cwd: \$PWD"; echo "dbus: \${DBUS_SESSION_BUS_ADDRESS-unset}"; echo "rt: \${STEAM_RUNTIME-unset}"; } >"$W/call\$n"
codes=(\$(cat "$W/codes")); c="\${codes[\$((n-1))]:-0}"
if [ "\$c" = S ]; then   # S: run until TERMed, like the real client
  trap 'echo term >"$W/term"; exit 143' TERM; echo \$\$ >"$W/runpid"
  while :; do sleep 0.1; done
fi
exit "\$c"
EOF
cat >"$W/bootstrap" <<EOF
#!/usr/bin/env bash
[ -e "$W/boot-fails" ] && { echo "steam-bootstrap: no network" >&2; exit 1; }
mkdir -p "\$RETROFORGE_STEAM_ROOT"; echo "$W/rt/run"
EOF
chmod +x "$W/rt/run" "$W/bootstrap"
WENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME HOME="$W/home" RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap"
      RETROFORGE_CPUINFO="$W/cpuinfo")
wrap() {  # wrap <exit codes of successive runs> [args...]
  echo "$1" >"$W/codes"; shift; rm -f "$W/count" "$W"/call*
  WOUT="$("${WENV[@]}" bash "$WRAP" "$@" 2>"$W/err")"; WRC=$?
  WERR="$(cat "$W/err")"
}
WROOT="$W/home/.local/share/Steam"

CASE="wrapper: launch"
touch "$W/mybus"
DBUS_SESSION_BUS_ADDRESS="unix:path=$W/mybus" STEAM_RUNTIME=1 wrap 0 -gamepadui -silent steam://rungameid/42
[ "$WRC" = 0 ] && grep -qx "args: -- $WROOT/steamrtarm64/steam -gamepadui -silent steam://rungameid/42" "$W/call1" \
  && ok "runs steamrtarm64/steam inside the runtime with the plugin's arguments" || bad "rc=$WRC $(cat "$W/call1" 2>&1) $WERR"
grep -qx "cwd: $WROOT" "$W/call1" && ok "from the Steam folder (XDG default)" || bad "$(grep cwd "$W/call1")"
[ "$(readlink "$W/home/.steam/steam")" = "$WROOT" ] && [ "$(readlink "$W/home/.steam/root")" = "$WROOT" ] \
  && ok "~/.steam/steam and ~/.steam/root point at it" || bad "links: $(ls -la "$W/home/.steam")"
grep -qx "dbus: unix:path=$W/mybus" "$W/call1" && ok "our own D-Bus address is kept" || bad "$(grep dbus "$W/call1")"
grep -qx "rt: unset" "$W/call1" && ok "STEAM_RUNTIME is unset" || bad "$(grep rt: "$W/call1")"

CASE="wrapper: foreign D-Bus"
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus" wrap 0
grep -qx "dbus: unset" "$W/call1" && ok "a bus socket that is not ours is dropped" || bad "$(grep dbus "$W/call1")"

CASE="wrapper: update restart"
wrap "42 42 7" steam://rungameid/1
[ "$(cat "$W/count")" = 3 ] && [ "$WRC" = 7 ] && ok "exit 42 starts the client again; the final status is returned" || bad "runs=$(cat "$W/count") rc=$WRC"
grep -qx "args: -- $WROOT/steamrtarm64/steam steam://rungameid/1" "$W/call3" && ok "with the same arguments" || bad "$(cat "$W/call3")"

CASE="wrapper: stopped by a signal"
echo S >"$W/codes"; rm -f "$W/count" "$W"/call* "$W/term" "$W/runpid"
"${WENV[@]}" bash "$WRAP" steam://rungameid/1 2>"$W/err" &
wpid=$!
for _ in $(seq 50); do [ -s "$W/runpid" ] && break; sleep 0.1; done
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ -e "$W/term" ] && ok "a TERM to the wrapper reaches the client" || bad "the client never got TERM"
[ "$WRC" = 143 ] && [ "$(cat "$W/count")" = 1 ] && ok "and the wrapper exits with its status, without restarting" \
  || bad "rc=$WRC runs=$(cat "$W/count")"
pid="$(cat "$W/runpid" 2>/dev/null)"
[ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && ok "nothing is left running" || { bad "client still running"; kill "$pid" 2>/dev/null; }

CASE="wrapper: bootstrap fails"
touch "$W/boot-fails"
wrap 0
[ "$WRC" = 1 ] && [ ! -e "$W/count" ] && grep -q "could not be set up" <<<"$WERR" && ok "exit 1, nothing run" || bad "rc=$WRC err=$WERR"
rm -f "$W/boot-fails"

CASE="wrapper: ~/.steam/steam is a real folder"
rm -f "$W/home/.steam/steam"; mkdir -p "$W/home/.steam/steam"
wrap 0
[ -d "$W/home/.steam/steam" ] && [ ! -L "$W/home/.steam/steam" ] && grep -q "leaving it alone" <<<"$WERR" \
  && ok "left alone, and said so" || bad "$(ls -la "$W/home/.steam")"
rmdir "$W/home/.steam/steam"

CASE="wrapper: SIGILL"
echo "Features	: fp asimd evtstrm crc32 cpuid" >"$W/cpuinfo"
wrap 132
[ "$WRC" = 132 ] && grep -q "kernel/patches/0025" <<<"$WERR" && ok "on a CPU without LSE it names the kernel patch" || bad "rc=$WRC err=$WERR"
echo "Features	: fp asimd evtstrm aes crc32 atomics fphp" >"$W/cpuinfo"
wrap 132
! grep -q "0025" <<<"$WERR" && ok "with LSE it does not" || bad "err=$WERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
