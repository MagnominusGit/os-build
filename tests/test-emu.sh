#!/usr/bin/env bash
# Offline test for /usr/bin/qforge-emu — the emulator manager the QForge plugin drives.
#
#   tests/test-emu.sh
#
# WHY THIS EXISTS. qforge-emu puts executables from the internet into the player's home and makes
# them what every ROM card runs. Each rule below is what keeps a bad download from becoming the
# emulator, and none of it shows when the download simply works:
#
#   - the pinned release's asset must still be the one QForge tested: GitHub's digest and size must
#     equal the catalog's BEFORE anything is fetched (an upstream that re-uploads under the same tag
#     is refused, not installed);
#   - the downloaded bytes must hash to the catalog's sha256, or nothing changes on disk;
#   - every transfer is https only, redirects included (curl --proto/--proto-redir =https);
#   - `current` flips atomically, the previous AppImage stays (a bad update can be rolled back),
#     older ones go;
#   - stdout is a contract: install prints forward-only `N%` lines and list prints JSON, and nothing
#     else, or the plugin misreads it.
#
# HOW: the shipped rootfs/overlay/usr/bin/qforge-emu runs with its environment seams (QFORGE_CURL,
# QFORGE_EMU_DIR, QFORGE_CATALOG) pointing into a sandbox; curl is a stub that serves a fake GitHub
# API answer and a fake AppImage, and logs every call. No network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT/rootfs/overlay/usr/bin/qforge-emu"
[ -f "$EMU" ] || { echo "no qforge-emu: $EMU" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)" && [ -d "$W" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/srv"

# --- the fake upstream ----------------------------------------------------------------------------
# An AppImage is any bytes here; its sha256 and size go into the catalog and the API answer.
mkasset() {  # mkasset <tag> <content>
  printf '%s' "$2" > "$W/srv/$1.AppImage"
}
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }

# catalog <tag> [sha] [size]: one emulator, dummy, pinned to <tag>.
catalog() {
  local f="$W/srv/$1.AppImage"
  cat > "$W/catalog.json" <<EOF
{"schema": 1, "emulators": {"dummy": {
  "name": "Dummy", "author": "A. Dummy", "systems": ["psx"], "github": "example/dummy", "tag": "$1",
  "asset": "^Dummy-arm64\\\\.AppImage\$", "sha256": "${2:-$(sha "$f")}", "size": ${3:-$(size "$f")},
  "homepage": "https://example.org/", "licence": {"name": "MIT", "url": "https://example.org/LICENSE"}}}}
EOF
}

# api <tag> [digest-sha] [size] [url]: what api.github.com/repos/example/dummy/releases/tags/<tag> says.
api() {
  local f="$W/srv/$1.AppImage"
  cat > "$W/srv/api-$1.json" <<EOF
{"tag_name": "$1", "assets": [
  {"name": "Dummy-x86_64.AppImage", "size": 1, "digest": "sha256:00", "browser_download_url": "https://github.com/example/dummy/releases/download/$1/Dummy-x86_64.AppImage"},
  {"name": "Dummy-arm64.AppImage", "size": ${3:-$(size "$f")}, "digest": "sha256:${2:-$(sha "$f")}",
   "browser_download_url": "${4:-https://github.com/example/dummy/releases/download/$1/Dummy-arm64.AppImage}"}]}
EOF
}

# The curl stub: logs its argv; the API URL gets the JSON, a download URL gets the asset of the tag
# in its path (or $W/srv/override when it exists, to serve wrong bytes). Exit 22 on anything else.
cat > "$W/bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$W/curl.log"
out="" url=""
while [ \$# -gt 0 ]; do
  case \$1 in
    -o|--output) out=\$2; shift 2 ;;
    https://*|http://*) url=\$1; shift ;;
    *) shift ;;
  esac
done
case \$url in
  https://api.github.com/repos/example/dummy/releases/tags/*)
    f="$W/srv/api-\${url##*/}.json"; [ -f "\$f" ] || exit 22
    if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi ;;
  https://github.com/example/dummy/releases/download/*/Dummy-arm64.AppImage)
    tag=\${url%/*}; tag=\${tag##*/}
    src="$W/srv/\$tag.AppImage"; [ -f "$W/srv/override" ] && src="$W/srv/override"
    [ -f "\$src" ] || exit 22
    [ -f "$W/srv/fail-download" ] && exit 56
    cp "\$src" "\${out:?no -o}" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$W/bin/curl"

D="$W/emus"
run() {  # run <args...>: sets OUT, ERR, RC
  OUT="$(QFORGE_CURL="$W/bin/curl" QFORGE_EMU_DIR="$D" QFORGE_CATALOG="$W/catalog.json" \
    python3 "$EMU" "$@" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}
reset() { rm -rf "$D" "$W/curl.log" "$W/srv/override" "$W/srv/fail-download"; mkdir -p "$D"; }
pct_only() {  # every stdout line is N% and they never go down, ending at 100
  awk 'BEGIN{last=-1} !/^[0-9]+%$/ {exit 1} {v=$0+0; if (v < last) exit 1; last=v} END{exit last != 100}' <<<"$OUT"
}

mkasset v1 "dummy build one"
mkasset v2 "dummy build two, longer"
mkasset v3 "dummy build three"

# =================================================================================================
CASE="bad invocations"
reset; catalog v1; api v1
run;                      [ "$RC" = 2 ] && ok "no command: exit 2" || bad "no command exited $RC"
run install;              [ "$RC" = 2 ] && ok "install with no emulator: exit 2" || bad "exited $RC"
run install nosuch;       [ "$RC" = 2 ] && ok "an emulator not in the catalog: exit 2" || bad "exited $RC"
run install ../dummy;     [ "$RC" = 2 ] && ok "a path as the emulator: exit 2" || bad "exited $RC"
run frobnicate dummy;     [ "$RC" = 2 ] && ok "an unknown command: exit 2" || bad "exited $RC"
[ ! -e "$W/curl.log" ] && ok "bad invocations never touch the network" || bad "curl ran for a bad invocation"

# =================================================================================================
CASE="tags"
# pkgforge-dev's AppImage repos (Dolphin) tag releases as <version>@<date>_<id>.
mkasset "2609@2026-10-01_1" "dummy pkgforge-style build"
reset; catalog "2609@2026-10-01_1"; api "2609@2026-10-01_1"
run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = "2609@2026-10-01_1.AppImage" ] \
  && ok "a tag with '@' installs as <tag>.AppImage" || bad "the '@' tag install exited $RC: $ERR"
reset; catalog "v1/../x" "$(sha "$W/srv/v1.AppImage")" "$(size "$W/srv/v1.AppImage")"
run install dummy
[ "$RC" = 4 ] && [ ! -e "$W/curl.log" ] && ok "a tag with '/' is refused before any download (exit 4)" \
  || bad "a '/' tag exited $RC (curl ran: $([ -e "$W/curl.log" ] && echo yes || echo no))"

# =================================================================================================
CASE="install"
reset; catalog v1; api v1
run install dummy
[ "$RC" = 0 ] && ok "exit 0" || bad "install exited $RC: $ERR"
[ "$(readlink "$D/dummy/current")" = v1.AppImage ] && ok "current -> v1.AppImage (relative link)" || bad "current is '$(readlink "$D/dummy/current")'"
cmp -s "$D/dummy/v1.AppImage" "$W/srv/v1.AppImage" && ok "the AppImage is the served bytes" || bad "installed file differs"
[ -x "$D/dummy/v1.AppImage" ] && ok "the AppImage is executable" || bad "not executable"
pct_only && ok "stdout is only forward N% lines ending at 100%" || bad "stdout was: $(tr '\n' '|' <<<"$OUT")"
[ -z "$(find "$D" -name '*.part')" ] && ok "no .part file left" || bad "a .part file was left"
grep -q 'api.github.com/repos/example/dummy/releases/tags/v1' "$W/curl.log" \
  && ok "looks the pinned tag up in the GitHub API" || bad "no API lookup of the pinned tag"
dl="$(grep 'Dummy-arm64.AppImage' "$W/curl.log")"
grep -q 'Dummy-x86_64' "$W/curl.log" && bad "fetched the asset the pattern does not match" || ok "fetches only the asset the pattern matches"
[[ $dl == *"--proto =https"* && $dl == *"--proto-redir =https"* ]] \
  && ok "the download is https only, redirects included" || bad "download curl lacks --proto/--proto-redir =https: $dl"
api_line="$(grep 'api.github.com' "$W/curl.log" | head -1)"
[[ $api_line == *"--proto =https"* ]] && ok "the API call is https only" || bad "API curl lacks --proto =https"
[[ $dl == *"--fail"* ]] && ok "curl --fail: an HTTP error is not saved as the AppImage" || bad "download curl lacks --fail"
[[ $api_line == *"--retry-all-errors"* && $dl == *"--retry-all-errors"* ]] \
  && ok "both calls retry every transient error (Wi-Fi drops: curl 55 on HW)" || bad "a curl call lacks --retry-all-errors"

CASE="install again (already current)"
rm -f "$W/curl.log"
run install dummy
[ "$RC" = 0 ] && [ "$OUT" = "100%" ] && ok "prints 100% and exits 0" || bad "rc=$RC out=$OUT"
[ ! -e "$W/curl.log" ] && ok "downloads nothing when the pinned tag is installed" || bad "re-downloaded an installed tag"

# =================================================================================================
CASE="refusals"
# Upstream re-uploaded under the same tag: the API's digest no longer matches the catalog.
reset; catalog v1; api v1 "$(sha "$W/srv/v2.AppImage")"
run install dummy
[ "$RC" = 4 ] && ok "API digest != catalog sha256: exit 4" || bad "exited $RC"
! grep -q 'Dummy-arm64.AppImage' "$W/curl.log" && ok "... and nothing is downloaded" || bad "downloaded despite the digest mismatch"
[ ! -e "$D/dummy/current" ] && ok "... and nothing is installed" || bad "installed despite the digest mismatch"
reset; catalog v1; api v1 "" 999
run install dummy
[ "$RC" = 4 ] && ok "API size != catalog size: exit 4" || bad "exited $RC"
# The served bytes are not the tested ones.
reset; catalog v1; api v1; cp "$W/srv/v3.AppImage" "$W/srv/override"
run install dummy
[ "$RC" = 4 ] && ok "downloaded bytes with the wrong sha256: exit 4" || bad "exited $RC"
[ ! -e "$D/dummy/current" ] && [ -z "$(find "$D" -type f)" ] && ok "... nothing installed, the .part is deleted" || bad "left: $(find "$D")"
# The API points the download somewhere that is not https.
reset; catalog v1; api v1 "" "" "http://github.com/example/dummy/releases/download/v1/Dummy-arm64.AppImage"
run install dummy
[ "$RC" = 4 ] && ok "an http:// download URL is refused: exit 4" || bad "exited $RC"
! grep -q 'http://' "$W/curl.log" && ok "... and never fetched" || bad "fetched an http URL"
# Network failures.
reset; catalog v1; rm -f "$W/srv/api-v1.json"
run install dummy
[ "$RC" = 3 ] && ok "the API lookup fails: exit 3" || bad "exited $RC"
reset; catalog v1; api v1; touch "$W/srv/fail-download"
run install dummy
[ "$RC" = 3 ] && ok "the download fails: exit 3" || bad "exited $RC"
[ -z "$(find "$D" -type f)" ] && ok "... and leaves no file" || bad "left: $(find "$D" -type f)"
grep -qv '^[0-9]*%$' <<<"$OUT" && bad "stdout carried an error message: $OUT" || ok "errors go to stderr, stdout stays parseable"

# =================================================================================================
CASE="update"
reset; catalog v1; api v1; run install dummy
catalog v2; api v2; run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = v2.AppImage ] && ok "a newer pin installs and current -> v2" || bad "rc=$RC current=$(readlink "$D/dummy/current")"
[ -f "$D/dummy/v1.AppImage" ] && ok "the previous AppImage (v1) is kept for a rollback" || bad "v1 was deleted"
catalog v3; api v3; run install dummy
[ "$(readlink "$D/dummy/current")" = v3.AppImage ] && [ -f "$D/dummy/v2.AppImage" ] && [ ! -e "$D/dummy/v1.AppImage" ] \
  && ok "a third version keeps only current (v3) and previous (v2)" || bad "left: $(ls "$D/dummy" | tr '\n' ' ')"
# A failed update leaves the working install alone.
catalog v1; api v1; cp "$W/srv/v2.AppImage" "$W/srv/override"
run install dummy
[ "$RC" = 4 ] && [ "$(readlink "$D/dummy/current")" = v3.AppImage ] && ok "a failed update keeps current on the working version" || bad "rc=$RC current=$(readlink "$D/dummy/current")"

# =================================================================================================
CASE="list"
reset; catalog v2; api v2
field() { python3 -c 'import json,sys; e=json.loads(sys.argv[1])["emulators"]["dummy"]; print(json.dumps(e[sys.argv[2]]))' "$OUT" "$1" 2>/dev/null; }
run list
[ "$RC" = 0 ] && python3 -c 'import json,sys; json.loads(sys.argv[1])' "$OUT" 2>/dev/null && ok "prints JSON, exit 0" || bad "rc=$RC out=$OUT"
[ "$(field installed)" = null ] && [ "$(field update)" = false ] && [ "$(field pinned)" = '"v2"' ] \
  && ok "not installed: installed null, pinned v2, no update" || bad "got installed=$(field installed) update=$(field update) pinned=$(field pinned)"
[ "$(field name)" = '"Dummy"' ] && [ "$(field size)" = "$(size "$W/srv/v2.AppImage")" ] && [ "$(field licence)" != null ] \
  && [ "$(field author)" = '"A. Dummy"' ] && [ "$(field homepage)" = '"https://example.org/"' ] \
  && ok "carries name, size, author, homepage and licence for the store screen" || bad "missing store fields"
catalog v1; api v1; run install dummy; catalog v2
run list
[ "$(field installed)" = '"v1"' ] && [ "$(field update)" = true ] && ok "v1 installed, v2 pinned: update true" || bad "got installed=$(field installed) update=$(field update)"
calls_before="$(wc -l < "$W/curl.log")"; run list
[ "$(wc -l < "$W/curl.log")" = "$calls_before" ] && ok "list never touches the network" || bad "list called curl"

# =================================================================================================
CASE="remove"
reset; catalog v1; api v1; run install dummy
catalog v2; api v2; run install dummy
run remove dummy
[ "$RC" = 0 ] && [ ! -e "$D/dummy" ] && ok "removes the emulator's folder (every version)" || bad "rc=$RC left: $(ls "$D/dummy" 2>&1)"
run remove dummy
[ "$RC" = 0 ] && ok "removing what is not installed is not an error" || bad "exited $RC"
mkdir -p "$D/other"; touch "$D/other/keep"
run remove dummy
[ -f "$D/other/keep" ] && ok "other emulators are left alone" || bad "touched another emulator"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
