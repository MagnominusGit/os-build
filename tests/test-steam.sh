#!/usr/bin/env bash
# Offline test for /usr/bin/steam and /usr/lib/retroforge/steam-bootstrap: how the image provides the
# `steam` the OpenGamepadUI Steam plugin launches games with.
#
#   tests/test-steam.sh
#
# WHY THIS EXISTS. Neither is exercised before a player picks a Steam game, and each rule below fails
# as a game that never starts, a black screen, a half-set-up client that looks ready, or a ~631 MB
# surprise download:
#   the pin (steam.pin): names CHANNELS, not versions; the client channel is a steamdeck_ line,
#     because the plugin starts the client with -steamdeck.
#   bootstrap, client:
#   - reads steam_client_<client_channel>_linuxarm64 and installs Valve's arm64 client binaries,
#     refusing them unless the manifest's sha256 matches;
#   - writes package/beta = the channel when it installs the client and when the file is missing,
#     and otherwise leaves it to the client;
#   - unpacks Valve's zips correctly: '\' separators, no execute bits in the zip, Unix symlinks;
#   - a failed download leaves no half-set-up client and no temp files, and never touches the
#     player's other files in the Steam folder;
#   - refuses a zip path or symlink that leaves its folder;
#   - downloads no Steam Runtime, and removes the one earlier builds installed.
#   wrapper:
#   - runs steamrtarm64/steam raw on the host (no runtime container: games' pressure-vessel cannot
#     start nested in it) with the plugin's arguments, from steamrtarm64 with its own libraries first
#     on LD_LIBRARY_PATH, and starts it again on exit 42 (after an update);
#   - points ~/.steam/steam and ~/.steam/root at the client, and the links Valve's steam.sh makes;
#   - drops a D-Bus address that is not ours, and the STEAM_RUNTIME variables;
#   - a failed bootstrap is exit 1 without running anything.
# Valve's servers are replaced by file:// URLs: $CDN for the client.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-bootstrap"
WRAP="$ROOT/rootfs/overlay/usr/bin/steam"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/steam.pin"
for f in "$BOOT" "$WRAP" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

mode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
sha()  { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
zeros() { printf '0%.0s' {1..64}; }

CDN="$T/cdn"; mkdir -p "$CDN"            # media.steampowered.com/client
DATA="$T/home/.local/share"
STEAM_ROOT="$DATA/Steam"
CLIENT="$STEAM_ROOT/steamrtarm64/steam"
BETA="$STEAM_ROOT/package/beta"
OLD_RT="$DATA/retroforge/steam-runtime"   # where earlier builds kept the Steam Runtime
PIN="$T/steam.pin"
CHAN=steamdeck_rftest

mkpin() {  # mkpin [extra lines...]
  { printf '# a test pin\nclient_channel: %s\n' "$CHAN"
    [ $# -gt 0 ] && printf '%s\n' "$@"
  } >"$PIN"
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
mkmanifest() {  # mkmanifest <client zip> [sha2] [channel]: a channel's manifest, with a decoy package first
  local file="bins_linuxarm64_linuxarm64.zip.$(basename "$1")"
  cp "$1" "$CDN/$file"
  cat >"$CDN/steam_client_${3:-$CHAN}_linuxarm64" <<EOF
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
boot() {  # boot [VAR=value...]: `steam-bootstrap --install`, as steam-install runs it
  OUT="$(env -u RETROFORGE_STEAM_PROGRESS HOME="$T/home" XDG_DATA_HOME="$DATA" \
         RETROFORGE_STEAM_PIN="$PIN" RETROFORGE_STEAM_CDN="file://$CDN" "$@" python3 "$BOOT" --install 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
bootn() {  # bootn [VAR=value...]: plain `steam-bootstrap`, as /usr/bin/steam runs it on every start
  OUT="$(env -u RETROFORGE_STEAM_PROGRESS HOME="$T/home" XDG_DATA_HOME="$DATA" \
         RETROFORGE_STEAM_PIN="$PIN" RETROFORGE_STEAM_CDN="file://$CDN" "$@" python3 "$BOOT" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
leftovers() { find "$DATA" -name '.retroforge-bootstrap-*' | head -3; }

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "a channel only: a steamdeck_ client line, no version, no runtime" \
  || bad "the image's steam.pin is malformed"
import re, sys
t = open(sys.argv[1]).read()
field = lambda k: (re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) or [None, None])[1]
# -steamdeck (the plugin's flag) keeps a steamdeck_ line; any other gets repointed at ~631 MB.
assert re.fullmatch(r"steamdeck_[a-z0-9_]+", field("client_channel") or ""), field("client_channel")
for k in ("version", "url", "sha256"):
    assert field(k) is None, f"{k} pins a version"
for k in ("runtime_base", "runtime_channel", "runtime_snapshot"):
    assert field(k) is None, f"{k}: the client runs without a Steam Runtime"
PY

CASE="fresh card, not installed"
mkpin
mkclient "$T/client.zip"; mkmanifest "$T/client.zip"
bootn
[ "$RC" = 10 ] && [ -z "$OUT" ] && grep -q "Steam Client is not installed: install it from Main menu > Emulators > Steam Client" <<<"$ERR" \
  && ok "without --install: exit 10, says where Steam Client is installed" || bad "rc=$RC out=$OUT err=$ERR"
[ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "and downloads nothing" || bad "$(ls -la "$STEAM_ROOT" 2>&1 | head)"
OUT="$(python3 "$BOOT" --bogus 2>"$T/err")"; RC=$?
[ "$RC" = 2 ] && grep -q "usage: steam-bootstrap \[--install\]" "$T/err" && ok "an unknown argument: exit 2" || bad "rc=$RC $(cat "$T/err")"

CASE="fresh card"
boot RETROFORGE_STEAM_PROGRESS=1
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && ok "exit 0, prints the client's path" || bad "rc=$RC out=$OUT err=$ERR"
[ -f "$CLIENT" ] && [ "$(mode "$CLIENT")" = 755 ] \
  && ok "the client binary is in place, 0755 although the zip says 0666" || bad "steam: $(ls -la "$STEAM_ROOT/steamrtarm64" 2>&1)"
[ "$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh")" = 755 ] && [ "$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")" = 644 ] \
  && ok "#! scripts 0755, data 0644" || bad "modes: sh=$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh") txt=$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")"
[ -d "$STEAM_ROOT/steamrtarm64/libs" ] && [ "$(readlink "$STEAM_ROOT/steamrtarm64/libs/libcurl.so")" = libcurl.so.4.8.0 ] \
  && ok "'\\' separators become folders, and link entries become symlinks" || bad "libs: $(ls -la "$STEAM_ROOT/steamrtarm64/libs" 2>&1)"
[ -z "$(find "$STEAM_ROOT" -name '*\\*')" ] && ok "no file has a '\\' in its name" || bad "$(find "$STEAM_ROOT" -name '*\\*')"
[ "$(cat "$BETA" 2>/dev/null)" = "$CHAN" ] && ok "package/beta names the pinned channel" || bad "beta: $(cat "$BETA" 2>&1)"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"
[ ! -e "$OLD_RT" ] && ok "no Steam Runtime is downloaded" || bad "$(ls -la "$OLD_RT")"
grep -q "Steam client from $CHAN" <<<"$ERR" && ok "says on stderr what it downloads, and from which channel" || bad "stderr: $ERR"
CZ="$(wc -c <"$T/client.zip" | tr -d ' ')"
grep -qx "steam-bootstrap: progress $CZ $CZ" <<<"$ERR" && [ "$(grep -c "^steam-bootstrap: progress " <<<"$ERR")" -ge 1 ] \
  && ok "RETROFORGE_STEAM_PROGRESS=1: progress lines, ending at the download's total" || bad "stderr: $ERR"
bootn
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && ok "installed: a plain start (steam's) prints the client's path" || bad "rc=$RC out=$OUT err=$ERR"
! grep -q "progress" <<<"$ERR" && ok "and no progress lines without the variable" || bad "stderr: $ERR"

CASE="installed, offline"
mv "$CDN" "$CDN.off"
bootn
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && [ -z "$ERR" ] && ok "a start reads nothing from the network, and says nothing" || bad "rc=$RC out=$OUT err=$ERR"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && [ -z "$ERR" ] && ok "nor does --install once the client is there" || bad "rc=$RC out=$OUT err=$ERR"
mv "$CDN.off" "$CDN"

CASE="a Steam Runtime from an earlier build"
mkdir -p "$OLD_RT/3c.0.20260824.1/steam-runtime-steamrt-arm64"
printf '#!/bin/sh\n' >"$OLD_RT/3c.0.20260824.1/steam-runtime-steamrt-arm64/run"
bootn
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && [ ! -e "$OLD_RT" ] && grep -q "removed $OLD_RT: the client runs without it now" <<<"$ERR" \
  && ok "removed on the next start, and said so" || bad "rc=$RC out=$OUT err=$ERR $(ls -la "$OLD_RT" 2>&1)"
bootn
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok "and nothing said after that" || bad "rc=$RC err=$ERR"

CASE="package/beta"
echo steamdeck_publicbeta >"$BETA"   # the client repointed itself
boot
[ "$RC" = 0 ] && [ "$(cat "$BETA")" = steamdeck_publicbeta ] && ok "left alone when present: the client owns it" || bad "rc=$RC beta=$(cat "$BETA") err=$ERR"
rm -f "$BETA"
bootn
[ "$RC" = 0 ] && [ "$(cat "$BETA" 2>/dev/null)" = "$CHAN" ] && ok "written again when missing, without a client download" \
  || bad "rc=$RC beta=$(cat "$BETA" 2>&1) err=$ERR"

CASE="the pin"
printf '# a test pin\n' >"$PIN"
boot
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "needs client_channel" <<<"$ERR" && ok "a pin without client_channel: exit 1" || bad "rc=$RC out=$OUT err=$ERR"
printf 'client_channel: ../evil\n' >"$PIN"
boot
[ "$RC" = 1 ] && grep -q "not a client channel" <<<"$ERR" && ok "a channel that is not a line name is refused" || bad "rc=$RC err=$ERR"
mkpin

CASE="client channel"
rm -rf "$STEAM_ROOT"; rm -f "$CDN"/steam_client_*
mkmanifest "$T/client.zip" "" steamdeck_otherline
boot
[ "$RC" = 1 ] && grep -q "steam_client_${CHAN}_linuxarm64" <<<"$ERR" && [ ! -e "$STEAM_ROOT/steamrtarm64" ] \
  && ok "only the pinned channel's manifest is read; a missing one is an error naming it" || bad "rc=$RC err=$ERR"
CHAN=steamdeck_otherline; mkpin
boot
[ "$RC" = 0 ] && [ -x "$STEAM_ROOT/steamrtarm64/steam" ] && [ "$(cat "$BETA" 2>/dev/null)" = steamdeck_otherline ] \
  && ok "steam_client_<channel>_linuxarm64 is built from the pin, and package/beta follows it" || bad "rc=$RC beta=$(cat "$BETA" 2>&1) err=$ERR"
CHAN=steamdeck_rftest; mkpin; mkmanifest "$T/client.zip"

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
echo steamdeck_publicbeta >"$BETA"
mkmanifest "$T/client.zip"
boot
[ "$RC" = 0 ] && [ -x "$STEAM_ROOT/steamrtarm64/steam" ] && ! grep -q stale "$STEAM_ROOT/steamrtarm64/builddate.txt" \
  && ok "a steamrtarm64/ without the client is replaced" || bad "rc=$RC err=$ERR"
[ "$(cat "$BETA")" = "$CHAN" ] && ok "installing the client sets package/beta to the channel" || bad "beta: $(cat "$BETA")"
[ -f "$STEAM_ROOT/steamapps/common/Game/data" ] && ok "the player's games are untouched" || bad "games gone"

CASE="manifest without the package"
rm -rf "$STEAM_ROOT/steamrtarm64"
printf '"linuxarm64"\n{\n\t"version"\t\t"1"\n}\n' >"$CDN/steam_client_${CHAN}_linuxarm64"
boot
[ "$RC" = 1 ] && grep -q "lists no bins_linuxarm64_linuxarm64" <<<"$ERR" && ok "an error that names the package" || bad "rc=$RC err=$ERR"

CASE="unsafe zip"
mkclient "$T/evil.zip" "../../escaped"; mkmanifest "$T/evil.zip"
boot
[ "$RC" = 1 ] && grep -q "unsafe path" <<<"$ERR" && ok "a path leaving the folder is refused" || bad "rc=$RC err=$ERR"
[ -z "$(find "$T" -name escaped)" ] && [ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "and nothing was written" || bad "$(find "$T" -name escaped)"

CASE="offline on a fresh card"
rm -rf "$CDN" "$DATA"
boot
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "could not download" <<<"$ERR" && ok "exit 1, says what it could not fetch" || bad "rc=$RC out=$OUT err=$ERR"

# ================================================================================================
# The wrapper, with the bootstrap stubbed: it puts a fake client where the real one is, and that
# records how it was called.
W="$T/w"; mkdir -p "$W"
cat >"$W/client" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$W/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$W/count"
{ echo "args: \$*"; echo "cwd: \$PWD"; echo "dbus: \${DBUS_SESSION_BUS_ADDRESS-unset}"; echo "rt: \${STEAM_RUNTIME-unset}"
  echo "ld: \${LD_LIBRARY_PATH-unset}"; } >"$W/call\$n"
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
mkdir -p "\$RETROFORGE_STEAM_ROOT/steamrtarm64"
cp "$W/client" "\$RETROFORGE_STEAM_ROOT/steamrtarm64/steam"; echo "\$RETROFORGE_STEAM_ROOT/steamrtarm64/steam"
EOF
chmod +x "$W/client" "$W/bootstrap"
# The x86 guest and the DXVK-Sarek block have their own suites (test-steam-x86-guest.sh,
# test-steam-compat-tools.sh). Here they would reach the real helpers, and on a device start real
# downloads into the test's home (1.4 GB; on an SM6115, Proton-CachyOS too): RETROFORGE_STEAM_X86_GUEST=0
# turns the guest off, and RETROFORGE_STEAM_SAREK_CLI names no such file.
WENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u LD_LIBRARY_PATH HOME="$W/home" RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap"
      RETROFORGE_CPUINFO="$W/cpuinfo" RETROFORGE_STEAM_X86_GUEST=0 RETROFORGE_STEAM_SAREK_CLI="$W/no-sarek-cli")
wrap() {  # wrap <exit codes of successive runs> [args...]
  echo "$1" >"$W/codes"; shift; rm -f "$W/count" "$W"/call*
  WOUT="$("${WENV[@]}" bash "$WRAP" "$@" 2>"$W/err")"; WRC=$?
  WERR="$(cat "$W/err")"
}
WROOT="$W/home/.local/share/Steam"

CASE="wrapper: launch"
touch "$W/mybus"
DBUS_SESSION_BUS_ADDRESS="unix:path=$W/mybus" STEAM_RUNTIME=1 wrap 0 -gamepadui -silent steam://rungameid/42
[ "$WRC" = 0 ] && grep -qx "args: -gamepadui -silent steam://rungameid/42" "$W/call1" \
  && ok "runs steamrtarm64/steam itself, no runtime container, with the plugin's arguments" || bad "rc=$WRC $(cat "$W/call1" 2>&1) $WERR"
grep -qx "cwd: $WROOT/steamrtarm64" "$W/call1" && ok "from steamrtarm64 in the Steam folder (XDG default)" || bad "$(grep cwd "$W/call1")"
grep -qx "ld: $WROOT/steamrtarm64:$WROOT/steamrtarm64/video" "$W/call1" \
  && ok "LD_LIBRARY_PATH is the client's own libraries (libav*, libvpx)" || bad "$(grep ld: "$W/call1")"
[ "$(readlink "$W/home/.steam/steam")" = "$WROOT" ] && [ "$(readlink "$W/home/.steam/root")" = "$WROOT" ] \
  && ok "~/.steam/steam and ~/.steam/root point at it" || bad "links: $(ls -la "$W/home/.steam")"
grep -qx "dbus: unix:path=$W/mybus" "$W/call1" && ok "our own D-Bus address is kept" || bad "$(grep dbus "$W/call1")"
grep -qx "rt: unset" "$W/call1" && ok "STEAM_RUNTIME is unset" || bad "$(grep rt: "$W/call1")"
[ -z "$WERR" ] && ok "nothing on stderr" || bad "stderr: $WERR"
[ "$(readlink "$W/home/.steam/bin64")" = "$WROOT/ubuntu12_64" ] && [ "$(readlink "$W/home/.steam/bin32")" = "$WROOT/ubuntu12_32" ] \
  && ok "~/.steam/bin64 and bin32 point at ubuntu12_64 and ubuntu12_32 (the overlay's preload paths)" || bad "links: $(ls -la "$W/home/.steam")"
[ "$(readlink "$W/home/.steam/sdkarm64")" = "$WROOT/linuxarm64" ] \
  && ok "~/.steam/sdkarm64 points at linuxarm64 (every game launches through its steam-launch-wrapper)" || bad "links: $(ls -la "$W/home/.steam")"

CASE="wrapper: Steam Client not installed"
cp "$W/bootstrap" "$W/bootstrap.real"
printf '#!/usr/bin/env bash\necho "steam-bootstrap: Steam Client is not installed: install it from Main menu > Emulators > Steam Client" >&2\nexit 10\n' >"$W/bootstrap"
wrap 0 steam://rungameid/42
[ "$WRC" = 1 ] && [ ! -e "$W/count" ] && ok "exit 1, the client is not started" || bad "rc=$WRC runs=$(cat "$W/count" 2>/dev/null)"
[ "$(grep -c . <<<"$WERR")" = 1 ] && grep -q "Main menu > Emulators > Steam Client" <<<"$WERR" \
  && ok "the bootstrap's one line says where to install it, and nothing more" || bad "stderr: $WERR"
mv "$W/bootstrap.real" "$W/bootstrap"

CASE="wrapper: LD_LIBRARY_PATH set"
echo 0 >"$W/codes"; rm -f "$W/count" "$W"/call*
"${WENV[@]}" LD_LIBRARY_PATH=/opt/x bash "$WRAP" 2>"$W/err"   # WENV unsets it, so it goes after
grep -qx "ld: $WROOT/steamrtarm64:$WROOT/steamrtarm64/video:/opt/x" "$W/call1" \
  && ok "the client's libraries come first, the caller's stay after them" || bad "$(grep ld: "$W/call1")"

CASE="wrapper: foreign D-Bus"
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus" wrap 0
grep -qx "dbus: unset" "$W/call1" && ok "a bus socket that is not ours is dropped" || bad "$(grep dbus "$W/call1")"

CASE="wrapper: update restart"
wrap "42 42 7" steam://rungameid/1
[ "$(cat "$W/count")" = 3 ] && [ "$WRC" = 7 ] && ok "exit 42 starts the client again; the final status is returned" || bad "runs=$(cat "$W/count") rc=$WRC"
grep -qx "args: steam://rungameid/1" "$W/call3" && ok "with the same arguments" || bad "$(cat "$W/call3")"

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

CASE="wrapper: the client fails"
wrap 1
[ "$WRC" = 1 ] && grep -q "the client exited with status 1" <<<"$WERR" && ok "a failed start is said" || bad "rc=$WRC err=$WERR"
wrap 0
! grep -q "exited with status" <<<"$WERR" && ok "a clean exit says nothing" || bad "err=$WERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
