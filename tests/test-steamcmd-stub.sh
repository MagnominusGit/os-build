#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/steamcmd-stub and its helper /usr/lib/retroforge/steamcmd-fetch:
# the ~/.steam/steamcmd/steamcmd.sh that downloads Valve's arm64 steamcmd the first time the
# OpenGamepadUI Steam plugin runs it, and becomes it.
#
#   tests/test-steamcmd-stub.sh
#
# WHY THIS EXISTS. Nothing runs the stub before a player opens Steam, and every rule below fails as
# a Steam library that never loads, with nothing on screen to say why:
#   - the pin in the image names a CHANNEL (Valve's steam_cmd_linuxarm64 manifest and its
#     bootstrapper package), not a file, so a new steamcmd release needs no pin bump;
#   - first run: reads the manifest, downloads the package it names, refuses it unless its sha256 is
#     the manifest's sha2, takes steamcmd.sh (in no package) from Valve's installer tarball only if
#     its sha256 is the pin's script_sha256, and never the tarball's binaries; unpacks Valve's zip
#     ('\' separators, 0666 entries) with execute bits on ELF files and scripts only; Valve's
#     steamcmd.sh replaces the stub and is exec'd in the same process with the plugin's arguments
#     untouched (the plugin talks to that process's pty), its exit status passed back, without the
#     stub's lock;
#   - only the downloaded files are written; an x86 linux32/ and game installs stay;
#   - a sha2 mismatch, a manifest without the package, a changed steamcmd.sh, no network, a missing
#     pin, or a download of the wrong shape: exit non-zero, the stub stays in place, nothing
#     half-done is left, and the next run tries again;
#   - steamcmd.sh is never Valve's before linuxarm64/steamcmd is there, even when a file cannot be
#     put in place;
#   - several copies at once (OGUI restarted the plugin mid-download): one download, and every copy
#     ends up running Valve's steamcmd;
#   - an interrupted download's temporary folder is cleaned up;
#   - run as anything but steamcmd.sh (the read-only image copy), it does nothing.
# Valve's servers are replaced by file:// URLs (real curl) and, where counting, timing or failure
# matters, by a fake curl (RETROFORGE_STEAMCMD_CURL). Valve's ELF files are stand-ins with a real
# ELF header, so this runs on any host.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUB_REAL="$ROOT/rootfs/overlay/usr/lib/retroforge/steamcmd-stub"
FETCH_REAL="$ROOT/rootfs/overlay/usr/lib/retroforge/steamcmd-fetch"
INSTALL="$ROOT/rootfs/overlay/usr/lib/retroforge/install-steamcmd"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/steamcmd.pin"
for f in "$STUB_REAL" "$FETCH_REAL" "$INSTALL" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done
for c in curl flock python3; do command -v "$c" >/dev/null || { echo "needs $c" >&2; exit 1; }; done

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
CDN="$T/cdn"
CURL_LOG="$T/curl.log"
MANIFEST=steam_cmd_linuxarm64
mkdir -p "$CDN"

# ---- Valve's side, as it was on 2026-10-16 -------------------------------------------------------
# The bootstrapper zip holds linuxarm64/steamcmd alone, stored 0666 with a '\' separator here (Valve's
# client zips do both). The installer tarball holds steamcmd.sh plus OLDER binaries, which must never
# be used. The stand-in steamcmd.sh reports its pid and arguments, whether it still holds the stub's
# lock, and whether its binary is in place and executable.
cat >"$T/fixtures.py" <<'PY'
import hashlib, io, sys, tarfile, zipfile

VALVE_SH = b'''#!/usr/bin/env bash
# stand-in for Valve's steamcmd.sh: : "${STEAM_PLATFORM:=linuxarm64}"
here="$(cd "$(dirname "$0")" && pwd)"
printf 'steamcmd.sh pid=%s args:' "$$"; printf ' [%s]' "$@"; echo
if flock -n "$here" true; then echo "lock: free"; else echo "lock: held"; fi
[ -x "$here/linuxarm64/steamcmd" ] && head -c 4 "$here/linuxarm64/steamcmd" | grep -q ELF \\
  && echo "linuxarm64/steamcmd in place: $(tail -n 1 "$here/linuxarm64/steamcmd")"
exit "${FAKE_STEAMCMD_RC:-0}"
'''

def elf(machine, what, cls=2):
    # ELF identification + e_type + e_machine, then a readable payload line.
    return (b"\x7fELF" + bytes([cls, 1, 1, 0]) + bytes(8) + (2).to_bytes(2, "little")
            + machine.to_bytes(2, "little") + b"\n" + what.encode() + b"\n")

def zipfile_(out, entries):
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data, *kind in entries:
            i = zipfile.ZipInfo(name, (2026, 10, 13, 19, 15, 56))
            i.create_system = 0
            if kind and kind[0] == "link":
                i.create_system = 3; i.external_attr = 0o120777 << 16
            elif data is None:
                i.external_attr = (0o40000 << 16) | 0x10; data = b""
            else:
                i.external_attr = 0o100666 << 16
            z.writestr(i, data)

def tarball(out, entries):
    with tarfile.open(out, "w:gz") as t:
        for name, data, mode in entries:
            i = tarfile.TarInfo(name); i.mode = mode; i.uname = i.gname = "mikela"; i.uid = 501
            if data is None:
                i.type = tarfile.DIRTYPE; t.addfile(i)
            else:
                i.size = len(data); t.addfile(i, io.BytesIO(data))

cmd, out = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
if cmd == "zip":
    kind, build = arg, (sys.argv[4] if len(sys.argv) > 4 else "build 1791918946")
    bin_ = elf(183, f"steamcmd {build}")
    if kind == "arm64":
        e = [("linuxarm64\\steamcmd", bin_)]
    elif kind == "full":   # a zip with more in it: a library, a text file, a folder
        e = [("linuxarm64/", None), ("linuxarm64\\steamcmd", bin_),
             ("linuxarm64/crashhandler.so", elf(183, "crashhandler")),
             ("public/", None), ("public\\steambootstrapper_english.txt", b'"Language" "English"\n')]
    elif kind == "with-script":
        e = [("linuxarm64\\steamcmd", bin_), ("steamcmd.sh", VALVE_SH)]
    elif kind == "with-stub":
        e = [("linuxarm64\\steamcmd", bin_), ("steamcmd.sh", open(sys.argv[4], "rb").read())]
    elif kind == "x86-script":   # the 2018 x86 launcher, which runs linux32/steamcmd
        e = [("linuxarm64\\steamcmd", bin_),
             ("steamcmd.sh", b'#!/bin/bash\nSTEAMEXE="${STEAMROOT}/linux32/${STEAMCMD}"\n')]
    elif kind == "x86":
        e = [("linux32\\steamcmd", elf(3, "steamcmd i386", cls=1))]
    elif kind == "x86_64":
        e = [("linuxarm64\\steamcmd", elf(62, "steamcmd x86_64"))]
    elif kind == "escape":
        e = [("linuxarm64\\steamcmd", bin_), ("..\\..\\escaped", b"out of the tree\n")]
    elif kind == "escape-link":
        e = [("linuxarm64\\steamcmd", bin_), ("linuxarm64/up", "../../..", "link")]
    zipfile_(out, e)
elif cmd == "tar":
    old = elf(183, "steamcmd 2026-07-27 tarball build")
    if arg == "good":
        e = [("linuxarm64/", None, 0o755), ("linuxarm64/steamcmd", old, 0o755),
             ("linuxarm64/steamerrorreporter", elf(183, "reporter"), 0o755), ("steamcmd.sh", VALVE_SH, 0o755)]
    elif arg == "republished":   # newer binaries, the same launcher
        e = [("linuxarm64/steamcmd", elf(183, "steamcmd 2026-10-13 tarball build"), 0o755),
             ("steamcmd.sh", VALVE_SH, 0o755)]
    elif arg == "changed":
        e = [("linuxarm64/steamcmd", old, 0o755), ("steamcmd.sh", VALVE_SH + b"# edited by Valve\n", 0o755)]
    elif arg == "no-script":
        e = [("linuxarm64/steamcmd", old, 0o755)]
    tarball(out, e)
elif cmd == "script-sha":
    print(hashlib.sha256(VALVE_SH).hexdigest())
elif cmd == "script":
    open(out, "wb").write(VALVE_SH)
PY
fx() { python3 "$T/fixtures.py" "$@"; }

# publish <zip>: put it on the fake CDN under Valve's content-addressed name; prints that name.
publish() {
  local name
  name="steamcmd_linuxarm64.zip.$(python3 -c 'import hashlib,sys; print(hashlib.sha1(open(sys.argv[1],"rb").read()).hexdigest())' "$1")"
  cp "$1" "$CDN/$name"; echo "$name"
}
# manifest <file> <sha2> [no-package|no-sha2]: Valve's VDF, with neighbouring packages that also carry
# a file and a sha2 (a parser that takes the first sha2 it sees installs the wrong thing).
manifest() {
  local file="$1" sha2="$2" how="${3:-}" boot
  boot="$(printf '\t"steamcmd_linuxarm64"\n\t{\n\t\t"file"\t\t"%s"\n\t\t"size"\t\t"3690466"\n' "$file")"
  [ "$how" = no-sha2 ] || boot+="$(printf '\n\t\t"sha2"\t\t"%s"' "$sha2")"
  boot+="$(printf '\n\t\t"zipvz"\t\t"steamcmd_linuxarm64.zip.vz.67cd5383e927e8ce9faf5f45352c690f013c7753_2675944"\n\t\t"sha2vz"\t\t"6d5d48fa02b7dcb496fcd607c6df71506818d38137257ffe5b9addeb311f4ec2"\n\t\t"IsBootstrapperPackage"\t\t"1"\n\t}')"
  [ "$how" = no-package ] && boot=""
  {
    printf '"linuxarm64"\n{\n\t"version"\t\t"1791918946"\n'
    printf '\t"steamcmd_bins_linuxarm64"\n\t{\n\t\t"file"\t\t"steamcmd_bins_linuxarm64.zip.a06259cdb1e10549b3cc98d5313a80a70d9bbcc7"\n'
    printf '\t\t"size"\t\t"17124550"\n\t\t"sha2"\t\t"584fb5a73ec5b7819216ebe958b57113a52b5165a72de923791bd8bb2b231c07"\n\t}\n'
    [ -n "$boot" ] && printf '%s\n' "$boot"
    printf '\t"steamcmd_public_all"\n\t{\n\t\t"file"\t\t"steamcmd_public_all.zip.5a294ec531ae00e2fd9f94c280007cd605076692"\n'
    printf '\t\t"size"\t\t"60349"\n\t\t"sha2"\t\t"dfa7b42940635dd870337eeb9bd1084ff88ddd25c94c3fecf2a5d7262f993d75"\n\t}\n}\n'
    printf '"kvsignatures"\n{\n\t"linuxarm64"\t\t"336cc0a1"\n}\n'
  } >"$CDN/$MANIFEST"
}
# release <zip>: publish it and point the manifest at it, as Valve does on a release.
release() { local f; f="$(publish "$1")"; manifest "$f" "$(sha "$1")"; RELEASED="$f"; }
mkpin() {  # mkpin [extra lines]: the channel pin, pointing at the fake CDN
  { printf 'name: steamcmd\ncdn: file://%s\nmanifest: %s\npackage: steamcmd_linuxarm64\n' "$CDN" "$MANIFEST"
    printf 'installer: file://%s/installer.tar.gz\nscript_sha256: %s\n' "$T" "$SCRIPT_SHA"
    [ $# -gt 0 ] && printf '%s\n' "$@"; } >"$PIN"
}
fresh() {  # a player's folder as install-steamcmd leaves it: the stub, plus whatever else is given
  rm -rf "$H"; mkdir -p "$H"
  RETROFORGE_STEAMCMD_STUB="$STUB_REAL" RETROFORGE_STEAMCMD_DIR="$D" python3 "$INSTALL" 2>/dev/null
  : >"$CURL_LOG"
}
# A curl that records each call (its URL, and its arguments) and can stall or fail, for every URL or
# for those matching FAKE_CURL_FAIL_MATCH. It takes the real one's arguments.
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
all="$*" out="" url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) url="$1"; shift ;; esac; done
echo "$url" >>"$CURL_LOG"; echo "$all" >>"$CURL_LOG.args"
sleep "${FAKE_CURL_SLEEP:-0}"
if [ -n "${FAKE_CURL_FAIL:-}" ] || { [ -n "${FAKE_CURL_FAIL_MATCH:-}" ] && [[ "$url" == *"$FAKE_CURL_FAIL_MATCH"* ]]; }; then
  echo "curl: (6) Could not resolve host: media.steampowered.com" >&2; exit 6
fi
cp "${url#file://}" "$out" 2>/dev/null || { echo "curl: (37) Couldn't open file ${url#file://}" >&2; exit 37; }
EOF
chmod 755 "$T/bin/curl"
export CURL_LOG
CURL=curl
# A stub that execs a stub downloads forever; kill anything still running after 60 s, so a broken
# stub fails the suite instead of hanging it. Not `timeout`: that would put a process between the
# test and the stub, and PID has to be the stub's own.
watchdog() { ( sleep 60; kill -9 "$@" ) >/dev/null 2>&1 & DOG=$!; }
run() {  # run <args...>: the stub as the plugin starts it. PID is the process the plugin would hold.
  HOME="$H" RETROFORGE_STEAMCMD_PIN="$PIN" RETROFORGE_STEAMCMD_FETCH="$FETCH_REAL" \
    RETROFORGE_STEAMCMD_CURL="$CURL" "$D/steamcmd.sh" "$@" >"$T/out" 2>"$T/err" & PID=$!
  watchdog "$PID"
  wait "$PID"; RC=$?
  kill "$DOG" 2>/dev/null
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
still_stub() { cmp -s "$STUB_REAL" "$D/steamcmd.sh"; }
leftovers()  { find "$D" -name '.steamcmd-download.*' 2>/dev/null | head -3; }
calls()      { wc -l <"$CURL_LOG" | tr -d ' '; }
fetched()    { grep -c -- "$1" "$CURL_LOG"; }   # fetched <pattern>: how many calls were for it
nothing_placed() { still_stub && [ ! -e "$D/linuxarm64" ] && [ -z "$(leftovers)" ] && [ -z "$OUT" ]; }

SCRIPT_SHA="$(fx script-sha x)"
fx script "$T/valve-steamcmd.sh"
fx tar "$T/installer.tar.gz" good
fx zip "$T/full.zip" full
release "$T/full.zip"; FULL_FILE="$RELEASED"
mkpin

# =================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "a channel: Valve's steam_cmd_linuxarm64 manifest and its bootstrapper package, no file" || bad "the image's steamcmd.pin is not the channel pin"
import re, sys
t = open(sys.argv[1]).read()
f = lambda k: (re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) or [None, None])[1]
assert f("name") == "steamcmd", f("name")
assert f("cdn") == "https://media.steampowered.com/client", f("cdn")
assert f("manifest") == "steam_cmd_linuxarm64", f("manifest")
assert f("package") == "steamcmd_linuxarm64", f("package")
for k in ("url", "sha256", "version", "fixed_file", "fixed_sha256"):
    assert f(k) is None, f"{k}: set ({f(k)}); a release pin names no fixed file"
PY
python3 - "$PIN_REAL" <<'PY' && ok "steamcmd.sh from Valve's arm64 installer tarball, checked by its own sha256" || bad "installer/script_sha256 malformed"
import re, sys
t = open(sys.argv[1]).read()
f = lambda k: (re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) or [None, None])[1]
assert f("installer") == "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linuxarm64.tar.gz", f("installer")
assert re.fullmatch(r"[0-9a-f]{64}", f("script_sha256") or ""), f("script_sha256")
PY
grep -q '^#fixed_file: steamcmd_linuxarm64\.zip\.[0-9a-f]\{40\}$' "$PIN_REAL" && grep -q '^#fixed_sha256: [0-9a-f]\{64\}$' "$PIN_REAL" \
  && ok "the fixed override is there for a reproducible install, commented out" || bad "no commented fixed_file/fixed_sha256 example"
grep -q 'RETROFORGE_STEAMCMD_PIN:-/usr/share/retroforge/steam/steamcmd.pin}' "$STUB_REAL" \
  && grep -q 'RETROFORGE_STEAMCMD_FETCH:-/usr/lib/retroforge/steamcmd-fetch}' "$STUB_REAL" \
  && ok "the stub reads the pin and runs the helper from where the overlay puts them" || bad "the stub's default paths are wrong"
[ -x "$FETCH_REAL" ] && head -n 1 "$FETCH_REAL" | grep -qx '#!/usr/bin/env python3' \
  && python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$FETCH_REAL" \
  && ok "the helper is executable Python that compiles" || bad "steamcmd-fetch: mode $(mode "$FETCH_REAL")"
[ ! -e "$ROOT/packages/steamcmd" ] && ! grep -q '^steamcmd ' "$ROOT/rootfs/manifest.lock" \
  && ok "no steamcmd in the image: no prebuilt pin, no lock row" || bad "packages/steamcmd or its lock row is back"

CASE="first run"
fresh
mkdir -p "$D/linux32" "$D/steamapps/common/Game"
printf 'ELF i386\n' >"$D/linux32/steamcmd"; printf 'game data\n' >"$D/steamapps/common/Game/data"
FAKE_STEAMCMD_RC=7 run +@ShutdownOnFailedCommand 0 "two words" "" +quit
[ "$RC" = 7 ] && ok "the exit status is steamcmd's own (7), so the stub is gone from the process" || bad "rc=$RC err=$ERR"
head -n 1 <<<"$OUT" | grep -qxF "steamcmd.sh pid=$PID args: [+@ShutdownOnFailedCommand] [0] [two words] [] [+quit]" \
  && ok "Valve's steamcmd.sh ran in the plugin's own process, arguments untouched (spaces, empty)" || bad "stdout: $OUT"
grep -qx "linuxarm64/steamcmd in place: steamcmd build 1791918946" <<<"$OUT" \
  && ok "and found the manifest's binary in place, executable" || bad "stdout: $OUT"
grep -qx "lock: free" <<<"$OUT" && ok "the stub's lock is not passed on to steamcmd" || bad "stdout: $OUT"
cmp -s "$T/valve-steamcmd.sh" "$D/steamcmd.sh" && ok "steamcmd.sh is Valve's from the tarball, byte for byte" || bad "steamcmd.sh: $(head -n 3 "$D/steamcmd.sh")"
[ ! -e "$D/linuxarm64/steamerrorreporter" ] && ! grep -q "tarball build" "$D/linuxarm64/steamcmd" \
  && ok "none of the tarball's (older) binaries are used" || bad "linuxarm64: $(ls "$D/linuxarm64")"
[ -f "$D/linuxarm64/steamcmd" ] && [ -f "$D/linuxarm64/crashhandler.so" ] && [ -f "$D/public/steambootstrapper_english.txt" ] \
  && [ -z "$(find "$D" -name '*\\*')" ] && ok "every file of the zip is in place, '\\' read as a separator" || bad "files: $(cd "$D" && find . -type f)"
[ "$(mode "$D/steamcmd.sh")" = 755 ] && [ "$(mode "$D/linuxarm64/steamcmd")" = 755 ] \
  && [ "$(mode "$D/linuxarm64/crashhandler.so")" = 755 ] && [ "$(mode "$D/public/steambootstrapper_english.txt")" = 644 ] \
  && ok "zip entries stored 0666: ELF files and the script 755, data 644" \
  || bad "modes sh=$(mode "$D/steamcmd.sh") bin=$(mode "$D/linuxarm64/steamcmd") so=$(mode "$D/linuxarm64/crashhandler.so") txt=$(mode "$D/public/steambootstrapper_english.txt")"
[ -f "$D/linux32/steamcmd" ] && [ -f "$D/steamapps/common/Game/data" ] \
  && ok "nothing else in the folder is touched (linux32/, game installs)" || bad "lost: $(cd "$D" && find . -type f)"
[ -z "$(leftovers)" ] && [ -z "$(find "$D" -maxdepth 1 -name '.*' ! -name . )" ] \
  && ok "no temporary folder and no lock file left" || bad "left: $(cd "$D" && find . -maxdepth 1 -name '.*')"
grep -qF "downloading Valve's arm64 steamcmd ($MANIFEST version 1791918946: $FULL_FILE)" <<<"$ERR" \
  && grep -q "in place; starting it" <<<"$ERR" \
  && ok "says which release it resolved on stderr, nothing of its own on stdout" || bad "stderr: $ERR"

CASE="second run"
: >"$CURL_LOG"
mv "$CDN" "$T/cdn.away"
CURL="$T/bin/curl" run +quit
mv "$T/cdn.away" "$CDN"
[ "$RC" = 0 ] && head -n 1 <<<"$OUT" | grep -qxF "steamcmd.sh pid=$PID args: [+quit]" && [ "$(calls)" = 0 ] \
  && ok "Valve's steamcmd runs directly: no stub, no network" || bad "rc=$RC calls=$(calls) out=$OUT err=$ERR"

CASE="a new release"
# Valve releases: a new package under a new name, the manifest points at it, and the installer
# tarball is republished with newer binaries but the same steamcmd.sh. The SAME pin installs it.
fx zip "$T/next.zip" arm64 "build 1792000000"
release "$T/next.zip"
old_installer="$(sha "$T/installer.tar.gz")"; fx tar "$T/installer.tar.gz" republished
fresh
: >"$CURL_LOG.args"
CURL="$T/bin/curl" run +quit
[ "$RC" = 0 ] && grep -qx "linuxarm64/steamcmd in place: steamcmd build 1792000000" <<<"$OUT" \
  && [ "$(sha "$T/installer.tar.gz")" != "$old_installer" ] && cmp -s "$T/valve-steamcmd.sh" "$D/steamcmd.sh" \
  && ok "the unchanged pin installs the new build from a republished installer: nothing to bump" || bad "rc=$RC out=$OUT err=$ERR"
[ "$(calls)" = 3 ] && [ "$(fetched "/$MANIFEST\$")" = 1 ] && [ "$(fetched "$RELEASED\$")" = 1 ] && [ "$(fetched installer.tar.gz)" = 1 ] \
  && ok "three downloads: the manifest, the package it names, the installer" || bad "calls: $(cat "$CURL_LOG")"
! grep -qv -- '--proto-redir =https' "$CURL_LOG.args" && ok "every download allows https redirects only" || bad "args: $(cat "$CURL_LOG.args")"
release "$T/full.zip"; fx tar "$T/installer.tar.gz" good

CASE="sha2 mismatch"
fresh
manifest "$FULL_FILE" "$(printf '0%.0s' $(seq 64))"
CURL="$T/bin/curl" run +quit
[ "$RC" != 0 ] && grep -q "sha256 mismatch for $FULL_FILE" <<<"$ERR" && grep -q "its sha2 in $MANIFEST is" <<<"$ERR" \
  && ok "a package whose sha256 is not the manifest's sha2: refused, exit $RC, and says so" || bad "rc=$RC err=$ERR"
nothing_placed && ok "the stub stays; nothing unpacked, nothing left, nothing run" || bad "linuxarm64=$(ls "$D/linuxarm64" 2>&1) left=$(leftovers) out=$OUT"
[ "$(fetched installer.tar.gz)" = 0 ] && ok "and the installer is not even downloaded" || bad "calls: $(cat "$CURL_LOG")"
manifest "$FULL_FILE" "$(sha "$T/full.zip" | tr a-f A-F)"
run +quit
[ "$RC" = 0 ] && ! still_stub && ok "the next run tries again (an upper-case sha2 is the same sha256)" || bad "rc=$RC err=$ERR"

CASE="manifest without the package"
fresh
manifest "$FULL_FILE" "$(sha "$T/full.zip")" no-package
CURL="$T/bin/curl" run +quit
[ "$RC" != 0 ] && grep -q "lists no steamcmd_linuxarm64" <<<"$ERR" && nothing_placed && [ "$(calls)" = 1 ] \
  && ok "refused after the manifest alone; the neighbours' files and sha2s are not taken instead" || bad "rc=$RC calls=$(calls) err=$ERR"
manifest "$FULL_FILE" "$(sha "$T/full.zip")" no-sha2
: >"$CURL_LOG"
CURL="$T/bin/curl" run +quit
[ "$RC" != 0 ] && grep -q "lists no steamcmd_linuxarm64 with a file and a sha2" <<<"$ERR" && nothing_placed && [ "$(calls)" = 1 ] \
  && ok "the package without a sha2: refused, nothing downloaded unchecked (not even its sha2vz)" || bad "rc=$RC calls=$(calls) err=$ERR"
printf 'not a manifest\n' >"$CDN/$MANIFEST"
run +quit
[ "$RC" != 0 ] && nothing_placed && ok "a manifest that is not one: the same" || bad "rc=$RC err=$ERR"
release "$T/full.zip"

CASE="steamcmd.sh changed"
fx tar "$T/installer.tar.gz" changed
fresh
run +quit
[ "$RC" != 0 ] && grep -q "Valve's steamcmd.sh has changed" <<<"$ERR" && grep -q "script_sha256" <<<"$ERR" \
  && ok "Valve edited the launcher: refused, and the message names the pin field to bump" || bad "rc=$RC err=$ERR"
nothing_placed && ok "the stub stays; the verified binary is not moved in either" || bad "linuxarm64=$(ls "$D/linuxarm64" 2>&1) left=$(leftovers)"
fx tar "$T/installer.tar.gz" no-script
run +quit
[ "$RC" != 0 ] && grep -q "has no steamcmd.sh" <<<"$ERR" && nothing_placed && ok "a tarball without steamcmd.sh: refused" || bad "rc=$RC err=$ERR"
printf 'not a tarball\n' >"$T/installer.tar.gz"
run +quit
[ "$RC" != 0 ] && grep -q "could not read Valve's installer tarball" <<<"$ERR" && nothing_placed && ok "not a tarball at all: refused" || bad "rc=$RC err=$ERR"
fx tar "$T/installer.tar.gz" good

CASE="the zip carries steamcmd.sh"
fx zip "$T/with-script.zip" with-script
release "$T/with-script.zip"
fx tar "$T/installer.tar.gz" changed   # would be refused, if it were used
fresh
CURL="$T/bin/curl" run +quit
[ "$RC" = 0 ] && cmp -s "$T/valve-steamcmd.sh" "$D/steamcmd.sh" && [ "$(mode "$D/steamcmd.sh")" = 755 ] \
  && ok "the package's own steamcmd.sh (vouched for by the manifest) is used, made executable" || bad "rc=$RC err=$ERR"
[ "$(fetched installer.tar.gz)" = 0 ] && ok "and the installer tarball is not downloaded" || bad "calls: $(cat "$CURL_LOG")"
fx tar "$T/installer.tar.gz" good
release "$T/full.zip"

CASE="offline"
fresh
FAKE_CURL_FAIL=1 CURL="$T/bin/curl" run +quit
[ "$RC" != 0 ] && grep -q "could not download file://$CDN/$MANIFEST (offline?)" <<<"$ERR" \
  && ok "no network: exit $RC with a clear message" || bad "rc=$RC err=$ERR"
nothing_placed && ok "the stub stays, nothing is left behind" || bad "left=$(leftovers) out=$OUT"
FAKE_CURL_FAIL_MATCH=installer CURL="$T/bin/curl" run +quit
[ "$RC" != 0 ] && grep -q "could not download file://$T/installer.tar.gz" <<<"$ERR" && nothing_placed \
  && ok "the CDN reachable but the installer host not: the downloaded binary is not moved in alone" || bad "rc=$RC err=$ERR"
CDN="$T/nowhere" mkpin
run +quit
[ "$RC" != 0 ] && nothing_placed && ok "real curl, a CDN that is not there: the same" || bad "rc=$RC err=$ERR"
mkpin
CURL="$T/bin/curl" run +quit
[ "$RC" = 0 ] && ! still_stub && grep -q "steamcmd.sh pid=$PID" <<<"$OUT" \
  && ok "back online, the next run downloads and runs it" || bad "rc=$RC out=$OUT err=$ERR"

CASE="pin"
fresh
RETROFORGE_STEAMCMD_PIN="$T/nowhere.pin" RETROFORGE_STEAMCMD_FETCH="$FETCH_REAL" HOME="$H" "$D/steamcmd.sh" +quit >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" != 0 ] && grep -q "no pin at $T/nowhere.pin" "$T/err" && still_stub && ok "no pin: an error that names it; the stub stays" || bad "rc=$RC err=$(cat "$T/err")"
printf 'name: steamcmd\nurl: file://%s/x.tar.gz\nsha256: %s\n' "$T" "$SCRIPT_SHA" >"$PIN"
run +quit
[ "$RC" != 0 ] && grep -q "needs cdn, manifest, package, installer, script_sha256" <<<"$ERR" && nothing_placed \
  && ok "an old file pin (url + sha256): refused, with the fields it needs" || bad "rc=$RC err=$ERR"
mkpin "fixed_file: $FULL_FILE"
run +quit
[ "$RC" != 0 ] && grep -q "fixed_file and fixed_sha256 go together" <<<"$ERR" && nothing_placed \
  && ok "half a fixed override: refused" || bad "rc=$RC err=$ERR"

CASE="fixed override"
fresh
mkpin "fixed_file: $FULL_FILE" "fixed_sha256: $(sha "$T/full.zip")"
fx zip "$T/next.zip" arm64 "build 1792000000"; release "$T/next.zip"   # the channel has moved on
CURL="$T/bin/curl" run +quit
[ "$RC" = 0 ] && grep -qx "linuxarm64/steamcmd in place: steamcmd build 1791918946" <<<"$OUT" \
  && ok "fixed_file + fixed_sha256 install that file, not what the channel serves now" || bad "rc=$RC out=$OUT err=$ERR"
[ "$(fetched "/$MANIFEST\$")" = 0 ] && grep -qF "fixed in $PIN" <<<"$ERR" && ok "without reading the manifest, and it says so" || bad "calls: $(cat "$CURL_LOG")"
fresh
mkpin "fixed_file: $FULL_FILE" "fixed_sha256: $(sha "$T/next.zip")"
run +quit
[ "$RC" != 0 ] && grep -q "sha256 mismatch for $FULL_FILE" <<<"$ERR" && grep -q "the pin's fixed_sha256 is" <<<"$ERR" && nothing_placed \
  && ok "a fixed file whose sha256 is not fixed_sha256: refused" || bad "rc=$RC err=$ERR"
mkpin "fixed_file: ../../etc/passwd" "fixed_sha256: $(sha "$T/full.zip")"
run +quit
[ "$RC" != 0 ] && grep -q "is not a package file name" <<<"$ERR" && nothing_placed && ok "a file name with a path in it: refused" || bad "rc=$RC err=$ERR"
mkpin; release "$T/full.zip"

CASE="wrong package"
refuse() {  # refuse <zip kind> <what> <message>: the manifest names a zip of that kind
  fx zip "$T/wrong.zip" "$1" "${4:-}"; release "$T/wrong.zip"; fresh; run +quit
  [ "$RC" != 0 ] && grep -q "$3" <<<"$ERR" && nothing_placed && [ ! -e "$H/escaped" ] && [ ! -e "$H/.steam/escaped" ] \
    && ok "$2: refused before anything is moved" || bad "$2: rc=$RC err=$ERR files=$(cd "$H" && find . -type f)"
}
refuse x86 "Valve's x86 bootstrapper (linux32/steamcmd)" "holds no arm64 linuxarm64/steamcmd"
refuse x86_64 "an x86_64 ELF at linuxarm64/steamcmd" "holds no arm64 linuxarm64/steamcmd"
refuse with-stub "a package whose steamcmd.sh is this stub (it would download forever)" "is RetroForge's stub" "$STUB_REAL"
refuse x86-script "a package whose steamcmd.sh is the x86 launcher (it would run linux32/)" "does not pick linuxarm64"
refuse escape "a path that leaves the folder (..\\..\\escaped)" "unsafe path"
refuse escape-link "a symlink that leaves the folder" "unsafe symlink"
printf 'not a zip\n' >"$T/junk.zip"; release "$T/junk.zip"; fresh; run +quit
[ "$RC" != 0 ] && grep -q "could not unpack" <<<"$ERR" && nothing_placed && ok "not a zip at all, sha2 matching: refused, nothing left" || bad "rc=$RC err=$ERR"
release "$T/full.zip"

CASE="a file cannot be put in place"
fresh
mkdir -p "$D/linuxarm64/steamcmd/x"   # a folder where the binary has to go
run +quit
[ "$RC" != 0 ] && still_stub && ok "exit $RC, and steamcmd.sh is still the stub, not Valve's pointing at nothing" || bad "rc=$RC err=$ERR"
[ -z "$(leftovers)" ] && [ -z "$OUT" ] && ok "nothing left, nothing run" || bad "left=$(leftovers) out=$OUT"
rm -rf "$D/linuxarm64/steamcmd"
run +quit
[ "$RC" = 0 ] && ! still_stub && ok "with the folder out of the way, the next run finishes the job" || bad "rc=$RC err=$ERR"

CASE="interrupted download"
fresh
mkdir -p "$D/.steamcmd-download.Ab12Cd/tree"; printf 'half\n' >"$D/.steamcmd-download.Ab12Cd/package.zip"
run +quit
[ "$RC" = 0 ] && [ -z "$(leftovers)" ] && ok "a power cut's temporary folder is removed by the next run" || bad "rc=$RC left=$(leftovers)"

CASE="no helper"
fresh
RETROFORGE_STEAMCMD_FETCH="$T/nowhere" RETROFORGE_STEAMCMD_PIN="$PIN" HOME="$H" "$D/steamcmd.sh" +quit >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" != 0 ] && grep -q "no $T/nowhere" "$T/err" && still_stub && [ -z "$(leftovers)" ] \
  && ok "the image's helper missing: an error that names it; the stub stays" || bad "rc=$RC err=$(cat "$T/err")"

CASE="not steamcmd.sh"
mkdir -p "$T/image"; cp "$STUB_REAL" "$T/image/steamcmd-stub"
: >"$CURL_LOG"
HOME="$H" RETROFORGE_STEAMCMD_PIN="$PIN" RETROFORGE_STEAMCMD_FETCH="$FETCH_REAL" RETROFORGE_STEAMCMD_CURL="$T/bin/curl" \
  "$T/image/steamcmd-stub" +quit >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" != 0 ] && [ "$(calls)" = 0 ] && [ "$(ls "$T/image")" = steamcmd-stub ] \
  && ok "the image's copy run as itself: exit $RC, no download, nothing written beside it" || bad "rc=$RC calls=$(calls) err=$(cat "$T/err")"

CASE="several at once"
fresh
pids=()
for i in 1 2 3; do
  HOME="$H" RETROFORGE_STEAMCMD_PIN="$PIN" RETROFORGE_STEAMCMD_FETCH="$FETCH_REAL" RETROFORGE_STEAMCMD_CURL="$T/bin/curl" \
    FAKE_CURL_SLEEP=1 "$D/steamcmd.sh" "+run$i" >"$T/out$i" 2>"$T/err$i" & pids+=($!)
done
watchdog "${pids[@]}"
rcs=""; for p in "${pids[@]}"; do wait "$p"; rcs+="$?"; done
kill "$DOG" 2>/dev/null
[ "$rcs" = 000 ] && ok "all three exit 0" || bad "exit statuses $rcs; $(cat "$T"/err[123])"
[ "$(fetched "/$MANIFEST\$")" = 1 ] && [ "$(calls)" = 3 ] && ok "one resolution and one download between them" || bad "calls: $(cat "$CURL_LOG")"
# ("lock: free" is not checked here: a copy still waiting may hold the lock for a moment by then.)
ran=1
for i in 1 2 3; do
  grep -qxF "steamcmd.sh pid=${pids[$((i-1))]} args: [+run$i]" "$T/out$i" || ran=0
done
[ "$ran" = 1 ] && ok "and every one ran Valve's steamcmd.sh in its own process, with its own arguments" \
  || bad "$(for i in 1 2 3; do echo "out$i: $(cat "$T/out$i")"; done)"
cmp -s "$T/valve-steamcmd.sh" "$D/steamcmd.sh" && [ -z "$(leftovers)" ] \
  && ok "Valve's steamcmd.sh in place, nothing left over" || bad "left=$(leftovers)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
