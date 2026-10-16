#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/steamcmd-stub: the ~/.steam/steamcmd/steamcmd.sh that downloads
# Valve's arm64 steamcmd the first time the OpenGamepadUI Steam plugin runs it, and becomes it.
#
#   tests/test-steamcmd-stub.sh
#
# WHY THIS EXISTS. Nothing runs the stub before a player opens Steam, and every rule below fails as
# a Steam library that never loads, with nothing on screen to say why:
#   - the pin in the image names Valve's arm64 tarball (not the x86 one the plugin fetches);
#   - first run: downloads the pinned tarball, unpacks it into its own folder, Valve's steamcmd.sh
#     replaces the stub, and Valve's steamcmd.sh is exec'd in the same process with the plugin's
#     arguments untouched (the plugin talks to that process's pty), its exit status passed back,
#     without the stub's lock;
#   - only the tarball's files are written; an x86 linux32/ and game installs stay;
#   - a sha256 mismatch, no network, a missing pin, or a tarball of the wrong shape: exit non-zero,
#     the stub stays in place, nothing half-done is left, and the next run tries again;
#   - steamcmd.sh is never Valve's before linuxarm64/steamcmd is there, even when a file cannot be
#     put in place;
#   - several copies at once (OGUI restarted the plugin mid-download): one download, and every copy
#     ends up running Valve's steamcmd;
#   - an interrupted download's temporary folder is cleaned up;
#   - run as anything but steamcmd.sh (the read-only image copy), it does nothing.
# Valve's server is replaced by file:// URLs (real curl) and, where timing or failure matters, by a
# fake curl (RETROFORGE_STEAMCMD_CURL).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUB_REAL="$ROOT/rootfs/overlay/usr/lib/retroforge/steamcmd-stub"
INSTALL="$ROOT/rootfs/overlay/usr/lib/retroforge/install-steamcmd"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/steamcmd.pin"
for f in "$STUB_REAL" "$INSTALL" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done
for c in curl flock tar sha256sum; do command -v "$c" >/dev/null || { echo "needs $c" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

mode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
sha()  { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

H="$T/home"
D="$H/.steam/steamcmd"
PIN="$T/steamcmd.pin"
CURL_LOG="$T/curl.log"

# Valve's tarball, as steamcmd_linuxarm64.tar.gz lays it out (strip 0). The stand-in steamcmd.sh
# reports its pid and arguments, whether it still holds the stub's lock, and runs the "binary".
mktarball() {  # mktarball <out.tar.gz> arm64|x86|stub
  python3 - "$1" "$2" "$STUB_REAL" <<'PY'
import io, sys, tarfile
out, kind, stub = sys.argv[1:4]
valve_sh = b'''#!/usr/bin/env bash
# stand-in for Valve's steamcmd.sh: : "${STEAM_PLATFORM:=linuxarm64}"
here="$(cd "$(dirname "$0")" && pwd)"
printf 'steamcmd.sh pid=%s args:' "$$"; printf ' [%s]' "$@"; echo
if flock -n "$here" true; then echo "lock: free"; else echo "lock: held"; fi
exec "$here/linuxarm64/steamcmd" "$@"
'''
binary = b'#!/bin/sh\necho "linuxarm64/steamcmd ran"\nexit "${FAKE_STEAMCMD_RC:-0}"\n'
def add(t, name, data=None, mode=0o644):
    i = tarfile.TarInfo(name); i.mode = mode; i.uname = i.gname = "mikela"; i.uid = 501
    if data is None:
        i.type = tarfile.DIRTYPE; t.addfile(i)
    else:
        i.size = len(data); t.addfile(i, io.BytesIO(data))
with tarfile.open(out, "w:gz") as t:
    if kind == "x86":
        add(t, "linux32/", mode=0o755)
        add(t, "linux32/steamcmd", b"ELF i386\n", 0o755)
        add(t, "steamcmd.sh", b'#!/bin/bash\nSTEAMEXE=linux32/steamcmd\n', 0o755)
    else:
        add(t, "linuxarm64/", mode=0o755)
        add(t, "linuxarm64/crashhandler.so", b"ELF arm64 crashhandler\n", 0o644)
        add(t, "linuxarm64/steamcmd", binary, 0o755)
        add(t, "linuxarm64/steamerrorreporter", b"ELF arm64 reporter\n", 0o755)
        add(t, "steamcmd.sh", open(stub, "rb").read() if kind == "stub" else valve_sh, 0o755)
PY
}
mkpin() {  # mkpin <url> <sha256>
  printf 'name: steamcmd\nversion: 20260727\nurl: %s\nsha256: %s\n' "$1" "$2" >"$PIN"
}
fresh() {  # a player's folder as install-steamcmd leaves it: the stub, plus whatever else is given
  rm -rf "$H"; mkdir -p "$H"
  RETROFORGE_STEAMCMD_STUB="$STUB_REAL" RETROFORGE_STEAMCMD_DIR="$D" python3 "$INSTALL" 2>/dev/null
  : >"$CURL_LOG"
}
# A curl that records each call and can stall or fail. It takes the real one's arguments.
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$$" >>"$CURL_LOG"
out="" url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) url="$1"; shift ;; esac; done
sleep "${FAKE_CURL_SLEEP:-0}"
if [ -n "${FAKE_CURL_FAIL:-}" ]; then echo "curl: (6) Could not resolve host: steamcdn-a.akamaihd.net" >&2; exit 6; fi
cp "${url#file://}" "$out"
EOF
chmod 755 "$T/bin/curl"
export CURL_LOG
CURL=curl
# A stub that execs a stub downloads forever; kill anything still running after 60 s, so a broken
# stub fails the suite instead of hanging it. Not `timeout`: that would put a process between the
# test and the stub, and PID has to be the stub's own.
watchdog() { ( sleep 60; kill -9 "$@" ) >/dev/null 2>&1 & DOG=$!; }
run() {  # run <args...>: the stub as the plugin starts it. PID is the process the plugin would hold.
  HOME="$H" RETROFORGE_STEAMCMD_PIN="$PIN" RETROFORGE_STEAMCMD_CURL="$CURL" \
    "$D/steamcmd.sh" "$@" >"$T/out" 2>"$T/err" & PID=$!
  watchdog "$PID"
  wait "$PID"; RC=$?
  kill "$DOG" 2>/dev/null
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
still_stub() { cmp -s "$STUB_REAL" "$D/steamcmd.sh"; }
leftovers()  { find "$D" -name '.steamcmd-download.*' 2>/dev/null | head -3; }
calls()      { wc -l <"$CURL_LOG" | tr -d ' '; }

mktarball "$T/arm64.tar.gz" arm64
mkdir -p "$T/valve"; tar -xzf "$T/arm64.tar.gz" -C "$T/valve"
GOOD_SHA="$(sha "$T/arm64.tar.gz")"

# =================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "name steamcmd, a date version, Valve's arm64 tarball, a sha256" || bad "the image's steamcmd.pin is malformed"
import re, sys
t = open(sys.argv[1]).read()
f = {k: re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) for k in ("name", "version", "url", "sha256")}
assert all(f.values()), f
n, v, u, s = (m.group(1) for m in f.values())
assert n == "steamcmd" and re.fullmatch(r"20\d{6}", v), (n, v)
assert u == "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linuxarm64.tar.gz", u
assert re.fullmatch(r"[0-9a-f]{64}", s), s
PY
grep -q 'RETROFORGE_STEAMCMD_PIN:-/usr/share/retroforge/steam/steamcmd.pin}' "$STUB_REAL" \
  && ok "the stub reads the pin from where the overlay puts it" || bad "the stub's default pin path is not /usr/share/retroforge/steam/steamcmd.pin"
[ ! -e "$ROOT/packages/steamcmd" ] && ! grep -q '^steamcmd ' "$ROOT/rootfs/manifest.lock" \
  && ok "no steamcmd in the image: no prebuilt pin, no lock row" || bad "packages/steamcmd or its lock row is back"

CASE="first run"
fresh
mkdir -p "$D/linux32" "$D/steamapps/common/Game"
printf 'ELF i386\n' >"$D/linux32/steamcmd"; printf 'game data\n' >"$D/steamapps/common/Game/data"
mkpin "file://$T/arm64.tar.gz" "$GOOD_SHA"
FAKE_STEAMCMD_RC=7 run +@ShutdownOnFailedCommand 0 "two words" "" +quit
[ "$RC" = 7 ] && ok "the exit status is steamcmd's own (7), so the stub is gone from the process" || bad "rc=$RC err=$ERR"
head -n 1 <<<"$OUT" | grep -qxF "steamcmd.sh pid=$PID args: [+@ShutdownOnFailedCommand] [0] [two words] [] [+quit]" \
  && ok "Valve's steamcmd.sh ran in the plugin's own process, arguments untouched (spaces, empty)" || bad "stdout: $OUT"
grep -qx "linuxarm64/steamcmd ran" <<<"$OUT" && ok "and found its binary in place" || bad "stdout: $OUT"
grep -qx "lock: free" <<<"$OUT" && ok "the stub's lock is not passed on to steamcmd" || bad "stdout: $OUT"
cmp -s "$T/valve/steamcmd.sh" "$D/steamcmd.sh" && ok "steamcmd.sh is now Valve's, byte for byte" || bad "steamcmd.sh: $(head -n 3 "$D/steamcmd.sh")"
same=1
for f in linuxarm64/steamcmd linuxarm64/crashhandler.so linuxarm64/steamerrorreporter; do
  cmp -s "$T/valve/$f" "$D/$f" || same=0
done
[ "$same" = 1 ] && ok "every file of the tarball is in place" || bad "linuxarm64: $(ls -la "$D/linuxarm64" 2>&1)"
[ "$(mode "$D/steamcmd.sh")" = 755 ] && [ "$(mode "$D/linuxarm64/steamcmd")" = 755 ] \
  && [ "$(mode "$D/linuxarm64/crashhandler.so")" = 644 ] && ok "modes from the tarball: scripts and binaries 755, the library 644" \
  || bad "modes sh=$(mode "$D/steamcmd.sh") bin=$(mode "$D/linuxarm64/steamcmd") so=$(mode "$D/linuxarm64/crashhandler.so")"
[ -f "$D/linux32/steamcmd" ] && [ -f "$D/steamapps/common/Game/data" ] \
  && ok "nothing else in the folder is touched (linux32/, game installs)" || bad "lost: $(cd "$D" && find . -type f)"
[ -z "$(leftovers)" ] && [ -z "$(find "$D" -maxdepth 1 -name '.*' ! -name . )" ] \
  && ok "no temporary folder and no lock file left" || bad "left: $(cd "$D" && find . -maxdepth 1 -name '.*')"
grep -q "downloading Valve's arm64 steamcmd" <<<"$ERR" && grep -q "in place; starting it" <<<"$ERR" \
  && ok "says what it does on stderr, nothing of its own on stdout" || bad "stderr: $ERR"

CASE="second run"
mkpin "file://$T/nonexistent.tar.gz" "$GOOD_SHA"
CURL="$T/bin/curl" run +quit
[ "$RC" = 0 ] && head -n 1 <<<"$OUT" | grep -qxF "steamcmd.sh pid=$PID args: [+quit]" && [ "$(calls)" = 0 ] \
  && ok "Valve's steamcmd runs directly: no stub, no network" || bad "rc=$RC calls=$(calls) out=$OUT err=$ERR"

CASE="sha256 mismatch"
fresh
mkpin "file://$T/arm64.tar.gz" "$(printf '0%.0s' $(seq 64))"
run +quit
[ "$RC" != 0 ] && grep -q "sha256 mismatch" <<<"$ERR" && ok "refused, exit $RC, and says so" || bad "rc=$RC err=$ERR"
still_stub && ok "the stub stays in place for the next run" || bad "steamcmd.sh changed"
[ ! -e "$D/linuxarm64" ] && [ -z "$(leftovers)" ] && [ -z "$OUT" ] \
  && ok "nothing unpacked, nothing left, nothing run" || bad "linuxarm64=$(ls "$D/linuxarm64" 2>&1) left=$(leftovers) out=$OUT"
grep -q "needs a bump" <<<"$ERR" && ok "the message points at the pin" || bad "stderr: $ERR"
mkpin "file://$T/arm64.tar.gz" "${GOOD_SHA^^}"
run +quit
[ "$RC" = 0 ] && ! still_stub && ok "the next run tries again (an upper-case sha256 in the pin is the same sha256)" || bad "rc=$RC err=$ERR"

CASE="offline"
fresh
mkpin "file://$T/arm64.tar.gz" "$GOOD_SHA"
FAKE_CURL_FAIL=1 CURL="$T/bin/curl" run +quit
[ "$RC" != 0 ] && grep -q "could not download" <<<"$ERR" && grep -q "offline" <<<"$ERR" \
  && ok "no network: exit $RC with a clear message" || bad "rc=$RC err=$ERR"
still_stub && [ ! -e "$D/linuxarm64" ] && [ -z "$(leftovers)" ] && [ -z "$OUT" ] \
  && ok "the stub stays, nothing is left behind" || bad "left=$(leftovers) out=$OUT"
mkpin "file://$T/gone.tar.gz" "$GOOD_SHA"
run +quit
[ "$RC" != 0 ] && still_stub && [ -z "$(leftovers)" ] && ok "real curl, a URL that is not there: the same" || bad "rc=$RC err=$ERR"
mkpin "file://$T/arm64.tar.gz" "$GOOD_SHA"
CURL="$T/bin/curl" run +quit
[ "$RC" = 0 ] && ! still_stub && grep -q "steamcmd.sh pid=$PID" <<<"$OUT" \
  && ok "back online, the next run downloads and runs it" || bad "rc=$RC out=$OUT err=$ERR"

CASE="no pin"
fresh
RETROFORGE_STEAMCMD_PIN="$T/nowhere.pin" HOME="$H" "$D/steamcmd.sh" +quit >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" != 0 ] && grep -q "no pin" "$T/err" && still_stub && ok "an error that names it; the stub stays" || bad "rc=$RC err=$(cat "$T/err")"
printf 'name: steamcmd\nversion: 1\n' >"$PIN"
run +quit
[ "$RC" != 0 ] && grep -q "no url or no sha256" <<<"$ERR" && still_stub && ok "a pin without url/sha256: refused" || bad "rc=$RC err=$ERR"

CASE="wrong tarball"
mktarball "$T/x86.tar.gz" x86
fresh
mkpin "file://$T/x86.tar.gz" "$(sha "$T/x86.tar.gz")"
run +quit
[ "$RC" != 0 ] && grep -q "is not Valve's arm64 steamcmd" <<<"$ERR" && still_stub && [ ! -e "$D/linux32" ] \
  && ok "the x86 tarball, even with a matching sha256: refused before anything is moved" || bad "rc=$RC err=$ERR"
mktarball "$T/loop.tar.gz" stub
mkpin "file://$T/loop.tar.gz" "$(sha "$T/loop.tar.gz")"
run +quit
[ "$RC" != 0 ] && still_stub && [ ! -e "$D/linuxarm64" ] \
  && ok "a tarball whose steamcmd.sh is this stub: refused (it would download forever)" || bad "rc=$RC err=$ERR"
printf 'not a tarball\n' >"$T/junk.tar.gz"
mkpin "file://$T/junk.tar.gz" "$(sha "$T/junk.tar.gz")"
run +quit
[ "$RC" != 0 ] && grep -q "could not unpack" <<<"$ERR" && still_stub && [ -z "$(leftovers)" ] \
  && ok "not a tarball at all: refused, nothing left" || bad "rc=$RC err=$ERR"

CASE="a file cannot be put in place"
fresh
mkpin "file://$T/arm64.tar.gz" "$GOOD_SHA"
mkdir -p "$D/linuxarm64/steamcmd/x"   # a folder where the binary has to go
run +quit
[ "$RC" != 0 ] && still_stub && ok "exit $RC, and steamcmd.sh is still the stub, not Valve's pointing at nothing" || bad "rc=$RC err=$ERR"
[ -z "$(leftovers)" ] && [ -z "$OUT" ] && ok "nothing left, nothing run" || bad "left=$(leftovers) out=$OUT"
rm -rf "$D/linuxarm64/steamcmd"
run +quit
[ "$RC" = 0 ] && ! still_stub && ok "with the folder out of the way, the next run finishes the job" || bad "rc=$RC err=$ERR"

CASE="interrupted download"
fresh
mkdir -p "$D/.steamcmd-download.Ab12Cd/tree"; printf 'half\n' >"$D/.steamcmd-download.Ab12Cd/steamcmd.tar.gz"
run +quit
[ "$RC" = 0 ] && [ -z "$(leftovers)" ] && ok "a power cut's temporary folder is removed by the next run" || bad "rc=$RC left=$(leftovers)"

CASE="not steamcmd.sh"
mkdir -p "$T/image"; cp "$STUB_REAL" "$T/image/steamcmd-stub"
: >"$CURL_LOG"
HOME="$H" RETROFORGE_STEAMCMD_PIN="$PIN" RETROFORGE_STEAMCMD_CURL="$T/bin/curl" \
  "$T/image/steamcmd-stub" +quit >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" != 0 ] && [ "$(calls)" = 0 ] && [ "$(ls "$T/image")" = steamcmd-stub ] \
  && ok "the image's copy run as itself: exit $RC, no download, nothing written beside it" || bad "rc=$RC calls=$(calls) err=$(cat "$T/err")"

CASE="several at once"
fresh
mkpin "file://$T/arm64.tar.gz" "$GOOD_SHA"
pids=()
for i in 1 2 3; do
  HOME="$H" RETROFORGE_STEAMCMD_PIN="$PIN" RETROFORGE_STEAMCMD_CURL="$T/bin/curl" FAKE_CURL_SLEEP=2 \
    "$D/steamcmd.sh" "+run$i" >"$T/out$i" 2>"$T/err$i" & pids+=($!)
done
watchdog "${pids[@]}"
rcs=""; for p in "${pids[@]}"; do wait "$p"; rcs+="$?"; done
kill "$DOG" 2>/dev/null
[ "$rcs" = 000 ] && ok "all three exit 0" || bad "exit statuses $rcs; $(cat "$T"/err[123])"
[ "$(calls)" = 1 ] && ok "one download between them" || bad "$(calls) downloads"
# ("lock: free" is not checked here: a copy still waiting may hold the lock for a moment by then.)
ran=1
for i in 1 2 3; do
  grep -qxF "steamcmd.sh pid=${pids[$((i-1))]} args: [+run$i]" "$T/out$i" || ran=0
done
[ "$ran" = 1 ] && ok "and every one ran Valve's steamcmd.sh in its own process, with its own arguments" \
  || bad "$(for i in 1 2 3; do echo "out$i: $(cat "$T/out$i")"; done)"
cmp -s "$T/valve/steamcmd.sh" "$D/steamcmd.sh" && [ -z "$(leftovers)" ] \
  && ok "Valve's steamcmd.sh in place, nothing left over" || bad "left=$(leftovers)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
