#!/usr/bin/env bash
# Offline test for ota/publish-bundle.sh — its INTEGRITY GATE, its ORDERING and its PRUNE.
#
#   tests/test-publish-bundle.sh
#
# WHY THIS FILE EXISTS. publish-bundle.sh computes $SHA from the LOCAL file before the upload, so the
# hash published in latest.json is only a claim about the served bytes until step 4 reads them back
# through the public url. That gap has no downstream backstop: the client does not check sha256 at
# all (docs/ota.md: the RAUC signature is the integrity gate), so corrupt bytes would surface no
# earlier than each device's own signature verification — after the download, once per device.
#
# THE ASSERTION THAT MATTERS is not "a mismatch is detected" but "a mismatch leaves latest.json
# ALONE". Detection that still flipped the pointer would be worse than no gate at all: it would
# publish the corrupt bundle AND report failure. Every failure case below checks the pointer.
#
# HOW IT WORKS: the real, shipped ota/publish-bundle.sh is executed — not a copy. Its seams are the
# R2_* and RETROFORGE_OTA_* variables it already documents, RETROFORGE_RCLONE (ota/lib-rclone.sh's
# one test seam: rclone_bin returns an absolute path, so PATH cannot shadow it), and PATH for curl and
# rauc. The "bucket" is a local directory: the rclone stub reads and writes it, and the curl stub
# serves it at R2_PUBLIC_BASE. Nothing here needs a network, a credential, a container or a bundle.
#
# WHAT THIS CANNOT COVER: that real R2 preserves bytes and honours Range, and that a real rauc accepts
# the signature. Step 4 covers the first in production, tests/test-verify-signing.sh the second.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$ROOT/ota/publish-bundle.sh"
[ -f "$PUBLISH" ] || { echo "no publish-bundle.sh: $PUBLISH" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

VERSION="9.9.9"
NAME="retroforge-$VERSION.raucb"
BUCKET=retroforge
CH="$W/bucket/$BUCKET/test"          # the channel directory, as the stubs see it

# --- the sandbox ---------------------------------------------------------------------------------
mkdir -p "$W/bin"

# rclone: only the verbs the script uses, against $W/bucket. Whole command lines are logged so a case
# can assert what was asked (the no-cache header), not just what happened. RETROFORGE_TEST_CORRUPT
# makes the stored bundle differ from the source WITHOUT changing its size — the corruption a size
# check would miss, which is the only kind step 4 exists for.
cat >"$W/bin/rclone" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RCLONELOG"
verb="$1"; shift
args=(); include=""
while [ $# -gt 0 ]; do
  case "$1" in
    --s3-chunk-size|--retries|--low-level-retries|--stats|--header-upload) shift 2 ;;
    --include) include="$2"; shift 2 ;;
    --stats-one-line|--files-only) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
localpath() { printf '%s\n' "$BUCKETDIR/${1#r2:}"; }
case "$verb" in
  copyto)
    dest="$(localpath "${args[1]}")"; mkdir -p "$(dirname "$dest")"; cp "${args[0]}" "$dest" || exit 1
    if [ "${RETROFORGE_TEST_CORRUPT:-0}" = 1 ] && [ "${dest##*.}" = raucb ]; then
      # FLIP the byte, never ASSIGN it: a constant written over random bytes is a no-op one run in
      # 256, which once made this suite flake (CI run 34398610843, 2026-09-09).
      orig=$(dd if="$dest" bs=1 skip=3 count=1 status=none | od -An -tu1 | tr -d ' ')
      printf "$(printf '\\%03o' $(( orig ^ 0xFF )))" | dd of="$dest" bs=1 seek=3 conv=notrunc status=none
    fi ;;
  cat)        [ "${TEST_CAT_FAIL:-0}" = 1 ] && exit 1      # a 403 / dropped connection, not "missing"
              f="$(localpath "${args[0]}")"; [ -f "$f" ] || exit 3; cat "$f" ;;
  lsf)        d="$(localpath "${args[0]}")"; [ -d "$d" ] || exit 0
              for x in "$d"/*; do
                [ -f "$x" ] || continue
                b="$(basename "$x")"
                # shellcheck disable=SC2053
                [ -z "$include" ] || [[ $b == $include ]] || continue
                printf '%s\n' "$b"
              done ;;
  deletefile) rm -f -- "$(localpath "${args[0]}")" ;;
  *) echo "stub rclone: unhandled verb $verb" >&2; exit 2 ;;
esac
STUB

# curl: serves $BUCKETDIR/$R2_BUCKET at R2_PUBLIC_BASE. A Range probe answers 206 (or 200 under
# TEST_NO_RANGE); a plain GET returns the bytes. TEST_UNSERVED simulates public access being off.
cat >"$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""; range=0
for a in "$@"; do
  case "$a" in -r) range=1 ;; http*|https*) url="$a" ;; esac
done
printf '%s\n' "$url" >> "$CURLLOG"
[ "${TEST_UNSERVED:-0}" = 1 ] && exit 22
path="${url#"$R2_PUBLIC_BASE"/}"
src="$BUCKETDIR/$R2_BUCKET/$path"
[ -f "$src" ] || exit 22
if [ "$range" = 1 ]; then
  if [ "${TEST_NO_RANGE:-0}" = 1 ]; then printf '200'; else printf '206'; fi
else
  cat "$src"
fi
STUB

# rauc: the signature gate and the manifest read. Both are real gates with their own coverage; here
# they only need to say yes so the cases below reach the upload.
cat >"$W/bin/rauc" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$RAUCLOG"
case "\$*" in
  *--output-format=shell*)
    echo "RAUC_MF_VERSION='$VERSION'"
    echo "RAUC_MF_COMPATIBLE='retroforge'"
    echo "RAUC_META_RETROFORGE_BUILD='20260101T000000Z'"
    echo "RAUC_META_RETROFORGE_GIT='abc1234'"
    echo "RAUC_META_RETROFORGE_MODE='release'"
    ;;
  *) echo "Verified inline signature by 'O = retroforge, CN = retroforge OTA release'" ;;
esac
STUB
chmod +x "$W/bin/rclone" "$W/bin/curl" "$W/bin/rauc"

# A bundle with real bytes, so the local sha256sum and stat are real.
BUNDLE="$W/$NAME"
head -c 4096 /dev/urandom >"$BUNDLE"

# Runs the SHIPPED publisher against the sandbox. Sets OUT/ERR/RC.
run() { # <env assignments...>
  local -a envs=()
  while [ $# -gt 0 ] && [[ $1 == *=* ]]; do envs+=("$1"); shift; done
  : >"$W/rclone.log"; : >"$W/curl.log"; : >"$W/rauc.log"
  OUT="$(env PATH="$W/bin:$PATH" \
      RETROFORGE_RCLONE="$W/bin/rclone" \
      RCLONELOG="$W/rclone.log" CURLLOG="$W/curl.log" RAUCLOG="$W/rauc.log" BUCKETDIR="$W/bucket" \
      R2_ACCOUNT_ID=acct R2_ACCESS_KEY_ID=key R2_SECRET_ACCESS_KEY=secret \
      R2_BUCKET="$BUCKET" R2_PUBLIC_BASE="https://pub.example" \
      "${envs[@]}" bash "$PUBLISH" "$BUNDLE" test 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}

pointer() { cat "$CH/latest.json" 2>/dev/null; }
reset_bucket() { rm -rf "$W/bucket"; mkdir -p "$CH"; }
seed() { for v in "$@"; do printf 'x' >"$CH/retroforge-$v.raucb"; done; }
have() { [ -f "$CH/retroforge-$1.raucb" ]; }

# =================================================================================================
CASE="happy-path"
reset_bucket
run
[ "$RC" = 0 ] && ok "exit 0 when the served bytes match" || bad "exit $RC, expected 0: $ERR"
printf '%s' "$ERR" | grep -q 'serves the bytes that were hashed' \
  && ok "says the served bytes were checked" \
  || bad "never reported checking the served bytes"
pointer | grep -q "\"bundle\": \"$NAME\"" \
  && ok "latest.json names the published bundle" \
  || bad "latest.json does not name $NAME"
published_sha="$(pointer | sed -n 's/.*"sha256": *"\([^"]*\)".*/\1/p')"
actual_sha="$(sha256sum "$CH/$NAME" | cut -d' ' -f1)"
[ -n "$published_sha" ] && [ "$published_sha" = "$actual_sha" ] \
  && ok "the sha256 in latest.json is the hash of the stored object" \
  || bad "published sha256 '$published_sha' != stored object '$actual_sha'"
grep 'copyto .*latest.json' "$W/rclone.log" | grep -q 'Cache-Control: no-cache' \
  && ok "latest.json is uploaded no-cache" \
  || bad "latest.json was uploaded without Cache-Control: no-cache"
# Ordering, proven rather than assumed: the bundle before the pointer.
b_line=$(grep -n "copyto .*$NAME" "$W/rclone.log" | head -1 | cut -d: -f1)
p_line=$(grep -n 'copyto .*latest.json' "$W/rclone.log" | head -1 | cut -d: -f1)
[ -n "$b_line" ] && [ -n "$p_line" ] && [ "$b_line" -lt "$p_line" ] \
  && ok "the bundle is uploaded before latest.json" \
  || bad "upload order wrong (bundle line '${b_line:-none}', pointer line '${p_line:-none}')"

# =================================================================================================
CASE="corrupt-upload-is-caught"
# The bytes change in storage and the size does not, so nothing before step 4 can notice.
reset_bucket
run RETROFORGE_TEST_CORRUPT=1
[ "$RC" != 0 ] && ok "exit $RC -- refuses to publish bytes that changed" \
               || bad "exit 0: a corrupt upload was published"
printf '%s' "$ERR" | grep -q 'CORRUPT OR STALE' \
  && ok "names the failure as corruption, not a transport error" \
  || bad "did not say CORRUPT OR STALE"
# THE assertion. Detection that still flipped the pointer would be worse than no gate.
[ -z "$(pointer)" ] \
  && ok "latest.json was NOT written -- the fleet is never offered the bad bundle" \
  || bad "latest.json exists after a corrupt upload: $(pointer)"

# =================================================================================================
CASE="corrupt-upload-leaves-the-previous-release"
# A channel that already serves something is the real-world case: the cost of getting this wrong is
# not a failed publish, it is taking a working update path down.
reset_bucket
prev='{"version":"1.0.0","bundle":"retroforge-1.0.0.raucb","size":10,"sha256":"deadbeef"}'
printf '%s\n' "$prev" >"$CH/latest.json"
head -c 10 /dev/zero >"$CH/retroforge-1.0.0.raucb"
run RETROFORGE_TEST_CORRUPT=1
[ "$RC" != 0 ] && ok "still fails" || bad "exit 0 on corrupt bytes"
[ "$(pointer)" = "$prev" ] \
  && ok "the previous release is still pointed at, byte for byte" \
  || bad "latest.json was modified: $(pointer)"
[ -f "$CH/retroforge-1.0.0.raucb" ] \
  && ok "the previous bundle was not pruned by a failed publish" \
  || bad "the failed publish pruned the release the fleet is running"

# =================================================================================================
CASE="unreadable-upload-is-a-failure-not-a-shrug"
# Public access off: the bytes are in the bucket but nobody can fetch them. Must fail closed.
reset_bucket
run TEST_UNSERVED=1
[ "$RC" != 0 ] && ok "exit $RC when the bundle is not publicly readable" \
               || bad "exit 0: published a pointer at bytes nobody can read"
printf '%s' "$ERR" | grep -q 'NOT publicly readable' \
  && ok "says why: public access" \
  || bad "did not explain the refusal"
[ -z "$(pointer)" ] \
  && ok "latest.json was NOT written" \
  || bad "latest.json exists: $(pointer)"

CASE="no-range-support-is-a-failure"
# rauc streams a bundle with Range requests; a front end that ignores Range breaks every install.
reset_bucket
run TEST_NO_RANGE=1
[ "$RC" != 0 ] && ok "exit $RC on a 200 to a Range request" || bad "exit 0 without Range support"
[ -z "$(pointer)" ] && ok "latest.json was NOT written" || bad "latest.json exists: $(pointer)"

# =================================================================================================
CASE="a-published-version-is-immutable"
# Re-uploading the bundle the pointer names would swap bytes under devices mid-download.
reset_bucket
printf 'live' >"$CH/$NAME"
live="{\"version\": \"$VERSION\", \"bundle\": \"$NAME\", \"size\": 4, \"sha256\": \"x\"}"
printf '%s\n' "$live" >"$CH/latest.json"
run
[ "$RC" != 0 ] && ok "exit $RC -- refuses to republish the live version" || bad "exit 0: overwrote a live bundle"
[ "$(cat "$CH/$NAME")" = live ] && ok "the live bundle's bytes are untouched" || bad "the live bundle was overwritten"
[ "$(pointer)" = "$live" ] && ok "latest.json is untouched" || bad "latest.json was modified: $(pointer)"

CASE="an-unreadable-pointer-is-not-an-absent-one"
# rclone cat fails the same way for a missing object and for a 403 or a dropped connection. Reading
# the second as "no latest.json" would wave the immutability check through and re-upload the live
# bundle under devices mid-download. The listing says latest.json exists, so this must stop.
reset_bucket
printf 'live' >"$CH/$NAME"
printf '%s\n' "$live" >"$CH/latest.json"
run TEST_CAT_FAIL=1
[ "$RC" != 0 ] && ok "exit $RC when the pointer exists but cannot be read" || bad "exit 0: published blind"
printf '%s' "$ERR" | grep -q 'cannot read test/latest.json' && ok "says it could not read the pointer" || bad "did not explain: $ERR"
grep -q "copyto .*$NAME" "$W/rclone.log" && bad "uploaded the bundle anyway" || ok "uploaded nothing"
[ "$(cat "$CH/$NAME")" = live ] && ok "the live bundle's bytes are untouched" || bad "the live bundle was overwritten"

CASE="a-failed-earlier-run-is-replaced"
# The same name present but NOT the pointer is a run that died before the flip: replace it.
reset_bucket
printf 'stale' >"$CH/$NAME"
run
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
cmp -s "$BUNDLE" "$CH/$NAME" && ok "the stale object was replaced" || bad "the stale object survived"

# =================================================================================================
CASE="missing-credentials-fail-before-any-work"
reset_bucket
run R2_SECRET_ACCESS_KEY=
[ "$RC" != 0 ] && ok "exit $RC on an empty secret" || bad "exit 0 with an empty secret"
printf '%s' "$ERR" | grep -q 'R2_SECRET_ACCESS_KEY' && ok "names the missing variable" || bad "did not name it: $ERR"
[ ! -s "$W/rauc.log" ] && ok "stopped before the signature gate" || bad "ran rauc first"

# =================================================================================================
# THE PRUNE (step 6). Seeded bundles are 1 byte; nothing here re-uploads them.
CASE="prune-deletes-only-beyond-keep"
reset_bucket
seed 9.9.1 9.9.2 9.9.3 9.9.4 9.9.5     # + the published 9.9.9 = six, KEEP=3
run
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
have 9.9.1 || have 9.9.2 || have 9.9.3 \
  && bad "the three oldest bundles were not pruned" \
  || ok "pruned the three oldest"
have 9.9.4 && have 9.9.5 && have 9.9.9 \
  && ok "kept exactly the newest KEEP=3" \
  || bad "pruned inside the retention budget"
[ -f "$CH/latest.json" ] \
  && ok "latest.json is not swept up by the retroforge-*.raucb filter" \
  || bad "the prune deleted latest.json"

CASE="prune-spares-the-bundle-the-pointer-names"
# THE CASE THE GUARD EXISTS FOR: a deliberate roll-back publish, re-shipping a known-good earlier
# version to a fleet on a bad one. It sorts OLDEST, so without the guard the publish would delete
# the very file its own latest.json had just started pointing at.
reset_bucket
seed 9.9.10 9.9.11 9.9.12 9.9.13       # all sort ABOVE the published 9.9.9
run
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
have 9.9.9 \
  && ok "the just-published bundle survives despite sorting oldest" \
  || bad "pruned the bundle latest.json names -- the fleet's update path is down"
have 9.9.10 \
  && bad "9.9.10 was inside the delete set and should have gone" \
  || ok "still prunes the others in the delete set"
have 9.9.11 && have 9.9.12 && have 9.9.13 \
  && ok "the newest KEEP=3 are untouched" \
  || bad "pruned inside the retention budget"

CASE="keep-0-disables-the-prune"
# The only off switch; an operator reaching for it mid-incident wants nothing deleted.
reset_bucket
seed 9.9.1 9.9.2 9.9.3 9.9.4 9.9.5
run RETROFORGE_OTA_KEEP=0
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
have 9.9.1 && have 9.9.2 && have 9.9.3 && have 9.9.4 && have 9.9.5 \
  && ok "nothing was pruned" \
  || bad "KEEP=0 still deleted bundles"

# =================================================================================================
printf '\ntest-publish-bundle.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
