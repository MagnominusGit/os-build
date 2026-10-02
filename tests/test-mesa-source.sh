#!/usr/bin/env bash
# Offline check for the mesa source fetch (packages/mesa/fetch-source.sh).
#
#   tests/test-mesa-source.sh
#
# WHY THIS EXISTS. The host driver (packages/mesa, via makepkg) has to survive upstream being down,
# which it was for over half an hour on 2026-08-23. packages/mesa/fetch-source.sh pre-seeds the
# tarball from a verified mirror; this file guards that path and its hash check.
#
# The tarball's integrity story is the other thing worth guarding. The sha256 in the PKGBUILD was
# verified against upstream's PGP signature by hand (see the provenance note there); the mirror is
# NOT trusted, it is checked against that same hash. A fetcher that stopped verifying would turn a
# convenience into a supply-chain hole, silently.
#
# Runs on the host with no root, no device, no build and no network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH="$ROOT/packages/mesa/fetch-source.sh"
MIRROR_PIN="$ROOT/packages/mesa/mirror.pin"
SOURCE_PIN="$ROOT/packages/mesa/source.pin"
PKGBUILD="$ROOT/packages/mesa/PKGBUILD"
OVERLAY="$ROOT/packages/build-overlay.sh"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$FETCH" "$MIRROR_PIN" "$SOURCE_PIN" "$PKGBUILD" "$OVERLAY"; do
    [[ -f $f ]] || { echo "missing input: $f" >&2; exit 1; }
done

echo "one fetch, verified"

# 1. The helper has to be executable: build-overlay.sh gates its pre-seed on `-x`, so a lost
#    exec bit does not fail, it silently skips the mirror and leaves makepkg to fend for itself.
[[ -x $FETCH ]] \
    && ok "fetch-source.sh is executable (build-overlay.sh's pre-seed is gated on -x)" \
    || bad "fetch-source.sh is not executable -- the makepkg pre-seed would silently skip"

# 4. The makepkg path. makepkg has no mirror fallback of its own, so the only way the host driver
#    gets one is the pre-seed hook in build-overlay.sh.
grep -q 'fetch-source.sh' "$OVERLAY" \
    && ok "build-overlay.sh pre-seeds via a package's fetch-source.sh" \
    || bad "build-overlay.sh has no pre-seed hook -- the HOST mesa build has no mirror"

echo
echo "the mirror is verified, not trusted"

# 5. The hash check is the whole safety argument. Without it a mirror could serve anything.
grep -q 'sha256sum --check --strict' "$FETCH" \
    && ok "the fetched tarball is checked against the PKGBUILD's sha256" \
    || bad "fetch-source.sh does not verify the tarball -- a mirror could serve anything"

# 6. And the hash comes from the PKGBUILD, not from the mirror pin. A fetcher that derived the
#    check from the same file as the URL would be verifying the mirror against itself.
grep -q 'sha256sums\[0\]' "$FETCH" \
    && ok "the expected hash is read from the PKGBUILD (not from mirror.pin)" \
    || bad "fetch-source.sh does not read sha256sums from the PKGBUILD"

# 7. A mismatch must be fatal and must NOT tell the reader to update the pin -- that hash is the
#    end of the PGP trust chain, and "make the error go away" is the wrong instinct here.
grep -q 'Do NOT update the pin to match' "$FETCH" \
    && ok "a hash mismatch is fatal and says not to re-pin around it" \
    || bad "no guard against 'fix' by re-pinning to whatever the mirror served"

echo
echo "the mirror hash stays out of the lock"

# 8. mirror.pin must be its OWN file. packages/inputhash.sh hashes source.pin (comments included)
#    into manifest.lock's qforge rows, so a mirror hash living there would force a full
#    `make relock` -- a re-resolve of every package -- for a value that cannot change the build.
grep -q '^sha512:' "$MIRROR_PIN" \
    && ok "the mirror hash lives in mirror.pin" \
    || bad "mirror.pin declares no sha512"
if grep -q 'mirror_sha512\|src.fedoraproject.org' "$SOURCE_PIN" "$PKGBUILD"; then
    bad "the mirror leaked into source.pin or the PKGBUILD -- both are hashed into manifest.lock, so this forces a relock per refresh"
else
    ok "source.pin and the PKGBUILD are free of mirror data (no relock per mirror refresh)"
fi

# 9. An empty sha512 must degrade to upstream-only rather than build a nonsense URL. That is the
#    state right after a version bump, before Fedora has the new tarball.
grep -q 'MIRROR_URL=""' "$FETCH" && grep -q '\[ -n "\$MIRROR_SHA512" \]' "$FETCH" \
    && ok "an empty mirror hash degrades to upstream-only" \
    || bad "fetch-source.sh would build a mirror URL from an empty hash"

echo
echo "outage behaviour"

# 10. The reason the outage cost ~9 minutes per build was curl's absent connect timeout: three
#     retries sat ~135s each before anyone found out. A fallback nobody reaches in time is not a
#     fallback.
grep -q -- '--connect-timeout' "$FETCH" \
    && ok "a dead host is detected in seconds, not minutes" \
    || bad "no --connect-timeout -- a dead upstream would stall before the mirror is tried"

# 11. Idempotence is what lets the makepkg pre-seed work at all (makepkg skips a source already
#     in the build dir) and what makes a retry after a failed build free.
grep -q 'already present and verified' "$FETCH" \
    && ok "an already-verified tarball is not re-downloaded" \
    || bad "fetch-source.sh re-downloads even when the verified tarball is already there"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
