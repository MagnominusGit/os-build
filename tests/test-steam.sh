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
#   bootstrap, runtime:
#   - resolves the runtime channel to a snapshot id on every start, and refuses an id that is not
#     one (it becomes a folder name);
#   - downloads that snapshot and refuses it unless it matches the snapshot's SHA256SUMS;
#   - a moved channel installs the new snapshot, then removes the old one, but not while a Steam
#     started from it still holds it; a failed move keeps the old one;
#   - offline, or on any failed update, starts with the newest installed snapshot and says so; with
#     none installed, exit 1;
#   - RETROFORGE_STEAM_RUNTIME_SNAPSHOT, or runtime_snapshot: in the pin, pins one snapshot.
#   bootstrap, client:
#   - reads steam_client_<client_channel>_linuxarm64 and installs Valve's arm64 client binaries,
#     refusing them unless the manifest's sha256 matches;
#   - writes package/beta = the channel when it installs the client and when the file is missing,
#     and otherwise leaves it to the client;
#   - unpacks Valve's zips correctly: '\' separators, no execute bits in the zip, Unix symlinks;
#   - a failed download leaves no half-set-up client and no temp files, and never touches the
#     player's other files in the Steam folder;
#   - refuses a zip path or symlink that leaves its folder.
#   wrapper:
#   - runs steamrtarm64/steam inside the runtime's `run` with the plugin's arguments, from the
#     Steam folder, and starts it again on exit 42 (after an update);
#   - holds a shared lock on the runtime snapshot's folder while the client runs;
#   - points ~/.steam/steam and ~/.steam/root at the client;
#   - drops a D-Bus address that is not ours, and the STEAM_RUNTIME variables;
#   - a failed bootstrap is exit 1 without running anything.
# Valve's servers are replaced by file:// URLs: $CDN for the client, $RT for the runtime images.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-bootstrap"
WRAP="$ROOT/rootfs/overlay/usr/bin/steam"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/steam.pin"
for f in "$BOOT" "$WRAP" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done
command -v flock >/dev/null || { echo "needs flock (util-linux)" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
holder=""
trap '[ -n "$holder" ] && kill "$holder" 2>/dev/null; rm -rf "$T"' EXIT

mode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
sha()  { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
zeros() { printf '0%.0s' {1..64}; }

CDN="$T/cdn"; mkdir -p "$CDN"            # media.steampowered.com/client
RT="$T/steamrt3c/images"; mkdir -p "$RT"  # repo.steampowered.com/steamrt3c/images
DATA="$T/home/.local/share"
STEAM_ROOT="$DATA/Steam"
BETA="$STEAM_ROOT/package/beta"
RT_DIR="$DATA/retroforge/steam-runtime"
PIN="$T/steam.pin"
CHAN=steamdeck_rftest; RTCHAN=rf-public-stable
S1=3c.0.20260101.1; S2=3c.0.20260201.2; S3=3c.0.20260301.3
RUN=steam-runtime-steamrt-arm64/run

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
publish() {  # publish <snapshot> <marker> [sha256 to list instead]: an image dir, as Valve lays it out
  mkdir -p "$RT/$1"
  mkruntime "$RT/$1/steam-runtime-steamrt-arm64.tar.xz" "$2"
  { echo "$(printf '1%.0s' {1..64}) *steam-runtime-steamrt-amd64.tar.xz"
    echo "$(printf '2%.0s' {1..64}) *steam-runtime-steamrt-arm64.sh"
    echo "${3:-$(sha "$RT/$1/steam-runtime-steamrt-arm64.tar.xz")} *steam-runtime-steamrt-arm64.tar.xz"
  } >"$RT/$1/SHA256SUMS"
}
point() { printf '%s\n' "$1" >"$RT/$RTCHAN.txt"; }  # point <snapshot id>: move the channel
mkpin() {  # mkpin [extra lines...]
  { printf '# a test pin\nclient_channel: %s\nruntime_base: file://%s\nruntime_channel: %s\n' "$CHAN" "$RT" "$RTCHAN"
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
boot() {  # boot [VAR=value...]
  OUT="$(env -u RETROFORGE_STEAM_RUNTIME_SNAPSHOT HOME="$T/home" XDG_DATA_HOME="$DATA" \
         RETROFORGE_STEAM_PIN="$PIN" RETROFORGE_STEAM_CDN="file://$CDN" "$@" python3 "$BOOT" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
leftovers() { find "$DATA" -name '.tmp-*' -o -name '.retroforge-bootstrap-*' | head -3; }
snapshots() { ls -A "$RT_DIR" | grep -v '^\.' | tr '\n' ' ' | sed 's/ $//'; }

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "channels only: a steamdeck_ client line, Valve's steamrt3c images, a runtime channel, no version" \
  || bad "the image's steam.pin is malformed"
import re, sys
t = open(sys.argv[1]).read()
field = lambda k: (re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) or [None, None])[1]
# -steamdeck (the plugin's flag) keeps a steamdeck_ line; any other gets repointed at ~631 MB.
assert re.fullmatch(r"steamdeck_[a-z0-9_]+", field("client_channel") or ""), field("client_channel")
assert field("runtime_base") == "https://repo.steampowered.com/steamrt3c/images", field("runtime_base")
assert re.fullmatch(r"[A-Za-z0-9_.-]+", field("runtime_channel") or ""), field("runtime_channel")
for k in ("runtime_snapshot", "version", "url", "sha256"):
    assert field(k) is None, f"{k} pins a version"
PY

CASE="fresh card"
publish "$S1" v1; point "$S1"; mkpin
mkclient "$T/client.zip"; mkmanifest "$T/client.zip"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S1/$RUN" ] \
  && ok "exit 0, prints the run of the snapshot the channel names" || bad "rc=$RC out=$OUT err=$ERR"
[ -x "$OUT" ] && [ -L "$RT_DIR/$S1/steam-runtime-steamrt-arm64/files/lib" ] \
  && ok "the runtime is unpacked with its symlinks" || bad "runtime: $(ls -laR "$RT_DIR" 2>&1 | head -20)"
[ -f "$STEAM_ROOT/steamrtarm64/steam" ] && [ "$(mode "$STEAM_ROOT/steamrtarm64/steam")" = 755 ] \
  && ok "the client binary is in place, 0755 although the zip says 0666" || bad "steam: $(ls -la "$STEAM_ROOT/steamrtarm64" 2>&1)"
[ "$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh")" = 755 ] && [ "$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")" = 644 ] \
  && ok "#! scripts 0755, data 0644" || bad "modes: sh=$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh") txt=$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")"
[ -d "$STEAM_ROOT/steamrtarm64/libs" ] && [ "$(readlink "$STEAM_ROOT/steamrtarm64/libs/libcurl.so")" = libcurl.so.4.8.0 ] \
  && ok "'\\' separators become folders, and link entries become symlinks" || bad "libs: $(ls -la "$STEAM_ROOT/steamrtarm64/libs" 2>&1)"
[ -z "$(find "$STEAM_ROOT" -name '*\\*')" ] && ok "no file has a '\\' in its name" || bad "$(find "$STEAM_ROOT" -name '*\\*')"
[ "$(cat "$BETA" 2>/dev/null)" = "$CHAN" ] && ok "package/beta names the pinned channel" || bad "beta: $(cat "$BETA" 2>&1)"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"
grep -q "downloading the Steam Runtime $S1 (now on $RTCHAN" <<<"$ERR" && grep -q "Steam client from $CHAN" <<<"$ERR" \
  && ok "says on stderr what it downloads, and from which channel" || bad "stderr: $ERR"

CASE="channel unchanged"
rm -f "$RT/$S1"/*; rm -rf "$CDN"; mkdir -p "$CDN"   # only the channel pointer is left
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S1/$RUN" ] && [ -z "$ERR" ] \
  && ok "only the channel is read: no download, nothing said" || bad "rc=$RC out=$OUT err=$ERR"

CASE="offline, runtime installed"
mv "$RT" "$RT.off"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S1/$RUN" ] && ok "still prints the installed run, exit 0" || bad "rc=$RC out=$OUT err=$ERR"
[ "$(grep -c . <<<"$ERR")" = 1 ] && grep -q "could not download.*$RTCHAN.txt.*starting with the installed Steam Runtime $S1" <<<"$ERR" \
  && ok "and says so in one line" || bad "stderr: $ERR"
mv "$RT.off" "$RT"

CASE="package/beta"
echo steamdeck_publicbeta >"$BETA"   # the client repointed itself
boot
[ "$RC" = 0 ] && [ "$(cat "$BETA")" = steamdeck_publicbeta ] && ok "left alone when present: the client owns it" || bad "rc=$RC beta=$(cat "$BETA") err=$ERR"
rm -f "$BETA"
boot
[ "$RC" = 0 ] && [ "$(cat "$BETA" 2>/dev/null)" = "$CHAN" ] && ok "written again when missing, without a client download" \
  || bad "rc=$RC beta=$(cat "$BETA" 2>&1) err=$ERR"

CASE="channel move, SHA256SUMS mismatch"
publish "$S2" v2 "$(zeros)"; point "$S2"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S1/$RUN" ] && grep -q "sha256 mismatch" <<<"$ERR" \
  && grep -q "starting with the installed Steam Runtime $S1" <<<"$ERR" \
  && ok "refused, and Steam starts in the old runtime" || bad "rc=$RC out=$OUT err=$ERR"
[ -x "$RT_DIR/$S1/$RUN" ] && [ ! -e "$RT_DIR/$S2" ] \
  && ok "the old runtime is kept, nothing half-unpacked" || bad "runtimes: $(snapshots)"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="channel move"
publish "$S2" v2
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S2/$RUN" ] && grep -q v2 "$OUT" \
  && ok "the new snapshot is installed and used" || bad "rc=$RC out=$OUT err=$ERR"
[ "$(snapshots)" = "$S2" ] && ok "and the old one removed afterwards" || bad "runtimes: $(snapshots)"
grep -q "downloading the Steam Runtime $S2" <<<"$ERR" && ok "says it downloads the new one" || bad "stderr: $ERR"

CASE="channel move while a Steam runs"
publish "$S3" v3; point "$S3"
# What /usr/bin/steam does while its client runs: a shared lock on the snapshot's folder.
( exec 9<"$RT_DIR/$S2"; flock -s 9; exec sleep 60 ) & holder=$!
for _ in $(seq 50); do flock -x -n "$RT_DIR/$S2" true || break; sleep 0.1; done
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S3/$RUN" ] && ok "the new snapshot is installed and used" || bad "rc=$RC out=$OUT err=$ERR"
[ -x "$RT_DIR/$S2/$RUN" ] && grep -q "keeping the Steam Runtime $S2" <<<"$ERR" \
  && ok "the one the running Steam holds is kept, and it says so" || bad "runtimes: $(snapshots) err=$ERR"
kill "$holder"; wait "$holder" 2>/dev/null; holder=""
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S3/$RUN" ] && [ "$(snapshots)" = "$S3" ] && [ -z "$ERR" ] \
  && ok "the next start removes it" || bad "rc=$RC runtimes: $(snapshots) err=$ERR"

CASE="bad snapshot id"
point "../../escaped"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S3/$RUN" ] && grep -q "does not name a Steam Runtime snapshot" <<<"$ERR" \
  && ok "refused; Steam starts in the installed runtime" || bad "rc=$RC out=$OUT err=$ERR"
[ -z "$(find "$T" -name escaped)" ] && [ "$(snapshots)" = "$S3" ] && ok "nothing made of it" || bad "$(find "$T" -name escaped) $(snapshots)"
rm -rf "$DATA"
printf '<html><body>Sign in to the Wi-Fi</body></html>\n' >"$RT/$RTCHAN.txt"   # a captive portal
boot
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "does not name a Steam Runtime snapshot" <<<"$ERR" \
  && ok "with no runtime installed: exit 1, nothing on stdout" || bad "rc=$RC out=$OUT err=$ERR"

CASE="pinned snapshot"
point "$S3"; mv "$RT/$RTCHAN.txt" "$RT/$RTCHAN.txt.off"   # pinned: the channel is not read at all
mkclient "$T/client.zip"; mkmanifest "$T/client.zip"
boot RETROFORGE_STEAM_RUNTIME_SNAPSHOT="$S2"
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S2/$RUN" ] && grep -q v2 "$OUT" && grep -q "Steam Runtime $S2 (pinned" <<<"$ERR" \
  && ok "RETROFORGE_STEAM_RUNTIME_SNAPSHOT installs that snapshot, without the channel" || bad "rc=$RC out=$OUT err=$ERR"
publish "$S1" v1; mkpin "runtime_snapshot: $S1"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S1/$RUN" ] && [ "$(snapshots)" = "$S1" ] \
  && ok "runtime_snapshot: in the pin does the same, and switches to it" || bad "rc=$RC out=$OUT runtimes: $(snapshots) err=$ERR"
boot RETROFORGE_STEAM_RUNTIME_SNAPSHOT="$S2"
[ "$RC" = 0 ] && [ "$OUT" = "$RT_DIR/$S2/$RUN" ] && ok "the environment wins over the pin" || bad "rc=$RC out=$OUT err=$ERR"
boot RETROFORGE_STEAM_RUNTIME_SNAPSHOT="../$S2"
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "not a Steam Runtime snapshot id to pin" <<<"$ERR" \
  && ok "a pin that is not a snapshot id is refused" || bad "rc=$RC out=$OUT err=$ERR"
mv "$RT/$RTCHAN.txt.off" "$RT/$RTCHAN.txt"; mkpin

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
rm -rf "$CDN" "$RT" "$DATA"
boot
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "could not download" <<<"$ERR" && ok "exit 1, says what it could not fetch" || bad "rc=$RC out=$OUT err=$ERR"

# ================================================================================================
# The wrapper, with the bootstrap stubbed: a fake runtime `run` records how it was called. The
# bootstrap's answer is $W/rt/run, so $W stands for the runtime snapshot's folder.
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
# The x86 guest and the DXVK-Sarek block have their own suites (test-steam-x86-guest.sh,
# test-steam-compat-tools.sh). Here they would reach the real helpers, and on a device start real
# downloads into the test's home (1.4 GB; on an SM6115, Proton-CachyOS too): RETROFORGE_STEAM_X86_GUEST=0
# turns the guest off, and RETROFORGE_STEAM_SAREK_CLI names no such file.
WENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME HOME="$W/home" RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap"
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
[ "$WRC" = 0 ] && grep -qx "args: -- $WROOT/steamrtarm64/steam -gamepadui -silent steam://rungameid/42" "$W/call1" \
  && ok "runs steamrtarm64/steam inside the runtime with the plugin's arguments" || bad "rc=$WRC $(cat "$W/call1" 2>&1) $WERR"
grep -qx "cwd: $WROOT" "$W/call1" && ok "from the Steam folder (XDG default)" || bad "$(grep cwd "$W/call1")"
[ "$(readlink "$W/home/.steam/steam")" = "$WROOT" ] && [ "$(readlink "$W/home/.steam/root")" = "$WROOT" ] \
  && ok "~/.steam/steam and ~/.steam/root point at it" || bad "links: $(ls -la "$W/home/.steam")"
grep -qx "dbus: unix:path=$W/mybus" "$W/call1" && ok "our own D-Bus address is kept" || bad "$(grep dbus "$W/call1")"
grep -qx "rt: unset" "$W/call1" && ok "STEAM_RUNTIME is unset" || bad "$(grep rt: "$W/call1")"
[ -z "$WERR" ] && ok "nothing on stderr" || bad "stderr: $WERR"

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
! flock -x -n "$W" true && ok "the runtime snapshot's folder is locked while the client runs" || bad "not locked"
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ -e "$W/term" ] && ok "a TERM to the wrapper reaches the client" || bad "the client never got TERM"
[ "$WRC" = 143 ] && [ "$(cat "$W/count")" = 1 ] && ok "and the wrapper exits with its status, without restarting" \
  || bad "rc=$WRC runs=$(cat "$W/count")"
pid="$(cat "$W/runpid" 2>/dev/null)"
[ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && ok "nothing is left running" || { bad "client still running"; kill "$pid" 2>/dev/null; }
flock -x -w 5 "$W" true && ok "and the lock is gone with them" || bad "still locked"

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
[ "$WRC" = 1 ] && grep -q "the client exited with status 1" <<<"$WERR" && grep -q "pressure-vessel-wrap" <<<"$WERR" \
  && ok "a failed start is said, with where the runtime's own errors are" || bad "rc=$WRC err=$WERR"
wrap 0
! grep -q "exited with status" <<<"$WERR" && ok "a clean exit says nothing" || bad "err=$WERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
