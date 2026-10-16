#!/usr/bin/env bash
# Offline test for the DXVK-Sarek setting: /usr/bin/retroforge-steam-sarek (the setting),
# /usr/lib/retroforge/steam-compat-tools (Proton-CachyOS arm64 as a Steam compatibility tool) and the
# block of /usr/bin/steam that applies it.
#
#   tests/test-steam-compat-tools.sh
#
# WHY THIS EXISTS. Nothing here runs before a player picks a Windows game, and each rule below fails
# as a game without a working DXVK, a half tool Steam lists, a setting that does not stick, or a
# player's own tool gone:
#   setting (retroforge-steam-sarek):
#   - never set: on for SoC class SM6115, off elsewhere and on an unknown board;
#   - the player's DXVK_SAREK=on|off in ~/.config/retroforge/steam.conf wins over that (last line;
#     anything else ignored), and RETROFORGE_STEAM_SAREK=on|off over both;
#   - on/off rewrites that one line and keeps the rest; off also stops a download in progress;
#   - on starts the download detached (a user unit, else setsid), off never downloads and turns
#     Sarek off in an installed tool before the client starts.
#   helper (steam-compat-tools):
#   - on: downloads the pinned tarball and refuses it unless the sha256 matches; installs <dir> into
#     compatibilitytools.d whole (symlinks kept), with its .retroforge-pin and the Sarek
#     user_settings.py; once installed, touches the network for nothing;
#   - off: deletes only its own user_settings.py, keeps the tool, never downloads;
#   - a failed download leaves no tool, no temp files, and the old version in place;
#   - a bump installs the new version and removes the old one a run LATER, never in the same run;
#   - never touches a folder it did not install, or a user_settings.py the player edited;
#   - sweeps what a killed run left, replaces a broken folder of its own, and leaves a running
#     install alone (lock).
#   wrapper (/usr/bin/steam): exports PROTON_DXVK_SAREK=1 exactly when the setting is on (keeping a
#   value the session already has), and runs the client either way.
# GitHub is replaced by file:// URLs; device-env, systemd-run and systemctl by stubs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-compat-tools"
CLI="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-sarek"
WRAP="$ROOT/rootfs/overlay/usr/bin/steam"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/proton-cachyos-arm64.pin"
for f in "$HELPER" "$CLI" "$WRAP" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
HOLDER=""
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$T"' EXIT

sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

SROOT="$T/home/.local/share/Steam"
TOOLS="$SROOT/compatibilitytools.d"
PIN="$T/proton-cachyos-arm64.pin"
V1=proton-cachyos-11.0-20261005-slr-arm64
V2=proton-cachyos-11.0-20261105-slr-arm64

mktool() {  # mktool <tar.xz> <top dir> <marker> [file to leave out]: laid out like Proton-CachyOS's
  python3 - "$@" <<'PY'
import io, sys, tarfile
path, top, marker = sys.argv[1:4]
omit = sys.argv[4] if len(sys.argv) > 4 else ""
def add(t, name, data=b"", mode=0o644, kind=tarfile.REGTYPE, link=""):
    i = tarfile.TarInfo(name); i.type = kind; i.mode = mode; i.linkname = link; i.size = len(data)
    t.addfile(i, io.BytesIO(data) if data else None)
files = {
    "compatibilitytool.vdf": ('"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "%s"\n    {\n'
                              '      "install_path" "."\n      "display_name" "%s"\n'
                              '      "from_oslist"  "windows"\n      "to_oslist"    "linux"\n    }\n  }\n}\n'
                              % (top, top)).encode(),
    "toolmanifest.vdf": b'"manifest"\n{\n  "version" "2"\n  "commandline" "/proton %verb%"\n'
                        b'  "require_tool_appid" "4185400"\n}\n',
    "proton": f"#!/usr/bin/env python3\n# {marker}\n".encode(),
    "version": f"1 {marker}\n".encode(),
}
with tarfile.open(path, "w:xz") as t:
    add(t, top, kind=tarfile.DIRTYPE, mode=0o755)
    for name, data in files.items():
        if name != omit:
            add(t, f"{top}/{name}", data, 0o755 if name == "proton" else 0o644)
    add(t, f"{top}/files/lib/wine/dxvk-sarek/aarch64-windows/d3d11.dll", b"MZ sarek\n")
    add(t, f"{top}/files/lib/libfoo.so.1", b"\x7fELF foo\n", 0o555)
    add(t, f"{top}/files/lib/libfoo.so", kind=tarfile.SYMTYPE, link="libfoo.so.1")
PY
}
mkpin() {  # mkpin <version> <dir> <tar.xz> [sha256]
  printf 'name: proton-cachyos-arm64\nversion: %s\ndir: %s\nurl: file://%s\nsha256: %s\n' \
    "$1" "$2" "$3" "${4:-$(sha "$3")}" >"$PIN"
}
tools() {  # tools <args>: the helper against the test's Steam root and pin
  OUT="$(HOME="$T/home" RETROFORGE_STEAM_ROOT="$SROOT" RETROFORGE_STEAM_COMPAT_PIN="$PIN" \
         python3 "$HELPER" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
leftovers() { find "$SROOT" -maxdepth 1 -name '.retroforge-compat-tools-*' | head -3; }
settings() {  # settings <tool dir>: the user_settings dict Proton would load, as JSON
  python3 -I -c 'import json, sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); import user_settings; print(json.dumps(user_settings.user_settings, sort_keys=True))' "$1"
}

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "name, version, dir, a GitHub release url naming both, and a sha256" || bad "the image's proton-cachyos-arm64.pin is malformed"
import re, sys
t = open(sys.argv[1]).read()
f = {k: re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) for k in ("name", "version", "dir", "url", "sha256")}
assert all(f.values()), f
n, v, d, u, s = (m.group(1) for m in f.values())
assert n == "proton-cachyos-arm64", n
assert re.fullmatch(r"[0-9a-f]{64}", s)
assert d.endswith("-arm64") and "/" not in d, d
assert u == f"https://github.com/CachyOS/proton-cachyos/releases/download/{v}/{d}.tar.xz", u
PY

CASE="helper: fresh install"
mktool "$T/v1.tar.xz" "$V1" v1; mkpin cachyos-1 "$V1" "$T/v1.tar.xz"
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOLS/$V1" ] && ok "exit 0, prints the tool's folder" || bad "rc=$RC out=$OUT err=$ERR"
[ -f "$TOOLS/$V1/compatibilitytool.vdf" ] && [ -f "$TOOLS/$V1/toolmanifest.vdf" ] && [ -x "$TOOLS/$V1/proton" ] \
  && [ -f "$TOOLS/$V1/files/lib/wine/dxvk-sarek/aarch64-windows/d3d11.dll" ] \
  && ok "the whole tree is in compatibilitytools.d/<dir>, proton executable" || bad "$(find "$TOOLS" | head -20)"
[ "$(readlink "$TOOLS/$V1/files/lib/libfoo.so")" = libfoo.so.1 ] && ok "symlinks are kept" || bad "libfoo.so: $(ls -la "$TOOLS/$V1/files/lib" 2>&1)"
grep -q 'require_tool_appid" "4185400"' "$TOOLS/$V1/toolmanifest.vdf" && ok "toolmanifest.vdf is the tarball's" || bad "$(cat "$TOOLS/$V1/toolmanifest.vdf")"
grep -qx "name: proton-cachyos-arm64" "$TOOLS/$V1/.retroforge-pin" && grep -qx "sha256: $(sha "$T/v1.tar.xz")" "$TOOLS/$V1/.retroforge-pin" \
  && ok "it carries .retroforge-pin with the pin's name and sha256" || bad "marker: $(cat "$TOOLS/$V1/.retroforge-pin" 2>&1)"
[ "$(settings "$TOOLS/$V1")" = '{"PROTON_DXVK_SAREK": "1"}' ] \
  && ok "user_settings.py loads as Proton loads it, with PROTON_DXVK_SAREK=1 and nothing else" || bad "settings: $(settings "$TOOLS/$V1" 2>&1)"
[ "$(ls -A "$TOOLS")" = "$V1" ] && ok "nothing else in compatibilitytools.d" || bad "$(ls -A "$TOOLS")"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"
grep -q "downloading $V1" <<<"$ERR" && grep -q "Steam lists it from its next start" <<<"$ERR" \
  && ok "says what it downloads, and that Steam needs a restart" || bad "stderr: $ERR"

CASE="helper: already installed"
rm -f "$T/v1.tar.xz"   # GitHub unreachable, the tarball gone
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOLS/$V1" ] && [ -z "$ERR" ] && ok "no download at all, says nothing" || bad "rc=$RC out=$OUT err=$ERR"

CASE="helper: off"
tools off
[ "$RC" = 0 ] && [ ! -e "$TOOLS/$V1/user_settings.py" ] && [ -x "$TOOLS/$V1/proton" ] && grep -q "turned off in $V1" <<<"$ERR" \
  && ok "deletes its user_settings.py, keeps the tool, never downloads" || bad "rc=$RC err=$ERR"
tools on
[ "$RC" = 0 ] && [ -f "$TOOLS/$V1/user_settings.py" ] && ok "on writes it again" || bad "rc=$RC err=$ERR"

CASE="helper: the player's user_settings.py"
printf 'user_settings = {"PROTON_LOG": "1", "PROTON_DXVK_SAREK": "1"}\n' >"$TOOLS/$V1/user_settings.py"
tools off
[ "$RC" = 0 ] && grep -q PROTON_LOG "$TOOLS/$V1/user_settings.py" && grep -q "player's own" <<<"$ERR" \
  && ok "off leaves an edited one alone, and says so" || bad "rc=$RC err=$ERR"
tools on
[ "$RC" = 0 ] && grep -q PROTON_LOG "$TOOLS/$V1/user_settings.py" && ok "on does not write over it" || bad "rc=$RC err=$ERR"
rm -f "$TOOLS/$V1/user_settings.py"; tools on

CASE="helper: other tools"
mkdir -p "$TOOLS/GE-Proton10-1" "$TOOLS/proton-cachyos-10.0-arm64" "$TOOLS/other-family"
echo player >"$TOOLS/GE-Proton10-1/compatibilitytool.vdf"
echo player >"$TOOLS/proton-cachyos-10.0-arm64/compatibilitytool.vdf"
cp "$TOOLS/$V1/user_settings.py" "$TOOLS/proton-cachyos-10.0-arm64/user_settings.py"
printf 'name: something-else\nversion: 1\nsha256: %s\n' "$(printf 'b%.0s' {1..64})" >"$TOOLS/other-family/.retroforge-pin"
tools off
[ -f "$TOOLS/proton-cachyos-10.0-arm64/user_settings.py" ] && ok "off never touches a folder it did not install" || bad "the player's tool lost its user_settings.py"
tools on

CASE="helper: bump, bad checksum"
mktool "$T/v2.tar.xz" "$V2" v2; mkpin cachyos-2 "$V2" "$T/v2.tar.xz" "$(printf '0%.0s' {1..64})"
tools on
[ "$RC" = 1 ] && grep -q "sha256 mismatch" <<<"$ERR" && [ -z "$OUT" ] && ok "refused (exit 1, nothing on stdout)" || bad "rc=$RC out=$OUT err=$ERR"
[ -x "$TOOLS/$V1/proton" ] && [ ! -e "$TOOLS/$V2" ] && ok "the old version is kept, nothing half-installed" || bad "$(ls -A "$TOOLS")"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="helper: bump"
mkpin cachyos-2 "$V2" "$T/v2.tar.xz"
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOLS/$V2" ] && grep -q v2 "$TOOLS/$V2/proton" && [ -f "$TOOLS/$V2/user_settings.py" ] \
  && ok "the new version is installed (with its own user_settings.py)" || bad "rc=$RC out=$OUT err=$ERR"
[ -x "$TOOLS/$V1/proton" ] && ok "the old one stays during the run that downloaded the new one" || bad "$V1 removed in the same run"
tools on
[ "$RC" = 0 ] && [ ! -e "$TOOLS/$V1" ] && [ -x "$TOOLS/$V2/proton" ] && grep -q "removing $V1" <<<"$ERR" \
  && ok "the next run removes the old one" || bad "rc=$RC err=$ERR $(ls -A "$TOOLS")"
[ -f "$TOOLS/GE-Proton10-1/compatibilitytool.vdf" ] && [ -f "$TOOLS/proton-cachyos-10.0-arm64/compatibilitytool.vdf" ] \
  && [ -f "$TOOLS/other-family/.retroforge-pin" ] \
  && ok "other tools, another pin's folder and a player's Proton-CachyOS are untouched" || bad "$(ls -A "$TOOLS")"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="helper: a killed run"
mkdir -p "$SROOT/.retroforge-compat-tools-dead/tree/$V2"; echo x >"$SROOT/.retroforge-compat-tools-dead/tool.tar.xz"
tools on
[ "$RC" = 0 ] && [ -z "$(leftovers)" ] && ok "what it left is swept on the next run" || bad "rc=$RC left: $(leftovers)"

CASE="helper: our folder, broken"
rm -f "$TOOLS/$V2/proton"
tools on
[ "$RC" = 0 ] && [ -x "$TOOLS/$V2/proton" ] && ok "a folder of ours without proton is installed again" || bad "rc=$RC err=$ERR"

CASE="helper: the pinned name is the player's"
rm -rf "$TOOLS/$V2"; mkdir -p "$TOOLS/$V2"; echo player >"$TOOLS/$V2/proton"
rm -f "$T/v2.tar.xz"
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOLS/$V2" ] && [ "$(cat "$TOOLS/$V2/proton")" = player ] \
  && [ ! -e "$TOOLS/$V2/.retroforge-pin" ] && [ ! -e "$TOOLS/$V2/user_settings.py" ] \
  && grep -q "not installed by RetroForge" <<<"$ERR" && ok "left alone, not downloaded over, and said so" || bad "rc=$RC out=$OUT err=$ERR"
rm -rf "$TOOLS/$V2"

CASE="helper: tarball without the pinned folder"
mktool "$T/v2.tar.xz" "proton-cachyos-renamed-arm64" v2; mkpin cachyos-2 "$V2" "$T/v2.tar.xz"
tools on
[ "$RC" = 1 ] && grep -q "has no $V2/" <<<"$ERR" && [ ! -e "$TOOLS/$V2" ] && [ ! -e "$TOOLS/proton-cachyos-renamed-arm64" ] \
  && ok "refused, nothing installed" || bad "rc=$RC err=$ERR $(ls -A "$TOOLS")"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="helper: tarball without proton"
mktool "$T/v2.tar.xz" "$V2" v2 proton; mkpin cachyos-2 "$V2" "$T/v2.tar.xz"
tools on
[ "$RC" = 1 ] && [ ! -e "$TOOLS/$V2" ] && ok "refused, nothing installed" || bad "rc=$RC err=$ERR"

CASE="helper: another run holds the lock"
mktool "$T/v2.tar.xz" "$V2" v2; mkpin cachyos-2 "$V2" "$T/v2.tar.xz"
python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' \
  "$SROOT/.retroforge-compat-tools.lock" "$T/locked" &
HOLDER=$!
for _ in $(seq 50); do [ -e "$T/locked" ] && break; sleep 0.1; done
tools on
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$TOOLS/$V2" ] && grep -q "already running" <<<"$ERR" \
  && ok "exits at once, installs nothing" || bad "rc=$RC out=$OUT err=$ERR"
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""
tools on
[ "$RC" = 0 ] && [ -x "$TOOLS/$V2/proton" ] && ok "and the next run installs" || bad "rc=$RC err=$ERR"

CASE="helper: offline on a fresh card"
rm -rf "$SROOT"
mkpin cachyos-2 "$V2" "$T/missing.tar.xz" "$(printf 'a%.0s' {1..64})"
tools on
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "could not download" <<<"$ERR" && [ -z "$(ls -A "$TOOLS")" ] \
  && ok "exit 1, says what it could not fetch, no tool" || bad "rc=$RC out=$OUT err=$ERR"
tools off
[ "$RC" = 0 ] && ok "off with no tool is nothing to do" || bad "rc=$RC err=$ERR"

CASE="helper: bad arguments"
tools
[ "$RC" = 2 ] && grep -q usage <<<"$ERR" && ok "no mode: exit 2 with the usage" || bad "rc=$RC err=$ERR"
tools --sarek
[ "$RC" = 2 ] && ok "an unknown mode: exit 2" || bad "rc=$RC err=$ERR"

# ================================================================================================
# The setting, with device-env, the helper, systemd-run and systemctl stubbed.
W="$T/w"; mkdir -p "$W/bin"
cat >"$W/device-env" <<EOF
#!/usr/bin/env bash
printf 'RETROFORGE_DEVICE_ID=%q\nRETROFORGE_SOC_CLASS=%q\n' test "\$(cat "$W/soc")"
EOF
cat >"$W/helper" <<EOF
#!/usr/bin/env bash
{ echo "args: \$*"; echo "root: \${RETROFORGE_STEAM_ROOT-unset}"; echo "sid: \$(ps -o sid= -p \$\$ | tr -d ' ')"; } >"$W/helper.call"
echo "helper \$1" >>"$W/sequence"
echo "helper stdout"; echo "helper stderr" >&2
sleep "\$(cat "$W/helper-sleep")"
touch "$W/helper.done"
EOF
cat >"$W/bin/systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$W/systemd-run.args"
exit "\$(cat "$W/systemd-run.rc")"
EOF
cat >"$W/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >"$W/systemctl.args"
EOF
chmod +x "$W/device-env" "$W/helper" "$W/bin/systemd-run" "$W/bin/systemctl"
WHOME="$W/home"
WROOT="$WHOME/.local/share/Steam"
WLOG="$WHOME/.local/share/retroforge/steam-compat-tools.log"
WCONF="$WHOME/.config/retroforge/steam.conf"
echo 0 >"$W/helper-sleep"
# Every run of the setting or the wrapper: the stubs, a clean environment, and VAR=value extras.
STUBS=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u PROTON_DXVK_SAREK -u RETROFORGE_STEAM_SAREK
       -u RETROFORGE_SOC_CLASS HOME="$WHOME" PATH="$W/bin:$PATH" RETROFORGE_DEVICE_ENV="$W/device-env"
       RETROFORGE_STEAM_COMPAT_TOOLS="$W/helper")
reset() {  # reset <SoC class> <systemd-run exit>
  echo "$1" >"$W/soc"; echo "$2" >"$W/systemd-run.rc"
  rm -f "$W/client" "$W/helper.call" "$W/helper.done" "$W/systemd-run.args" "$W/systemctl.args" "$W/sequence"
}
sarek() {  # sarek <SoC class> <args...> [-- VAR=value...]: run the setting command
  local soc="$1"; shift; local args=() extra=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1-}" = -- ] && { shift; extra=("$@"); }
  reset "$soc" 1
  SOUT="$("${STUBS[@]}" ${extra[@]+"${extra[@]}"} bash "$CLI" "${args[@]}" 2>"$W/err")"; SRC=$?
  SERR="$(cat "$W/err")"
}
settle() { for _ in $(seq 100); do [ -e "$W/helper.done" ] && return 0; sleep 0.1; done; return 1; }

CASE="setting: never set"
sarek SM6115 status
[ "$SRC" = 0 ] && [ "$SOUT" = on ] && grep -q "the default on SM6115" <<<"$SERR" && ok "on for the SM6115, and says it is the default" || bad "rc=$SRC out=$SOUT err=$SERR"
sarek SM8250 status
[ "$SOUT" = off ] && ok "off for the SM8250" || bad "out=$SOUT err=$SERR"
sarek SM8550 status
[ "$SOUT" = off ] && ok "off for the SM8550" || bad "out=$SOUT err=$SERR"
reset SM6115 1
SOUT="$("${STUBS[@]}" RETROFORGE_DEVICE_ENV="$W/missing" bash "$CLI" status 2>"$W/err")"
[ "$SOUT" = off ] && grep -q "an unknown board" "$W/err" && ok "off when device-env cannot say" || bad "out=$SOUT err=$(cat "$W/err")"
[ ! -e "$WCONF" ] && ok "status writes nothing" || bad "status created $WCONF"

CASE="setting: off on the SM6115"
sarek SM6115 off
[ "$SRC" = 0 ] && [ "$SOUT" = off ] && ok "prints off" || bad "rc=$SRC out=$SOUT err=$SERR"
[ "$(grep -v '^#' "$WCONF")" = "DXVK_SAREK=off" ] && head -1 "$WCONF" | grep -q '^# ' && ok "saved as DXVK_SAREK=off, under a comment" || bad "conf: $(cat "$WCONF" 2>&1)"
grep -qx -- "--user stop retroforge-steam-compat-tools.service" "$W/systemctl.args" && ok "a download in progress is stopped" || bad "systemctl: $(cat "$W/systemctl.args" 2>&1)"
[ ! -e "$W/systemd-run.args" ] && [ ! -e "$W/helper.call" ] && ok "nothing is downloaded" || bad "the helper was started"
sarek SM6115 status
[ "$SOUT" = off ] && grep -q "$WCONF" <<<"$SERR" && ok "it sticks, and status says where it comes from" || bad "out=$SOUT err=$SERR"

CASE="setting: on on the SM8250"
printf '# mine\nOTHER=1\nDXVK_SAREK=off\nDXVK_SAREK=off\n' >"$WCONF"
sarek SM8250 on
[ "$SRC" = 0 ] && [ "$SOUT" = on ] && ok "prints on" || bad "rc=$SRC out=$SOUT err=$SERR"
[ "$(cat "$WCONF")" = "$(printf '# mine\nOTHER=1\nDXVK_SAREK=on')" ] && ok "one DXVK_SAREK line, the rest of the file kept" || bad "conf: $(cat "$WCONF")"
settle && grep -qx "args: on" "$W/helper.call" && ok "the download starts at once (setsid here)" || bad "the helper was not started"
[ ! -e "$W/systemctl.args" ] && ok "nothing is stopped" || bad "systemctl: $(cat "$W/systemctl.args")"
sarek SM8250 status
[ "$SOUT" = on ] && ok "it sticks on a board whose default is off" || bad "out=$SOUT err=$SERR"

CASE="setting: what the file can say"
printf 'DXVK_SAREK=on\nDXVK_SAREK=yes\n' >"$WCONF"
sarek SM8250 status
[ "$SOUT" = off ] && ok "a value other than on/off (last line) falls back to the default" || bad "out=$SOUT"
printf 'DXVK_SAREK=off\nDXVK_SAREK=on' >"$WCONF"   # no newline at the end
sarek SM8250 status
[ "$SOUT" = on ] && ok "the last line counts, with or without a newline" || bad "out=$SOUT"

CASE="setting: RETROFORGE_STEAM_SAREK"
printf 'DXVK_SAREK=on\n' >"$WCONF"
sarek SM6115 status -- RETROFORGE_STEAM_SAREK=off
[ "$SOUT" = off ] && grep -q RETROFORGE_STEAM_SAREK <<<"$SERR" && ok "off beats the saved on" || bad "out=$SOUT err=$SERR"
rm -f "$WCONF"
sarek SM8250 status -- RETROFORGE_STEAM_SAREK=on
[ "$SOUT" = on ] && ok "on beats the board's default" || bad "out=$SOUT"
sarek SM8250 off -- RETROFORGE_STEAM_SAREK=on
[ "$SOUT" = on ] && grep -q "saved off, but RETROFORGE_STEAM_SAREK says on" <<<"$SERR" && grep -qx DXVK_SAREK=off "$WCONF" \
  && ok "saving off under it saves, and says the override still wins" || bad "out=$SOUT err=$SERR"
sarek SM8250 status -- RETROFORGE_STEAM_SAREK=maybe
[ "$SOUT" = off ] && ok "an override other than on/off is ignored" || bad "out=$SOUT"

CASE="setting: cannot save"
rm -rf "$WHOME/.config"; mkdir -p "$WHOME"; echo file >"$WHOME/.config"
sarek SM6115 off
[ "$SRC" = 1 ] && grep -q "could not save" <<<"$SERR" && [ -z "$SOUT" ] && ok "exit 1, says so" || bad "rc=$SRC out=$SOUT err=$SERR"
rm -f "$WHOME/.config"

CASE="setting: bad invocation"
sarek SM6115
[ "$SRC" = 2 ] && grep -q usage <<<"$SERR" && ok "no command: exit 2 with the usage" || bad "rc=$SRC err=$SERR"
sarek SM6115 on extra
[ "$SRC" = 2 ] && ok "an extra argument: exit 2" || bad "rc=$SRC"

CASE="setting: off with the real helper"
# A tool the real helper installed with Sarek on, then off: the real helper deletes its file.
mkpin cachyos-2 "$V2" "$T/v2.tar.xz"
HOME="$WHOME" RETROFORGE_STEAM_ROOT="$WROOT" RETROFORGE_STEAM_COMPAT_PIN="$PIN" python3 "$HELPER" on >/dev/null 2>&1
[ -f "$WROOT/compatibilitytools.d/$V2/user_settings.py" ] || bad "fixture: no user_settings.py to turn off"
reset SM6115 1
SOUT="$("${STUBS[@]}" RETROFORGE_STEAM_COMPAT_TOOLS="$HELPER" RETROFORGE_STEAM_COMPAT_PIN="$PIN" bash "$CLI" off 2>"$W/err")"
[ "$SOUT" = off ] && [ ! -e "$WROOT/compatibilitytools.d/$V2/user_settings.py" ] && [ -x "$WROOT/compatibilitytools.d/$V2/proton" ] \
  && ok "Sarek is off in the installed tool, which stays" || bad "out=$SOUT err=$(cat "$W/err")"
rm -f "$WCONF"

# ================================================================================================
# The wrapper, with the bootstrap and the runtime stubbed too, and the real setting command.
mkdir -p "$W/rt"
cat >"$W/rt/run" <<EOF
#!/usr/bin/env bash
echo "sarek: \${PROTON_DXVK_SAREK-unset}" >"$W/client"
echo client >>"$W/sequence"
EOF
cat >"$W/bootstrap" <<EOF
#!/usr/bin/env bash
mkdir -p "\$RETROFORGE_STEAM_ROOT"; echo "$W/rt/run"
EOF
chmod +x "$W/rt/run" "$W/bootstrap"
wrap() {  # wrap <SoC class> <systemd-run exit> [VAR=value...]
  reset "$1" "$2"; shift 2
  "${STUBS[@]}" RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap" RETROFORGE_STEAM_SAREK_CLI="$CLI" "$@" \
    bash "$WRAP" steam://rungameid/1 2>"$W/err"; WRC=$?
  WERR="$(cat "$W/err")"
}

CASE="wrapper: SM6115, user manager"
wrap SM6115 0
[ "$WRC" = 0 ] && [ -e "$W/client" ] && ok "the client runs" || bad "rc=$WRC err=$WERR"
grep -qx "sarek: 1" "$W/client" && ok "with PROTON_DXVK_SAREK=1" || bad "$(cat "$W/client" 2>&1)"
args="$(cat "$W/systemd-run.args" 2>/dev/null)"
grep -qx -- --user <<<"$args" && grep -qx -- --unit=retroforge-steam-compat-tools <<<"$args" && grep -qx -- --collect <<<"$args" \
  && ok "the download is a collected user unit with a fixed name" || bad "systemd-run: $args"
grep -qx -- "--setenv=RETROFORGE_STEAM_ROOT=$WROOT" <<<"$args" && ok "told where the Steam root is" || bad "systemd-run: $args"
grep -qx "StandardOutput=append:$WLOG" <<<"$args" && grep -qx "StandardError=append:$WLOG" <<<"$args" && [ -d "${WLOG%/*}" ] \
  && ok "logging to ~/.local/share/retroforge/steam-compat-tools.log" || bad "systemd-run: $args"
[ "$(tail -n 2 <<<"$args" | tr '\n' ' ')" = "$W/helper on " ] && ok "running steam-compat-tools on" || bad "systemd-run: $args"
sleep 0.3; [ ! -e "$W/helper.call" ] && ok "and nothing else runs it" || bad "the helper ran directly too"

CASE="wrapper: SM6115, no user manager"
echo 3 >"$W/helper-sleep"; : >"$WLOG"
wrap SM6115 1
[ "$WRC" = 0 ] && [ -e "$W/client" ] && [ ! -e "$W/helper.done" ] && ok "the client runs without waiting for the download" || bad "rc=$WRC err=$WERR"
settle && ok "the helper still finishes after the wrapper is gone" || bad "the helper never finished"
grep -qx "args: on" "$W/helper.call" && grep -qx "root: $WROOT" "$W/helper.call" && ok "with on and the Steam root" || bad "$(cat "$W/helper.call" 2>&1)"
[ "$(sed -n 's/^sid: //p' "$W/helper.call")" != "$(ps -o sid= -p $$ | tr -d ' ')" ] && ok "in a session of its own (setsid)" || bad "same session"
grep -qx "helper stdout" "$WLOG" && grep -qx "helper stderr" "$WLOG" && ok "its output goes to the log" || bad "log: $(cat "$WLOG")"
echo 0 >"$W/helper-sleep"

CASE="wrapper: SM6115, turned off"
printf 'DXVK_SAREK=off\n' >"$WCONF"
wrap SM6115 1
sleep 0.3
[ ! -e "$W/systemd-run.args" ] && [ ! -e "$W/helper.call" ] && ok "no download, and no helper while no tool of ours has Sarek on" || bad "the helper was started: $(cat "$W/helper.call" 2>&1)"
grep -qx "sarek: unset" "$W/client" && ok "no PROTON_DXVK_SAREK" || bad "$(cat "$W/client" 2>&1)"
mkdir -p "$WROOT/compatibilitytools.d/$V2"; touch "$WROOT/compatibilitytools.d/$V2/.retroforge-pin" "$WROOT/compatibilitytools.d/$V2/user_settings.py"
wrap SM6115 1
[ "$(tr '\n' ' ' <"$W/sequence")" = "helper off client " ] && ok "with Sarek on in a tool of ours, steam-compat-tools off runs before the client" \
  || bad "sequence: $(cat "$W/sequence" 2>&1)"
rm -rf "$WROOT/compatibilitytools.d/$V2"

CASE="wrapper: SM6115, the session's PROTON_DXVK_SAREK"
rm -f "$WCONF"
wrap SM6115 0 PROTON_DXVK_SAREK=0
grep -qx "sarek: 0" "$W/client" && ok "a PROTON_DXVK_SAREK=0 the session already has is kept" || bad "$(cat "$W/client" 2>&1)"

CASE="wrapper: SM8250"
wrap SM8250 1
sleep 0.3
[ ! -e "$W/systemd-run.args" ] && [ ! -e "$W/helper.call" ] && ok "no download" || bad "the helper was started"
grep -qx "sarek: unset" "$W/client" && ok "no PROTON_DXVK_SAREK" || bad "$(cat "$W/client" 2>&1)"

CASE="wrapper: SM8250, turned on"
printf 'DXVK_SAREK=on\n' >"$WCONF"
wrap SM8250 1
settle && grep -qx "args: on" "$W/helper.call" && ok "the download starts" || bad "$(cat "$W/helper.call" 2>&1)"
grep -qx "sarek: 1" "$W/client" && ok "and PROTON_DXVK_SAREK=1" || bad "$(cat "$W/client" 2>&1)"
rm -f "$WCONF"

CASE="wrapper: RETROFORGE_STEAM_SAREK=off"
wrap SM6115 0 RETROFORGE_STEAM_SAREK=off
[ ! -e "$W/systemd-run.args" ] && grep -qx "sarek: unset" "$W/client" && ok "the SM6115 gets neither" || bad "$(cat "$W/client" 2>&1)"

CASE="wrapper: no setting command"
reset SM6115 0
"${STUBS[@]}" RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap" RETROFORGE_STEAM_SAREK_CLI="$W/missing" bash "$WRAP" 2>"$W/err"; WRC=$?
[ "$WRC" = 0 ] && grep -qx "sarek: unset" "$W/client" && [ ! -s "$W/err" ] && ok "the client runs, nothing exported, no error" || bad "rc=$WRC err=$(cat "$W/err")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
