#!/usr/bin/env bash
# Offline check that the tree carries retroforge's name, not the one it was derived from.
#
#   tests/test-upstream-name.sh
#
# WHY THIS EXISTS. retroforge started from a copy of NovaDeck's build tree, and the old name was in
# ~5000 places: file names, D-Bus names, units, labels, env vars. A leftover is not cosmetic — a
# unit that still names /usr/lib/novadeck/ points at a path that no longer exists, and nothing
# fails until that unit runs on a device. So every mention is an error, except ATTRIBUTION, which
# must stay exactly as written:
#
#   - patch author lines (From:/Signed-off-by:/Co-developed-by:) and copyright lines may name the
#     upstream project in any spelling — rewriting them would misattribute the work;
#   - 'Nova-Deck' (the upstream GitHub org) may name the repos we still pull from (qcom-firmwares,
#     steamos-efi) and appear in copyright/author lines, but a link to the upstream PROJECT
#     (Nova-Deck/os-build) belongs only in README.md's acknowledgement.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="tests/test-upstream-name.sh"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# A grep -n line ("file:line:text") whose text is attribution, in any of the forms above.
ATTRIBUTION='^[^:]+:[0-9]+:[+ -]?[[:space:]]*(From|Signed-off-by|Co-developed-by):|^[^:]+:[0-9]+:.*[Cc]opyright'

cd "$ROOT" || exit 1
# Tracked-or-not, but never the reference copy, the git dir or build outputs.
mapfile -t FILES < <(find . \( -path ./_ref -o -path ./.git -o -path ./out -o -path ./work \) -prune \
                       -o \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort)

echo "names"
paths="$(printf '%s\n' "${FILES[@]}" | grep -v -x -F "$SELF" | grep -i 'novadeck' || true)"
if [ -z "$paths" ]; then
  ok "no file or directory is named novadeck"
else
  bad "paths still named novadeck:"
  printf '       %s\n' $paths
fi

echo
echo "contents"
hits="$(printf '%s\0' "${FILES[@]}" | grep -v -z -x -F "$SELF" \
        | xargs -0 grep -InE '[Nn][Oo][Vv][Aa][Dd][Ee][Cc][Kk]' 2>/dev/null \
        | grep -vE "$ATTRIBUTION" || true)"
if [ -z "$hits" ]; then
  ok "no file mentions novadeck (any case) outside attribution lines"
else
  bad "novadeck still mentioned:"
  printf '%s\n' "$hits" | cut -c1-160 | sed 's/^/       /'
fi

proj="$(printf '%s\0' "${FILES[@]}" | grep -v -z -x -F "$SELF" | grep -v -z -x -F README.md \
        | xargs -0 grep -InF 'Nova-Deck/os-build' 2>/dev/null || true)"
if [ -z "$proj" ]; then
  ok "the upstream project (Nova-Deck/os-build) is linked only from README.md's acknowledgement"
else
  bad "links to the upstream project outside README.md:"
  printf '%s\n' "$proj" | cut -c1-160 | sed 's/^/       /'
fi

# The acknowledgement is required, not merely allowed: the tree is GPL-2.0-or-later work derived
# from NovaDeck, and its notices travel with it.
if grep -qF 'Nova-Deck' README.md 2>/dev/null; then
  ok "README.md still acknowledges where this tree came from"
else
  bad "README.md no longer acknowledges NovaDeck — the derived-work notice is required"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
