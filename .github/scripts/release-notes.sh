#!/usr/bin/env bash
# retroforge release notes — what changed since the previous release in the same tag series, written
# for the people flashing or updating a device.
#
#   .github/scripts/release-notes.sh <tag> <ref> <out-file>
#
#   <tag>  the release tag, e.g. card/v0.0.6 or ota/v0.0.6. Only its series (`card/` or `ota/`) and
#          whether it is a pre-release are read: a dispatch with publish:true has no tag yet.
#   <ref>  the commit being released (GITHUB_SHA).
#
# THE MODEL RUNS ON CLOUDFLARE WORKERS AI, the account that already holds the OTA bucket:
#   CF_ACCOUNT_ID  the Cloudflare account id (CI: the CLOUDFLARE_ACCOUNT_ID secret, which R2 uses too)
#   CF_AI_TOKEN    an API token with Workers AI Read + Edit (CI: the CLOUDFLARE_AI_TOKEN secret)
# through its OpenAI-compatible chat endpoint. Override the model with RELEASE_NOTES_MODEL.
# NOT GitHub Models: that was the first choice and it was retired on 2026-07-30, inference API and all.
#
# FREE, AND IT STAYS FREE. The Workers Free plan includes 10,000 neurons a day and answers over that
# with an error, not a bill (pricing page, 2026-11-07). One summary of ~3k tokens in / 500 out on
# mistral-small-3.1 costs ~120 neurons. Cloudflare states it neither trains on nor retains the input
# (workers-ai/platform/data-usage), which matters: these are a private repo's commit messages.
#
# IT NEVER FAILS A RELEASE. Any failure (no token, quota spent, an empty answer) falls back to a
# plain list of commit subjects, with a ::warning:: saying why. A release held up by a summary is
# worse than a release with a list.
#
# THE INPUT IS CAPPED, so the cost per release stays flat however long the gap since the last one:
# each commit goes in as its subject plus the first paragraph of its body, cut at LOG_CAP characters.
# The commit bodies here are long and explain the WHY; the first paragraph is where the user-visible
# change usually is.
set -euo pipefail

TAG="${1:?usage: $0 <tag> <ref> <out-file>}"
REF="${2:?usage: $0 <tag> <ref> <out-file>}"
OUT="${3:?usage: $0 <tag> <ref> <out-file>}"
MODEL="${RELEASE_NOTES_MODEL:-@cf/mistralai/mistral-small-3.1-24b-instruct}"
ENDPOINT="${RELEASE_NOTES_ENDPOINT:-https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID:-}/ai/v1/chat/completions}"
LOG_CAP="${RELEASE_NOTES_LOG_CAP:-24000}"
PARA_CAP=600

warn() { echo "::warning::release notes: $*" >&2; }

series="${TAG%%/*}"
# The previous release in the same series, reachable from this commit and not this commit itself
# (`$REF^`, so a re-run from the tag does not find itself). A stable release compares against the
# previous STABLE one, so its notes cover everything its users have not had, betas included; a beta
# compares against whatever came last.
case "$TAG" in
  *-*) exclude=() ;;
  *)   exclude=(--exclude "$series/v*-*") ;;
esac
prev="$(git describe --tags --abbrev=0 --match "$series/v*" "${exclude[@]}" "$REF^" 2>/dev/null || true)"
if [ -n "$prev" ]; then
  range="$prev..$REF"
else
  range="$REF"
  warn "no earlier $series/ tag reachable from $REF; summarising its last 50 commits"
fi

# One record per commit: subject, then the first paragraph of the body, capped.
log="$(git log --no-merges --max-count=200 --format='%h%x1f%s%x1f%b%x1e' $range \
  | awk -v RS='\x1e' -v FS='\x1f' -v cap="$PARA_CAP" '
      NF >= 2 {
        sha = $1; gsub(/^[ \n]+/, "", sha)
        body = $3; sub(/^[ \n]+/, "", body)
        n = index(body, "\n\n"); if (n) body = substr(body, 1, n - 1)
        gsub(/\n/, " ", body)
        if (length(body) > cap) body = substr(body, 1, cap) "..."
        printf "- %s %s\n", sha, $2
        if (body != "") printf "  %s\n", body
      }')"
[ -n "$prev" ] || log="$(printf '%s\n' "$log" | awk '/^- /{n++} n<=50')"
subjects="$(git log --no-merges --max-count=200 --format='- %s' $range)"
[ -n "$prev" ] || subjects="$(printf '%s\n' "$subjects" | head -50)"

if [ -z "$subjects" ]; then
  echo "No changes since ${prev:-the previous release}." >"$OUT"
  exit 0
fi
if [ "${#log}" -gt "$LOG_CAP" ]; then
  log="$(printf '%s\n' "$subjects" | head -c "$LOG_CAP")"
fi

fallback() {
  warn "$1; using the commit list"
  {
    echo "### Changes since ${prev:-the start}"
    echo
    printf '%s\n' "$subjects"
  } >"$OUT"
  exit 0
}

[ -n "${CF_AI_TOKEN:-}" ] || fallback "no CF_AI_TOKEN (the CLOUDFLARE_AI_TOKEN secret)"
[ -n "${CF_ACCOUNT_ID:-}" ] || [ -n "${RELEASE_NOTES_ENDPOINT:-}" ] || fallback "no CF_ACCOUNT_ID (the CLOUDFLARE_ACCOUNT_ID secret)"
command -v jq >/dev/null || fallback "jq is not installed"

system='You write release notes for RetroForge, a Linux OS for ARM handheld game consoles (Qualcomm Snapdragon handhelds from AYN, AYANEO, Retroid, Anbernic, Mangmi, KONKR and others). You are given the commit log since the previous release, in Conventional Commits form (feat, fix, perf, ...; the scope is in parentheses).

Write Markdown release notes for the people who use these devices:
- Use only these level-3 sections, in this order, and leave out any that would be empty: "### New", "### Fixes", "### Devices" (support for a specific handheld or SoC: displays, audio, Wi-Fi, firmware, suspend), "### Under the hood" (performance or size changes a user would notice).
- One short bullet per user-visible change, in plain words. Merge commits that describe one change. Name the device when a change is specific to one.
- Leave out CI, workflow, test, build-system, packaging-pin, relock and documentation-only commits, and internal refactors with no visible effect.
- Do not invent anything the commits do not say. No version number, no title, no preamble, no closing remarks.'

body="$(jq -n --arg model "$MODEL" --arg system "$system" \
  --arg user "Release ${TAG#*/}. Commits since ${prev:-the start}:"$'\n\n'"$log" \
  '{model: $model, temperature: 0.2, max_tokens: 1500,
    messages: [{role: "system", content: $system}, {role: "user", content: $user}]}')"

resp="$(curl -sS --max-time 120 -w '\n%{http_code}' "$ENDPOINT" \
  -H "Authorization: Bearer $CF_AI_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$body" 2>&1)" || fallback "request to Workers AI failed: $(printf '%s' "$resp" | tail -c 300)"
code="$(printf '%s' "$resp" | tail -n1)"
resp="$(printf '%s' "$resp" | sed '$d')"
[ "$code" = 200 ] || fallback "Workers AI answered HTTP $code: $(printf '%s' "$resp" | tr '\n' ' ' | head -c 300)"

# OpenAI-shaped from this endpoint; the native /ai/run shape ({result: {response}}) is accepted too,
# so pointing RELEASE_NOTES_ENDPOINT at it needs no other change.
notes="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // .result.response // empty' 2>/dev/null || true)"
[ -n "${notes//[[:space:]]/}" ] || fallback "Workers AI returned no text"

printf '%s\n' "$notes" >"$OUT"
echo "release notes: $MODEL summarised $(printf '%s\n' "$subjects" | wc -l) commits since ${prev:-the start}" >&2
