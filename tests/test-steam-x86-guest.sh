#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/steam-x86-guest and its block in /usr/bin/steam: the x86 guest
# (FEX's ArchLinux RootFS) that gives x86 Steam games a GPU driver under Valve's FEX tool.
#
#   tests/test-steam-x86-guest.sh
#
# WHY THIS EXISTS. None of it runs before a player picks an x86 game, and each rule below fails as a
# game with no GPU driver, a 1.4 GB download that never finishes, a dead mount in the home, or a
# `steam` that waits minutes before the client starts:
#   helper:
#   - downloads the pinned image, refuses it unless the sha256 matches, renames it into place, and
#     resumes a download that was cut short (Range) instead of starting over;
#   - one fetch at a time; a bump keeps the old image (and mounts it) until the new one is in place;
#   - mounts with squashfuse, TERM and INT ignored, never twice; replaces a dead mount;
#   - releases only when no `steam` holds the users lock, and an inherited copy of that lock in the
#     helper itself does not count;
#   - `start` leaves a holder outside the caller's process tree that ignores TERM, and releases once
#     the caller is gone, SIGKILL included;
#   - a download that finishes while Steam runs is mounted then, and not when Steam is gone.
#   wrapper:
#   - the client starts without waiting for the download, which goes on detached after `steam` exits;
#   - STEAM_COMPAT_GRAPHICS_PROVIDER and ~/.steam/sdk32, sdk64 are set up;
#   - mounted before the client starts, released when the last `steam` exits, never by a second one;
#   - RETROFORGE_STEAM_X86_GUEST=0 turns all of it off.
# squashfuse and fusermount3 are stubs that edit a fake mount table, as in test-portmaster.sh. FEX's
# server is a local HTTP server that honours Range and can be slowed down or cut off.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-x86-guest"
WRAP="$ROOT/rootfs/overlay/usr/bin/steam"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/x86-guest.pin"
for f in "$HELPER" "$WRAP" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
cleanup() {
  pkill -f "$T/" 2>/dev/null
  pkill -f "$HELPER" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
until_true() {  # until_true <tenths> <command...>: poll for up to <tenths>/10 s
  local n="$1"; shift
  for _ in $(seq "$n"); do "$@" && return 0; sleep 0.1; done
  "$@"
}
quiet() { ! pgrep -f "$HELPER" >/dev/null; }   # no holder or fetch left
settle() { until_true 100 quiet || echo "  (helper processes still running: $(pgrep -af "$HELPER"))"; }

# ---- stubs: squashfuse / fusermount3 on a fake mount table ---------------------------------------
mkdir -p "$T/stub"
cat >"$T/stub/squashfuse" <<EOF
#!/bin/bash
echo "squashfuse \$*" >>"$T/calls"
awk '/^SigIgn:/ { print \$2 }' /proc/\$\$/status >"$T/sigign"
case \$(basename "\$1") in bad*) exit 1 ;; esac
echo "squashfuse \$(printf '%s' "\$2" | sed 's/ /\\\\040/g') fuse.squashfuse ro,nosuid,nodev 0 0" >>"$T/mounts"
echo '{"graphics_provider_v0":{}}' >"\$2/graphics_provider.json"
echo "\$1" >"\$2/.image"
EOF
cat >"$T/stub/fusermount" <<EOF
#!/bin/bash
echo "fusermount \$*" >>"$T/calls"
m="\${!#}"; e="\$(printf '%s' "\$m" | sed 's/ /\\\\040/g')"
M="\$e" awk '\$2 != ENVIRON["M"]' "$T/mounts" >"$T/mounts.new" && mv "$T/mounts.new" "$T/mounts"
rm -f "\$m/graphics_provider.json" "\$m/.image"
EOF
chmod +x "$T/stub/"*
: >"$T/mounts"
export RETROFORGE_MOUNTS="$T/mounts" RETROFORGE_SQUASHFUSE="$T/stub/squashfuse" RETROFORGE_FUSERMOUNT="$T/stub/fusermount"

# ---- FEX's server: Range, and $SRV/.delay (seconds, mid-body) / $SRV/.mode (range|full|cut) ---------
SRV="$T/srv"; mkdir -p "$SRV"
cat >"$T/server.py" <<'PY'
import http.server, os, sys, time
root, portfile, logf = sys.argv[1:4]
def setting(name, default):
    try:
        return open(os.path.join(root, name)).read().strip()
    except OSError:
        return default
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(root, self.path.lstrip("/"))
        rng, mode = self.headers.get("Range"), setting(".mode", "range")
        with open(logf, "a") as f:
            f.write(f"GET {self.path} range={rng}\n")
        if not os.path.isfile(path):
            self.send_error(404)
            return
        data = open(path, "rb").read()
        start = 0
        if rng and mode != "full":
            start = int(rng.split("=")[1].split("-")[0])
            if start >= len(data):
                self.send_response(416)
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        else:
            self.send_response(200)
        body = data[start:]
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        half = len(body) // 2
        self.wfile.write(body[:half])
        self.wfile.flush()
        if mode == "cut":
            self.close_connection = True
            return
        time.sleep(float(setting(".delay", "0")))
        self.wfile.write(body[half:])
    def log_message(self, *args):
        pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(portfile + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
os.rename(portfile + ".tmp", portfile)
srv.serve_forever()
PY
python3 "$T/server.py" "$SRV" "$T/port" "$T/requests" &
until_true 50 test -s "$T/port" || { echo "the test server did not start" >&2; exit 1; }
URL="http://127.0.0.1:$(cat "$T/port")"

mkimage() {  # mkimage <file> <seed>: 300 kB of bytes
  python3 -c 'import random,sys; random.seed(sys.argv[2]); open(sys.argv[1],"wb").write(random.randbytes(300000))' "$1" "$2"
}
PIN="$T/x86-guest.pin"
mkpin() {  # mkpin <version> <file on the server> [sha256]
  printf 'name: fex-rootfs-archlinux\nversion: %s\nurl: %s/%s\nsha256: %s\n' \
    "$1" "$URL" "$2" "${3:-$(sha "$SRV/$2")}" >"$PIN"
}
export RETROFORGE_STEAM_X86_GUEST_PIN="$PIN"

GUEST="$T/data dir/fex-guest"   # a space: /proc/mounts writes it \040
MNT="$GUEST/root"
helper() {  # helper <cmd>: RC, ERR
  RETROFORGE_STEAM_X86_GUEST_DIR="$GUEST" python3 "$HELPER" "$@" 2>"$T/err"; RC=$?
  ERR="$(cat "$T/err")"
}
calls() { grep -c "^$1 " "$T/calls" 2>/dev/null; }
reset_calls() { : >"$T/calls"; : >"$T/requests"; }
in_table() {  # in_table <dir>: is it in the fake mount table (awk -v would decode \040 itself)
  M="$1" awk '{ gsub(/\\040/, " ", $2) } $2 == ENVIRON["M"] { f = 1 } END { exit !f }' "$T/mounts"
}
is_mounted() { in_table "$MNT"; }
not_mounted() { ! is_mounted; }
leftovers() { find "$GUEST" -name '.*.part' 2>/dev/null; }
holdlock() {  # holdlock <file> sh|ex: one process that holds the lock until killed; LOCKPID
  rm -f "$T/locked"
  python3 -c 'import fcntl,sys,time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_SH if sys.argv[2] == "sh" else fcntl.LOCK_EX)
open(sys.argv[3], "w").close(); time.sleep(600)' "$1" "$2" "$T/locked" &
  LOCKPID=$!
  until_true 50 test -e "$T/locked"
}
unlock() { kill "$LOCKPID"; wait "$LOCKPID" 2>/dev/null; }

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "name, version, a dated rootfs.fex-emu.gg url naming it, and a sha256" || bad "the image's x86-guest.pin is malformed"
import re, sys
t = open(sys.argv[1]).read()
f = {k: re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) for k in ("name", "version", "url", "sha256")}
assert all(f.values())
n, v, u, s = (m.group(1) for m in f.values())
assert n == "fex-rootfs-archlinux", n
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", v), v
assert re.fullmatch(r"[0-9a-f]{64}", s)
assert u == f"https://rootfs.fex-emu.gg/ArchLinux/{v}/ArchLinux.sqsh", u
PY

CASE="mount, nothing downloaded"
mkimage "$SRV/v1.sqsh" one; mkpin 2026-01-01 v1.sqsh; reset_calls
helper mount
[ "$RC" = 2 ] && [ "$(calls squashfuse)" = 0 ] && not_mounted && ok "exit 2 (start a fetch), nothing mounted" || bad "rc=$RC err=$ERR"

CASE="fetch"
reset_calls
helper fetch
IMG1="$GUEST/fex-rootfs-archlinux-2026-01-01.sqsh"
[ "$RC" = 0 ] && cmp -s "$IMG1" "$SRV/v1.sqsh" && ok "the image is in place as <name>-<version>.sqsh" || bad "rc=$RC err=$ERR $(ls -A "$GUEST")"
[ -z "$(leftovers)" ] && ok "no partial download left" || bad "left: $(leftovers)"
grep -q "downloading the x86 guest" <<<"$ERR" && grep -q "100% of" <<<"$ERR" && ok "says what it downloads, with progress" || bad "stderr: $ERR"
not_mounted && [ "$(calls squashfuse)" = 0 ] && ok "no steam running: not mounted" || bad "mounted: $(cat "$T/mounts")"

CASE="fetch, already there"
reset_calls
helper fetch
[ "$RC" = 0 ] && [ ! -s "$T/requests" ] && ok "no download at all" || bad "rc=$RC requests: $(cat "$T/requests")"

CASE="mount"
reset_calls
helper mount
[ "$RC" = 0 ] && is_mounted && [ -f "$MNT/graphics_provider.json" ] && ok "mounted on fex-guest/root, graphics_provider.json there" || bad "rc=$RC err=$ERR mounts: $(cat "$T/mounts")"
grep -qxF "squashfuse $IMG1 $MNT" "$T/calls" && ok "squashfuse <image> <root>" || bad "calls: $(cat "$T/calls")"
ign=$((16#$(cat "$T/sigign")))
(( ign & (1 << 14) )) && (( ign & (1 << 1) )) && ok "squashfuse starts with TERM and INT ignored" || bad "SigIgn=$(cat "$T/sigign")"

CASE="mount, already mounted"
reset_calls
helper mount
[ "$RC" = 0 ] && [ "$(calls squashfuse)" = 0 ] && [ "$(grep -c fuse.squashfuse "$T/mounts")" = 1 ] && ok "never mounted twice" || bad "rc=$RC calls: $(cat "$T/calls")"

CASE="release, steam running"
holdlock "$GUEST/.users.lock" sh; reset_calls
helper release
[ "$RC" = 0 ] && is_mounted && [ "$(calls fusermount)" = 0 ] && ok "left mounted while a steam holds the users lock" || bad "rc=$RC calls: $(cat "$T/calls")"
unlock

CASE="release, inherited lock"
# A helper that inherited the only copy of the lock (exec'd from a holder) must not count itself.
( exec 9>>"$GUEST/.users.lock"; flock -s 9; RETROFORGE_STEAM_X86_GUEST_DIR="$GUEST" exec python3 "$HELPER" release ) 2>"$T/err"
not_mounted && grep -qF -- "-u -z $MNT" "$T/calls" && ok "released (lazily): the helper's own inherited copy is closed first" || bad "mounts: $(cat "$T/mounts") calls: $(cat "$T/calls")"

CASE="dead mount"
helper mount; rm -f "$MNT/graphics_provider.json"; reset_calls   # squashfuse killed: ENOTCONN
helper mount
[ "$RC" = 0 ] && [ "$(calls fusermount)" = 1 ] && [ "$(calls squashfuse)" = 1 ] && [ -f "$MNT/graphics_provider.json" ] \
  && ok "released and mounted again" || bad "rc=$RC err=$ERR calls: $(cat "$T/calls")"
grep -q "dead mount" <<<"$ERR" && ok "and said so" || bad "stderr: $ERR"
helper release

CASE="start"
sleep 600 & FAKESTEAM=$!; reset_calls
helper start "$FAKESTEAM"
[ "$RC" = 0 ] && is_mounted && ok "mounted for the caller" || bad "rc=$RC err=$ERR"
HOLD="$(pgrep -f "steam-x86-guest start $FAKESTEAM")"
[ -n "$HOLD" ] && [ "$(ps -o sid= -p "$HOLD" | tr -d ' ')" != "$(ps -o sid= -p $$ | tr -d ' ')" ] \
  && [ "$(ps -o ppid= -p "$HOLD" | tr -d ' ')" != $$ ] && ok "a holder is left, in its own session, not our child" || bad "holder: '$HOLD' $(ps -o pid,ppid,sid,args -p "${HOLD:-1}")"
kill -TERM $HOLD 2>/dev/null; sleep 0.3
[ -n "$HOLD" ] && kill -0 $HOLD 2>/dev/null && is_mounted && ok "it ignores TERM (OGUI's Exit), the mount stays" || bad "the holder died of TERM"
holdlock "$GUEST/.users.lock" sh   # a second steam
kill -KILL "$FAKESTEAM"; wait "$FAKESTEAM" 2>/dev/null
until_true 50 sh -c "! kill -0 $HOLD 2>/dev/null"
! kill -0 $HOLD 2>/dev/null && is_mounted && ok "its steam SIGKILLed: the holder goes, another steam keeps the mount" || bad "holder=$HOLD mounts: $(cat "$T/mounts")"
unlock
sleep 600 & FAKESTEAM=$!
helper start "$FAKESTEAM"
kill -KILL "$FAKESTEAM"; wait "$FAKESTEAM" 2>/dev/null
until_true 50 not_mounted && ok "the last steam SIGKILLed: released" || bad "mounts: $(cat "$T/mounts")"

CASE="fetch, bad checksum"
mkimage "$SRV/v2.sqsh" two; mkpin 2026-02-01 v2.sqsh "$(printf '0%.0s' {1..64})"; reset_calls
helper fetch
[ "$RC" = 1 ] && grep -q "sha256 mismatch" <<<"$ERR" && ok "refused (exit 1)" || bad "rc=$RC err=$ERR"
[ ! -e "$GUEST/fex-rootfs-archlinux-2026-02-01.sqsh" ] && [ -z "$(leftovers)" ] && ok "nothing half-downloaded left" || bad "$(ls -A "$GUEST")"
[ -f "$IMG1" ] && ok "the old image is kept" || bad "old image gone"

CASE="bump, not downloaded yet"
mkpin 2026-02-01 v2.sqsh; reset_calls
helper mount
[ "$RC" = 2 ] && grep -qxF "squashfuse $IMG1 $MNT" "$T/calls" && ok "exit 2, and the old image is mounted meanwhile" || bad "rc=$RC calls: $(cat "$T/calls")"

CASE="download cut short"
echo cut >"$SRV/.mode"; reset_calls
helper fetch
PART="$GUEST/.fex-rootfs-archlinux-2026-02-01.sqsh.part"
[ "$RC" = 1 ] && grep -q "cut short" <<<"$ERR" && [ "$(wc -c <"$PART")" = 150000 ] && ok "exit 1, the 150 kB it got kept for later" || bad "rc=$RC err=$ERR part=$(wc -c <"$PART" 2>&1)"
[ -f "$IMG1" ] && ok "the old image is still there" || bad "old image gone"

CASE="resume"
echo range >"$SRV/.mode"; reset_calls
helper fetch
IMG2="$GUEST/fex-rootfs-archlinux-2026-02-01.sqsh"
grep -q "range=bytes=150000-" "$T/requests" && ok "asks for the rest only (Range: bytes=150000-)" || bad "requests: $(cat "$T/requests")"
[ "$RC" = 0 ] && cmp -s "$IMG2" "$SRV/v2.sqsh" && ok "the joined image is in place" || bad "rc=$RC err=$ERR"
[ ! -e "$IMG1" ] && [ -z "$(leftovers)" ] && ok "the old image is removed once the new one is in place" || bad "$(ls -A "$GUEST")"
is_mounted && ok "a mount of the old image is left to the last steam to release" || bad "unmounted under a running game"
helper release

CASE="server without Range"
mkimage "$SRV/v3.sqsh" three; mkpin 2026-03-01 v3.sqsh
head -c 1000 "$SRV/v1.sqsh" >"$GUEST/.fex-rootfs-archlinux-2026-03-01.sqsh.part"
echo full >"$SRV/.mode"; reset_calls
helper fetch
[ "$RC" = 0 ] && cmp -s "$GUEST/fex-rootfs-archlinux-2026-03-01.sqsh" "$SRV/v3.sqsh" && ok "a 200 to a Range request starts over" || bad "rc=$RC err=$ERR"
echo range >"$SRV/.mode"

CASE="stale partial of another version"
head -c 1000 "$SRV/v1.sqsh" >"$GUEST/.fex-rootfs-archlinux-2026-01-01.sqsh.part"
mkimage "$SRV/v4.sqsh" four; mkpin 2026-04-01 v4.sqsh
helper fetch
[ "$RC" = 0 ] && [ -z "$(leftovers)" ] && [ "$(cd "$GUEST" && ls -- *.sqsh)" = fex-rootfs-archlinux-2026-04-01.sqsh ] \
  && ok "removed; only the pinned image is left" || bad "rc=$RC $(ls -A "$GUEST")"

CASE="one fetch at a time"
mkimage "$SRV/v5.sqsh" five; mkpin 2026-05-01 v5.sqsh; reset_calls
holdlock "$GUEST/.fetch.lock" ex
helper fetch
[ "$RC" = 0 ] && [ ! -s "$T/requests" ] && ok "a second fetch exits 0 at once" || bad "rc=$RC requests: $(cat "$T/requests")"
unlock

CASE="download done while steam runs"
holdlock "$GUEST/.users.lock" sh; reset_calls
helper fetch
[ "$RC" = 0 ] && is_mounted && grep -q "fex-rootfs-archlinux-2026-05-01.sqsh" "$MNT/.image" && ok "mounted as soon as it is in place" || bad "rc=$RC err=$ERR"
unlock
helper release
not_mounted && ok "and released by the last steam" || bad "$(cat "$T/mounts")"

CASE="offline"
mkpin 2026-06-01 missing.sqsh "$(printf 'a%.0s' {1..64})"
helper fetch
[ "$RC" = 1 ] && grep -q "could not download" <<<"$ERR" && ok "exit 1, says what it could not fetch" || bad "rc=$RC err=$ERR"
settle

# ================================================================================================
# The wrapper, with the bootstrap stubbed and the real helper: a fake runtime `run` records how the
# client was started.
W="$T/w"; mkdir -p "$W/rt"
WHOME="$W/home"; WROOT="$WHOME/.local/share/Steam"; WGUEST="$WHOME/.local/share/retroforge/fex-guest"
cat >"$W/rt/run" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$W/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$W/count"
{
  echo "provider: \${STEAM_COMPAT_GRAPHICS_PROVIDER-unset}"
  [ -f "$WGUEST/root/graphics_provider.json" ] && echo "mounted: yes" || echo "mounted: no"
  ls "$WGUEST"/*.sqsh >/dev/null 2>&1 && echo "image: yes" || echo "image: no"
} >"$W/call\$n"
codes=(\$(cat "$W/codes")); c="\${codes[\$((n-1))]:-0}"
if [ "\$c" = S ]; then
  trap 'exit 143' TERM; echo \$\$ >"$W/runpid"
  while :; do sleep 0.1; done
fi
exit "\$c"
EOF
cat >"$W/bootstrap" <<EOF
#!/usr/bin/env bash
mkdir -p "\$RETROFORGE_STEAM_ROOT"; echo "$W/rt/run"
EOF
cat >"$W/helper" <<EOF
#!/usr/bin/env bash
echo "helper \$*" >>"$T/calls"
exec python3 "$HELPER" "\$@"
EOF
chmod +x "$W/rt/run" "$W/bootstrap" "$W/helper"
WENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u RETROFORGE_STEAM_X86_GUEST -u STEAM_COMPAT_GRAPHICS_PROVIDER
      -u RETROFORGE_STEAM_X86_GUEST_DIR HOME="$WHOME" RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap"
      RETROFORGE_STEAM_X86_GUEST_HELPER="$W/helper" RETROFORGE_CPUINFO=/dev/null)
w_mounted() { in_table "$WGUEST/root"; }
w_unmounted() { ! w_mounted; }
wrap() {  # wrap <exit codes of successive runs> [args...]
  echo "$1" >"$W/codes"; shift; rm -f "$W/count" "$W"/call*
  "${WENV[@]}" bash "$WRAP" "$@" >"$W/out" 2>"$W/err"; WRC=$?
  WERR="$(cat "$W/err")"
}
start_bg() {  # start_bg: a wrapper whose client runs until TERMed; WPID
  echo S >"$W/codes"; rm -f "$W/count" "$W"/call* "$W/runpid"
  "${WENV[@]}" bash "$WRAP" steam://rungameid/1 >/dev/null 2>"$W/err" &
  WPID=$!
  until_true 100 test -s "$W/runpid"
}
image_there() { ls "$WGUEST"/*.sqsh >/dev/null 2>&1; }

CASE="wrapper: first start"
mkimage "$SRV/w.sqsh" wrapper; mkpin 2026-07-01 w.sqsh
echo 3 >"$SRV/.delay"; reset_calls
wrap 0 steam://rungameid/42
[ "$WRC" = 0 ] && grep -qx "image: no" "$W/call1" && ok "the client starts at once, before the download is done" || bad "rc=$WRC $(cat "$W/call1" 2>&1) $WERR"
grep -qx "provider: $WGUEST/root/graphics_provider.json" "$W/call1" && ok "STEAM_COMPAT_GRAPHICS_PROVIDER=<guest>/root/graphics_provider.json already" || bad "$(cat "$W/call1")"
[ "$(readlink "$WHOME/.steam/sdk64")" = "$WROOT/linux64" ] && [ "$(readlink "$WHOME/.steam/sdk32")" = "$WROOT/linux32" ] \
  && ok "~/.steam/sdk64 and sdk32 point at the client's linux64 and linux32" || bad "links: $(ls -la "$WHOME/.steam")"
grep -q "^helper start [0-9]" "$T/calls" && ok "steam ran the helper's start with its PID" || bad "calls: $(cat "$T/calls")"
! image_there && ok "steam is gone, the download is not done yet" || bad "the wrapper waited for the download"
until_true 100 image_there && cmp -s "$WGUEST/fex-rootfs-archlinux-2026-07-01.sqsh" "$SRV/w.sqsh" \
  && ok "the detached download finishes after steam exits" || bad "no image: $(ls -A "$WGUEST")"
settle
w_unmounted && ok "and is not mounted with no steam running" || bad "mounts: $(cat "$T/mounts")"
grep -q "downloading the x86 guest" "$W/err" && grep -q "the x86 guest is in place" "$W/err" && ok "its log goes to steam's stderr" || bad "stderr: $(cat "$W/err")"
echo 0 >"$SRV/.delay"

CASE="wrapper: downloaded"
reset_calls
wrap 0 steam://rungameid/42
grep -qx "mounted: yes" "$W/call1" && ok "mounted before the client starts" || bad "$(cat "$W/call1" 2>&1) $WERR"
settle
[ ! -s "$T/requests" ] && ok "no download" || bad "requests: $(cat "$T/requests")"
w_unmounted && grep -qF "fusermount -u -z $WGUEST/root" "$T/calls" && ok "released (lazily) once steam exits" || bad "mounts: $(cat "$T/mounts") calls: $(cat "$T/calls")"

CASE="wrapper: a second steam"
reset_calls
start_bg
w_mounted && ok "the first steam mounted it" || bad "not mounted: $(cat "$W/err")"
wrap 0 steam://rungameid/2
second="$(grep "^helper start" "$T/calls" | tail -1 | cut -d' ' -f3)"
until_true 50 sh -c "! pgrep -f 'steam-x86-guest start $second' >/dev/null"
[ "$(calls squashfuse)" = 1 ] && ok "the second does not mount again" || bad "calls: $(cat "$T/calls")"
w_mounted && ok "and leaves it mounted when it exits" || bad "the second steam unmounted the first one's guest"
kill -TERM "$WPID"; wait "$WPID"
until_true 50 w_unmounted && ok "the first releases it when it exits" || bad "mounts: $(cat "$T/mounts")"
settle

CASE="wrapper: download done while steam runs"
rm -f "$WGUEST"/*.sqsh; mkimage "$SRV/w2.sqsh" wrapper2; mkpin 2026-08-01 w2.sqsh
echo 1 >"$SRV/.delay"; reset_calls
start_bg
grep -qx "mounted: no" "$W/call1" && ok "steam starts with nothing mounted" || bad "$(cat "$W/call1" 2>&1)"
until_true 100 w_mounted && ok "mounted when the download finishes, while steam runs" || bad "mounts: $(cat "$T/mounts") err: $(cat "$W/err")"
kill -TERM "$WPID"; wait "$WPID"
until_true 50 w_unmounted && ok "released when steam exits" || bad "mounts: $(cat "$T/mounts")"
echo 0 >"$SRV/.delay"
settle

CASE="wrapper: dead mount from a killed squashfuse"
RETROFORGE_STEAM_X86_GUEST_DIR="$WGUEST" python3 "$HELPER" mount 2>/dev/null
rm -f "$WGUEST/root/graphics_provider.json"; reset_calls
wrap 0
grep -qx "mounted: yes" "$W/call1" && [ "$(calls squashfuse)" = 1 ] && ok "replaced before the client starts" || bad "$(cat "$W/call1") calls: $(cat "$T/calls")"
until_true 50 w_unmounted && ok "and released after" || bad "mounts: $(cat "$T/mounts")"
settle

CASE="wrapper: opted out"
rm -rf "$WGUEST" "$WHOME/.steam"; reset_calls
echo 0 >"$W/codes"; rm -f "$W/count" "$W"/call*
"${WENV[@]}" RETROFORGE_STEAM_X86_GUEST=0 bash "$WRAP" >/dev/null 2>"$W/err"
grep -qx "provider: unset" "$W/call1" && ok "RETROFORGE_STEAM_X86_GUEST=0: no STEAM_COMPAT_GRAPHICS_PROVIDER" || bad "$(cat "$W/call1")"
[ ! -s "$T/calls" ] && [ ! -e "$WGUEST" ] && ok "no helper run, no download, nothing created" || bad "calls: $(cat "$T/calls") $(ls -A "$WGUEST" 2>&1)"
[ -L "$WHOME/.steam/sdk64" ] && ok "the sdk links are still made" || bad "$(ls -la "$WHOME/.steam")"

CASE="wrapper: ~/.steam/sdk64 is a real folder"
rm -f "$WHOME/.steam/sdk64"; mkdir -p "$WHOME/.steam/sdk64"
wrap 0
[ -d "$WHOME/.steam/sdk64" ] && [ ! -L "$WHOME/.steam/sdk64" ] && grep -q "sdk64 is a directory, not a link; leaving it alone" <<<"$WERR" \
  && ok "left alone, and said so" || bad "$(ls -la "$WHOME/.steam")"
settle

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
