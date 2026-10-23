#!/usr/bin/env bash
# Offline test for the DXVK-Sarek setting: /usr/bin/retroforge-steam-sarek (the setting),
# /usr/lib/retroforge/steam-compat-tools (Proton-CachyOS arm64 as a Steam compatibility tool) and the
# block of /usr/bin/steam that applies it.
#
#   tests/test-steam-compat-tools.sh
#
# WHY THIS EXISTS. Nothing here runs before a player picks a Windows game, and each rule below fails
# as a game without a working DXVK, a half tool Steam lists, a tool a game loses, a setting that does
# not stick, or a player's own tool gone:
#   setting (retroforge-steam-sarek):
#   - never set: on for SoC class SM6115, off elsewhere and on an unknown board;
#   - the player's DXVK_SAREK=on|off in ~/.config/retroforge/steam.conf wins over that (last line;
#     anything else ignored), and RETROFORGE_STEAM_SAREK=on|off over both;
#   - on/off rewrites that one line and keeps the rest; off also stops a download in progress;
#   - on starts the download detached (a user unit, else setsid), off never downloads and turns
#     Sarek off in an installed tool before the client starts.
#   helper (steam-compat-tools):
#   - the image's pin follows the channel (no tag), and names one folder for the tool;
#   - on: one API request picks the newest release with the arm64 tarball and its .sha512sum (highest
#     Proton version, then latest published), skipping releases without them, drafts, prereleases
#     and uploads in progress; refuses a tarball unless its sha512 (and GitHub's sha256) match;
#     installs it whole as compatibilitytools.d/<dir> (symlinks kept), its compatibilitytool.vdf
#     naming the tool <dir>, with its .retroforge-pin and the Sarek user_settings.py;
#   - the release already installed: no download, nothing said;
#   - GitHub unreachable, rate limited, answering nonsense or with no arm64 build: the installed
#     release stays (exit 0); on a fresh card, exit 1 and no tool;
#   - a new release replaces the old one under the same name, by rename, keeping the player's
#     user_settings.py; while a process runs from the tool (a mapped file) it waits, checked, and goes
#     in at a later run without a second download; one withdrawn meanwhile is dropped;
#   - folders of the earlier per-release scheme go once the one-name folder is in, each when nothing
#     runs from it (working folder), and a player's user_settings.py in one comes along;
#   - a tag in the pin holds that release (asked by tag, then not at all), and a sha512 with it is
#     checked instead of the .sha512sum;
#   - off: deletes only its own user_settings.py, keeps the tool, never downloads;
#   - never touches a folder it did not install, or a user_settings.py the player edited;
#   - sweeps what a killed run left, replaces a broken folder of its own, refuses a tarball without
#     its folder, proton or a compatibilitytool.vdf it can rename, and leaves a running install alone
#     (lock).
#   wrapper (/usr/bin/steam): exports PROTON_DXVK_SAREK=1 exactly when the setting is on (keeping a
#   value the session already has), and runs the client either way.
# GitHub's API is a local fake (a pin's releases: points at it) and the downloads are file:// URLs;
# device-env, systemd-run and systemctl are stubs.
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
HOLDER=""; SERVER=""
trap 'for p in $HOLDER $SERVER; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT

digest() { python3 -c 'import hashlib,sys; print(hashlib.new(sys.argv[1], open(sys.argv[2],"rb").read()).hexdigest())' "$1" "$2"; }

SROOT="$T/home/.local/share/Steam"
TOOLS="$SROOT/compatibilitytools.d"
STABLE=proton-cachyos-arm64-retroforge
TOOL="$TOOLS/$STABLE"
NEXT="$SROOT/.retroforge-compat-tools.next"
SHOWN="Proton-CachyOS arm64 (RetroForge)"
PIN="$T/proton-cachyos-arm64.pin"
DL="$T/dl"; API="$T/api"; mkdir -p "$DL" "$API"
# Releases: R<n> is the tag, D<n> its tarball's top folder (the asset's name without .tar.xz).
R0=cachyos-11.0-20260703-slr;  D0=proton-cachyos-11.0-20260703-slr-arm64
R1=cachyos-11.0-20261005-slr;  D1=proton-cachyos-11.0-20261005-slr-arm64
R2=cachyos-11.0-20261105-slr;  D2=proton-cachyos-11.0-20261105-slr-arm64
R3=cachyos-11.0-20261215-slr;  D3=proton-cachyos-11.0-20261215-slr-arm64
RS=cachyos-10.0-sunset-slr;    DS=proton-cachyos-10.0-sunset-slr-arm64
RN=cachyos-12.0-20261201-slr;  DN=proton-cachyos-12.0-20261201-slr-arm64
RX=cachyos-11.0-20261231-slr;  DX=proton-cachyos-11.0-20261231-slr-arm64

mktool() {  # mktool <top> <marker> [no-proton|no-dir|bad-vdf]: $DL/<top>.tar.xz, laid out like Proton-CachyOS's
  python3 - "$DL" "$@" <<'PY'
import io, os, sys, tarfile
dl, top, marker = sys.argv[1:4]
what = sys.argv[4] if len(sys.argv) > 4 else ""
def add(t, name, data=b"", mode=0o644, kind=tarfile.REGTYPE, link=""):
    i = tarfile.TarInfo(name); i.type = kind; i.mode = mode; i.linkname = link; i.size = len(data)
    t.addfile(i, io.BytesIO(data) if data else None)
vdf = ('"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "%s" // Internal name of this tool\n    {\n'
       '      // Can register this tool with Steam in two ways:\n      "install_path" "."\n\n'
       '      // For this template, we\'re going to substitute the display_name key in here, e.g.:\n'
       '      "display_name" "%s"\n\n      "from_oslist"  "windows"\n      "to_oslist"    "linux"\n    }\n  }\n}\n'
       % (top, top))
if what == "bad-vdf":
    vdf = '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "a" { "install_path" "." }\n    "b" { "install_path" "." }\n  }\n}\n'
files = {
    "compatibilitytool.vdf": vdf.encode(),
    "toolmanifest.vdf": b'"manifest"\n{\n  "version" "2"\n  "commandline" "/proton %verb%"\n'
                        b'  "require_tool_appid" "4185400"\n}\n',
    "proton": f"#!/usr/bin/env python3\n# {marker}\n".encode(),
    "version": f"1 {marker}\n".encode(),
    "user_settings.sample.py": b"user_settings = {}\n",
}
d = top + "-renamed" if what == "no-dir" else top
with tarfile.open(os.path.join(dl, top + ".tar.xz"), "w:xz") as t:
    add(t, d, kind=tarfile.DIRTYPE, mode=0o755)
    for name, data in files.items():
        if not (name == "proton" and what == "no-proton"):
            add(t, f"{d}/{name}", data, 0o755 if name == "proton" else 0o644)
    add(t, f"{d}/files/lib/wine/dxvk-sarek/aarch64-windows/d3d11.dll", b"MZ sarek\n")
    add(t, f"{d}/files/lib/libfoo.so.1", b"\x7fELF foo\n", 0o555)
    add(t, f"{d}/files/lib/libfoo.so", kind=tarfile.SYMTYPE, link="libfoo.so.1")
PY
}
# releases <<EOF, one per line: <tag> <published> <top|-> [flags]: the fake API's list of releases.
# flags: nosidecar badsidecar baddigest nodigest uploading draft prerelease. - = no arm64 build.
releases() { python3 "$T/releases.py" "$DL" "$API/releases.json"; }
cat >"$T/releases.py" <<'PY'
import hashlib, json, os, sys
dl, out = sys.argv[1:3]
rels = []
for line in sys.stdin:
    if not line.strip():
        continue
    tag, published, top, *flags = line.split()
    x86 = f"proton-{tag}-x86_64"
    assets = [{"name": x86 + ".tar.xz", "state": "uploaded", "browser_download_url": f"file://{dl}/{x86}.tar.xz"},
              {"name": x86 + ".sha512sum", "state": "uploaded", "browser_download_url": f"file://{dl}/{x86}.sha512sum"}]
    if top != "-":
        path = os.path.join(dl, top + ".tar.xz")
        data = open(path, "rb").read()
        tarball = {"name": top + ".tar.xz", "state": "starter" if "uploading" in flags else "uploaded",
                   "browser_download_url": "file://" + path}
        if "nodigest" not in flags:
            tarball["digest"] = "sha256:" + ("0" * 64 if "baddigest" in flags else hashlib.sha256(data).hexdigest())
        assets.append(tarball)
        if "nosidecar" not in flags:
            side = os.path.join(dl, f"{tag}.{top}.sha512sum")
            with open(side, "w") as f:
                f.write(("0" * 128 if "badsidecar" in flags else hashlib.sha512(data).hexdigest()) + f"  {top}.tar.xz\n")
            assets.append({"name": top + ".sha512sum", "state": "uploaded", "browser_download_url": "file://" + side})
    rels.append({"tag_name": tag, "published_at": published, "draft": "draft" in flags,
                 "prerelease": "prerelease" in flags, "assets": assets})
with open(out, "w") as f:
    json.dump(rels, f, indent=1)
PY

# The fake API: GET <base>?per_page=N (the list) and <base>/tags/<tag>, from $API/releases.json. Every
# request goes to $API/requests.log. $API/status, when there, is the answer instead: an HTTP code (403
# comes with GitHub's rate-limit headers) or "garbage" (200, not JSON).
cat >"$T/api.py" <<'PY'
import http.server, json, os, sys, urllib.parse
d = sys.argv[1]
BASE = "/repos/CachyOS/proton-cachyos/releases"
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body=b"{}", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        with open(os.path.join(d, "requests.log"), "a") as f:
            f.write(self.path + "\n")
        try:
            status = open(os.path.join(d, "status")).read().strip()
        except OSError:
            status = ""
        if status == "garbage":
            return self.reply(200, b"<html>not json</html>")
        if status:
            limit = [("X-RateLimit-Remaining", "0"), ("X-RateLimit-Reset", "1792209892")] if status == "403" else []
            return self.reply(int(status), b'{"message": "no"}', limit)
        url = urllib.parse.urlsplit(self.path)
        rels = json.load(open(os.path.join(d, "releases.json")))
        if url.path == BASE:
            n = int(urllib.parse.parse_qs(url.query).get("per_page", ["30"])[0])
            return self.reply(200, json.dumps(rels[:n]).encode())
        if url.path.startswith(BASE + "/tags/"):
            tag = urllib.parse.unquote(url.path[len(BASE + "/tags/"):])
            for r in rels:
                if r["tag_name"] == tag:
                    return self.reply(200, json.dumps(r).encode())
        self.reply(404, b'{"message": "Not Found"}')
    def log_message(self, *args):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port.part"), "w") as f:
    f.write(str(s.server_address[1]))
os.rename(os.path.join(d, "port.part"), os.path.join(d, "port"))
s.serve_forever()
PY
python3 "$T/api.py" "$API" & SERVER=$!
for _ in $(seq 100); do [ -e "$API/port" ] && break; sleep 0.1; done
[ -e "$API/port" ] || { echo "the fake API did not start" >&2; exit 1; }
RELEASES="http://127.0.0.1:$(cat "$API/port")/repos/CachyOS/proton-cachyos/releases"

mkpin() {  # mkpin [tag] [sha512] [releases url]
  { printf 'name: proton-cachyos-arm64\nreleases: %s\nasset: proton-cachyos-*-slr-arm64.tar.xz\n' "${3:-$RELEASES}"
    printf 'dir: %s\ndisplay_name: %s\n' "$STABLE" "$SHOWN"
    [ -n "${1-}" ] && printf 'tag: %s\n' "$1"
    [ -n "${2-}" ] && printf 'sha512: %s\n' "$2"; } >"$PIN"
}
NOPROXY=(env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY)
tools() {  # tools <args>: the helper against the test's Steam root and pin. REQS: its API requests.
  : >"$API/requests.log"
  OUT="$("${NOPROXY[@]}" HOME="$T/home" RETROFORGE_STEAM_ROOT="$SROOT" RETROFORGE_STEAM_COMPAT_PIN="$PIN" \
         python3 "$HELPER" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"; REQS="$(cat "$API/requests.log")"
}
asked() { grep -c . "$API/requests.log"; }
leftovers() { find "$SROOT" -maxdepth 1 -name '.retroforge-compat-tools-*' | head -3; }
tag_of() { sed -n 's/^tag: //p' "$1/.retroforge-pin" 2>/dev/null; }
settings() {  # settings <tool dir>: the user_settings dict Proton would load, as JSON
  python3 -I -c 'import json, sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); import user_settings; print(json.dumps(user_settings.user_settings, sort_keys=True))' "$1"
}
vdf_strings() {  # vdf_strings <tool dir>: compatibilitytool.vdf's quoted strings, comments dropped, |-joined
  python3 -c 'import re, sys; t = re.sub(r"//[^\n]*", "", open(sys.argv[1]).read()); print("|".join(re.findall(r"\"([^\"]*)\"", t)))' "$1/compatibilitytool.vdf"
}
VDF_OURS="compatibilitytools|compat_tools|$STABLE|install_path|.|display_name|$SHOWN|from_oslist|windows|to_oslist|linux"
ours_only() { [ "$(cd "$TOOLS" && LC_ALL=C ls -d proton-cachyos-1* 2>/dev/null | grep -v '^proton-cachyos-10.0-arm64$')" = "" ]; }
hold() {  # hold <how> <path>: a process of ours that maps a file there (map) or works in a folder there (cwd)
  rm -f "$T/held"
  if [ "$1" = map ]; then
    python3 -c 'import mmap, sys, time
f = open(sys.argv[1], "rb"); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ); f.close()
open(sys.argv[2], "w").close(); time.sleep(120)' "$2" "$T/held" &
  else
    (cd "$2" && touch "$T/held" && exec sleep 120) &
  fi
  HOLDER=$!
  for _ in $(seq 50); do [ -e "$T/held" ] && break; sleep 0.1; done
}
release() { kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""; }

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "a channel (no tag): the GitHub API, the arm64 tarball, one folder and name" || bad "the image's proton-cachyos-arm64.pin is not that"
import fnmatch, re, sys
t = open(sys.argv[1]).read()
f = {}
for k in ("name", "releases", "asset", "dir", "display_name", "tag", "sha512"):
    m = re.search(rf"^{k}:[ \t]*(.*?)[ \t]*$", t, re.M)
    f[k] = m.group(1) if m and m.group(1) else None
assert f["name"] == "proton-cachyos-arm64", f
assert f["releases"] == "https://api.github.com/repos/CachyOS/proton-cachyos/releases", f
assert fnmatch.fnmatchcase("proton-cachyos-11.0-20261005-slr-arm64.tar.xz", f["asset"]), f
for other in ("proton-cachyos-11.0-20261005-slr-x86_64.tar.xz", "proton-cachyos-11.0-20261005-slr-arm64.sha512sum"):
    assert not fnmatch.fnmatchcase(other, f["asset"]), other
assert f["dir"] == "proton-cachyos-arm64-retroforge", f
assert f["display_name"] == "Proton-CachyOS arm64 (RetroForge)", f
assert f["tag"] is None and f["sha512"] is None, f
PY

CASE="helper: fresh install"
mktool "$D0" v0; mktool "$D1" v1
releases <<EOF
$R1 2026-10-04T21:30:56Z $D1
$R0 2026-07-22T00:57:55Z $D0
EOF
mkpin
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && ok "exit 0, prints the tool's folder" || bad "rc=$RC out=$OUT err=$ERR"
[ "$REQS" = "/repos/CachyOS/proton-cachyos/releases?per_page=20" ] && ok "one API request, for the newest 20 releases" || bad "requests: $REQS"
[ -f "$TOOL/compatibilitytool.vdf" ] && [ -f "$TOOL/toolmanifest.vdf" ] && [ -x "$TOOL/proton" ] \
  && [ -f "$TOOL/files/lib/wine/dxvk-sarek/aarch64-windows/d3d11.dll" ] && grep -q v1 "$TOOL/proton" \
  && ok "the newest release, whole, in compatibilitytools.d/$STABLE, proton executable" || bad "$(find "$TOOLS" | head -20)"
[ "$(readlink "$TOOL/files/lib/libfoo.so")" = libfoo.so.1 ] && ok "symlinks are kept" || bad "libfoo.so: $(ls -la "$TOOL/files/lib" 2>&1)"
grep -q 'require_tool_appid" "4185400"' "$TOOL/toolmanifest.vdf" && ok "toolmanifest.vdf is the tarball's" || bad "$(cat "$TOOL/toolmanifest.vdf")"
[ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] && grep -q '"'"$STABLE"'" // Internal name of this tool' "$TOOL/compatibilitytool.vdf" \
  && ok "compatibilitytool.vdf names the tool $STABLE, shown as $SHOWN, the rest and its comments kept" \
  || bad "vdf: $(cat "$TOOL/compatibilitytool.vdf")"
[ "$(cat "$TOOL/.retroforge-pin")" = "$(printf 'name: proton-cachyos-arm64\ntag: %s\nasset: %s.tar.xz\nsha512: %s\nsha256: %s' \
    "$R1" "$D1" "$(digest sha512 "$DL/$D1.tar.xz")" "$(digest sha256 "$DL/$D1.tar.xz")")" ] \
  && ok "its .retroforge-pin: the name, the tag, the asset, its sha512 and sha256" || bad "marker: $(cat "$TOOL/.retroforge-pin" 2>&1)"
[ "$(settings "$TOOL")" = '{"PROTON_DXVK_SAREK": "1"}' ] \
  && ok "user_settings.py loads as Proton loads it, with PROTON_DXVK_SAREK=1 and nothing else" || bad "settings: $(settings "$TOOL" 2>&1)"
[ "$(ls -A "$TOOLS")" = "$STABLE" ] && ok "nothing else in compatibilitytools.d" || bad "$(ls -A "$TOOLS")"
[ -z "$(leftovers)" ] && [ ! -e "$NEXT" ] && ok "no temporary folders left" || bad "left: $(leftovers) $(ls -d "$NEXT" 2>&1)"
grep -q "downloading $D1.tar.xz ($R1)" <<<"$ERR" && grep -q "Steam lists it as \"$SHOWN\" from its next start" <<<"$ERR" \
  && ok "says what it downloads, and that Steam needs a restart" || bad "stderr: $ERR"
cp "$TOOL/user_settings.py" "$T/sarek.py"

CASE="helper: already installed"
mv "$DL/$D1.tar.xz" "$DL/$D1.away"   # a download would fail
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ -z "$ERR" ] && [ "$(asked)" = 1 ] && ok "one API request, no download, says nothing" || bad "rc=$RC out=$OUT err=$ERR requests=$REQS"
mv "$DL/$D1.away" "$DL/$D1.tar.xz"

CASE="helper: off"
tools off
[ "$RC" = 0 ] && [ ! -e "$TOOL/user_settings.py" ] && [ -x "$TOOL/proton" ] && grep -q "turned off in $STABLE" <<<"$ERR" \
  && [ "$(asked)" = 0 ] && ok "deletes its user_settings.py, keeps the tool, asks nothing" || bad "rc=$RC err=$ERR requests=$REQS"
tools on
[ "$RC" = 0 ] && [ -f "$TOOL/user_settings.py" ] && ok "on writes it again" || bad "rc=$RC err=$ERR"

CASE="helper: the player's user_settings.py"
printf 'user_settings = {"PROTON_LOG": "1", "PROTON_DXVK_SAREK": "1"}\n' >"$TOOL/user_settings.py"
tools off
[ "$RC" = 0 ] && grep -q PROTON_LOG "$TOOL/user_settings.py" && grep -q "player's own" <<<"$ERR" \
  && ok "off leaves an edited one alone, and says so" || bad "rc=$RC err=$ERR"
tools on
[ "$RC" = 0 ] && grep -q PROTON_LOG "$TOOL/user_settings.py" && ok "on does not write over it" || bad "rc=$RC err=$ERR"
rm -f "$TOOL/user_settings.py"; tools on

CASE="helper: other tools"
mkdir -p "$TOOLS/GE-Proton10-1" "$TOOLS/proton-cachyos-10.0-arm64" "$TOOLS/other-family"
echo player >"$TOOLS/GE-Proton10-1/compatibilitytool.vdf"
echo player >"$TOOLS/proton-cachyos-10.0-arm64/compatibilitytool.vdf"
cp "$T/sarek.py" "$TOOLS/proton-cachyos-10.0-arm64/user_settings.py"
printf 'name: something-else\ntag: 1\nsha256: %s\n' "$(printf 'b%.0s' {1..64})" >"$TOOLS/other-family/.retroforge-pin"
tools off
[ -f "$TOOLS/proton-cachyos-10.0-arm64/user_settings.py" ] && ok "off never touches a folder it did not install" || bad "the player's tool lost its user_settings.py"
tools on

CASE="helper: GitHub cannot be asked"
echo 500 >"$API/status"
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && grep -q "answered 500" <<<"$ERR" && grep -q "keeping $R1" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && ok "an API error: the installed release stays, exit 0, says so" || bad "rc=$RC out=$OUT err=$ERR"
echo 403 >"$API/status"
tools on
[ "$RC" = 0 ] && grep -q "allows no more requests from this network until" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && ok "the rate limit used up: the same, and says until when" || bad "rc=$RC err=$ERR"
echo garbage >"$API/status"
tools on
[ "$RC" = 0 ] && grep -q "could not ask GitHub's API" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && ok "an answer that is not JSON: the same" || bad "rc=$RC err=$ERR"
rm -f "$API/status"
mkpin "" "" "http://127.0.0.1:1/repos/CachyOS/proton-cachyos/releases"
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && grep -q "could not ask GitHub's API" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && ok "no network: the same" || bad "rc=$RC out=$OUT err=$ERR"
mkpin
releases <<EOF
$R2 2026-11-05T00:00:00Z -
$R1 2026-10-04T21:30:56Z -
EOF
tools on
[ "$RC" = 0 ] && grep -q "none of the newest 2 releases has proton-cachyos-\*-slr-arm64.tar.xz" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && [ -x "$TOOL/proton" ] && ok "no release with an arm64 build: the same" || bad "rc=$RC err=$ERR"

CASE="helper: a new release, bad sha512"
mktool "$D2" v2
releases <<EOF
$R2 2026-11-05T00:00:00Z $D2 badsidecar
$R1 2026-10-04T21:30:56Z $D1
EOF
tools on
[ "$RC" = 1 ] && grep -q "sha512 mismatch" <<<"$ERR" && [ -z "$OUT" ] && ok "refused (exit 1, nothing on stdout)" || bad "rc=$RC out=$OUT err=$ERR"
[ "$(tag_of "$TOOL")" = "$R1" ] && grep -q v1 "$TOOL/proton" && ours_only && ok "the installed release stays, nothing half-installed" || bad "$(ls -A "$TOOLS")"
[ -z "$(leftovers)" ] && [ ! -e "$NEXT" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="helper: a new release, GitHub's sha256 disagrees"
releases <<EOF
$R2 2026-11-05T00:00:00Z $D2 baddigest
$R1 2026-10-04T21:30:56Z $D1
EOF
tools on
[ "$RC" = 1 ] && grep -q "sha256 mismatch.*GitHub lists" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] && [ -z "$(leftovers)" ] \
  && ok "refused, the installed release stays" || bad "rc=$RC err=$ERR"

CASE="helper: the newest release with an arm64 build"
mktool "$DS" sunset; mktool "$DN" v12; mktool "$DX" vx
releases <<EOF
$RX 2026-12-31T00:00:00Z -
$RX 2026-12-30T00:00:00Z $DX nosidecar
$RX 2026-12-29T00:00:00Z $DX uploading
$RN 2026-12-28T00:00:00Z $DN draft
$RN 2026-12-27T00:00:00Z $DN prerelease
$RS 2026-11-20T00:00:00Z $DS
$R1 2026-10-04T21:30:56Z $D1
$R2 2026-11-05T00:00:00Z $D2
EOF
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && grep -q v2 "$TOOL/proton" \
  && ok "$R2: not one without an arm64 build or a .sha512sum, still uploading, a draft, a prerelease, or 10.0-sunset published after it" \
  || bad "rc=$RC out=$OUT tag=$(tag_of "$TOOL") err=$ERR"
[ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] && ok "under the same name, compatibilitytool.vdf rewritten again" || bad "vdf: $(cat "$TOOL/compatibilitytool.vdf")"
[ "$(settings "$TOOL")" = '{"PROTON_DXVK_SAREK": "1"}' ] && ok "with the Sarek user_settings.py" || bad "settings: $(settings "$TOOL" 2>&1)"
grep -q "updated $TOOL from $R1 to $R2" <<<"$ERR" && ok "says it updated, from what to what" || bad "stderr: $ERR"
ours_only && [ -z "$(leftovers)" ] && [ ! -e "$NEXT" ] && ok "the old release is gone, no second folder, nothing left" || bad "$(ls -A "$TOOLS") left: $(leftovers)"
[ -f "$TOOLS/GE-Proton10-1/compatibilitytool.vdf" ] && [ -f "$TOOLS/proton-cachyos-10.0-arm64/compatibilitytool.vdf" ] \
  && [ -f "$TOOLS/other-family/.retroforge-pin" ] \
  && ok "other tools, another pin's folder and a player's Proton-CachyOS are untouched" || bad "$(ls -A "$TOOLS")"

CASE="helper: a new release while a game runs from the tool"
mktool "$D3" v3
releases <<EOF
$R3 2026-12-15T00:00:00Z $D3
$R2 2026-11-05T00:00:00Z $D2
EOF
printf 'user_settings = {"PROTON_LOG": "1"}\n' >"$TOOL/user_settings.py"
hold map "$TOOL/files/lib/libfoo.so.1"
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && grep -q v2 "$TOOL/proton" \
  && ok "the release in use stays in place" || bad "rc=$RC out=$OUT tag=$(tag_of "$TOOL") err=$ERR"
[ "$(tag_of "$NEXT")" = "$R3" ] && [ -x "$NEXT/proton" ] && grep -q "a game runs from $TOOL: $R3 is ready" <<<"$ERR" \
  && ok "the new one waits, checked, in .retroforge-compat-tools.next, and it says so" || bad "next: $(tag_of "$NEXT") err=$ERR"
releases <<EOF
$R2 2026-11-05T00:00:00Z $D2
EOF
tools on
[ "$RC" = 0 ] && [ ! -e "$NEXT" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && ok "withdrawn upstream meanwhile: dropped" || bad "rc=$RC err=$ERR $(ls -A "$SROOT")"
releases <<EOF
$R3 2026-12-15T00:00:00Z $D3
$R2 2026-11-05T00:00:00Z $D2
EOF
tools on
[ "$(tag_of "$NEXT")" = "$R3" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && ok "published again: it waits again" || bad "not waiting again: $(tag_of "$NEXT") $(tag_of "$TOOL") err=$ERR"
release
mv "$DL/$D3.tar.xz" "$DL/$D3.away"   # a second download would fail
tools on
[ "$RC" = 0 ] && [ "$(tag_of "$TOOL")" = "$R3" ] && grep -q v3 "$TOOL/proton" && [ ! -e "$NEXT" ] \
  && grep -q "$R3 was downloaded and checked before" <<<"$ERR" && ok "with nothing running from it, the next run puts it in without downloading" \
  || bad "rc=$RC tag=$(tag_of "$TOOL") err=$ERR"
[ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] && ours_only && [ -z "$(leftovers)" ] && ok "under the same name, and nothing left" || bad "$(ls -A "$TOOLS") $(leftovers)"
grep -q PROTON_LOG "$TOOL/user_settings.py" && grep -q "keeping the player's own user_settings.py" <<<"$ERR" \
  && ok "the player's user_settings.py came along" || bad "settings: $(cat "$TOOL/user_settings.py" 2>&1) err=$ERR"
mv "$DL/$D3.away" "$DL/$D3.tar.xz"
rm -f "$TOOL/user_settings.py"; tools on

CASE="helper: folders of the earlier per-release scheme"
rm -rf "$SROOT"; mkdir -p "$TOOLS"
for d in "$D0" "$D1"; do   # as the earlier helper left them: the tarball's folder and a marker naming the version
  tar -xJf "$DL/$d.tar.xz" -C "$TOOLS"
  printf 'name: proton-cachyos-arm64\nversion: cachyos-%s\nsha256: %s\n' "$d" "$(digest sha256 "$DL/$d.tar.xz")" >"$TOOLS/$d/.retroforge-pin"
done
cp "$T/sarek.py" "$TOOLS/$D1/user_settings.py"
printf 'user_settings = {"PROTON_LOG": "1"}\n' >"$TOOLS/$D0/user_settings.py"
releases <<EOF
$R2 2026-11-05T00:00:00Z $D2
$R1 2026-10-04T21:30:56Z $D1
EOF
hold cwd "$TOOLS/$D1/files"
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && [ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] \
  && ok "the one-name folder is installed" || bad "rc=$RC out=$OUT err=$ERR"
[ ! -e "$TOOLS/$D0" ] && grep -q "removing $D0, of the earlier per-release scheme" <<<"$ERR" && ok "an earlier folder goes once it is in" || bad "$(ls -A "$TOOLS") err=$ERR"
[ -x "$TOOLS/$D1/proton" ] && grep -q "keeping $D1, of the earlier per-release scheme, while something runs from it" <<<"$ERR" \
  && ok "one a process works in stays" || bad "$(ls -A "$TOOLS") err=$ERR"
grep -q PROTON_LOG "$TOOL/user_settings.py" && ok "the player's user_settings.py from an earlier folder came along" || bad "settings: $(cat "$TOOL/user_settings.py" 2>&1)"
release
tools on
[ "$RC" = 0 ] && [ "$(ls -A "$TOOLS")" = "$STABLE" ] && grep -q "removing $D1" <<<"$ERR" && ok "and goes at the next run" || bad "rc=$RC $(ls -A "$TOOLS") err=$ERR"
rm -f "$TOOL/user_settings.py"; tools on

CASE="helper: a tag in the pin"
releases <<EOF
$R3 2026-12-15T00:00:00Z $D3
$R2 2026-11-05T00:00:00Z $D2 badsidecar
$R1 2026-10-04T21:30:56Z $D1
EOF
mkpin "$R1"
tools on
[ "$RC" = 0 ] && [ "$(tag_of "$TOOL")" = "$R1" ] && grep -q v1 "$TOOL/proton" && [ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] \
  && ok "installs that release, under the same name, though the channel has newer" || bad "rc=$RC tag=$(tag_of "$TOOL") err=$ERR"
[ "$REQS" = "/repos/CachyOS/proton-cachyos/releases/tags/$R1" ] && ok "asking GitHub for it alone" || bad "requests: $REQS"
echo 500 >"$API/status"
tools on
[ "$RC" = 0 ] && [ "$(asked)" = 0 ] && [ -z "$ERR" ] && ok "once it is in, asks nothing" || bad "rc=$RC requests=$REQS err=$ERR"
rm -f "$API/status"
mkpin "$R2" "$(printf '0%.0s' {1..128})"
tools on
[ "$RC" = 1 ] && grep -q "sha512 mismatch" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] && ok "with a sha512 the tarball does not have: refused" || bad "rc=$RC err=$ERR"
mkpin "$R2" "$(digest sha512 "$DL/$D2.tar.xz")"
tools on
[ "$RC" = 0 ] && [ "$(tag_of "$TOOL")" = "$R2" ] && ok "with its sha512: installed, its own (bad) .sha512sum not used" || bad "rc=$RC err=$ERR"
mkpin cachyos-11.0-20990101-slr
tools on
[ "$RC" = 0 ] && grep -q "answered 404" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R2" ] && ok "a tag GitHub does not have: the installed release stays" || bad "rc=$RC err=$ERR"
mkpin
printf 'name: proton-cachyos-arm64\n' >"$T/bad.pin"
OUT="$(RETROFORGE_STEAM_ROOT="$SROOT" RETROFORGE_STEAM_COMPAT_PIN="$T/bad.pin" python3 "$HELPER" on 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q "needs name, releases, asset, dir, display_name" <<<"$OUT" && ok "a pin without the channel's fields: exit 1" || bad "rc=$RC out=$OUT"

CASE="helper: a killed run"
mkdir -p "$SROOT/.retroforge-compat-tools-dead/tree/$D3"; echo x >"$SROOT/.retroforge-compat-tools-dead/tool.tar.xz"
tools on
[ "$RC" = 0 ] && [ -z "$(leftovers)" ] && [ "$(tag_of "$TOOL")" = "$R3" ] && ok "what it left is swept on the next run" || bad "rc=$RC left: $(leftovers) err=$ERR"

CASE="helper: our folder, broken"
rm -f "$TOOL/proton"
tools on
[ "$RC" = 0 ] && [ -x "$TOOL/proton" ] && grep -q v3 "$TOOL/proton" && ok "a folder of ours without proton is installed again" || bad "rc=$RC err=$ERR"

CASE="helper: the tool's name is the player's"
rm -rf "$TOOL"; mkdir -p "$TOOL"; echo player >"$TOOL/proton"
tools on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ "$(cat "$TOOL/proton")" = player ] \
  && [ ! -e "$TOOL/.retroforge-pin" ] && [ ! -e "$TOOL/user_settings.py" ] && [ "$(asked)" = 0 ] \
  && grep -q "not installed by RetroForge" <<<"$ERR" && ok "left alone, nothing asked or downloaded, and said so" || bad "rc=$RC out=$OUT err=$ERR"
rm -rf "$TOOL"

CASE="helper: tarball without its folder"
mktool "$DX" vx no-dir
releases <<EOF
$RX 2026-12-31T00:00:00Z $DX
EOF
tools on
[ "$RC" = 1 ] && grep -q "has no $DX/" <<<"$ERR" && [ ! -e "$TOOL" ] && [ ! -e "$TOOLS/$DX-renamed" ] && [ -z "$(leftovers)" ] \
  && ok "refused, nothing installed or left" || bad "rc=$RC err=$ERR $(ls -A "$TOOLS")"

CASE="helper: tarball without proton"
mktool "$DX" vx no-proton; releases <<<"$RX 2026-12-31T00:00:00Z $DX"
tools on
[ "$RC" = 1 ] && [ ! -e "$TOOL" ] && ok "refused, nothing installed" || bad "rc=$RC err=$ERR"

CASE="helper: a compatibilitytool.vdf it cannot rename"
mktool "$DX" vx bad-vdf; releases <<<"$RX 2026-12-31T00:00:00Z $DX"
tools on
[ "$RC" = 1 ] && grep -q "could not name $DX's compatibilitytool.vdf $STABLE" <<<"$ERR" && [ ! -e "$TOOL" ] && [ -z "$(leftovers)" ] \
  && ok "two tools in it: refused, nothing installed" || bad "rc=$RC err=$ERR"

CASE="helper: another run holds the lock"
releases <<<"$R3 2026-12-15T00:00:00Z $D3"
python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' \
  "$SROOT/.retroforge-compat-tools.lock" "$T/locked" &
HOLDER=$!
for _ in $(seq 50); do [ -e "$T/locked" ] && break; sleep 0.1; done
tools on
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$TOOL" ] && [ "$(asked)" = 0 ] && grep -q "already running" <<<"$ERR" \
  && ok "exits at once, asks and installs nothing" || bad "rc=$RC out=$OUT err=$ERR"
release
tools on
[ "$RC" = 0 ] && [ -x "$TOOL/proton" ] && ok "and the next run installs" || bad "rc=$RC err=$ERR"

CASE="helper: offline on a fresh card"
rm -rf "$SROOT"
mkpin "" "" "http://127.0.0.1:1/repos/CachyOS/proton-cachyos/releases"
tools on
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "could not ask GitHub's API.*no proton-cachyos-arm64 is installed" <<<"$ERR" && [ -z "$(ls -A "$TOOLS")" ] \
  && ok "exit 1, says what it could not ask, no tool" || bad "rc=$RC out=$OUT err=$ERR"
tools off
[ "$RC" = 0 ] && ok "off with no tool is nothing to do" || bad "rc=$RC err=$ERR"
mkpin

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
# RETROFORGE_STEAM_X86_GUEST=0: the wrapper's FEX guest block has its own suite (test-steam-x86-guest.sh);
# here it would reach the real helper (and on a device start a real 1.4 GB download).
STUBS=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u PROTON_DXVK_SAREK -u RETROFORGE_STEAM_SAREK
       -u RETROFORGE_SOC_CLASS HOME="$WHOME" PATH="$W/bin:$PATH" RETROFORGE_DEVICE_ENV="$W/device-env"
       RETROFORGE_STEAM_COMPAT_TOOLS="$W/helper" RETROFORGE_STEAM_X86_GUEST=0 RETROFORGE_STEAM_DIRECT_CLI="$W/no-direct-cli")
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
mkpin; releases <<<"$R3 2026-12-15T00:00:00Z $D3"
"${NOPROXY[@]}" HOME="$WHOME" RETROFORGE_STEAM_ROOT="$WROOT" RETROFORGE_STEAM_COMPAT_PIN="$PIN" python3 "$HELPER" on >/dev/null 2>&1
[ -f "$WROOT/compatibilitytools.d/$STABLE/user_settings.py" ] || bad "fixture: no user_settings.py to turn off"
reset SM6115 1
SOUT="$("${STUBS[@]}" RETROFORGE_STEAM_COMPAT_TOOLS="$HELPER" RETROFORGE_STEAM_COMPAT_PIN="$PIN" bash "$CLI" off 2>"$W/err")"
[ "$SOUT" = off ] && [ ! -e "$WROOT/compatibilitytools.d/$STABLE/user_settings.py" ] && [ -x "$WROOT/compatibilitytools.d/$STABLE/proton" ] \
  && ok "Sarek is off in the installed tool, which stays" || bad "out=$SOUT err=$(cat "$W/err")"
rm -f "$WCONF"

# ================================================================================================
# The wrapper, with the bootstrap and the client stubbed too, and the real setting command.
mkdir -p "$W/rt"
cat >"$W/rt/run" <<EOF
#!/usr/bin/env bash
echo "sarek: \${PROTON_DXVK_SAREK-unset}" >"$W/client"
echo client >>"$W/sequence"
EOF
cat >"$W/bootstrap" <<EOF
#!/usr/bin/env bash
mkdir -p "\$RETROFORGE_STEAM_ROOT/steamrtarm64"; echo "$W/rt/run"
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
mkdir -p "$WROOT/compatibilitytools.d/$STABLE"; touch "$WROOT/compatibilitytools.d/$STABLE/.retroforge-pin" "$WROOT/compatibilitytools.d/$STABLE/user_settings.py"
wrap SM6115 1
[ "$(tr '\n' ' ' <"$W/sequence")" = "helper off client " ] && ok "with Sarek on in a tool of ours, steam-compat-tools off runs before the client" \
  || bad "sequence: $(cat "$W/sequence" 2>&1)"
rm -rf "$WROOT/compatibilitytools.d/$STABLE"

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

# ================================================================================================
# ARMv8.0: proton-armv8.pin (sunshineinabox/proton-armv8), taken when /proc/cpuinfo has no `atomics`:
# .tar.zst assets with a <asset>.sha512 sidecar; experimental releases are prereleases.
PIN8_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/proton-armv8.pin"
CASE="armv8: the real pin"
python3 - "$PIN8_REAL" <<'PY' && ok "stable channel: proton-armv8's API, its .tar.zst with .sha512, one folder" || bad "proton-armv8.pin is not that"
import re, sys
f = dict(re.findall(r"^(\w+):[ \t]*(.*?)[ \t]*$", open(sys.argv[1]).read(), re.M))
assert f["releases"] == "https://api.github.com/repos/sunshineinabox/proton-armv8/releases", f
assert f["asset"] == "proton-armv8-proton-*.tar.zst" and f["sidecar"] == ".sha512", f
assert f["dir"] == "proton-armv8-retroforge" and "tag" not in f and "prereleases" not in f, f
PY

S8="$T/home8/.local/share/Steam"; TOOLS8="$S8/compatibilitytools.d"; DIR8=proton-armv8-retroforge
PINS8="$T/pins8"; mkdir -p "$PINS8"
{ printf 'name: proton-armv8\nreleases: %s\nasset: proton-armv8-proton-*.tar.zst\nsidecar: .sha512\n' "$RELEASES"
  printf 'dir: %s\ndisplay_name: Proton ARMv8.0 (RetroForge)\n' "$DIR8"; } >"$PINS8/proton-armv8.pin"
{ printf 'name: proton-armv8-experimental\nreleases: %s\nasset: proton-armv8-experimental-*.tar.zst\n' "$RELEASES"
  printf 'sidecar: .sha512\nprereleases: yes\ndir: proton-armv8-experimental-retroforge\ndisplay_name: Exp\n'; } >"$PINS8/exp.pin"
grep -v '^prereleases:' "$PINS8/exp.pin" >"$PINS8/exp-noprerelease.pin"
mkpin; cp "$PIN" "$PINS8/proton-cachyos-arm64.pin"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n' >"$T/cpuinfo-v80"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid\n' >"$T/cpuinfo-v82"

mktool8() {  # mktool8 <top> <marker>: $DL/<top>.tar.zst
  mktool "$1" "$2" &&
    python3 -c 'import lzma, sys; open(sys.argv[2], "wb").write(lzma.open(sys.argv[1]).read())' "$DL/$1.tar.xz" "$DL/$1.tar" &&
    rm -f "$DL/$1.tar.xz" && zstd -q -f --rm "$DL/$1.tar" -o "$DL/$1.tar.zst"
}
cat >"$T/releases8.py" <<'PY'
import hashlib, json, os, sys
dl, out = sys.argv[1:3]
rels = []
for line in sys.stdin:
    if not line.strip():
        continue
    tag, published, top, *flags = line.split()
    path = os.path.join(dl, top + ".tar.zst")
    data = open(path, "rb").read()
    with open(path + ".sha512", "w") as f:
        f.write(("0" * 128 if "badsidecar" in flags else hashlib.sha512(data).hexdigest()) + f"  {top}.tar.zst\n")
    rels.append({"tag_name": tag, "published_at": published, "draft": False, "prerelease": "prerelease" in flags,
                 "assets": [{"name": top + ".tar.zst", "state": "uploaded", "browser_download_url": "file://" + path,
                             "digest": "sha256:" + hashlib.sha256(data).hexdigest()},
                            {"name": top + ".tar.zst.sha512", "state": "uploaded",
                             "browser_download_url": "file://" + path + ".sha512"}]})
json.dump(rels, open(out, "w"), indent=1)
PY
releases8() { python3 "$T/releases8.py" "$DL" "$API/releases.json"; }
tools8() {  # tools8 <cpuinfo> <pin|-> <args>: the helper against $S8, its pin chosen by the CPU unless given
  local pin=()
  [ "$2" != - ] && pin=(RETROFORGE_STEAM_COMPAT_PIN="$2")
  : >"$API/requests.log"
  OUT="$("${NOPROXY[@]}" HOME="$T/home8" RETROFORGE_STEAM_ROOT="$S8" RETROFORGE_STEAM_PINS="$PINS8" \
         RETROFORGE_CPUINFO="$1" "${pin[@]}" python3 "$HELPER" "${@:3}" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
for t in proton-11.0-2c proton-11.0-2e experimental-11.0-20261014; do mktool8 "proton-armv8-$t" "armv8 $t"; done
releases8 <<EOF
armv8-experimental-11.0-20261014 2026-10-22T13:00:00Z proton-armv8-experimental-11.0-20261014 prerelease
armv8-proton-11.0-2e 2026-10-22T12:00:00Z proton-armv8-proton-11.0-2e
armv8-proton-11.0-2c 2026-10-01T12:00:00Z proton-armv8-proton-11.0-2c
EOF

CASE="armv8: an ARMv8.0 CPU"
tools8 "$T/cpuinfo-v80" - on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOLS8/$DIR8" ] && [ "$(tag_of "$TOOLS8/$DIR8")" = armv8-proton-11.0-2e ] \
  && ok "proton-armv8.pin: the newest stable .tar.zst, checked by its .sha512" || bad "rc=$RC out=$OUT err=$ERR"
grep -q "armv8 proton-11.0-2e" "$TOOLS8/$DIR8/proton" && [ -L "$TOOLS8/$DIR8/files/lib/libfoo.so" ] \
  && ok "unpacked whole, symlinks kept" || bad "$(ls -la "$TOOLS8/$DIR8" 2>&1 | head -5)"
[ "$(vdf_strings "$TOOLS8/$DIR8")" = "compatibilitytools|compat_tools|$DIR8|install_path|.|display_name|Proton ARMv8.0 (RetroForge)|from_oslist|windows|to_oslist|linux" ] \
  && ok "named $DIR8 for Steam" || bad "$(vdf_strings "$TOOLS8/$DIR8")"
[ "$(settings "$TOOLS8/$DIR8")" = '{"PROTON_DXVK_SAREK": "1"}' ] && ok "DXVK-Sarek on in it" || bad "$(settings "$TOOLS8/$DIR8" 2>&1)"

CASE="armv8: a CPU with atomics"
rm -rf "$T/home8"
tools8 "$T/cpuinfo-v82" - on
[ "$RC" = 1 ] && grep -q "proton-cachyos-\*-slr-arm64.tar.xz" <<<"$ERR" && [ ! -e "$TOOLS8/$DIR8" ] \
  && ok "keeps proton-cachyos-arm64.pin" || bad "rc=$RC err=$ERR"

CASE="armv8: experimental"
rm -rf "$T/home8"
tools8 "$T/cpuinfo-v80" "$PINS8/exp.pin" on
[ "$RC" = 0 ] && [ "$(tag_of "$TOOLS8/proton-armv8-experimental-retroforge")" = armv8-experimental-11.0-20261014 ] \
  && ok "prereleases: yes takes the prerelease" || bad "rc=$RC err=$ERR"
rm -rf "$T/home8"
tools8 "$T/cpuinfo-v80" "$PINS8/exp-noprerelease.pin" on
[ "$RC" = 1 ] && grep -q "with its checksum" <<<"$ERR" && ok "without it, a prerelease is skipped" || bad "rc=$RC err=$ERR"

CASE="armv8: a bad .sha512"
rm -rf "$T/home8"
releases8 <<EOF
armv8-proton-11.0-2e 2026-10-22T12:00:00Z proton-armv8-proton-11.0-2e badsidecar
EOF
tools8 "$T/cpuinfo-v80" - on
[ "$RC" = 1 ] && grep -q "sha512 mismatch" <<<"$ERR" && [ ! -e "$TOOLS8/$DIR8" ] && [ -z "$(find "$S8" -maxdepth 1 -name '.retroforge-compat-tools-*')" ] \
  && ok "refused, nothing installed, nothing left" || bad "rc=$RC err=$ERR"

CASE="armv8: off"
rm -rf "$T/home8"
releases8 <<EOF
armv8-proton-11.0-2e 2026-10-22T12:00:00Z proton-armv8-proton-11.0-2e
EOF
tools8 "$T/cpuinfo-v80" - on
mkdir -p "$TOOLS8/$STABLE"
printf 'name: proton-cachyos-arm64\ntag: %s\n' "$R1" >"$TOOLS8/$STABLE/.retroforge-pin"
cp "$TOOLS8/$DIR8/user_settings.py" "$TOOLS8/$STABLE/user_settings.py"
tools8 "$T/cpuinfo-v80" - off
[ "$RC" = 0 ] && [ ! -e "$TOOLS8/$DIR8/user_settings.py" ] && [ ! -e "$TOOLS8/$STABLE/user_settings.py" ] && [ -e "$TOOLS8/$DIR8/proton" ] \
  && ok "Sarek off in it and in a Proton-CachyOS left on the device; the tools stay" || bad "rc=$RC err=$ERR"

# ================================================================================================
# entry: another kind of tool (fex-armv8.pin, retroforge-steam-fex), beside Proton.
FEXDIR=fex-armv8-retroforge
{ printf 'name: fex-armv8\nreleases: %s\nasset: fex-armv8-*.tar.zst\nsidecar: .sha512\n' "$RELEASES"
  printf 'dir: %s\ndisplay_name: FEX ARMv8.0 (RetroForge)\nentry: FEXCompatTool\n' "$FEXDIR"; } >"$PINS8/fex.pin"
mktoolfex() {  # mktoolfex <top> [nocompat]: $DL/<top>.tar.zst, a FEX tool's folder (no proton)
  local d="$T/mkfex/$1"
  rm -rf "$T/mkfex"; mkdir -p "$d/usr/bin" "$d/rootfs"
  printf '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "%s"\n    {\n      "install_path" "."\n      "display_name" "FEX ARMv8.0"\n      "from_oslist" "linux"\n      "to_oslist" "linux"\n    }\n  }\n}\n' "$1" >"$d/compatibilitytool.vdf"
  printf '"manifest"\n{\n  "commandline" "/fex-compat-tool %%verb%% --"\n  "compatmanager_layer_name" "fex"\n}\n' >"$d/toolmanifest.vdf"
  echo "$1" >"$d/usr/bin/FEX"; [ "${2:-}" = nocompat ] || echo "$1" >"$d/FEXCompatTool"
  tar -C "$T/mkfex" -cf - "$1" | zstd -q -f -o "$DL/$1.tar.zst"
}

CASE="entry: a FEX tool"
rm -rf "$T/home8"; mktoolfex fex-armv8-FEX-2607-76-g37265b1
releases8 <<EOF
fex-armv8-FEX-2607-76-g37265b1 2026-10-23T06:00:00Z fex-armv8-FEX-2607-76-g37265b1
armv8-proton-11.0-2e 2026-10-22T12:00:00Z proton-armv8-proton-11.0-2e
EOF
tools8 "$T/cpuinfo-v80" "$PINS8/fex.pin" on
[ "$RC" = 0 ] && [ "$OUT" = "$TOOLS8/$FEXDIR" ] && [ "$(tag_of "$TOOLS8/$FEXDIR")" = fex-armv8-FEX-2607-76-g37265b1 ] \
  && ok "its release, among Proton's, checked by its .sha512" || bad "rc=$RC out=$OUT err=$ERR"
[ "$(vdf_strings "$TOOLS8/$FEXDIR")" = "compatibilitytools|compat_tools|$FEXDIR|install_path|.|display_name|FEX ARMv8.0 (RetroForge)|from_oslist|linux|to_oslist|linux" ] \
  && ok "named $FEXDIR for Steam" || bad "$(vdf_strings "$TOOLS8/$FEXDIR")"
[ -f "$TOOLS8/$FEXDIR/FEXCompatTool" ] && [ ! -e "$TOOLS8/$FEXDIR/user_settings.py" ] && [ ! -e "$TOOLS8/$FEXDIR/proton" ] \
  && ok "checked by FEXCompatTool, no proton, nothing of Sarek" || bad "$(ls -a "$TOOLS8/$FEXDIR")"
[ -e "$S8/.retroforge-fex-armv8.lock" ] && [ ! -e "$S8/.retroforge-compat-tools.lock" ] \
  && ok "its own lock, not Proton's" || bad "$(ls -a "$S8")"
tools8 "$T/cpuinfo-v80" - on
[ "$RC" = 0 ] && [ -e "$TOOLS8/$DIR8/proton" ] && [ "$(tag_of "$TOOLS8/$FEXDIR")" = fex-armv8-FEX-2607-76-g37265b1 ] \
  && ok "Proton installs beside it, and leaves it alone" || bad "rc=$RC err=$ERR"
tools8 "$T/cpuinfo-v80" "$PINS8/fex.pin" off
[ "$RC" = 0 ] && [ -f "$TOOLS8/$FEXDIR/FEXCompatTool" ] && [ -f "$TOOLS8/$DIR8/user_settings.py" ] \
  && ok "off: nothing to do for it, and Proton's Sarek stays" || bad "rc=$RC err=$ERR"

CASE="entry: a FEX tarball without it"
rm -rf "$T/home8"; mktoolfex fex-armv8-FEX-2607-76-g37265b1 nocompat
releases8 <<EOF
fex-armv8-FEX-2607-76-g37265b1 2026-10-23T06:00:00Z fex-armv8-FEX-2607-76-g37265b1
EOF
tools8 "$T/cpuinfo-v80" "$PINS8/fex.pin" on
[ "$RC" = 1 ] && grep -q "has no fex-armv8-FEX-2607-76-g37265b1/ with compatibilitytool.vdf, toolmanifest.vdf, FEXCompatTool" <<<"$ERR" \
  && [ ! -e "$TOOLS8/$FEXDIR" ] && ok "refused, nothing installed" || bad "rc=$RC err=$ERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
