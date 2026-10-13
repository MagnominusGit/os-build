#!/usr/bin/env bash
# retroforge OTA bundle publisher — puts a signed RAUC bundle in the Cloudflare R2 bucket devices
# update from, and flips the channel pointer at it.
#
#   ota/publish-bundle.sh out/images/retroforge-0.2.0.raucb [channel]
#
# Credentials and the bucket come from the environment only (ota/lib-rclone.sh: R2_ACCOUNT_ID,
# R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET, R2_PUBLIC_BASE). The bucket layout is the one
# retroforge-update reads, rooted at R2_PUBLIC_BASE: <channel>/latest.json and <channel>/<bundle>.
# R2 replaced a self-hosted nginx box on 2026-10-13; the SSH/rsync publisher and the server's
# provisioning scripts are in git history before that date.
#
# THE SIGNATURE GATE RUNS FIRST, BEFORE A BYTE MOVES, and it has no override. A bundle is accepted
# only if it verifies against the CA that is baked into every device's keyring
# (ota/rauc/retroforge-ca.pem, installed as /etc/rauc/keyring.pem by rootfs/assemble-rootfs.sh).
# Publishing an unsigned or dev-cert bundle would not be a near miss: `make bundle` without PKIDIR
# mints an EPHEMERAL 7-day cert that is deleted with its tempdir, so the result is a ~530 MiB download
# every device in the field throws away at the last step, over Wi-Fi, having already asked the user
# to say yes. There is deliberately no --force.
#
# THE VERIFICATION INCANTATION IS NOT OBVIOUS and the obvious one is wrong:
#
#   rauc info --conf=<system.conf> --keyring=<ca.pem> <bundle>     <- correct
#   rauc info --keyring=<ca.pem> <bundle>                          <- FALSE RED
#
# --conf is what supplies check-purpose=codesign. Without it rauc applies its default `smimesign`
# purpose, which accepts only emailProtection or no EKU at all, and rejects our codeSigning release
# cert with "unsuitable certificate purpose" — a bundle that every device would happily install.
# --keyring overrides only [keyring] path=, which names /etc/rauc/keyring.pem: an on-device absolute
# path that does not exist here. Same pair as ota/rauc/verify-signing.sh and docs/RUNBOOK.md.
#
# ORDER OF OPERATIONS IS THE WHOLE DESIGN. The bundle first, then its bytes read back through the
# PUBLIC url and hashed, and latest.json written LAST. A device that checks mid-publish must see
# either the old release or the new one, never a pointer at a URL that 404s or at bytes that did not
# survive the trip. An S3 object appears whole or not at all, so no .part-and-rename is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/build/lib-container.sh"

# Retention, per channel. A bundle is ~530 MiB (measured 2026-10-13) against R2's 10 GB free tier, so
# three per channel leaves room for stable and beta together. Keeping the previous releases is the
# rollback: if a published update turns out bad, re-pointing latest.json at the one before it is the
# fastest fleet-wide fix there is, and it only works if those bytes are still in the bucket.
KEEP="${RETROFORGE_OTA_KEEP:-3}"

BUNDLE="${1:-}"
CHANNEL="${2:-${RETROFORGE_OTA_CHANNEL:-stable}}"

log()  { printf '[publish] %s\n' "$*" >&2; }
die()  { printf '[publish] %s\n' "$*" >&2; exit 1; }

[ -n "$BUNDLE" ] || die "usage: $0 <bundle.raucb> [channel]"
[ -f "$BUNDLE" ] || die "no such bundle: $BUNDLE"
case "$CHANNEL" in
  ''|*[!A-Za-z0-9._-]*) die "channel '$CHANNEL' has characters that do not belong in a URL path" ;;
esac
case "$KEEP" in
  ''|*[!0-9]*) die "RETROFORGE_OTA_KEEP must be a whole number, got '$KEEP'" ;;
esac

BUNDLE_ABS="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")"
NAME="$(basename "$BUNDLE_ABS")"

# Credentials are checked HERE, before the signature gate and the hash, because they are needed
# only from step 3 on: a missing one should cost seconds, not a verification and a full read first.
. "$ROOT/ota/lib-rclone.sh"
r2_env
BASE_URL="${R2_PUBLIC_BASE%/}"
REMOTE="r2:$R2_BUCKET/$CHANNEL"

# --- 1. the signature gate -----------------------------------------------------------------------
CONF_REL="rootfs/overlay/etc/rauc/system.conf"
KEYRING_REL="ota/rauc/retroforge-ca.pem"
[ -f "$ROOT/$CONF_REL" ]    || die "no $CONF_REL — run this from the retroforge tree"
[ -f "$ROOT/$KEYRING_REL" ] || die "no $KEYRING_REL — run this from the retroforge tree"

# rauc is not a host tool here (it is version-pinned in build/Dockerfile precisely so the bundle
# WRITER and the device's installer cannot drift), so fall back to the build container.
#
# NOTE THE `-c`: retroforge-build's ENTRYPOINT is /bin/bash, so `docker run <img> rauc ...` runs
# `bash rauc ...` and bash tries to SOURCE the binary — "cannot execute binary file", which reads
# like a broken image and is not. Everything else in the repo passes it shell scripts, so this is the
# first caller that has to know.
rauc_info() { # <extra rauc args...>  — the bundle path is resolved per backend, not by the caller
  if command -v rauc >/dev/null 2>&1; then
    ( cd "$ROOT" && rauc info --conf="$CONF_REL" --keyring="$KEYRING_REL" "$@" "$BUNDLE_ABS" )
  else
    command -v "$RETROFORGE_CONTAINER" >/dev/null 2>&1 || die "neither rauc nor $RETROFORGE_CONTAINER is available; cannot verify the signature, so nothing will be published"
    # The bundle's directory is mounted read-only at /bundle so a path outside the repo still works.
    ctr run --rm -v "$ROOT":/src -v "$(dirname "$BUNDLE_ABS")":/bundle:ro -w /src retroforge-build \
      -c "rauc info --conf=$CONF_REL --keyring=$KEYRING_REL $* /bundle/$(printf %q "$NAME")"
  fi
}

log "verifying $NAME against the device keyring ($KEYRING_REL, through $CONF_REL)"
if ! chain="$(rauc_info 2>&1)"; then
  printf '%s\n' "$chain" | sed 's/^/         /' >&2
  die "REFUSED: $NAME does not verify against the keyring every device carries.
  A bundle that fails here fails on the device too, after a multi-gigabyte download the user agreed
  to. If this says 'unsuitable certificate purpose' the --conf above was not applied; if it says
  'signature verification failed' the bundle was signed with a dev cert — rebuild with
  PKIDIR=\$HOME/retroforge-pki make bundle."
fi
log "ok: $(printf '%s\n' "$chain" | grep -m1 'Verified.*signature' | sed 's/^ *//')"

# --- 2. identity, read out of the bundle ----------------------------------------------------------
# Not from the caller, not from the build tree, not from the filename. Same principle as Phase 2:
# genbundle.sh reads the version out of the image it wraps, and this reads it back out of the bundle
# that image is inside. The name a release is published under can then never be one it does not
# carry. `shell` output rather than json so this needs no jq, and so [meta.retroforge] fields surface
# through the same parser if the bundle carries them.
meta="$(rauc_info --output-format=shell 2>/dev/null)" || die "could not read the bundle manifest"
mf() { printf '%s\n' "$meta" | sed -n "s/^$1='\(.*\)'$/\1/p" | tail -1; }

VERSION="$(mf RAUC_MF_VERSION)"
COMPATIBLE="$(mf RAUC_MF_COMPATIBLE)"
# Decorative, and absent from bundles built before the Phase 2 manifest gained [meta.retroforge]. The
# client identifies an update by `version` alone (genbundle.sh guarantees it is never empty and never
# the literal `dev`), so these two are for a human reading latest.json, not for the update logic.
BUILD="$(mf RAUC_META_RETROFORGE_BUILD)"
GIT="$(mf RAUC_META_RETROFORGE_GIT)"
MODE="$(mf RAUC_META_RETROFORGE_MODE)"

[ "$COMPATIBLE" = retroforge ] || die "bundle compatible is '$COMPATIBLE', not 'retroforge' — no device would install it"

# THE SECOND GATE, and the signature does not imply it. A dev image carries Wi-Fi credentials and an
# authorized_keys, and `RETROFORGE_DEV=1 PKIDIR=~/retroforge-pki make bundle` — the normal, correct way
# to build a bundle for testing on your own hardware — produces one signed with the REAL release key.
# To a signature check that is indistinguishable from a shippable release, because the signature is
# over the bytes and says nothing about their provenance. Only the mode stamp the payload carries can
# tell them apart.
#
# Empty is REFUSED, not waved through: an image assembled before this field existed cannot answer the
# question, and "cannot answer" has to mean no. Re-assemble it — the answer is a property of the
# build, so there is nothing to add after the fact.
case "$MODE" in
  release) ;;
  dev) die "REFUSED: this bundle's payload was built as a DEV image (mode=dev).
  A dev image carries Wi-Fi credentials and an authorized_keys, and it is signed with the same
  release key as a shippable one, so nothing downstream would catch this. Build without
  RETROFORGE_DEV=1 — note that release builds are CI's job (see .github/workflows/image.yml)." ;;
  *) die "REFUSED: this bundle does not say how it was built (mode='${MODE:-<absent>}').
  Bundles assembled before the mode stamp existed cannot answer it, and 'cannot answer' means no.
  Re-assemble the rootfs and re-bundle; the answer is a property of the build, not metadata that
  can be added afterwards." ;;
esac
case "$VERSION" in
  ''|*[!A-Za-z0-9._+-]*) die "bundle version '$VERSION' is not usable as a filename or URL segment" ;;
esac
# The client builds the download URL from latest.json's `bundle` field and nothing else, so the file
# on the server has to be named for the version inside it. genbundle.sh already names it this way;
# this catches a hand-renamed file, which would otherwise publish a pointer at a 404.
[ "$NAME" = "retroforge-$VERSION.raucb" ] || die "filename/version mismatch: '$NAME' should be 'retroforge-$VERSION.raucb'
  The version comes from inside the bundle; renaming the file does not change it."

SIZE="$(stat -c %s "$BUNDLE_ABS")"
log "computing sha256 over $((SIZE / 1024 / 1024)) MiB"
SHA="$(sha256sum "$BUNDLE_ABS" | cut -d' ' -f1)"
log "publishing v$VERSION (mode $MODE${BUILD:+, build $BUILD}${GIT:+, git $GIT}) to $BASE_URL/$CHANNEL/"

RCLONE="$(rclone_bin)"

# The pointer as the bucket holds it now, read through the API rather than the public url so no CDN
# cache can stand between this and the truth. Empty ONLY when the channel provably has no
# latest.json: `rclone cat` fails the same way for a missing object, a 403 and a dropped connection,
# and treating all of those as "absent" would wave the immutability check below through on a
# transient error. So a failed read is followed by a listing, and anything but a clean "not there"
# stops the publish. Exit 3 from lsf is rclone's "directory not found": a channel never published.
current_pointer() {
  local out listing rc=0
  if out="$("$RCLONE" cat "$REMOTE/latest.json" 2>/dev/null)"; then
    printf '%s\n' "$out" | sed -n 's/.*"bundle": *"\([^"]*\)".*/\1/p' | head -1
    return 0
  fi
  listing="$("$RCLONE" lsf --files-only "$REMOTE/" 2>/dev/null)" || rc=$?
  if [ "$rc" = 3 ] || { [ "$rc" = 0 ] && ! printf '%s\n' "$listing" | grep -qx 'latest.json'; }; then
    return 0
  fi
  die "cannot read $CHANNEL/latest.json, and the bucket does not say it is absent (lsf exit $rc).
  Refusing to go on: without the current pointer the publish cannot tell whether $NAME is already
  live. Check the R2 credentials and endpoint, then re-run."
}

# --- 3. upload -------------------------------------------------------------------------------------
# A VERSION IS PUBLISHED ONCE. Overwriting the bundle latest.json already names would swap the bytes
# under devices that may be mid-download (rauc streams with Range requests), so that is refused. A
# bundle that exists but is NOT the pointer is a previous run that died before the flip, and is
# simply replaced.
live="$(current_pointer)" || exit 1
[ "$live" != "$NAME" ] || die "REFUSED: $NAME is what $CHANNEL/latest.json already points at.
  A published version is immutable: devices may be downloading it right now. Bump the version."

log "uploading $NAME -> $REMOTE/ (multipart, resumable per part)"
"$RCLONE" copyto --s3-chunk-size 64M --retries 5 --low-level-retries 10 \
  --stats 30s --stats-one-line \
  "$BUNDLE_ABS" "$REMOTE/$NAME" || die "upload failed; latest.json was NOT touched, so the fleet still sees the previous release"

# --- 4. prove the PUBLIC bytes are the bytes we hashed -----------------------------------------------
# $SHA is computed from the LOCAL file, so without this step the sha256 that goes into latest.json is
# a claim about this machine's copy, not the one being served. And the client does not check sha256
# (docs/ota.md: the RAUC signature is the integrity gate), so nothing else between here and each
# device's own signature verification would notice — after every device on the channel has spent the
# download. Read back through R2_PUBLIC_BASE, the way a device will, so the same pass also proves
# public access is on and catches a CDN serving a stale object under this name.
#
# BEFORE the pointer flip, deliberately: everything up to step 5 is invisible to devices, so a failure
# here leaves the fleet on the previous release. The bad object stays in the bucket under its final
# name, where it serves nobody because latest.json does not name it; the next run replaces it.
url="$BASE_URL/$CHANNEL/$NAME"
log "verifying public readability: $url"
code="$(curl -fsS -o /dev/null -w '%{http_code}' -r 0-0 --max-time 30 "$url" || true)"
case "$code" in
  206) log "ok: 206 Partial Content (public, and Range works — rauc streams the bundle with it)" ;;
  200) die "the bundle is public but Range is NOT honoured (200 rather than 206) at $url
  rauc streams a bundle with Range requests, so devices could not install it. latest.json was NOT
  flipped. Check what sits in front of the bucket (a custom domain's cache or transform rules)." ;;
  *)   die "the uploaded bundle is NOT publicly readable (HTTP ${code:-no response}) at $url
  The bytes are in the bucket, so this is an access setting, not a failed upload. Enable public
  access on '$R2_BUCKET' (R2 -> bucket -> Settings -> Public access), or check R2_PUBLIC_BASE.
  latest.json was NOT flipped, so the fleet still sees the previous release." ;;
esac

log "verifying the served bytes (sha256 over the public url, ~$((SIZE / 1024 / 1024)) MiB)"
served_sha="$(curl -fsS --max-time 1800 "$url" | sha256sum | cut -d' ' -f1)" || served_sha=""
[ -n "$served_sha" ] || die "could not read $url back — refusing to publish a pointer at bytes nobody has checked"
[ "$served_sha" = "$SHA" ] || die "CORRUPT OR STALE: $url does not serve what was uploaded.
  local:  $SHA
  served: $served_sha
  latest.json was NOT flipped, so the fleet is unaffected and still sees the previous release.
  If a custom domain fronts the bucket, purge its cache for this url; otherwise re-run."
log "ok: the public url serves the bytes that were hashed"

# --- 5. flip the pointer, last ---------------------------------------------------------------------
# Everything above this line is invisible to devices. This is the line that publishes.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
# if/fi rather than `[ -n "$BUILD" ] && printf`: under `set -e` an AND-list whose test fails takes
# the whole script down, so the terse form would abort every publish of a bundle without meta.
{
  printf '{\n'
  printf '  "version": "%s",\n' "$VERSION"
  if [ -n "$BUILD" ]; then printf '  "build": "%s",\n' "$BUILD"; fi
  if [ -n "$GIT" ];   then printf '  "git": "%s",\n'   "$GIT";   fi
  printf '  "bundle": "%s",\n' "$NAME"
  printf '  "size": %s,\n' "$SIZE"
  printf '  "sha256": "%s"\n' "$SHA"
  printf '}\n'
} >"$tmp"

# NO-CACHE, because this one object changes in place and a cached copy is a fleet that cannot see a
# release (or, after a rollback, one still being offered the bad one). The bundles never change once
# published, so they keep whatever caching the bucket or domain applies.
"$RCLONE" copyto --retries 5 \
  --header-upload "Cache-Control: no-cache" --header-upload "Content-Type: application/json" \
  "$tmp" "$REMOTE/latest.json" || die "could not write latest.json; the bundle is uploaded and verified, so re-running is safe"

# Read it back over HTTPS — the same way a device will. This is what catches a caching layer or an
# R2_PUBLIC_BASE that is not the bucket being written.
log "reading latest.json back over HTTPS"
served="$(curl -fsS --max-time 30 "$BASE_URL/$CHANNEL/latest.json" || true)"
[ -n "$served" ] || die "latest.json was written but does not come back from $BASE_URL/$CHANNEL/latest.json"
if ! printf '%s' "$served" | grep -q "\"bundle\": \"$NAME\""; then
  printf '%s\n' "$served" | sed 's/^/         /' >&2
  die "the served latest.json does not name $NAME — something is serving a stale or different file"
fi
log "published: $url"

# --- 6. prune --------------------------------------------------------------------------------------
# Within this channel only, so a run of betas can never evict the stable release. Never the bundle
# just published, which latest.json now names (step 5 read that back) — it sorts OLDEST in a
# deliberate roll-back publish of an earlier version, and deleting it would leave the pointer dangling.
# A failed prune does not fail the publish: the release is already live.
if [ "$KEEP" -ge 1 ]; then
  mapfile -t old < <("$RCLONE" lsf --files-only --include 'retroforge-*.raucb' "$REMOTE/" 2>/dev/null | sort -V)
  n=${#old[@]}
  if [ "$n" -gt "$KEEP" ]; then
    for f in "${old[@]:0:$((n - KEEP))}"; do
      [ "$f" = "$NAME" ] && continue
      log "pruning $CHANNEL/$f"
      "$RCLONE" deletefile "$REMOTE/$f" || log "could not prune $CHANNEL/$f (continuing — the publish itself succeeded)"
    done
  fi
fi

log "devices on channel '$CHANNEL' will be offered v$VERSION on their next check"
