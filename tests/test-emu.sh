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
  https://github.com/example/dummy/releases/download/nightly/Dummy-*-arm64.AppImage)
    src="$W/srv/nightly.AppImage"; [ -f "$W/srv/override" ] && src="$W/srv/override"
    [ -f "\$src" ] || exit 22
    cp "\$src" "\${out:?no -o}" ;;
  https://data.example/db)
    [ -f "$W/srv/fail-data" ] && exit 22
    cp "$W/srv/data" "\${out:?no -o}" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$W/bin/curl"

D="$W/emus"
run() {  # run <args...>: sets OUT, ERR, RC
  OUT="$(HOME="$W/home" QFORGE_CURL="$W/bin/curl" QFORGE_EMU_DIR="$D" QFORGE_CATALOG="$W/catalog.json" \
    python3 "$EMU" "$@" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}
reset() { rm -rf "$D" "$W/home" "$W/curl.log" "$W/srv/override" "$W/srv/fail-download" "$W/srv/fail-data"; mkdir -p "$D" "$W/home"; }
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
CASE="data files"
# RPCS3 fetches its per-game config database only from its Qt game list, never with --no-gui:
# the catalog's "data" files are fetched after an install or update instead (HW 2026-10-07).
with_data() {  # with_data <json list>: add "data" to the catalog's dummy entry
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["emulators"]["dummy"]["data"]=json.loads(sys.argv[2]); json.dump(c, open(sys.argv[1], "w"))' \
    "$W/catalog.json" "$1"
}
DB='[{"url": "https://data.example/db", "to": ".config/dummy/db.dat"}]'
printf 'database one' > "$W/srv/data"
reset; catalog v1; api v1; with_data "$DB"
run install dummy
[ "$RC" = 0 ] && [ "$(cat "$W/home/.config/dummy/db.dat" 2>/dev/null)" = "database one" ] \
  && ok "an install fetches the catalog's data file into the player's home" || bad "data fetch: rc=$RC $ERR"
pct_only && ok "stdout stays N% lines only" || bad "stdout: $OUT"
grep "data.example/db" "$W/curl.log" | grep -q -- "--proto =https" && ok "data downloads are https only too" || bad "data curl args: $(grep data.example "$W/curl.log")"
[ -z "$(find "$W/home" -name '*.qforge-part')" ] && ok "no partial file left" || bad "a .qforge-part was left"
: > "$W/curl.log"; printf 'database two' > "$W/srv/data"
run install dummy
[ "$RC" = 0 ] && ! grep -q data.example "$W/curl.log" && [ "$(cat "$W/home/.config/dummy/db.dat")" = "database one" ] \
  && ok "not fetched again while the pin is already current" || bad "refetched on a no-op install"
catalog v2; api v2; with_data "$DB"; touch "$W/srv/fail-data"
run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = "v2.AppImage" ] && [ "$(cat "$W/home/.config/dummy/db.dat")" = "database one" ] \
  && grep -q "could not fetch ~/.config/dummy/db.dat" <<<"$ERR" \
  && ok "a failed data fetch keeps the previous file, warns, and the update still succeeds" || bad "failed data fetch: rc=$RC $ERR"
rm -f "$W/srv/fail-data"; catalog v3; api v3; with_data "$DB"
run install dummy
[ "$RC" = 0 ] && [ "$(cat "$W/home/.config/dummy/db.dat")" = "database two" ] && ok "an update refreshes it" || bad "update did not refresh: $ERR"
reset; catalog v1; api v1
with_data '[{"url": "http://data.example/db", "to": "a"}, {"url": "https://data.example/db", "to": "../escape"}, {"url": "https://data.example/db", "to": "/abs"}]'
run install dummy
[ "$RC" = 0 ] && [ "$(grep -c "skipping a bad data entry" <<<"$ERR")" = 3 ] && ! grep -q data.example "$W/curl.log" && [ ! -e "$W/escape" ] \
  && ok "plain http, '..' and absolute targets are skipped (never fetched), the install succeeds" || bad "bad entries: rc=$RC $ERR"

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
CASE="nightly channel"
# Cemu has no aarch64 release that runs (2.6 predates the AArch64 recompiler): its catalog entry
# follows pkgforge-dev's rolling `nightly` release (user decision 2026-10-07). No sha256 in the
# catalog: GitHub's per-asset digest is required instead and the bytes must match it; the build is
# installed as nightly-<id>, <id> = the asset pattern's capture group (the commit in the file name).
nightly_catalog() {  # nightly_catalog [asset-pattern]
  cat > "$W/catalog.json" <<EOF
{"schema": 1, "emulators": {"dummy": {
  "name": "Dummy", "author": "A. Dummy", "systems": ["psx"], "github": "example/dummy", "tag": "nightly",
  "channel": "nightly", "asset": "${1:-^Dummy-([0-9a-f]+)-arm64\\\\.AppImage\$}", "size": 1000,
  "homepage": "https://example.org/", "licence": {"name": "MIT", "url": "https://example.org/LICENSE"}}}}
EOF
}
nightly_api() {  # nightly_api <id> <content> [digest]: the nightly release now carries build <id>
  printf '%s' "$2" > "$W/srv/nightly.AppImage"
  local f="$W/srv/nightly.AppImage" digest
  digest="${3-sha256:$(sha "$f")}"
  cat > "$W/srv/api-nightly.json" <<EOF
{"tag_name": "nightly", "assets": [
  {"name": "Dummy-$1-x86_64.AppImage", "size": 1, "digest": "sha256:00", "browser_download_url": "https://github.com/example/dummy/releases/download/nightly/Dummy-$1-x86_64.AppImage"},
  {"name": "Dummy-$1-arm64.AppImage", "size": $(size "$f"), "digest": "$digest",
   "browser_download_url": "https://github.com/example/dummy/releases/download/nightly/Dummy-$1-arm64.AppImage"}]}
EOF
}
reset; nightly_catalog; nightly_api abc123 "nightly build abc"
run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = nightly-abc123.AppImage ] \
  && ok "installs the current nightly as nightly-<commit>.AppImage" || bad "rc=$RC current=$(readlink "$D/dummy/current") $ERR"
cmp -s "$D/dummy/nightly-abc123.AppImage" "$W/srv/nightly.AppImage" && ok "the AppImage is the served bytes" || bad "installed file differs"
pct_only && ok "stdout is only forward N% lines ending at 100%" || bad "stdout was: $(tr '\n' '|' <<<"$OUT")"
: > "$W/curl.log"; run install dummy
[ "$RC" = 0 ] && [ "$OUT" = "100%" ] && grep -q 'api.github.com' "$W/curl.log" && ! grep -q 'download/nightly/' "$W/curl.log" \
  && grep -q "already the latest" <<<"$ERR" \
  && ok "same build again: asks GitHub, downloads nothing, says it is already the latest" || bad "rc=$RC out=$OUT $ERR"
nightly_api def456 "nightly build def, newer"
run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = nightly-def456.AppImage ] && [ -f "$D/dummy/nightly-abc123.AppImage" ] \
  && ok "a newer nightly installs, the previous one is kept for a rollback" || bad "rc=$RC left: $(ls "$D/dummy" | tr '\n' ' ')"
run list
[ "$(field channel)" = '"nightly"' ] && [ "$(field installed)" = '"nightly-def456"' ] && [ "$(field update)" = false ] \
  && ok "list: channel nightly, installed nightly-<commit>, update unknown offline (false)" \
  || bad "got channel=$(field channel) installed=$(field installed) update=$(field update)"
# Refusals: no digest to check against, bytes that do not match it.
reset; nightly_catalog; nightly_api abc123 "nightly build abc" ""
run install dummy
[ "$RC" = 4 ] && ! grep -q 'download/nightly/' "$W/curl.log" && [ ! -e "$D/dummy/current" ] \
  && ok "no GitHub digest: exit 4, nothing downloaded" || bad "rc=$RC $ERR"
reset; nightly_catalog; nightly_api abc123 "nightly build abc"; printf 'tampered' > "$W/srv/override"
run install dummy
[ "$RC" = 4 ] && [ -z "$(find "$D" -type f)" ] && ok "bytes that do not hash to GitHub's digest: exit 4, nothing left" || bad "rc=$RC left: $(find "$D" -type f)"
# No capture group: the build is named by its digest.
reset; nightly_catalog '^Dummy-[0-9a-f]+-arm64\\.AppImage$'; nightly_api abc123 "nightly build abc"
run install dummy
want="nightly-$(sha "$W/srv/nightly.AppImage" | cut -c1-12).AppImage"
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = "$want" ] && ok "no capture group: named nightly-<sha256 prefix>" || bad "current=$(readlink "$D/dummy/current") want $want: $ERR"
# A pinned entry stays pinned: a sha256 is still required without the channel.
reset; nightly_catalog; python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); del c["emulators"]["dummy"]["channel"]; json.dump(c, open(sys.argv[1], "w"))' "$W/catalog.json"
nightly_api abc123 "nightly build abc"; run install dummy
[ "$RC" = 4 ] && [ ! -e "$D/dummy/current" ] && ok "no channel and no sha256: refused (exit 4)" || bad "rc=$RC $ERR"
reset; nightly_catalog; python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["emulators"]["dummy"]["channel"]="weekly"; json.dump(c, open(sys.argv[1], "w"))' "$W/catalog.json"
run install dummy
[ "$RC" = 4 ] && [ ! -e "$W/curl.log" ] && ok "an unknown channel is refused before any download" || bad "rc=$RC"

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
